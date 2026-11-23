-- ============================================================
-- Migration 13 — Connexion par email + code à usage unique
--
-- La connexion ne se fait plus par mot de passe : l'utilisateur
-- saisit l'adresse email d'un membre, la base génère un code à
-- 6 chiffres à usage unique et l'envoie sur cette adresse (Edge
-- Function « login-code », secret partagé de la migration 12).
-- La validité du code est paramétrable dans Supabase :
--   update app_settings set value = '15'    -- minutes
--     where key = 'otp_validity_minutes';
-- (cette ligne est créée ci-dessous, éditable aussi via le
--  Table Editor).
--
-- Le rôle est porté par le MEMBRE : members.role in ('user','admin').
-- Seuls les membres « admin » ont les pouvoirs admin ; tous les
-- autres membres sont des « user » :
--   update members set role = 'admin' where id = '<uuid>';
-- (ou via le site : fiche membre → bouton admin)
--
-- Nettoyage : app_users et les fonctions de connexion par mot de
-- passe sont supprimées ; les sessions pointent désormais sur le
-- membre (auth_sessions.member_id).
--
-- À exécuter dans le SQL Editor de Supabase, après les migrations
-- 10 à 12.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Rôle porté par le membre.
-- ------------------------------------------------------------
alter table members
  add column if not exists role text not null default 'user'
    check (role in ('user', 'admin'));

-- ------------------------------------------------------------
-- 2. Paramètre de validité des codes (minutes).
-- ------------------------------------------------------------
insert into app_settings (key, value)
values ('otp_validity_minutes', '10')
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 3. Table des codes à usage unique.
-- ------------------------------------------------------------
create table if not exists login_codes (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references members (id) on delete cascade,
  email        text not null,
  code_hash    text not null,
  attempts     int  not null default 0,
  request_ip   text not null default 'inconnu',
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null
);

create index if not exists idx_login_codes_email on login_codes (lower(email));
create index if not exists idx_login_codes_created on login_codes (created_at);

alter table login_codes enable row level security; -- aucune policy

-- 4. Journal des tentatives : distinction mot de passe / code.
alter table auth_attempts
  add column if not exists kind text not null default 'password';
create index if not exists idx_auth_attempts_kind_ip
  on auth_attempts (kind, ip, attempted_at);

-- ------------------------------------------------------------
-- 5. Sessions rattachées au membre (et rôles user/admin).
--    Les sessions d'un membre supprimé sont retirées en cascade.
-- ------------------------------------------------------------
alter table auth_sessions drop constraint if exists auth_sessions_user_id_fkey;
alter table auth_sessions drop constraint if exists auth_sessions_role_check;
alter table auth_sessions
  add column if not exists member_id uuid references members (id) on delete cascade;
alter table auth_sessions drop column if exists user_id;
alter table auth_sessions
  add constraint auth_sessions_role_check
    check (role in ('user', 'admin'));
create index if not exists idx_auth_sessions_member on auth_sessions (member_id);

-- Les anciens rôles « viewer » éventuels deviennent « user ».
update auth_sessions set role = 'user' where role = 'viewer';

