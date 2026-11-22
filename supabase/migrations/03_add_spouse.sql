-- ============================================================
-- Migration 03 — Relation conjoint
--
-- Ajoute un lien conjoint entre membres. Le lien est stocké dans
-- les deux sens (m.spouse_id = s et s.spouse_id = m) ; la fonction
-- set_spouse garantit la cohérence lors des changements.
-- La suppression d'un membre libère le conjoint (on delete set null).
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

alter table members
  add column if not exists spouse_id uuid references members (id) on delete set null;

-- Définit (ou retire si p_spouse_id = NULL) le conjoint d'un membre,
-- en détachant systématiquement les liens résiduels dans tous les sens.
create or replace function set_spouse(p_password text, p_member_id uuid, p_spouse_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_old uuid;
begin
  if verify_password(p_password) is distinct from 'admin' then
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

-- get_members : inclut le conjoint dans chaque fiche.
-- Migre le correctif de la migration 01 (siblings) et ajoute "spouse".
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
