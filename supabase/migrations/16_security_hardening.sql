-- ============================================================
-- Migration 16 — Durcissement de la sécurité
--
-- Corrige les points relevés par l'analyse de sécurité :
--
--  1. Fonctions internes (core, envoi d'emails…) retirées de l'API
--     publique : EXECUTE n'est plus accordé par défaut à PUBLIC /
--     anon / authenticated. Seules les fonctions réellement appelées
--     par le site sont ré-autorisées, explicitement.
--  2. login_with_code : les échecs ne sont plus perdus. Auparavant,
--     « raise exception » annulait toute la transaction (compteur
--     d'essais, journal des échecs, verrou IP, alerte email) : rien
--     n'était jamais enregistré. La fonction renvoie maintenant un
--     JSON { error } au lieu de lever une exception, après avoir
--     enregistré l'échec. Les essais d'un code sont aussi sérialisés
--     (verrou de ligne) pour empêcher les essais en parallèle, et un
--     succès ne remet plus à zéro les échecs de l'IP.
--  3. request_login_code : les plafonds (60 s et 10/h par adresse,
--     30/15 min par IP, 500/15 min global) s'appuient sur un journal
--     persistant (login_code_requests) au lieu de login_codes dont
--     les lignes étaient supprimées avant d'être comptées.
--  4. client_ip : ne prend plus la 1re valeur de X-Forwarded-For
--     (falsifiable par le client) mais cf-connecting-ip si présent,
--     sinon la DERNIÈRE valeur de X-Forwarded-For.
--  5. notify_lockout_email : envoie maintenant x-webhook-secret
--     (la fonction Edge l'exige depuis la migration 12 : les alertes
--     étaient rejetées en 401 sans bruit).
--  6. delete_member : interdit de supprimer le dernier administrateur.
--  7. submit_proposal : liste blanche de champs, tailles bornées,
--     10 propositions/heure par proposeur, 200 en attente au plus.
--  8. app_settings : lecture publique limitée à la clé family_name.
--
-- À exécuter dans le SQL Editor de Supabase, après la migration 15.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Journal persistant des demandes de code.
--    L'adresse est stockée hashée (pas d'email en clair, y compris
--    pour les adresses inconnues). Purgé au-delà d'un jour.
-- ------------------------------------------------------------
create table if not exists login_code_requests (
  id          bigint generated always as identity primary key,
  email_hash  text not null,
  ip          text not null,
  sent        boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists idx_lcr_ip_created
  on login_code_requests (ip, created_at);
create index if not exists idx_lcr_email_created
  on login_code_requests (email_hash, created_at) where sent;
create index if not exists idx_lcr_created
  on login_code_requests (created_at);

alter table login_code_requests enable row level security; -- aucune policy

-- ------------------------------------------------------------
-- 4. IP cliente (anti-usurpation de X-Forwarded-For).
--    Après la migration, vérifiez ce que reçoit réellement la base
--    (voir « Vérifications » en bas de ce fichier) : si le proxy de
--    votre projet ajoute plusieurs sauts, adaptez le choix de
--    l'élément.
-- ------------------------------------------------------------
create or replace function client_ip()
returns text
language plpgsql
stable
as $$
declare
  h      json;
  v_cf   text;
  v_xff  text;
  v_arr  text[];
begin
  begin
    h := nullif(btrim(coalesce(current_setting('request.headers', true), '')), '')::json;
  exception when others then
    h := null;
  end;
  if h is null then
    return 'inconnu';
  end if;

  if json_typeof(h) = 'object' then
    select kv.value into v_cf
      from json_each_text(h) kv where lower(kv.key) = 'cf-connecting-ip' limit 1;
    select kv.value into v_xff
      from json_each_text(h) kv where lower(kv.key) = 'x-forwarded-for' limit 1;
  elsif json_typeof(h) = 'array' then
    select e->>'value' into v_cf
      from json_array_elements(h) e where lower(e->>'name') = 'cf-connecting-ip' limit 1;
    select e->>'value' into v_xff
      from json_array_elements(h) e where lower(e->>'name') = 'x-forwarded-for' limit 1;
  end if;

  v_cf := nullif(btrim(coalesce(v_cf, '')), '');
  if v_cf is not null then
    return left(v_cf, 64);
  end if;

  if v_xff is not null and btrim(v_xff) <> '' then
    v_arr := regexp_split_to_array(btrim(v_xff), '\s*,\s*');
    return left(v_arr[array_length(v_arr, 1)], 64);
  end if;

  return 'inconnu';
end $$;

-- ------------------------------------------------------------
-- 5. Alerte de blocage : ajoute le secret partagé.
-- ------------------------------------------------------------
create or replace function notify_lockout_email(p_source text, p_ip text, p_failures int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_url     text := 'https://bzpjyaajphhdtmdbugat.supabase.co/functions/v1/notify-lockout';
  v_key     text := 'sb_publishable_hXG9LBkkCzyFVrF6zKYAsg_0vSIOain';
  v_secret  text;
  v_body    jsonb;
  v_headers jsonb;
begin
  select value into v_secret from app_secrets where key = 'edge_shared_secret';
  if v_secret is null or length(v_secret) = 0 then
    return; -- secret non installé : pas d'envoi possible
  end if;

  v_body := jsonb_build_object(
    'source', p_source,
    'ip', p_ip,
    'failures', p_failures,
    'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'apikey', v_key,
    'Authorization', 'Bearer ' || v_key,
    'x-webhook-secret', v_secret
  );

  begin
    perform net.http_post(v_url, v_body, '{}'::jsonb, v_headers, 5000);
  exception when others then
    null; -- l'alerte ne doit jamais bloquer la protection
  end;
end $$;

-- ------------------------------------------------------------
-- 3. Demande de code : plafonds fondés sur le journal persistant.
--    Réponse toujours uniforme (anti-énumération, cf. migration 15).
--    Seuls l'erreur de format et les plafonds IP / global lèvent une
--    exception (ils ne dépendent pas de l'existence de l'adresse).
--    Les plafonds par adresse ne comptent que les envois réels
--    (sent = true) : spammer une adresse ne peut pas prolonger son
--    délai d'attente.
-- ------------------------------------------------------------
create or replace function request_login_code(p_email text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := lower(trim(coalesce(p_email, '')));
  v_hash    text;
  v_member  members%rowtype;
  v_ip      text := client_ip();
  v_minutes int := 10;
  v_matched boolean := false;
  v_send    boolean := false;
  v_code    text;
begin
  -- Purge des données anciennes (> 1 jour).
  delete from login_codes where created_at < now() - interval '1 day';
  delete from login_code_requests where created_at < now() - interval '1 day';

  if v_email = ''
     or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Adresse email invalide';
  end if;

  -- Anti-spam IP : 30 demandes / 15 minutes et par IP.
  if (
    select count(*) from login_code_requests
    where ip = v_ip and created_at > now() - interval '15 minutes'
  ) >= 30 then
    raise exception 'Trop de demandes de code. Réessayez plus tard.';
  end if;

  -- Plafond global (toutes IP confondues) : 500 demandes / 15 min.
  if (
    select count(*) from login_code_requests
    where created_at > now() - interval '15 minutes'
  ) >= 500 then
    raise exception 'Trop de demandes de code. Réessayez plus tard.';
  end if;

  v_hash := encode(digest(v_email, 'sha256'), 'hex');

  -- Sérialise les demandes simultanées pour une même adresse
  -- (sinon deux requêtes parallèles passent toutes les deux le délai).
  perform pg_advisory_xact_lock(hashtext('login_req:' || v_hash));

  -- Validité paramétrable (app_settings.otp_validity_minutes).
  begin
    select coalesce(nullif(value, '')::int, 10) into v_minutes
    from app_settings where key = 'otp_validity_minutes';
  exception when others then
    v_minutes := null;
  end;
  if v_minutes is null or v_minutes < 1 then
    v_minutes := 10;
  end if;
  if v_minutes > 1440 then
    v_minutes := 1440;
  end if;

  -- L'adresse doit correspondre à exactement un membre.
  select * into v_member
  from members
  where lower(trim(coalesce(email, ''))) = v_email;
  if found and (
    select count(*) from members
    where lower(trim(coalesce(email, ''))) = v_email
  ) = 1 then
    v_matched := true;
  end if;

  -- Plafonds par adresse, silencieux : 60 s mini entre deux envois,
  -- 10 envois / heure. Comptés sur les envois réels du journal.
  if v_matched
     and not exists (
       select 1 from login_code_requests
       where email_hash = v_hash and sent
         and created_at > now() - interval '60 seconds'
     )
     and (
       select count(*) from login_code_requests
       where email_hash = v_hash and sent
         and created_at > now() - interval '1 hour'
     ) < 10 then

    v_send := true;

    -- Un seul code actif par adresse : les précédents sont invalidés.
    delete from login_codes where lower(email) = v_email;

    -- Code à 8 chiffres, stocké hashé ; tirage sur 40 bits.
    v_code := lpad('' || (
      ('x' || substr(encode(gen_random_bytes(5), 'hex'), 1, 10))::bit(40)::bigint % 100000000
    ), 8, '0');

    insert into login_codes (member_id, email, code_hash, request_ip, expires_at)
    values (
      v_member.id,
      v_email,
      encode(digest(v_code, 'sha256'), 'hex'),
      v_ip,
      now() + make_interval(mins => v_minutes)
    );

    perform send_code_email(v_member.email, v_code, v_minutes);
  end if;

  -- Journalisation de toute demande valide (envoyée ou non).
  insert into login_code_requests (email_hash, ip, sent)
  values (v_hash, v_ip, v_send);

  return format(
    'Si un membre de la famille correspond à cette adresse, un code lui a été envoyé (valable %s minutes).',
    v_minutes
  );
end $$;

-- ------------------------------------------------------------
-- 2. Connexion avec le code.
--    CONTRAT MODIFIÉ : en cas d'échec (code invalide, expiré, trop de
--    tentatives), la fonction renvoie { "error": "..." } au lieu de
--    lever une exception — sinon la transaction est annulée et
--    l'échec n'est jamais enregistré. En cas de succès : { token, role }.
--    Le site traite déjà l'absence de « token » comme un échec ; pour
--    afficher le message précis, remplacer dans js/app.js :
--      throw new Error('Code invalide.');
--    par :
--      throw new Error((res && res.error) || 'Code invalide.');
-- ------------------------------------------------------------
create or replace function login_with_code(p_email text, p_code text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := lower(trim(coalesce(p_email, '')));
  v_code    text := trim(coalesce(p_code, ''));
  v_row     login_codes%rowtype;
  v_ip      text := client_ip();
  v_fails   int;
  v_ok      boolean;
  v_role    text;
  v_token   text;
begin
  -- Sérialise les tentatives d'une même IP : le comptage des échecs
  -- ci-dessous n'est alors plus contournable par requêtes parallèles.
  perform pg_advisory_xact_lock(hashtext('login_ip:' || v_ip));

  delete from auth_attempts where attempted_at < now() - interval '2 days';

  -- Verrou par IP : 15 échecs / 15 minutes.
  select count(*) into v_fails
  from auth_attempts
  where kind = 'code' and not success
    and ip = v_ip
    and attempted_at > now() - interval '15 minutes';
  if v_fails >= 15 then
    return json_build_object('error', 'Trop de tentatives. Réessayez dans quelques minutes.');
  end if;

  -- Verrou de ligne : les essais sur un même code sont sérialisés
  -- (5 essais au plus, même en parallèle).
  select * into v_row
  from login_codes
  where lower(email) = v_email
  order by created_at desc
  limit 1
  for update;

  v_ok := found
          and v_row.expires_at >= now()
          and v_row.attempts < 5
          and v_row.code_hash = encode(digest(v_code, 'sha256'), 'hex');

  if not v_ok then
    if found then
      update login_codes set attempts = attempts + 1 where id = v_row.id;
      if v_row.attempts + 1 >= 5 then
        delete from login_codes where id = v_row.id;
      end if;
    end if;

    insert into auth_attempts (ip, success, kind) values (v_ip, false, 'code');

    -- Alerte email quand le seuil de blocage est franchi.
    if v_fails + 1 = 15 then
      perform notify_lockout_email('code', v_ip, v_fails + 1);
    end if;

    return json_build_object('error', 'Code invalide ou expiré');
  end if;

  -- Succès : le code est consommé. Les échecs de l'IP ne sont PAS
  -- remis à zéro (sinon un compte légitime les efface à volonté).
  delete from login_codes where id = v_row.id;

  select role into v_role from members where id = v_row.member_id;
  if v_role is null then
    return json_build_object('error', 'Code invalide ou expiré');
  end if;

  -- Purge des sessions expirées.
  delete from auth_sessions where expires_at < now();

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into auth_sessions (token_hash, role, member_id, expires_at)
  values (
    encode(digest(v_token, 'sha256'), 'hex'),
    v_role,
    v_row.member_id,
    now() + make_interval(mins => app_session_validity_minutes())
  );

  return json_build_object('token', v_token, 'role', v_role);
end $$;

-- ------------------------------------------------------------
-- 6. Suppression d'un membre : jamais le dernier administrateur.
-- ------------------------------------------------------------
create or replace function delete_member(p_session_token text, p_member_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if session_role(p_session_token) is distinct from 'admin' then
    raise exception 'Modifications réservées aux administrateurs';
  end if;

  if (select role from members where id = p_member_id) = 'admin'
     and (
       select count(*) from members
       where role = 'admin' and id <> p_member_id
     ) = 0 then
    raise exception 'Impossible de supprimer le dernier administrateur';
  end if;

  delete from members where id = p_member_id;
end $$;

-- ------------------------------------------------------------
-- 7. Dépôt d'une proposition : champs filtrés, tailles et débit bornés.
-- ------------------------------------------------------------
create or replace function submit_proposal(p_session_token text, p_member_id uuid, p_proposal jsonb)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_user    text;
  v_id      uuid;
  v_payload jsonb;
  v_key     text;
  c_uuid    constant text :=
    '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  v_user := app_username(p_session_token);
  if v_user is null then
    raise exception 'Session invalide ou expirée';
  end if;

  if p_proposal is null or jsonb_typeof(p_proposal) <> 'object' then
    raise exception 'Proposition invalide';
  end if;
  if octet_length(p_proposal::text) > 4000 then
    raise exception 'Proposition trop volumineuse';
  end if;

  if p_member_id is not null
     and not exists (select 1 from members where id = p_member_id) then
    raise exception 'Membre introuvable';
  end if;

  -- Débit : 10 propositions / heure par proposeur, 200 en attente.
  if (
    select count(*) from member_proposals
    where proposed_by = v_user and created_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'Trop de propositions. Réessayez plus tard.';
  end if;
  if (select count(*) from member_proposals where status = 'pending') >= 200 then
    raise exception 'Trop de propositions en attente. Réessayez plus tard.';
  end if;

  -- Validation (nom, prénom, naissance et sexe obligatoires).
  if coalesce(trim(p_proposal->>'last_name'), '') = ''
     or coalesce(trim(p_proposal->>'first_name'), '') = '' then
    raise exception 'Le nom et le prénom sont obligatoires';
  end if;
  if coalesce(p_proposal->>'birth_date', '') = '' then
    raise exception 'La date de naissance est obligatoire';
  end if;
  if coalesce(p_proposal->>'sex', '') not in ('M', 'F') then
    raise exception 'Sexe invalide (M ou F)';
  end if;

  -- Dates valides (un cast invalide lève une erreur avant l'insertion).
  perform (p_proposal->>'birth_date')::date;
  perform nullif(p_proposal->>'wedding_date', '')::date;
  perform nullif(p_proposal->>'death_date', '')::date;

  -- Relations : identifiant de membre ou vide.
  foreach v_key in array array['pere', 'mere', 'spouse'] loop
    if coalesce(p_proposal->>v_key, '') <> ''
       and (p_proposal->>v_key) !~ c_uuid then
      raise exception 'Relation invalide';
    end if;
  end loop;

  -- Liste blanche : seuls les champs connus sont conservés.
  v_payload := jsonb_build_object(
    'last_name',    left(trim(p_proposal->>'last_name'), 100),
    'first_name',   left(trim(p_proposal->>'first_name'), 100),
    'sex',          p_proposal->>'sex',
    'birth_date',   p_proposal->>'birth_date',
    'address',      left(coalesce(p_proposal->>'address', ''), 300),
    'email',        left(coalesce(p_proposal->>'email', ''), 200),
    'wedding_date', coalesce(p_proposal->>'wedding_date', ''),
    'death_date',   coalesce(p_proposal->>'death_date', ''),
    'pere',         coalesce(p_proposal->>'pere', ''),
    'mere',         coalesce(p_proposal->>'mere', ''),
    'spouse',       coalesce(p_proposal->>'spouse', '')
  );

  insert into member_proposals (member_id, proposed_by, payload)
  values (p_member_id, v_user, v_payload)
  returning id into v_id;

  return json_build_object('id', v_id, 'username', v_user);
end $$;

-- ------------------------------------------------------------
-- 8. app_settings : seule la clé family_name est publique.
--    (les durées OTP / session restent lisibles côté serveur par les
--    fonctions security definer.)
-- ------------------------------------------------------------
drop policy if exists "lecture publique des reglages" on app_settings;
create policy "lecture publique des reglages"
  on app_settings
  for select
  using (key = 'family_name');

-- ------------------------------------------------------------
-- 1. Droits d'exécution : tout retirer, puis ré-autoriser seulement
--    les fonctions appelées par le navigateur.
--    À garder en DERNIER dans ce fichier.
--    Conséquence : toute future fonction appelée par le site devra
--    recevoir un « grant execute ... to anon, authenticated » explicite.
-- ------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'request_login_code', 'login_with_code', 'session_role', 'app_logout',
        'get_members', 'upsert_member', 'delete_member', 'set_parent',
        'set_spouse', 'set_member_role', 'submit_proposal', 'list_proposals',
        'accept_proposal', 'reject_proposal', 'site_ping'
      )
  loop
    execute format('grant execute on function %s to anon, authenticated', r.sig);
  end loop;
end $$;

-- ============================================================
-- Vérifications (à lancer après la migration)
-- ============================================================
-- a) Seules les 15 fonctions publiques doivent être exécutables par anon :
--      select p.proname
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--      where n.nspname = 'public'
--        and has_function_privilege('anon', p.oid, 'execute')
--      order by 1;
--
-- b) Les échecs sont enfin enregistrés (après un faux code) :
--      select ip, kind, success, attempted_at
--      from auth_attempts order by attempted_at desc limit 5;
--
-- c) Ce que reçoit la base comme en-têtes (choix de client_ip) :
--      create function debug_headers() returns text language sql as
--        $f$ select current_setting('request.headers', true) $f$;
--      grant execute on function debug_headers() to anon;
--    Appelez-la une fois depuis le navigateur avec un en-tête
--    « X-Forwarded-For: 1.2.3.4 » forgé : l'IP réelle doit apparaître
--    comme cf-connecting-ip ou en DERNIÈRE position de la liste.
--    Puis : drop function debug_headers();
