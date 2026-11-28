-- ============================================================
-- Migration 17 — site_ping réservé aux sessions administrateur
--
-- Jusqu'ici site_ping était exécutable par anon et déclenché au
-- chargement de la page d'accueil par tous les visiteurs (50 pings
-- chacun) : n'importe qui, y compris un automate, pouvait écrire
-- dans traffic_logging et maintenir la base « réveillée ».
--
-- Désormais le site ne ping que lorsqu'un administrateur ouvre une
-- session (côté navigateur : sendKeepAlive déplacé de init() vers
-- showApp(), uniquement si role = 'admin').
--
-- Restriction côté base : le site utilise des sessions maison
-- (token passé en argument, aucune connexion Supabase Auth), toutes
-- les requêtes navigateur s'exécutent donc sous le rôle anon — un
-- simple « revoke ... from anon » bloquerait aussi les pings admin.
-- La restriction se fait donc DANS la fonction : nouvelle signature
-- site_ping(p_session_token, p_client_id) qui exige une session
-- admin ouverte et non expirée (aucun glissement d'expiration :
-- 50 pings ne prolongent pas la session). L'ancienne signature
-- site_ping(text) est supprimée, avec ses droits.
--
-- À exécuter dans le SQL Editor de Supabase, après la migration 16.
-- ============================================================

create or replace function site_ping(p_session_token text, p_client_id text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  c_traffic_cap constant int := 100000; -- plafond de traces < 24 h
begin
  -- Réservé aux sessions administrateur ouvertes.
  if p_session_token is null or not exists (
    select 1
    from auth_sessions
    where token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
      and role = 'admin'
      and expires_at > now()
  ) then
    return 'refuse';
  end if;

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

-- L'ancienne signature (sans session) n'a plus lieu d'être : la
-- supprimer retire avec elle les droits qui lui étaient accordés.
drop function if exists site_ping(text);

-- Le navigateur s'exécute toujours sous le rôle anon (sessions
-- maison) : la fonction doit rester accessible, mais elle refuse
-- elle-même tout appel sans session admin ouverte.
grant execute on function site_ping(text, text) to anon, authenticated;
