-- ============================================================
-- Migration 08 — Verrou global + alerte email de blocage
--
-- Complète la migration 07 :
--   - verrou GLOBAL indépendant des IP : 10 échecs en 15 minutes
--     (toutes IP confondues) bloquent toute nouvelle tentative pour
--     tous les clients pendant le reste de la fenêtre, même avec le
--     bon mot de passe ;
--   - lorsqu'un blocage (IP ou global) est déclenché, un email est
--     envoyé aux administrateurs via la fonction Edge
--     "notify-lockout" (pg_net), même stratégie que les notifications
--     de propositions de modification.
--
-- L'appel de notification est tunné dans un bloc exception : un
-- échec d'envoi ne perturbe jamais la protection elle-même.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

-- pg_net : appels HTTP asynchrones depuis Postgres (pré-installé sur
-- Supabase ; l'exécution est un no-op s'il existe déjà).
create extension if not exists pg_net;

-- Envoi de l'alerte de blocage aux administrateurs.
create or replace function notify_lockout_email(p_source text, p_ip text, p_failures int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  -- URL de la fonction et clé publique du projet (à ajuster si le
  -- projet change) : voyez js/config.js.
  v_url text := 'https://bzpjyaajphhdtmdbugat.supabase.co/functions/v1/notify-lockout';
  v_key text := 'sb_publishable_hXG9LBkkCzyFVrF6zKYAsg_0vSIOain';
begin
  begin
    perform net.http_post(
      v_url,
      jsonb_build_object(
        'source', p_source,
        'ip', p_ip,
        'failures', p_failures,
        'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      ),
      5000,
      jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', v_key,
        'Authorization', 'Bearer ' || v_key
      )
    );
  exception when others then
    null; -- l'alerte ne doit jamais bloquer la protection
  end;
end $$;

-- verify_password : verrou global + verrou par IP + alerte email.
create or replace function verify_password(p_password text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_ip           text := client_ip();
  v_role         text;
  v_ip_count     int;
  v_global_count int;
  v_wait         interval;
begin
  -- Purge des tentatives anciennes.
  delete from auth_attempts where attempted_at < now() - interval '2 days';

  -- Verrou global (toutes IP) : protecte contre les attaques réparties.
  select count(*), max(attempted_at) + interval '15 minutes' - now()
    into v_global_count, v_wait
  from auth_attempts
  where not success
    and attempted_at > now() - interval '15 minutes';

  if v_global_count >= 10 then
    raise exception
      'Trop de tentatives sur le site. Réessayez dans % minute(s).',
      greatest(1, ceil(extract(epoch from v_wait) / 60))::text;
  end if;

  -- Verrou par IP.
  select count(*), max(attempted_at) + interval '15 minutes' - now()
    into v_ip_count, v_wait
  from auth_attempts
  where ip = v_ip
    and not success
    and attempted_at > now() - interval '15 minutes';

  if v_ip_count >= 5 then
    raise exception
      'Trop de tentatives depuis votre connexion. Réessayez dans % minute(s).',
      greatest(1, ceil(extract(epoch from v_wait) / 60))::text;
  end if;

  -- Vérification du mot de passe.
  select role into v_role
  from app_users
  where is_active
    and password_hash = crypt(p_password, password_hash)
  limit 1;

  if v_role is null then
    insert into auth_attempts (ip, success) values (v_ip, false);

    -- Un blocage vient de se déclencher : alerte email (seulement au
    -- moment où le seuil est atteint, pas à chaque tentative).
    select count(*) into v_ip_count
    from auth_attempts
    where ip = v_ip and not success
      and attempted_at > now() - interval '15 minutes';

    select count(*) into v_global_count
    from auth_attempts
    where not success
      and attempted_at > now() - interval '15 minutes';

    if v_ip_count = 5 then
      perform notify_lockout_email('ip', v_ip, v_ip_count);
    end if;
    if v_global_count = 10 then
      perform notify_lockout_email('global', v_ip, v_global_count);
    end if;
  else
    -- Succès : remise à zéro des échecs de cette IP.
    delete from auth_attempts where ip = v_ip and not success;
  end if;

  return v_role;
end $$;
