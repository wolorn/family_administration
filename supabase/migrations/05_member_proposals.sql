-- ============================================================
-- Migration 05 — Propositions de modification par les utilisateurs
--
-- Les utilisateurs non admin peuvent proposer des corrections sur
-- un membre existant. La proposition est stockée en attente dans
-- member_proposals ; un admin la consulte (comparaison avant/après)
-- puis l'accepte (application) ou la refuse.
--
-- Les fonctions "core" (sans vérification de rôle) sont extraites
-- d'upsert_member / set_parent / set_spouse afin d'être réutilisées
-- par accept_proposal. Les fonctions publiques conservent leurs
-- vérifications (comportement inchangé).
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create table if not exists member_proposals (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members (id) on delete cascade,
  proposed_by text not null,
  payload     jsonb not null,
  status      text not null default 'pending'
              check (status in ('pending', 'accepted', 'rejected')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  text
);

alter table member_proposals enable row level security;

create index if not exists proposals_member_idx on member_proposals (member_id);
create index if not exists proposals_status_idx on member_proposals (status);

-- ------------------------------------------------------------
-- Résolution du compte à partir du mot de passe (les comptes
-- actifs ne partagent pas leurs mots de passe : créer/cchanger
-- le mot de passe l'interdisent).
-- ------------------------------------------------------------
create or replace function app_username(p_password text)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select username
  from app_users
  where is_active
    and password_hash = crypt(p_password, password_hash)
  limit 1;
$$;

-- ------------------------------------------------------------
-- Fonctions core (security definer, SANS vérification de rôle).
-- Appelées uniquement par les wrappers publics et accept_proposal.
-- ------------------------------------------------------------

-- Insertion ou mise à jour d'un membre (contenu de upsert_member).
create or replace function member_apply_core(p_member jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
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

-- Définit ou retire le père ('pere') / la mère ('mere')
-- (contenu de set_parent).
create or replace function set_parent_core(p_child_id uuid, p_parent_id uuid, p_slot text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_sex text;
begin
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

-- Définit ou retire le conjoint (contenu de set_spouse).
create or replace function set_spouse_core(p_member_id uuid, p_spouse_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_old uuid;
begin
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

-- ------------------------------------------------------------
-- Wrappers publics (comportement inchangé : admin uniquement).
-- ------------------------------------------------------------

create or replace function upsert_member(p_password text, p_member jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if verify_password(p_password) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;
  return member_apply_core(p_member);
end $$;

create or replace function set_parent(p_password text, p_child_id uuid, p_parent_id uuid, p_slot text)
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
  perform set_parent_core(p_child_id, p_parent_id, p_slot);
end $$;

create or replace function set_spouse(p_password text, p_member_id uuid, p_spouse_id uuid)
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
  perform set_spouse_core(p_member_id, p_spouse_id);
end $$;

-- ------------------------------------------------------------
-- Propositions
-- payload : clés usuelles du membre (last_name, first_name, sex,
-- birth_date, address, email, wedding_date, death_date) + relations
-- 'pere' / 'mere' / 'spouse' (uuid texte ou '').
-- ------------------------------------------------------------

-- Enregistre une proposition (tout utilisateur actif).
create or replace function submit_proposal(p_password text, p_member_id uuid, p_proposal jsonb)
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
  v_user := app_username(p_password);
  if v_user is null then
    raise exception 'Mot de passe invalide';
  end if;

  if not exists (select 1 from members where id = p_member_id) then
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

-- Liste des propositions en attente (admin uniquement).
create or replace function list_proposals(p_password text)
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

  return coalesce((
    select json_agg(json_build_object(
      'id', p.id,
      'member_id', p.member_id,
      'member_name', m.first_name || ' ' || m.last_name,
      'proposed_by', p.proposed_by,
      'payload', p.payload,
      'created_at', p.created_at
    ) order by p.created_at)
    from member_proposals p
    join members m on m.id = p.member_id
    where p.status = 'pending'
  ), '[]'::json);
end $$;

-- Accepte une proposition : applique les données + relations
-- proposées puis marque la proposition comme acceptée.
create or replace function accept_proposal(p_password text, p_proposal_id uuid)
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
  if verify_password(p_password) is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs';
  end if;

  select * into v_row
  from member_proposals
  where id = p_proposal_id and status = 'pending'
  for update;

  if not found then
    raise exception 'Proposition introuvable ou déjà traitée';
  end if;

  -- Données du membre (le payload porte l'id existant).
  v_member_id := member_apply_core(v_row.payload || jsonb_build_object('id', v_row.member_id));

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
      decided_at = now(),
      decided_by = app_username(p_password)
  where id = p_proposal_id;
end $$;

-- Refuse une proposition (admin uniquement).
create or replace function reject_proposal(p_password text, p_proposal_id uuid)
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

  update member_proposals
  set status = 'rejected',
      decided_at = now(),
      decided_by = app_username(p_password)
  where id = p_proposal_id and status = 'pending';

  if not found then
    raise exception 'Proposition introuvable ou déjà traitée';
  end if;
end $$;
