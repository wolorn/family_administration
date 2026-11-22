-- ============================================================
-- Migration 04 — Lecture publique effective de app_settings
--
-- La policy RLS de la migration 02 autorise le SELECT mas la
-- table n'a reçu aucun privilège GRANT pour le rôle anon
-- (les privilèges par défaut ne s'appliquent pas aux tables
-- créées via le SQL Editor sur ce projet).
--
-- Symptôme avant correction :
--   permission denied for table app_settings (HTTP 401, code 42501)
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

grant select on public.app_settings to anon;
