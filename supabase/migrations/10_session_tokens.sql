-- ============================================================
-- Migration 10 — Sessions à token (fin du mot de passe en clair)
--
-- Le mot de passe n'est plus transmis qu'une fois, à la connexion
-- (app_login). Toutes les fonctions RPC reçoivent ensuite un token
-- de session opaque (256 bits, stocké hashé en SHA-256), expirable
-- (24 h glissantes) et révocable côté serveur (app_logout,
-- désactivation ou changement de mot de passe du compte).
--
-- Sessions révoquées automatiquement quand :
--   - l'utilisateur se déconnecte (app_logout) ;
--   - le mot de passe du compte change (set_user_password) ;
--   - le compte est désactivé (set_user_active) ou supprimé.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create table if not exists auth_sessions (
  id           uuid primary key default gen_random_uuid(),
  token_hash   text not null unique,
  role         text not null check (role in ('viewer', 'admin')),
  user_id      uuid not null references app_users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  expires_at   timestamptz not null
);

create index if not exists idx_auth_sessions_expires on auth_sessions (expires_at);
create index if not exists idx_auth_sessions_user on auth_sessions (user_id);

alter table auth_sessions enable row level security;

-- ------------------------------------------------------------
-- session_role : valide le token, fait glisser l'expiration
-- (24 h après chaque usage) et refuse les comptes désactivés.
-- Renvoie le rôle, ou NULL si session absente/expirée/révoquée.
-- ------------------------------------------------------------
create or replace function session_role(p_session_token text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role text;
begin
  if p_session_token is null or p_session_token = '' then
    return null;
  end if;

  update auth_sessions s
     set last_used_at = now(),
         expires_at   = now() + interval '24 hours'
    from app_users u
   where u.id = s.user_id
     and u.is_active
     and s.token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
     and s.expires_at > now()
   returning s.role into v_role;

  return v_role;
end $$;

-- ------------------------------------------------------------
-- app_login : vérifie le mot de passe (avec la protection anti
-- brute-force de la migration 08) puis ouvre une session.
-- Renvoie { token, role, username }.
-- ------------------------------------------------------------
create or replace function app_login(p_password text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role     text;
  v_user_id  uuid;
  v_username text;
  v_token    text;
begin
  v_role := verify_password(p_password);
  if v_role is null then
    -- verify_password a déjà journalisé la tentative (verrou IP/global).
    raise exception 'Mot de passe invalide';
  end if;

  select id, username into v_user_id, v_username
  from app_users
  where is_active
    and password_hash = crypt(p_password, password_hash)
  limit 1;

  -- Purge des sessions expirées.
  delete from auth_sessions where expires_at < now();

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into auth_sessions (token_hash, role, user_id)
  values (encode(digest(v_token, 'sha256'), 'hex'), v_role, v_user_id);

  return json_build_object('token', v_token, 'role', v_role, 'username', v_username);
end $$;

-- ------------------------------------------------------------
-- app_logout : révoque la session courante.
-- ------------------------------------------------------------
create or replace function app_logout(p_session_token text)
returns void
language sql
volatile
security definer
set search_path = public, extensions
as $$
  delete from auth_sessions
  where token_hash = encode(digest(p_session_token, 'sha256'), 'hex');
$$;

-- ------------------------------------------------------------
-- app_username : résout l'identifiant depuis la session
-- (l'ancienne version dérivait le compte du mot de passe).
-- ------------------------------------------------------------
create or replace function app_username(p_session_token text)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select u.username
  from auth_sessions s
  join app_users u on u.id = s.user_id
  where s.token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and s.expires_at > now()
    and u.is_active
  limit 1;
$$;

-- ------------------------------------------------------------
-- Fonctions RPC existantes : le paramètre p_password devient
-- p_session_token (corps inchangé par ailleurs, hormis la
-- vérification via session_role).
-- ------------------------------------------------------------

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

create or replace function list_users(p_session_token text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
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

create or replace function list_proposals(p_session_token text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
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

create or replace function upsert_member(p_session_token text, p_member jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;
  return member_apply_core(p_member);
end $$;

create or replace function delete_member(p_session_token text, p_member_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;
  delete from members where id = p_member_id;
end $$;

create or replace function set_parent(p_session_token text, p_child_id uuid, p_parent_id uuid, p_slot text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;
  perform set_parent_core(p_child_id, p_parent_id, p_slot);
end $$;

create or replace function set_spouse(p_session_token text, p_member_id uuid, p_spouse_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_old uuid;
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;

  if not exists (select 1 from members where id = p_member_id) then
    raise exception 'Membre introuvable';
  end if;

  if p_spouse_id is not null then
    if p_spouse_id = p_member_id then
      raise exception 'Un membre ne peut pas être son propre conjoint';
    end if;
    if not exists (select 1 from members where id = p_spouse_id) then
      raise exception 'Conjoint introuvable';
    end if;
  end if;

  select spouse_id into v_old from members where id = p_member_id;

  -- 1. Détache quiconque se déclare conjoint de ce membre.
  update members set spouse_id = null
  where spouse_id = p_member_id
    and id <> p_member_id;

  -- 2. Détache l'éventuel conjoint déclaré par ce membre.
  if v_old is not null and (p_spouse_id is null or v_old <> p_spouse_id) then
    update members set spouse_id = null where id = v_old;
  end if;

  -- 3. Détache le précédent conjoint de la nouvelle cible.
  if p_spouse_id is not null then
    update members set spouse_id = null
    where spouse_id = p_spouse_id
      and id not in (p_spouse_id, p_member_id);
  end if;

  -- 4. Crée le lien dans les deux sens.
  update members set spouse_id = p_spouse_id where id = p_member_id;

  if p_spouse_id is not null then
    update members set spouse_id = p_member_id where id = p_spouse_id;
  end if;
end $$;

create or replace function submit_proposal(p_session_token text, p_member_id uuid, p_proposal jsonb)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_user text;
  v_id   uuid;
begin
  v_user := app_username(p_session_token);
  if v_user is null then
    raise exception 'Session invalide ou expirée';
  end if;

  if p_member_id is not null
     and not exists (select 1 from members where id = p_member_id) then
    raise exception 'Membre introuvable';
  end if;

  -- Validation minimale au dépôt (validation complète à l'acceptation).
  if p_proposal->>'last_name' is null or p_proposal->>'first_name' is null then
    raise exception 'Le nom et le prénom sont obligatoires';
  end if;
  if p_proposal->>'birth_date' is null then
    raise exception 'La date de naissance est obligatoire';
  end if;
  if p_proposal->>'sex' not in ('M', 'F') then
    raise exception 'Sexe invalide (M ou F)';
  end if;

  insert into member_proposals (member_id, proposed_by, payload)
  values (p_member_id, v_user, p_proposal)
  returning id into v_id;

  return json_build_object('id', v_id, 'username', v_user);
end $$;

create or replace function accept_proposal(p_session_token text, p_proposal_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_row       member_proposals%rowtype;
  v_member_id uuid;
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs';
  end if;

  select * into v_row
  from member_proposals
  where id = p_proposal_id and status = 'pending'
  for update;

  if not found then
    raise exception 'Proposition introuvable ou déjà traitée';
  end if;

  -- Données du membre : mise à jour si le membre existe déjà,
  -- création sinon (id vide = nouveau membre).
  v_member_id := member_apply_core(
    v_row.payload || jsonb_build_object('id', coalesce(v_row.member_id::text, ''))
  );

  -- Relations proposées ('' ou absent = retrait du lien).
  perform set_parent_core(
    v_member_id,
    nullif(v_row.payload->>'pere', '')::uuid,
    'pere'
  );
  perform set_parent_core(
    v_member_id,
    nullif(v_row.payload->>'mere', '')::uuid,
    'mere'
  );
  perform set_spouse_core(
    v_member_id,
    nullif(v_row.payload->>'spouse', '')::uuid
  );

  update member_proposals
  set status = 'accepted',
      member_id = v_member_id,
      decided_at = now(),
      decided_by = app_username(p_session_token)
  where id = p_proposal_id;
end $$;

create or replace function reject_proposal(p_session_token text, p_proposal_id uuid)
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

  update member_proposals
  set status = 'rejected',
      decided_at = now(),
      decided_by = app_username(p_session_token)
  where id = p_proposal_id and status = 'pending';

  if not found then
    raise exception 'Proposition introuvable ou déjà traitée';
  end if;
end $$;

create or replace function create_user(p_session_token text, p_username text, p_new_password text, p_role text)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role text;
  v_id   uuid;
begin
  v_role := session_role(p_session_token);
  if v_role is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs';
  end if;

  if p_role not in ('viewer', 'admin') then
    raise exception 'Rôle invalide';
  end if;
  if length(p_new_password) < 8 then
    raise exception 'Le mot de passe doit contenir au moins 8 caractères';
  end if;
  -- Un mot de passe ne doit pas être partagé par deux comptes actifs,
  -- sinon on ne saurait pas quel rôle appliquer.
  if exists (
    select 1 from app_users u
    where u.is_active
      and u.password_hash = crypt(p_new_password, u.password_hash)
  ) then
    raise exception 'Ce mot de passe est déjà utilisé par un autre compte';
  end if;

  insert into app_users (username, password_hash, role)
  values (p_username, crypt(p_new_password, gen_salt('bf', 12)), p_role)
  returning id into v_id;

  return v_id;
end $$;

create or replace function set_user_password(p_session_token text, p_user_id uuid, p_new_password text)
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
  if length(p_new_password) < 8 then
    raise exception 'Le mot de passe doit contenir au moins 8 caractères';
  end if;
  if exists (
    select 1 from app_users u
    where u.id <> p_user_id
      and u.is_active
      and u.password_hash = crypt(p_new_password, u.password_hash)
  ) then
    raise exception 'Ce mot de passe est déjà utilisé par un autre compte';
  end if;
  update app_users
  set password_hash = crypt(p_new_password, gen_salt('bf', 12))
  where id = p_user_id;

  -- Sécurité : les sessions existantes du compte sont révoquées.
  delete from auth_sessions where user_id = p_user_id;
end $$;

create or replace function set_user_active(p_session_token text, p_user_id uuid, p_is_active boolean)
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
  -- Toujours garder au moins un admin actif.
  if (
    select count(*)
    from app_users
    where role = 'admin' and is_active and id <> p_user_id
  ) = 0 then
    raise exception 'Impossible de retirer le dernier administrateur actif';
  end if;
  update app_users set is_active = p_is_active where id = p_user_id;

  -- Sécurité : les sessions existantes du compte sont révoquées.
  delete from auth_sessions where user_id = p_user_id;
end $$;

create or replace function delete_user(p_session_token text, p_user_id uuid)
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
  if (
    select count(*)
    from app_users
    where role = 'admin' and is_active and id <> p_user_id
  ) = 0 then
    raise exception 'Impossible de supprimer le dernier administrateur actif';
  end if;
  delete from app_users where id = p_user_id;
end $$;
