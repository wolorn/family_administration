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
begin
  -- La signature installée ici est
  -- http_post(url text, body jsonb, params jsonb, headers jsonb,
  --           timeout_milliseconds int) : aucun paramètre d'URL.
  begin
    perform net.http_post(
      v_url,
      v_body,
      '{}'::jsonb,
      v_headers,
      5000
    );
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

-- ============================================================
-- Recréation des fonctions de lecture en VOLATILE
--
-- La nouvelle verify_password (07) journalise les tentatives de
-- connexion dans auth_attempts (INSERT / DELETE). PostgREST exécute
-- les fonctions STABLE dans une transaction read-only, ce qui fait
-- échouer la journalisation (erreur 25006). Ces fonctions ne
-- téléphonent qu'à verify_password puis lisent : passer en VOLATILE
-- est sans risque fonctionnel et rend la transaction inscriptible.
-- ============================================================

create or replace function get_members(p_password text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role text;
begin
  v_role := verify_password(p_password);
  if v_role is null then
    raise exception 'Mot de passe invalide';
  end if;

  return (
    select coalesce(json_agg(t), '[]'::json)
    from (
      select
        m.id,
        m.last_name,
        m.first_name,
        m.sex,
        m.birth_date,
        m.address,
        m.email,
        m.wedding_date,
        m.death_date,
        (
          select coalesce(json_agg(json_build_object(
            'id', p.id, 'first_name', p.first_name,
            'last_name', p.last_name, 'sex', p.sex,
            'birth_date', p.birth_date
          )), '[]'::json)
          from relationships r
          join members p on p.id = r.parent_id
          where r.child_id = m.id
        ) as parents,
        (
          select coalesce(json_agg(json_build_object(
            'id', c.id, 'first_name', c.first_name,
            'last_name', c.last_name, 'sex', c.sex,
            'birth_date', c.birth_date
          )), '[]'::json)
          from relationships r
          join members c on c.id = r.child_id
          where r.parent_id = m.id
        ) as children,
        (
          select coalesce(json_agg(json_build_object(
            'id', d.id, 'first_name', d.first_name,
            'last_name', d.last_name, 'sex', d.sex,
            'birth_date', d.birth_date
          )), '[]'::json)
          from (
            select distinct s.id, s.first_name, s.last_name, s.sex, s.birth_date
            from relationships r1
            join relationships r2 on r2.parent_id = r1.parent_id
            join members s on s.id = r2.child_id
            where r1.child_id = m.id
              and r2.child_id <> m.id
          ) as d
        ) as siblings,
        (
          select coalesce(json_agg(json_build_object(
            'id', s.id, 'first_name', s.first_name,
            'last_name', s.last_name, 'sex', s.sex,
            'birth_date', s.birth_date
          )), '[]'::json)
          from members s
          where s.id = m.spouse_id
             or s.spouse_id = m.id
        ) as spouse
      from members m
    ) as t
  );
end $$;

create or replace function list_users(p_password text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs';
  end if;
  return coalesce(
    (select json_agg(t)
     from (
       select id, username, role, is_active, created_at
       from app_users
       order by username
     ) as t),
    '[]'::json
  );
end $$;

create or replace function list_proposals(p_password text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs';
  end if;

  return coalesce((
    select json_agg(json_build_object(
      'id', p.id,
      'member_id', p.member_id,
      'member_name', coalesce(
        m.first_name || ' ' || m.last_name,
        (p.payload->>'first_name') || ' ' || (p.payload->>'last_name'),
        'Nouveau membre'
      ),
      'proposed_by', p.proposed_by,
      'payload', p.payload,
      'created_at', p.created_at
    ) order by p.created_at)
    from member_proposals p
    left join members m on m.id = p.member_id
    where p.status = 'pending'
  ), '[]'::json);
end $$;
