-- ============================================================
-- Migration 15 — Anti énumération des adresses email
--
-- Problème : request_login_code répondait différemment selon que
-- l'adresse correspondait à un membre (« Code envoyé à X »), à
-- aucun (« Aucun membre ne correspond... ») ou à plusieurs. Un
-- attaquant pouvait donc découvrir quelles adresses email font
-- partie de la famille (sans pouvoir se connecter, mais pour du
-- phishing ou du spam ciblé).
--
-- Corrections :
--   1. Réponse UNIFORME dans tous les cas (adresse inconnue,
--      ambiguë ou valide, y compris en cas d'atteinte des plafonds
--      par adresse) : même message, jamais d'exception dépendante
--      de l'existence de l'adresse. Seule l'erreur de FORMAT reste
--      visible (elle ne révèle rien). Aucun envoi pour les
--      adresses non reconnues.
--   2. Plafond GLOBAL : 500 demandes / 15 minutes toutes IP
--      confondues (les plafonds par IP ne suffisent pas face à une
--      attaque répartie sur plusieurs IP).
--
-- La famille normale est très loin de ces plafonds (1 code par
-- connexion) ; un dépassement du plafond global ne peut être que
-- le fait d'une attaque.
--
-- À exécuter dans le SQL Editor de Supabase, après la migration 14.
-- ============================================================

create or replace function request_login_code(p_email text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := lower(trim(coalesce(p_email, '')));
  v_member  members%rowtype;
  v_ip      text := client_ip();
  v_minutes int := 10;
  v_matched boolean := false;
  v_code    text;
begin
  -- Purge des codes anciens (> 1 jour).
  delete from login_codes where created_at < now() - interval '1 day';

  if v_email = ''
     or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Adresse email invalide';
  end if;

  -- Anti-spam IP : 30 demandes / 15 minutes et par IP.
  if (
    select count(*) from login_codes
    where request_ip = v_ip
      and created_at > now() - interval '15 minutes'
  ) >= 30 then
    raise exception 'Trop de demandes de code. Réessayez plus tard.';
  end if;

  -- Plafond global (toutes IP confondues) : 500 demandes / 15 min.
  -- Les plafonds par IP ne suffisent pas face à une attaque répartie.
  if (
    select count(*) from login_codes
    where created_at > now() - interval '15 minutes'
  ) >= 500 then
    raise exception 'Trop de demandes de code. Réessayez plus tard.';
  end if;

  -- Validité paramétrable (app_settings.otp_validity_minutes, minutes),
  -- lue avant toute divergence de flux.
  begin
    select coalesce(nullif(value, '')::int, 10) into v_minutes
    from app_settings where key = 'otp_validity_minutes';
  exception when others then
    v_minutes := null; -- valeur invalide → défaut
  end;
  if v_minutes is null or v_minutes < 1 then
    v_minutes := 10;
  end if;
  if v_minutes > 1440 then
    v_minutes := 1440; -- au plus 24 h
  end if;

  -- L'adresse doit correspondre à exactement un membre pour qu'un
  -- code soit envoyé ; toute autre adresse reçoit la même réponse
  -- (sans envoi), pour ne rien révéler.
  select * into v_member
  from members
  where lower(trim(coalesce(email, ''))) = v_email;
  if found and (
    select count(*) from members
    where lower(trim(coalesce(email, ''))) = v_email
  ) = 1 then
    v_matched := true;
  end if;

  -- Même pour une adresse reconnue, les plafonds d'envoi (60 s
  -- minimum entre deux envois, 10/h par adresse) ne produisent
  -- PAS d'exception : dépasser un plafond doit être indiscernable
  -- d'une adresse inconnue, sinon deux sondes consécutives
  -- suffiraient à confirmer l'existence de l'adresse. Dans ce cas
  -- (comme pour une adresse inconnue) aucun code n'est envoyé.
  if v_matched
     and not exists (
       select 1 from login_codes
       where lower(email) = v_email
         and created_at > now() - interval '60 seconds'
     )
     and (
       select count(*) from login_codes
       where lower(email) = v_email
         and created_at > now() - interval '1 hour'
     ) < 10 then

    -- Un seul code actif par adresse : les précédents sont invalidés.
    delete from login_codes where lower(email) = v_email;

    -- Code à 8 chiffres, stocké hashé (jamais en clair en base) ;
    -- tirage sur 40 bits pour un biais de modulo négligeable.
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

  return format(
    'Si un membre de la famille correspond à cette adresse, un code lui a été envoyé (valable %s minutes).',
    v_minutes
  );
end $$;