-- ------------------------------------------------------------
-- 6. Envoi du code par email (pg_net → Edge Function « login-code »).
-- ------------------------------------------------------------
create or replace function send_code_email(p_email text, p_code text, p_minutes int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_url     text := 'https://bzpjyaajphhdtmdbugat.supabase.co/functions/v1/login-code';
  v_key     text := 'sb_publishable_hXG9LBkkCzyFVrF6zKYAsg_0vSIOain';
  v_secret  text;
  v_body    jsonb;
  v_headers jsonb;
begin
  select value into v_secret from app_secrets where key = 'edge_shared_secret';
  if v_secret is null or length(v_secret) = 0 then
    return; -- secret non installé : pas d'envoi possible
  end if;

  v_body := jsonb_build_object(
    'email', p_email,
    'code', p_code,
    'minutes', p_minutes,
    'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'apikey', v_key,
    'Authorization', 'Bearer ' || v_key,
    'x-webhook-secret', v_secret
  );

  begin
    perform net.http_post(
      v_url,
      v_body,
      '{}'::jsonb,
      v_headers,
      5000
    );
  exception when others then
    null; -- l'envoi ne doit jamais bloquer la demande de code
  end;
end $$;

-- ------------------------------------------------------------
-- 7. Demande de code : vérifie l'email d'un membre, génère et envoie
--    un code à usage unique. Garde-fous :
--    - un seul code actif par email (le nouveau remplace l'ancien) ;
--    - 60 s minimum entre deux envois pour la même adresse ;
--    - 10 envois max par adresse et par heure ;
--    - 30 envois max par IP et par 15 minutes (anti-spam d'emails).
-- ------------------------------------------------------------
create or replace function request_login_code(p_email text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_email    text := lower(trim(coalesce(p_email, '')));
  v_member   members%rowtype;
  v_ip       text := client_ip();
  v_minutes  int;
  v_code     text;
begin
  -- Purge des codes anciens (> 1 jour).
  delete from login_codes where created_at < now() - interval '1 day';

  if v_email = ''
     or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Adresse email invalide';
  end if;

  -- Anti-spam IP : 30 demandes / 15 minutes et par IP.
  if (
    select count(*) from login_codes
    where request_ip = v_ip
      and created_at > now() - interval '15 minutes'
  ) >= 30 then
    raise exception 'Trop de demandes de code. Réessayez plus tard.';
  end if;

  -- L'email doit correspondre à exactement un membre.
  select * into v_member
  from members
  where lower(trim(coalesce(email, ''))) = v_email;
  if not found then
    raise exception 'Aucun membre ne correspond à cette adresse email';
  end if;
  if (
    select count(*) from members
    where lower(trim(coalesce(email, ''))) = v_email
  ) > 1 then
    raise exception 'Plusieurs membres partagent cette adresse. Contactez un administrateur.';
  end if;

  -- Délai entre deux envois pour la même adresse.
  if exists (
    select 1 from login_codes
    where lower(email) = v_email
      and created_at > now() - interval '60 seconds'
  ) then
    raise exception 'Un code vient d''être envoyé. Attendez une minute avant de redemander.';
  end if;

  -- Plafond horaire par adresse.
  if (
    select count(*) from login_codes
    where lower(email) = v_email
      and created_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'Trop de codes demandés pour cette adresse. Réessayez dans une heure.';
  end if;

  -- Validité paramétrable (app_settings.otp_validity_minutes, minutes).
  begin
    select coalesce(nullif(value, '')::int, 10) into v_minutes
    from app_settings where key = 'otp_validity_minutes';
  exception when others then
    v_minutes := null; -- valeur invalide → défaut
  end;
  if v_minutes is null or v_minutes < 1 then
    v_minutes := 10;
  end if;
  if v_minutes > 1440 then
    v_minutes := 1440; -- au plus 24 h
  end if;

  -- Un seul code actif par adresse : les précédents sont invalidés.
  delete from login_codes where lower(email) = v_email;

  -- Code à 6 chiffres, stocké hashé (jamais en clair en base).
  v_code := lpad('' || (
    ('x' || substr(encode(gen_random_bytes(4), 'hex'), 1, 8))::bit(32)::bigint % 1000000
  ), 6, '0');

  insert into login_codes (member_id, email, code_hash, request_ip, expires_at)
  values (
    v_member.id,
    v_email,
    encode(digest(v_code, 'sha256'), 'hex'),
    v_ip,
    now() + make_interval(mins => v_minutes)
  );

  perform send_code_email(v_member.email, v_code, v_minutes);

  return format('Code envoyé à %s (valable %s minutes).', v_member.email, v_minutes);
end $$;

-- ------------------------------------------------------------
-- 8. Connexion avec le code. Garde-fous :
--    - 5 essais maxi par code (au-delà, le code est invalidé) ;
--    - 15 échecs / 15 minutes par IP → blocage de connexion
--      + email d'alerte aux admins (seuil franchi une seule fois) ;
--    - succès : purge des échecs de l'IP et session ouverte.
-- ------------------------------------------------------------
create or replace function login_with_code(p_email text, p_code text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := lower(trim(coalesce(p_email, '')));
  v_code    text := trim(coalesce(p_code, ''));
  v_row     login_codes%rowtype;
  v_ip      text := client_ip();
  v_fails   int;
  v_role    text;
  v_token   text;
begin
  -- Verrou par IP (tentatives de code) : 15 échecs / 15 minutes.
  select count(*) into v_fails
  from auth_attempts
  where kind = 'code' and not success
    and ip = v_ip
    and attempted_at > now() - interval '15 minutes';
  if v_fails >= 15 then
    raise exception 'Trop de tentatives. Réessayez dans quelques minutes.';
  end if;

  select * into v_row
  from login_codes
  where lower(email) = v_email
  order by created_at desc
  limit 1;

  if not found
     or v_row.expires_at < now()
     or v_row.attempts >= 5
     or v_row.code_hash is distinct from
        encode(digest(v_code, 'sha256'), 'hex') then
    if found then
      update login_codes set attempts = attempts + 1 where id = v_row.id;
      if v_row.attempts + 1 >= 5 then
        delete from login_codes where id = v_row.id;
      end if;
    end if;

    insert into auth_attempts (ip, success, kind) values (v_ip, false, 'code');

    -- Alerte email quand le seuil de blocage est franchi.
    if v_fails + 1 = 15 then
      perform notify_lockout_email('code', v_ip, v_fails + 1);
    end if;

    raise exception 'Code invalide ou expiré';
  end if;

  -- Succès : le code est consommé, journal remis à zéro pour l'IP.
  delete from login_codes where id = v_row.id;
  delete from auth_attempts where ip = v_ip and kind = 'code' and not success;

  select role into v_role from members where id = v_row.member_id;

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into auth_sessions (token_hash, role, member_id)
  values (encode(digest(v_token, 'sha256'), 'hex'), v_role, v_row.member_id);

  return json_build_object('token', v_token, 'role', v_role);
end $$;

-- ------------------------------------------------------------
-- 9. Changement de rôle d'un membre (admin uniquement) ; toutes les
--    sessions ouvertes du membre recalées sur le nouveau rôle.
-- ------------------------------------------------------------
create or replace function set_member_role(p_session_token text, p_member_id uuid, p_role text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs';
  end if;
  if p_role not in ('user', 'admin') then
    raise exception 'Rôle invalide';
  end if;
  if not exists (select 1 from members where id = p_member_id) then
    raise exception 'Membre introuvable';
  end if;
  if p_role = 'user' and (
    select role from members where id = p_member_id
  ) = 'admin' and (
    select count(*) from members
    where role = 'admin' and id <> p_member_id
  ) = 0 then
    raise exception 'Impossible de retirer le dernier administrateur';
  end if;

  update members set role = p_role where id = p_member_id;

  -- Les sessions ouvertes du membre suivent son nouveau rôle.
  update auth_sessions set role = p_role where member_id = p_member_id;
end $$;

-- ------------------------------------------------------------
-- 10. Recréations alignées sur le nouveau modèle.
--     app_username : le nom du membre portant la session.
--     get_members  : ajoute le rôle du membre.
-- ------------------------------------------------------------
create or replace function app_username(p_session_token text)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select m.first_name || ' ' || m.last_name
  from auth_sessions s
  join members m on m.id = s.member_id
  where s.token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and s.expires_at > now()
  limit 1;
$$;

create or replace function get_members(p_session_token text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role text;
begin
  v_role := session_role(p_session_token);
  if v_role is null then
    raise exception 'Session invalide ou expirée';
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
        m.role,
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

-- ------------------------------------------------------------
-- 11. Nettoyage de l'ancien système par mot de passe.
-- ------------------------------------------------------------
drop function if exists app_login(text);
drop function if exists verify_password(text);
drop function if exists list_users(text);
drop function if exists create_user(text, text, text, text);
drop function if exists set_user_password(text, uuid, text);
drop function if exists set_user_active(text, uuid, boolean);
drop function if exists delete_user(text, uuid);
drop table if exists app_users;
