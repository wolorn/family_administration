// Utilitaires partagés (dates, âge, libellés, liens externes).

export function parseDate(iso) {
  if (!iso) return null;
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d);
}

export function formatDate(iso) {
  const d = parseDate(iso);
  if (!d) return '—';
  return d.toLocaleDateString('fr-FR');
}

export function todayISO() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function ageOf(member) {
  const birth = parseDate(member.birth_date);
  if (!birth) return null;
  const ref = parseDate(member.death_date) || parseDate(todayISO());
  let age = ref.getFullYear() - birth.getFullYear();
  const beforeBirthday =
    ref.getMonth() < birth.getMonth() ||
    (ref.getMonth() === birth.getMonth() && ref.getDate() < birth.getDate());
  if (beforeBirthday) age--;
  return Math.max(age, 0);
}

export const SEX_LABEL = { M: 'Masculin', F: 'Féminin' };

function isIos() {
  return (
    /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  );
}

// Lien cartographique adapté à l'appareil :
// - Android (pointer tactile) : URI geo: (le système propose quelle app ouvrir)
// - iOS : lien Maps Apple (comportement équivalent)
// - bureau : recherche web Google Maps
export function addressHref(address) {
  const q = encodeURIComponent(address);
  const coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
  if (coarse && isIos()) return `https://maps.apple.com/?q=${q}`;
  if (coarse) return `geo:0,0?q=${q}`;
  return `https://www.google.com/maps/search/?api=1&query=${q}`;
}
