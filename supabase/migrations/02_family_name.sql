-- ============================================================
-- Migration 02 — Nom de la famille
--
-- Ajoute une table de réglages contenant le nom de la famille à
-- administrer. Lecture publique (affichée avant connexion),
-- aucune écriture possible pour le rôle anon.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create table if not exists app_settings (
  key   text primary key,
  value text not null
);

alter table app_settings enable row level security;

drop policy if exists "lecture publique des reglages" on app_settings;
create policy "lecture publique des reglages"
  on app_settings
  for select
  using (true);

insert into app_settings (key, value)
values ('family_name', 'Ma Famille')
on conflict (key) do nothing;

-- Pour changer le nom de la famille :
-- update app_settings set value = 'NOUVEAU_NOM' where key = 'family_name';
