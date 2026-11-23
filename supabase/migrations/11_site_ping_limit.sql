-- ============================================================
-- Migration 11 — site_ping : plafond d'insertion
--
-- site_ping est exécutable par anon : sans garde-fou, un automate
-- pourrait saturer traffic_logging (quota disque du projet). La
-- fonction n'insère plus si la table contient déjà un grand nombre
-- de traces de moins de 24 h (la purge intégrée supprime les plus
-- anciennes, la table redescend d'elle-même ensuite).
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

-- Index au service de la purge et du comptage par fenêtre de 24 h.
create index if not exists idx_traffic_logging_visited
  on traffic_logging (visited_at);

-- Rejet silencieux au-delà du plafond : le ping reste "réussi" du
-- point de vue du visiteur légitime, seul l'insert est sauté.
create or replace function site_ping(p_client_id text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  c_traffic_cap constant int := 100000; -- plafond de traces < 24 h
begin
  if p_client_id is null or length(trim(p_client_id)) = 0
     or length(p_client_id) > 64 then
    p_client_id := 'anonyme';
  end if;

  -- Purge d'abord : libère l'espace avant d'évaluer le plafond.
  delete from traffic_logging where visited_at < now() - interval '1 day';

  if (
    select count(*)
    from traffic_logging
    where visited_at >= now() - interval '1 day'
  ) >= c_traffic_cap then
    return 'plafond';
  end if;

  insert into traffic_logging (client_id) values (p_client_id);

  return 'ok';
end $$;

-- Exécution ouverte : c'est un visiteur non connecté qui ping.
grant execute on function site_ping(text) to anon, authenticated;
