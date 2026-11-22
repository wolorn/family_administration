-- ============================================================
-- Administration familiale — Schéma Supabase
-- À exécuter entièrement dans le SQL Editor de Supabase.
-- ============================================================

-- Sur Supabase, pgcrypto est installé dans le schéma "extensions".
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- Utilisateurs de l'application
-- role : 'viewer' = lecture seule, 'admin' = lecture + écriture
-- ------------------------------------------------------------
create table if not exists app_users (
  id            uuid primary key default gen_random_uuid(),
  username      text unique not null,
  password_hash text not null,
  role          text not null check (role in ('viewer', 'admin')),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Membres de la famille
-- ------------------------------------------------------------
create table if not exists members (
  id           uuid primary key default gen_random_uuid(),
  last_name    text not null,
  first_name   text not null,
  sex          text not null check (sex in ('M', 'F')),
  birth_date   date not null,
  address      text,
  email        text,
  wedding_date date,
  death_date   date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Relations parent -> enfant (source de vérité unique).
-- Père/mère = lien parent/enfant ; frère/sœur = dérivé des parents.
-- ------------------------------------------------------------
create table if not exists relationships (
  id        uuid primary key default gen_random_uuid(),
  parent_id uuid not null references members (id) on delete cascade,
  child_id  uuid not null references members (id) on delete cascade,
  unique (parent_id, child_id),
  check (parent_id <> child_id)
);

create index if not exists relationships_child_idx on relationships (child_id);
create index if not exists relationships_parent_idx on relationships (parent_id);

-- ------------------------------------------------------------
-- RLS : aucun accès direct aux tables depuis le navigateur.
-- Tout passe par les fonctions RPC ci-dessous qui vérifient
-- le mot de passe à chaque appel.
-- ------------------------------------------------------------
alter table app_users      enable row level security;
alter table members        enable row level security;
alter table relationships  enable row level security;

-- ============================================================
-- Fonctions de sécurité et d'accès (security definer)
-- ============================================================

-- Vérifie le mot de passe et renvoie le rôle ('viewer' | 'admin')
-- ou NULL si le mot de passe est invalide.
create or replace function verify_password(p_password text)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select role
  from app_users
  where is_active
    and password_hash = crypt(p_password, password_hash)
  limit 1;
$$;

-- Vue complète des membres + relations (lecture).
create or replace function get_members(p_password text)
returns json
language plpgsql
stable
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
        ) as siblings
      from members m
    ) as t
  );
end $$;

-- Ajout ou modification d'un membre (admin uniquement).
create or replace function upsert_member(p_password text, p_member jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role  text;
  v_id    uuid;
begin
  v_role := verify_password(p_password);
  if v_role is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;

  if p_member->>'last_name' is null or p_member->>'first_name' is null then
    raise exception 'Le nom et le prénom sont obligatoires';
  end if;
  if p_member->>'birth_date' is null then
    raise exception 'La date de naissance est obligatoire';
  end if;
  if p_member->>'sex' not in ('M', 'F') then
    raise exception 'Sexe invalide (M ou F)';
  end if;

  v_id := nullif(p_member->>'id', '')::uuid;

  if v_id is null then
    insert into members (last_name, first_name, sex, birth_date, address, email, wedding_date, death_date)
    values (
      p_member->>'last_name',
      p_member->>'first_name',
      p_member->>'sex',
      (p_member->>'birth_date')::date,
      nullif(p_member->>'address', ''),
      nullif(p_member->>'email', ''),
      nullif(p_member->>'wedding_date', '')::date,
      nullif(p_member->>'death_date', '')::date
    )
    returning id into v_id;
  else
    if not exists (select 1 from members where id = v_id) then
      raise exception 'Membre introuvable';
    end if;
    update members set
      last_name    = p_member->>'last_name',
      first_name   = p_member->>'first_name',
      sex          = p_member->>'sex',
      birth_date   = (p_member->>'birth_date')::date,
      address      = nullif(p_member->>'address', ''),
      email        = nullif(p_member->>'email', ''),
      wedding_date = nullif(p_member->>'wedding_date', '')::date,
      death_date   = nullif(p_member->>'death_date', '')::date,
      updated_at   = now()
    where id = v_id;
  end if;

  return v_id;
end $$;

-- Suppression d'un membre (admin uniquement).
create or replace function delete_member(p_password text, p_member_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;
  delete from members where id = p_member_id;
end $$;

-- Définit ou retire le père ('pere') ou la mère ('mere') d'un membre
-- (admin uniquement). p_parent_id = NULL retire le lien.
create or replace function set_parent(p_password text, p_child_id uuid, p_parent_id uuid, p_slot text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_sex text;
begin
  if verify_password(p_password) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;

  if p_slot = 'pere' then v_sex := 'M';
  elsif p_slot = 'mere' then v_sex := 'F';
  else raise exception 'Slot de parent invalide : %', p_slot;
  end if;

  if not exists (select 1 from members where id = p_child_id) then
    raise exception 'Membre (enfant) introuvable';
  end if;

  if p_parent_id is not null then
    if p_parent_id = p_child_id then
      raise exception 'Un membre ne peut pas être son propre parent';
    end if;
    if not exists (select 1 from members where id = p_parent_id) then
      raise exception 'Membre (parent) introuvable';
    end if;
    -- Interdire les cycles : le nouvel "enfant" ne doit pas être
    -- déjà un ancêtre du "parent".
    if exists (
      with recursive ancestors as (
        select parent_id from relationships where child_id = p_parent_id
        union all
        select r.parent_id
        from relationships r
        join ancestors a on a.parent_id = r.child_id
      )
      select 1 from ancestors where parent_id = p_child_id
    ) then
      raise exception 'Cycle détecté dans l''arbre familial';
    end if;
  end if;

  -- Retire le lien existant dans ce slot (père ou mère).
  delete from relationships r
  where r.child_id = p_child_id
    and exists (
      select 1 from members p where p.id = r.parent_id and p.sex = v_sex
    );

  if p_parent_id is not null then
    insert into relationships (parent_id, child_id)
    values (p_parent_id, p_child_id)
    on conflict do nothing;
  end if;
end $$;

-- ============================================================
-- Gestion des comptes (admin uniquement)
-- ============================================================

create or replace function list_users(p_password text)
returns json
language plpgsql
stable
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

create or replace function create_user(p_password text, p_username text, p_new_password text, p_role text)
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
  v_role := verify_password(p_password);
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

create or replace function set_user_password(p_password text, p_user_id uuid, p_new_password text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
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
end $$;

create or replace function set_user_active(p_password text, p_user_id uuid, p_is_active boolean)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
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
end $$;

create or replace function delete_user(p_password text, p_user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
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

-- ============================================================
-- Comptes initiaux : CHANGER CES MOTS DE PASSE immédiatement
-- après l'exécution du script, avec :
--
-- update app_users
-- set password_hash = crypt('NOUVEAU_MOT_DE_PASSE', gen_salt('bf', 12))
-- where username = 'admin';
--
-- (idem pour le compte 'famille')
-- ============================================================
insert into app_users (username, password_hash, role)
values
  ('admin',   crypt('CHANGE_ME_ADMIN',   gen_salt('bf', 12)), 'admin'),
  ('famille', crypt('CHANGE_ME_FAMILLE', gen_salt('bf', 12)), 'viewer')
on conflict (username) do nothing;
