-- ============================================================
-- Migration 07 — Protection contre le brute-force des mots de passe
--
-- Journalisation des tentatives et verrou glissant par IP, appliqué
-- à chaque appel RPC vérifiant le mot de passe : 5 échecs en 15 min
-- depuis la même IP bloquent toute nouvelle tentative pendant le
-- reste de la fenêtre, même avec le bon mot de passe. Un succès
-- remet le compteur à zéro ; les tentatives sont purgées après 2 jours.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create table if not exists auth_attempts (
  id           bigint generated always as identity primary key,
  ip           text not null,
  success      boolean not null,
  attempted_at timestamptz not null default now()
);

alter table auth_attempts enable row level security;

create index if not exists auth_attempts_ip_idx
  on auth_attempts (ip, attempted_at);

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

-- Vérifie le mot de passe avec journalisation et verrou par IP.
create or replace function verify_password(p_password text)
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
  -- Purge des tentatives anciennes.
  delete from auth_attempts where attempted_at < now() - interval '2 days';

  -- Verrou par IP : trop d'échecs récents, on refuse même le bon mot
  -- de passe jusqu'à la fin de la fenêtre glissante de 15 minutes.
  select count(*), max(attempted_at) + interval '15 minutes' - now()
    into v_count, v_wait
  from auth_attempts
  where ip = v_ip
    and not success
    and attempted_at > now() - interval '15 minutes';

  if v_count >= 5 then
    raise exception
      'Trop de tentatives depuis votre connexion. Réessayez dans % minute(s).',
      greatest(1, ceil(extract(epoch from v_wait) / 60))::text;
  end if;

  -- Vérification du mot de passe.
  select role into v_role
  from app_users
  where is_active
    and password_hash = crypt(p_password, password_hash)
  limit 1;

  if v_role is null then
    insert into auth_attempts (ip, success)
    values (v_ip, false);
  else
    -- Succès : remise à zéro des échecs de cette IP.
    delete from auth_attempts where ip = v_ip and not success;
  end if;

  return v_role;
end $$;
