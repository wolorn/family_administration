-- ============================================================
-- Migration 07 — Protection contre le brute-force des mots de passe
--
-- Deux verrous glissants, appliqués à chaque appel RPC vérifiant le
-- mot de passe (via verify_password/verify_login) :
--   - par compte : 5 échecs en 15 min bloquent le compte 15 min
--     (actif quand l'identifiant est saisi sur l'écran de connexion) ;
--   - par IP : 10 échecs en 15 min bloquent l'IP (extraite de
--     l'en-tête X-Forwarded-For transmis par PostgREST).
-- Un succès remise à zéro l'historique du compte/de l'IP. Les
-- tentatives sont purgées au-delà de 2 jours.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create table if not exists auth_attempts (
  id           bigint generated always as identity primary key,
  ip           text not null,
  username     text,
  success      boolean not null,
  attempted_at timestamptz not null default now()
);

alter table auth_attempts enable row level security;

create index if not exists auth_attempts_ip_idx
  on auth_attempts (ip, attempted_at);
create index if not exists auth_attempts_username_idx
  on auth_attempts (username, attempted_at)
  where username is not null;

-- IP cliente : PostgREST transmet les en-têtes via le réglage
-- 'request.headers' (X-Forwarded-For peut être une liste, première
-- entrée = client réel). 'inconnu' si l'en-tête est absent.
create or replace function client_ip()
returns text
language sql
stable
as $$
  select coalesce((
    select split_part(h->>'value', ',', 1)
    from json_array_elements(
      coalesce(current_setting('request.headers', true), '[]'::json)
    ) as h
    where lower(h->>'name') = 'x-forwarded-for'
    limit 1
  ), 'inconnu');
$$;

-- Vérifie l'identifiant/mot de passe avec journalisation et verrous.
-- p_username NULL : seule la correspondance par mot de passe s'applique
-- (comportement historique), protégée par le verrou par IP.
create or replace function verify_login(p_username text, p_password text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_ip    text := client_ip();
  v_role  text;
  v_count int;
  v_wait  interval;
begin
  p_username := nullif(trim(coalesce(p_username, '')), '');

  -- Purge des tentatives anciennes.
  delete from auth_attempts where attempted_at < now() - interval '2 days';

  -- Verrou par compte (identifiant fourni sur l'écran de connexion) :
  -- protège spécifiquement les comptes à mot de passe simple.
  if p_username is not null then
    select count(*), max(attempted_at) + interval '15 minutes' - now()
      into v_count, v_wait
    from auth_attempts
    where username = p_username
      and not success
      and attempted_at > now() - interval '15 minutes';

    if v_count >= 5 then
      raise exception
        'Compte temporairement bloqué (trop de tentatives). Réessayez dans % minute(s).',
        greatest(1, ceil(extract(epoch from v_wait) / 60))::text;
    end if;
  end if;

  -- Verrou par IP (s'applique à tous les appels, même sans identifiant).
  select count(*), max(attempted_at) + interval '15 minutes' - now()
    into v_count, v_wait
  from auth_attempts
  where ip = v_ip
    and not success
    and attempted_at > now() - interval '15 minutes';

  if v_count >= 10 then
    raise exception
      'Trop de tentatives depuis votre connexion. Réessayez dans % minute(s).',
      greatest(1, ceil(extract(epoch from v_wait) / 60))::text;
  end if;

  -- Vérification des identifiants.
  select role into v_role
  from app_users
  where is_active
    and (p_username is null or username = p_username)
    and password_hash = crypt(p_password, password_hash)
  limit 1;

  if v_role is null then
    insert into auth_attempts (ip, username, success)
    values (v_ip, p_username, false);
  else
    -- Succès : remise à zéro des échecs du compte et de l'IP.
    delete from auth_attempts
    where not success
      and (ip = v_ip or (p_username is not null and username = p_username));
  end if;

  return v_role;
end $$;

-- verify_password conservé pour tous les appels RPC existants :
-- délègue à verify_login sans identifiant (verrou par IP + journalisation).
create or replace function verify_password(p_password text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  return verify_login(null, p_password);
end $$;
