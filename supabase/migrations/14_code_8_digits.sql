-- ============================================================
-- Migration 14 — Code de connexion à 8 chiffres
--
-- Le code à usage unique envoyé par email passe de 6 à 8 chiffres
-- (grille de 100 000 000 de combinaisons). Seule la génération
-- change : request_login_code est recréée à l'identique avec un
-- tirage sur 40 bits (gen_random_bytes(5)) pour limiter le biais
-- du modulo. La comparaison se fait sur le hash SHA-256 : aucun
-- autre changement (login_with_code, tentatives, verrous...).
--
-- À exécuter dans le SQL Editor de Supabase, après la migration 13.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Demande de code : identique à la migration 13, seul le
--    format du code change (8 chiffres).
-- ------------------------------------------------------------
create or replace function request_login_code(p_email text)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_email    text := lower(trim(coalesce(p_email, '')));
  v_member   members%rowtype;
  v_ip       text := client_ip();
  v_minutes  int;
  v_code     text;
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

  -- L'email doit correspondre à exactement un membre.
  select * into v_member
  from members
  where lower(trim(coalesce(email, ''))) = v_email;
  if not found then
    raise exception 'Aucun membre ne correspond à cette adresse email';
  end if;
  if (
    select count(*) from members
    where lower(trim(coalesce(email, ''))) = v_email
  ) > 1 then
    raise exception 'Plusieurs membres partagent cette adresse. Contactez un administrateur.';
  end if;

  -- Délai entre deux envois pour la même adresse.
  if exists (
    select 1 from login_codes
    where lower(email) = v_email
      and created_at > now() - interval '60 seconds'
  ) then
    raise exception 'Un code vient d''être envoyé. Attendez une minute avant de redemander.';
  end if;

  -- Plafond horaire par adresse.
  if (
    select count(*) from login_codes
    where lower(email) = v_email
      and created_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'Trop de codes demandés pour cette adresse. Réessayez dans une heure.';
  end if;

  -- Validité paramétrable (app_settings.otp_validity_minutes, minutes).
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

  -- Un seul code actif par adresse : les précédents sont invalidés.
  delete from login_codes where lower(email) = v_email;

  -- Code à 8 chiffres, stocké hashé (jamais en clair en base).
  -- Tirage sur 40 bits (5 octets de gen_random_bytes) modulo 1e8 :
  -- biais de modulo négligeable, contrairement à un tirage sur 32 bits.
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

  return format('Code envoyé à %s (valable %s minutes).', v_member.email, v_minutes);
end $$;
