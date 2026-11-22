-- ============================================================
-- Migration 06 — Propositions de création de membre
--
-- Une proposition peut maintenant concerner un membre qui n'existe
-- pas encore (member_id NULL) : création proposée par un utilisateur
-- non admin. L'acceptation crée le membre puis lui applique les
-- relations proposées.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

alter table member_proposals
  alter column member_id drop not null;

-- Enregistre une proposition (tout utilisateur actif).
-- p_member_id = NULL : proposition de création d'un nouveau membre.
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

-- Liste des propositions en attente (admin uniquement).
-- Pour une proposition de création, le nom vient du payload.
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

-- Accepte une proposition : applique les données + relations
-- proposées puis marque la proposition comme acceptée.
-- member_id NULL : crée le membre à partir du payload.
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
      decided_by = app_username(p_password)
  where id = p_proposal_id;
end $$;
