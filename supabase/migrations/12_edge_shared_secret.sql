-- ============================================================
-- Migration 12 — Protection des Edge Functions par secret partagé
--
-- Les fonctions Edge (notify-proposal, notify-lockout) vérifient
-- désormais l'en-tête « x-webhook-secret » contre le secret
-- EDGE_SHARED_SECRET défini dans les secrets Supabase. Sans lui :
-- réponse 401. Les appels légitimes partent toujours de Postgres
-- (pg_net), le secret ne se trouve jamais côté navigateur.
--
-- La notification de proposition, qui était déclenchée depuis le
-- navigateur, l'est maintenant par un trigger Postgres à l'insertion
-- d'une ligne dans member_proposals (aucun autre changement : les
-- emails partent du même SMTP).
--
-- Installation :
--   1. supabase secrets set EDGE_SHARED_SECRET="<valeur longue aléatoire>"
--   2. même valeur en base :
--      insert into app_secrets (key, value)
--      values ('edge_shared_secret', '<la même valeur>');
--   3. redéployer les deux fonctions Edge.
--
-- À exécuter dans le SQL Editor de Supabase.
-- ============================================================

-- Coffre privé : RLS activée, aucune policy, aucun grant → lisible
-- uniquement par les fonctions security definer du propriétaire.
create table if not exists app_secrets (
  key   text primary key,
  value text not null
);

alter table app_secrets enable row level security;

-- ------------------------------------------------------------
-- Envoi de la notification de proposition (pg_net → Edge Function).
-- ------------------------------------------------------------
create or replace function notify_proposal_email(
  p_member_name text,
  p_user        text,
  p_changes     jsonb,
  p_kind        text default 'edition'
)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  -- URL de la fonction et clé publique du projet (à ajuster si le
  -- projet change) : voyez js/config.js.
  v_url     text := 'https://bzpjyaajphhdtmdbugat.supabase.co/functions/v1/notify-proposal';
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
    'member', p_member_name,
    'proposed_by', p_user,
    'changes', p_changes,
    'kind', p_kind
  );
  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'apikey', v_key,
    'Authorization', 'Bearer ' || v_key,
    'x-webhook-secret', v_secret
  );

  begin
    perform net.http_post(
      v_url,
      v_body,
      '{}'::jsonb,
      v_headers,
      5000
    );
  exception when others then
    null; -- la notification ne doit jamais bloquer la proposition
  end;
end $$;

-- ------------------------------------------------------------
-- Trigger : à chaque proposition insérée (modification ou création),
-- calcule les différences vs la fiche en base puis notifie les admins.
-- ------------------------------------------------------------
create or replace function fn_after_proposal_insert()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_row        members%rowtype;
  v_member     text;
  v_changes    jsonb := '[]'::jsonb;
  v_kind       text := 'edition';
  v_fields     text[] := array[
    'first_name', 'last_name', 'sex', 'birth_date',
    'address', 'email', 'wedding_date', 'death_date'
  ];
begin
  if new.member_id is not null then
    select * into v_row from members where id = new.member_id;
    v_member := v_row.first_name || ' ' || v_row.last_name;

    -- Différences entre le payload proposé et la fiche actuelle.
    select coalesce(jsonb_agg(jsonb_build_object(
      'field', case f
        when 'first_name'   then 'Prénom'
        when 'last_name'    then 'Nom'
        when 'sex'          then 'Sexe'
        when 'birth_date'   then 'Date de naissance'
        when 'address'      then 'Adresse'
        when 'email'        then 'Adresse email'
        when 'wedding_date' then 'Date de mariage'
        when 'death_date'   then 'Date de décès'
        else f
      end,
      'from', to_jsonb(v_row) ->> f,
      'to',   new.payload ->> f
    )), '[]'::jsonb)
    into v_changes
    from unnest(v_fields) as f
    where coalesce(new.payload ->> f, '')
          is distinct from
          coalesce(to_jsonb(v_row) ->> f, '');
  else
    -- Proposition de création : tous les champs fournis sont nouveaux.
    v_kind := 'creation';
    v_member := coalesce(new.payload ->> 'first_name', '') || ' ' ||
                coalesce(new.payload ->> 'last_name', '');

    select coalesce(jsonb_agg(jsonb_build_object(
      'field', case f
        when 'first_name'   then 'Prénom'
        when 'last_name'    then 'Nom'
        when 'sex'          then 'Sexe'
        when 'birth_date'   then 'Date de naissance'
        when 'address'      then 'Adresse'
        when 'email'        then 'Adresse email'
        when 'wedding_date' then 'Date de mariage'
        when 'death_date'   then 'Date de décès'
        else f
      end,
      'from', null,
      'to',   new.payload ->> f
    )), '[]'::jsonb)
    into v_changes
    from unnest(v_fields) as f
    where new.payload ->> f is not null;
  end if;

  perform notify_proposal_email(v_member, new.proposed_by, v_changes, v_kind);

  return new;
end $$;

drop trigger if exists trg_proposal_notify on member_proposals;
create trigger trg_proposal_notify
  after insert on member_proposals
  for each row execute function fn_after_proposal_insert();
