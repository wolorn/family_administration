-- ============================================================
-- Migration 01 — Correction de get_members
--
-- Erreur corrigée :
--   COALESCE could not convert type jsonb to json
--
-- La sous-requête "siblings" coalesçait le résultat de json_agg
-- (type json) avec '[]'::jsonb. La déduplication est désormais
-- faite en SQL (select distinct) et le json_agg est coalescé
-- avec '[]'::json.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

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
