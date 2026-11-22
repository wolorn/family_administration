-- ============================================================
-- Migration 08 — Verrou global + alerte email de blocage
--
-- Complète la migration 07 :
--   - verrou GLOBAL indépendant des IP : 10 échecs en 15 minutes
--     (toutes IP confondues) bloquent toute nouvelle tentative pour
--     tous les clients pendant le reste de la fenêtre, même avec le
--     bon mot de passe ;
--   - lorsqu'un blocage (IP ou global) est déclenché, un email est
--     envoyé aux administrateurs via la fonction Edge
--     "notify-lockout" (pg_net), même stratégie que les notifications
--     de propositions de modification.
--
-- L'appel de notification est tunné dans un bloc exception : un
-- échec d'envoi ne perturbe jamais la protection elle-même.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

-- pg_net : appels HTTP asynchrones depuis Postgres. Le schéma "net"
-- est créé par l'extension elle-même : ne surtout pas le pré-créer
-- (erreur 55000 "schema net is not a member of extension pg_net").
drop extension if exists pg_net;
drop schema if exists net cascade;
create extension if not exists pg_net;

-- Garde-fou : vérifier que la version installée supporte les
-- en-têtes HTTP (arg "headers"), indispensables pour l'authentification
-- de l'appel vers la fonction Edge.
do $$
declare
  v_version text;
begin
  select coalesce(extversion, '(absente)') into v_version
  from pg_extension where extname = 'pg_net';

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on p.pronamespace = n.oid
    where n.nspname = 'net'
      and p.proname = 'http_post'
      and position('timeout_milliseconds' in pg_get_function_identity_arguments(p.oid)) > 0
  ) then
    raise exception
      'pg_net est trop ancien (version %) : net.http_post(url, body, timeout, headers) est indisponible.',
      v_version;
  end if;
end $$;

-- ------------------------------------------------------------
-- Cette migration est AUTONOME : elle recrée le journal des
-- tentatives, client_ip et le verrou par IP de la migration 07
-- (create if not exists / or replace), puis ajoute le verrou global
-- et l'alerte email. Elle peut donc être exécutée seule.
-- ------------------------------------------------------------

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
  with hdr as (
    select case
      when current_setting('request.headers', true) is null
        or btrim(current_setting('request.headers', true)) = ''
        then '[]'::json
      else current_setting('request.headers', true)::json
    end as h
  )
  select coalesce(
    (select split_part(e->>'value', ',', 1)
     from hdr, json_array_elements(hdr.h) e
     where json_typeof(hdr.h) = 'array'
       and lower(e->>'name') = 'x-forwarded-for'
     limit 1),
    (select split_part(kv.value, ',', 1)
     from hdr, json_each_text(hdr.h) kv
     where json_typeof(hdr.h) = 'object'
       and lower(kv.key) = 'x-forwarded-for'
     limit 1),
    'inconnu'
  );
$$;

-- Envoi de l'alerte de blocage aux administrateurs.
create or replace function notify_lockout_email(p_source text, p_ip text, p_failures int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  -- URL de la fonction et clé publique du projet (à ajuster si le
  -- projet change) : voyez js/config.js.
  v_url     text := 'https://bzpjyaajphhdtmdbugat.supabase.co/functions/v1/notify-lockout';
  v_key     text := 'sb_publishable_hXG9LBkkCzyFVrF6zKYAsg_0vSIOain';
  v_body    jsonb := jsonb_build_object(
    'source', p_source,
    'ip', p_ip,
    'failures', p_failures,
    'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  v_headers jsonb := jsonb_build_object(
    'Content-Type', 'application/json',
    'apikey', v_key,
    'Authorization', 'Bearer ' || v_key
  );
  -- Certaines versions de pg_net déclarent http_post avec des
  -- paramètres json et non jsonb : on détecte le type réel de "body".
  v_kind    text;
begin
  begin
    select split_part((string_to_array(pg_get_function_arguments(p.oid), ', '))[2], ' ', 2)
      into v_kind
    from pg_proc p
    join pg_namespace n on p.pronamespace = n.oid
    where n.nspname = 'net'
      and p.proname = 'http_post'
      and position('timeout_milliseconds' in pg_get_function_identity_arguments(p.oid)) > 0
    limit 1;

    if coalesce(v_kind, '') = 'json' then
      perform net.http_post(v_url, v_body::json, 5000, v_headers::json);
    else
      perform net.http_post(v_url, v_body, 5000, v_headers);
    end if;
  exception when others then
    null; -- l'alerte ne doit jamais bloquer la protection
  end;
end $$;

-- verify_password : verrou global + verrou par IP + alerte email.
create or replace function verify_password(p_password text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_ip           text := client_ip();
  v_role         text;
  v_ip_count     int;
  v_global_count int;
  v_wait         interval;
begin
  -- Purge des tentatives anciennes.
  delete from auth_attempts where attempted_at < now() - interval '2 days';

  -- Verrou global (toutes IP) : protecte contre les attaques réparties.
  select count(*), max(attempted_at) + interval '15 minutes' - now()
    into v_global_count, v_wait
  from auth_attempts
  where not success
    and attempted_at > now() - interval '15 minutes';

  if v_global_count >= 10 then
    raise exception
      'Trop de tentatives sur le site. Réessayez dans % minute(s).',
      greatest(1, ceil(extract(epoch from v_wait) / 60))::text;
  end if;

  -- Verrou par IP.
  select count(*), max(attempted_at) + interval '15 minutes' - now()
    into v_ip_count, v_wait
  from auth_attempts
  where ip = v_ip
    and not success
    and attempted_at > now() - interval '15 minutes';

  if v_ip_count >= 5 then
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
    insert into auth_attempts (ip, success) values (v_ip, false);

    -- Un blocage vient de se déclencher : alerte email (seulement au
    -- moment où le seuil est atteint, pas à chaque tentative).
    select count(*) into v_ip_count
    from auth_attempts
    where ip = v_ip and not success
      and attempted_at > now() - interval '15 minutes';

    select count(*) into v_global_count
    from auth_attempts
    where not success
      and attempted_at > now() - interval '15 minutes';

    if v_ip_count = 5 then
      perform notify_lockout_email('ip', v_ip, v_ip_count);
    end if;
    if v_global_count = 10 then
      perform notify_lockout_email('global', v_ip, v_global_count);
    end if;
  else
    -- Succès : remise à zéro des échecs de cette IP.
    delete from auth_attempts where ip = v_ip and not success;
  end if;

  return v_role;
end $$;
