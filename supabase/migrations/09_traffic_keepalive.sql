-- ============================================================
-- Migration 09 — Keep-alive : évite la mise en pause de la DB gratuite
--
-- Un visiteur ouvre la page → le site appelle 50 fois la fonction
-- site_ping avec l'identifiant client. Chaque appel insère une ligne
-- dans traffic_logging, ce qui génère du trafic régulier sur la base
-- (même stratégie que le projet "75 ans"). Les lignes de plus d'un
-- jour sont purgées à chaque appel.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create table if not exists traffic_logging (
  id         bigint generated always as identity primary key,
  client_id  text not null,
  visited_at timestamptz not null default now()
);

alter table traffic_logging enable row level security;

-- Le site ne lit ni ne modifie cette table : tout passe par la
-- fonction ci-dessous, security definer (RLS : aucune policy directe).
create or replace function site_ping(p_client_id text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if p_client_id is null or length(trim(p_client_id)) = 0
     or length(p_client_id) > 64 then
    p_client_id := 'anonyme';
  end if;

  insert into traffic_logging (client_id) values (p_client_id);

  -- Purge des traces de plus d'un jour (coût négligeable, table bornée).
  delete from traffic_logging where visited_at < now() - interval '1 day';

  return 'ok';
end $$;

-- Exécution ouverte : c'est un visiteur non connecté qui ping.
grant execute on function site_ping(text) to anon, authenticated;
