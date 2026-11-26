import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { parseDate, formatDate, todayISO, ageOf, SEX_LABEL, addressHref } from './utils.js';
import { openExportModal } from './export.js';
import { openTree, closeTree } from './tree.js';

// ------------------------------------------------------------
// Configuration et client Supabase
// ------------------------------------------------------------
const supabaseUrl = window.FAMILY_SUPABASE_URL || '';
const supabaseKey = window.FAMILY_SUPABASE_ANON_KEY || '';
const isConfigured =
  supabaseUrl.startsWith('https://') &&
  !supabaseUrl.includes('VOTRE-PROJET') &&
  supabaseKey.length > 20 &&
  !supabaseKey.includes('VOTRE_CLE');

const supabase = isConfigured ? createClient(supabaseUrl, supabaseKey) : null;

// ------------------------------------------------------------
// État
// ------------------------------------------------------------
let sessionToken = sessionStorage.getItem('family_admin_session') || '';
let role = null;
let members = [];
let formMode = 'edit'; // 'edit' (admin) | 'proposal' (proposition d'un viewer)
let proposals = [];
let successTimer = null;

// ------------------------------------------------------------
// Raccourcis DOM
// ------------------------------------------------------------
const $ = (id) => document.getElementById(id);

const els = {
  familyName: $('family-name'),
  loginSection: $('login-section'),  loginForm: $('login-form'),
  loginEmail: $('login-email'),
  loginError: $('login-error'),
  codeForm: $('code-form'),
  codeHint: $('code-hint'),
  loginCode: $('login-code'),
  codeError: $('code-error'),
  resendBtn: $('resend-btn'),
  configError: $('config-error'),
  appSection: $('app-section'),
  sessionBar: $('session-bar'),
  sessionUser: $('session-user'),
  logoutBtn: $('logout-btn'),
  searchInput: $('search-input'),
  countLabel: $('count-label'),
  readActions: $('read-actions'),
  treeBtn: $('tree-btn'),
  exportBtn: $('export-btn'),
  copyEmailsBtn: $('copy-emails-btn'),
  proposeAddBtn: $('propose-add-btn'),
  treeOverlay: $('tree-overlay'),
  treeCloseBtn: $('tree-close-btn'),
  birthdayBanner: $('birthday-banner'),
  adminActions: $('admin-actions'),
  addMemberBtn: $('add-member-btn'),
  proposalsBtn: $('proposals-btn'),
  globalSuccess: $('global-success'),
  globalError: $('global-error'),
  tbody: $('members-tbody'),
  thActions: $('th-actions'),
  emptyMsg: $('empty-msg'),
  proposalsSection: $('proposals-section'),
  proposalsList: $('proposals-list'),
  proposalsError: $('proposals-error'),
  memberModal: $('member-modal'),
  memberModalTitle: $('member-modal-title'),
  memberDetails: $('member-details'),
  memberAdminActions: $('member-admin-actions'),
  memberViewerActions: $('member-viewer-actions'),
  proposeBtn: $('propose-btn'),
  editMemberBtn: $('edit-member-btn'),
  memberRoleBtn: $('member-role-btn'),
  deleteMemberBtn: $('delete-member-btn'),
  memberError: $('member-error'),
  formModal: $('member-form-modal'),
  formTitle: $('member-form-title'),
  form: $('member-form'),
  formNote: $('form-note'),
  formError: $('form-error'),
  formSubmit: $('form-submit'),
};

// ------------------------------------------------------------
// Appel RPC générique : le token de session est injecté
// automatiquement dans chaque requête (sauf les étapes de connexion
// par email/code). Aucun mot de passe n'est jamais transmis.
// ------------------------------------------------------------
const RPC_NO_SESSION = new Set(['request_login_code', 'login_with_code']);

function rpc(name, args = {}) {
  if (!supabase) {
    return Promise.reject(new Error('Supabase non configuré. Éditez js/config.js.'));
  }
  const payload = sessionToken && !RPC_NO_SESSION.has(name)
    ? { ...args, p_session_token: sessionToken }
    : args;
  return supabase.rpc(name, payload).then(({ data, error }) => {
    if (error) throw new Error(error.message);
    return data;
  }).catch((err) => {
    // Session tombée en cours d'usage (expiration, révocation) :
    // retour à l'écran de connexion.
    if (sessionToken && /session invalide|expirée/i.test(err.message)) {
      endSession();
    }
    throw err;
  });
}

function showError(element, message) {
  element.textContent = message;
  element.hidden = false;
}

function clearError(element) {
  element.hidden = true;
}

// Tri par jour de l'année de naissance (anniversaires).
function birthdayKey(member) {
  const d = parseDate(member.birth_date);
  if (!d) return [99, 99];
  return [d.getMonth() + 1, d.getDate()];
}

async function loadFamilyName() {
  if (!supabase) return;
  const { data, error } = await supabase
    .from('app_settings')
    .select('value')
    .eq('key', 'family_name')
    .maybeSingle();
  if (error || !data || !data.value) {
    els.familyName.textContent = 'Administration familiale';
    return;
  }
  els.familyName.textContent = data.value;
  document.title = `${data.value} — Administration familiale`;
}

// ------------------------------------------------------------
// Session
// ------------------------------------------------------------
// Adresse email en attente de code (étape 1 → étape 2 du login).
let pendingLoginEmail = '';

function showLoginStep(step) {
  els.codeError.hidden = true;
  els.loginError.hidden = true;
  if (step === 'email') {
    els.loginForm.hidden = false;
    els.codeForm.hidden = true;
    pendingLoginEmail = '';
  } else {
    els.loginForm.hidden = true;
    els.codeForm.hidden = false;
    els.codeHint.textContent = `Un code à usage unique a été envoyé à ${pendingLoginEmail}.`;
    els.loginCode.value = '';
    els.loginCode.focus();
  }
}

// Étape 1 : demande d'un code (envoyé par email via la base).
async function sendLoginCode() {
  els.loginForm.hidden = false;
  try {
    els.loginForm.querySelector('button[type="submit"]').disabled = true;
    const msg = await rpc('request_login_code', { p_email: els.loginEmail.value.trim() });
    pendingLoginEmail = els.loginEmail.value.trim().toLowerCase();
    els.codeHint.hidden = false;
    showLoginStep('code');
    if (msg) els.codeHint.textContent = msg;
  } catch (err) {
    showError(els.loginError, err.message);
  } finally {
    els.loginForm.querySelector('button[type="submit"]').disabled = false;
  }
}

// Étape 2 : connexion avec le code reçu.
async function loginWithCode() {
  try {
    els.loginCode.disabled = true;
    const res = await rpc('login_with_code', {
      p_email: pendingLoginEmail,
      p_code: els.loginCode.value.trim(),
    });
    // Depuis la migration 16, login_with_code renvoie { error } au lieu de lever
    // une exception (sinon l'échec n'est pas enregistré) : afficher le message précis.
    if (!res || !res.token) throw new Error((res && res.error) || 'Code invalide.');
    sessionToken = res.token;
    role = res.role;
    sessionStorage.setItem('family_admin_session', res.token);
    await loadMembers();
    showApp();
  } catch (err) {
    showError(els.codeError, err.message);
  } finally {
    els.loginCode.disabled = false;
  }
}

function endSession() {
  sessionToken = '';
  role = null;
  members = [];
  sessionStorage.removeItem('family_admin_session');
  els.appSection.hidden = true;
  els.sessionBar.hidden = true;
  els.loginSection.hidden = false;
  showLoginStep('email');
  els.loginEmail.value = '';
  proposals = [];
  els.proposalsSection.hidden = true;
}

function logout() {
  // Révocation côté serveur (meilleur effort) puis nettoyage local.
  if (sessionToken) {
    rpc('app_logout', {}).catch(() => {});
  }
  endSession();
}

function showApp() {
  els.loginSection.hidden = true;
  els.appSection.hidden = false;
  els.sessionBar.hidden = false;
  els.sessionUser.textContent = role === 'admin'
    ? 'Connecté : administrateur'
    : 'Connecté : utilisateur (lecture seule)';
  const isAdmin = role === 'admin';
  els.adminActions.hidden = !isAdmin;
  els.readActions.hidden = false;
  els.proposeAddBtn.hidden = isAdmin;
  els.thActions.hidden = !isAdmin;
  updateSortIndicators();
  renderTable();
  if (isAdmin) refreshProposalsCount();
}

function showGlobalError(message) {
  showError(els.globalError, message);
}

async function loadMembers() {
  members = (await rpc('get_members', {})) || [];
  renderTable();
  renderBirthdayBanner();
}

// ------------------------------------------------------------
// Anniversaires du jour
// ------------------------------------------------------------
function renderBirthdayBanner() {
  const today = parseDate(todayISO());
  const md = (d) =>
    `${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const todayMd = md(today);
  const leap = (y) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const names = [];
  for (const m of members) {
    if (m.death_date) continue;
    const b = parseDate(m.birth_date);
    if (!b) continue;
    const bMd = md(b);
    // Le 29 février est fêté le 28 les années non bissextiles.
    const match =
      bMd === todayMd ||
      (!leap(today.getFullYear()) && todayMd === '02-28' && bMd === '02-29');
    if (match) names.push(`${m.first_name} ${m.last_name} (${ageOf(m)} ans)`);
  }
  if (names.length === 0) {
    els.birthdayBanner.hidden = true;
    return;
  }
  const listed = names.length > 1 ? names.slice(0, -1).join(', ') + ' et ' + names.at(-1) : names[0];
  els.birthdayBanner.textContent = `Joyeux anniversaire à ${listed} !`;
  els.birthdayBanner.hidden = false;
}

// ------------------------------------------------------------
// Tableau principal : tri par colonne + recherche
// ------------------------------------------------------------

const tieBreak = (a, b) =>
  a.last_name.localeCompare(b.last_name) || a.first_name.localeCompare(b.first_name);

const sorters = {
  birthday: (a, b) => {
    const ka = birthdayKey(a);
    const kb = birthdayKey(b);
    return (ka[0] - kb[0]) || (ka[1] - kb[1]) || tieBreak(a, b);
  },
  first_name: (a, b) => a.first_name.localeCompare(b.first_name) || tieBreak(a, b),
  last_name: (a, b) => a.last_name.localeCompare(b.last_name) || tieBreak(a, b),
  birth_date: (a, b) =>
    (a.birth_date || '').localeCompare(b.birth_date || '') || tieBreak(a, b),
  age: (a, b) => ((ageOf(a) ?? -1) - (ageOf(b) ?? -1)) || tieBreak(a, b),
};

let sortState = { key: 'birthday', dir: 1 };

function updateSortIndicators() {
  for (const th of document.querySelectorAll('#members-table th.sortable')) {
    const key = th.dataset.sort;
    const ind = th.querySelector('.sort-ind');
    if (key === sortState.key) {
      ind.textContent = sortState.dir === 1 ? ' ↑' : ' ↓';
      th.setAttribute('aria-sort', sortState.dir === 1 ? 'ascending' : 'descending');
    } else {
      ind.textContent = '';
      th.removeAttribute('aria-sort');
    }
  }
  // Contrôle de tri mobile : reste synchronisé avec l'état du tri.
  const mobileKey = document.getElementById('mobile-sort-key');
  if (mobileKey) mobileKey.value = sortState.key;
  const mobileDir = document.getElementById('mobile-sort-dir');
  if (mobileDir) mobileDir.textContent = sortState.dir === 1 ? '↑' : '↓';
}

function getVisibleMembers() {
  const query = els.searchInput.value.trim().toLowerCase();
  const sorted = [...members].sort((a, b) => sorters[sortState.key](a, b) * sortState.dir);
  return query
    ? sorted.filter((m) => memberSearchText(m).includes(query))
    : sorted;
}

function memberSearchText(member) {
  const parts = [
    member.first_name,
    member.last_name,
    member.sex,
    SEX_LABEL[member.sex],
    member.birth_date,
    formatDate(member.birth_date),
    member.address,
    member.email,
    member.wedding_date,
    member.death_date,
  ];
  return parts.filter(Boolean).join(' ').toLowerCase();
}

function renderTable() {
  const visible = getVisibleMembers();

  els.tbody.textContent = '';
  for (const m of visible) {
    const tr = document.createElement('tr');
    tr.className = m.death_date ? 'deceased' : '';

    const tdFirst = document.createElement('td');
    tdFirst.textContent = m.first_name;
    const tdLast = document.createElement('td');
    tdLast.textContent = m.last_name;
    const tdBirth = document.createElement('td');
    tdBirth.textContent = formatDate(m.birth_date);
    const tdAge = document.createElement('td');
    const age = ageOf(m);
    tdAge.textContent = m.death_date ? `${age} ans (décédé·e)` : `${age} ans`;

    // Libellés utilisés par l'affichage en cartes sur mobile.
    tdFirst.dataset.label = 'Prénom';
    tdLast.dataset.label = 'Nom';
    tdBirth.dataset.label = 'Naissance';
    tdAge.dataset.label = 'Âge';

    tr.append(tdFirst, tdLast, tdBirth, tdAge);

    if (role === 'admin') {
      const tdActions = document.createElement('td');
      const editBtn = document.createElement('button');
      editBtn.type = 'button';
      editBtn.textContent = 'Modifier';
      editBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        openMemberForm(m);
      });
      const deleteBtn = document.createElement('button');
      deleteBtn.type = 'button';
      deleteBtn.textContent = 'Supprimer';
      deleteBtn.classList.add('danger');
      deleteBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        deleteMember(m);
      });
      tdActions.append(editBtn, deleteBtn);
      tdActions.dataset.label = 'Actions';
      tr.appendChild(tdActions);
    }

    tr.addEventListener('click', () => openMemberModal(m.id));
    els.tbody.appendChild(tr);
  }

  els.countLabel.textContent = `${visible.length} membre${visible.length > 1 ? 's' : ''}`;
  els.emptyMsg.hidden = visible.length > 0;
}

// ------------------------------------------------------------
// Recherche
// ------------------------------------------------------------
els.searchInput.addEventListener('input', renderTable);

// Contrôle de tri mobile (l'en-tête du tableau est masqué sur petit écran).
const mobileSortKey = document.getElementById('mobile-sort-key');
const mobileSortDir = document.getElementById('mobile-sort-dir');
if (mobileSortKey) {
  mobileSortKey.value = sortState.key;
  mobileSortKey.addEventListener('change', () => {
    sortState = { key: mobileSortKey.value, dir: sortState.dir };
    updateSortIndicators();
    renderTable();
  });
}
if (mobileSortDir) {
  mobileSortDir.addEventListener('click', () => {
    sortState.dir = -sortState.dir;
    updateSortIndicators();
    renderTable();
  });
}

// ------------------------------------------------------------
// Fiche détaillée
// ------------------------------------------------------------
function findMember(id) {
  return members.find((m) => m.id === id);
}

function relationItems(member, key, label) {
  const list = member[key] || [];
  if (list.length === 0) return null;

  const group = document.createElement('div');
  group.className = 'relation-group';

  const title = document.createElement('h3');
  title.textContent = `${label} (${list.length})`;
  group.appendChild(title);

  const ul = document.createElement('ul');
  ul.className = 'relation-list';
  for (const r of list) {
    const li = document.createElement('li');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = `${r.first_name} ${r.last_name} (${formatDate(r.birth_date)})`;
    btn.addEventListener('click', () => openMemberModal(r.id));
    li.appendChild(btn);
    ul.appendChild(li);
  }
  group.appendChild(ul);
  return group;
}

// Adresse à afficher pour un membre : sa propre adresse, sinon celle
// de son conjoint, sinon celle d'un parent pour un mineur. Renvoie
// { address, source } ou null si aucune adresse n'est trouvée ; source
// explique l'origine de l'adresse de substitution.
function displayAddress(member) {
  if (member.address) return { address: member.address, source: null };

  const spouse = (member.spouse || [])[0];
  if (spouse) {
    const s = findMember(spouse.id);
    if (s && s.address) {
      return {
        address: s.address,
        source: `adresse de ${s.first_name} ${s.last_name}, conjoint`,
      };
    }
  }

  const MINOR_AGE = 18;
  if ((ageOf(member) ?? Infinity) < MINOR_AGE) {
    for (const p of member.parents || []) {
      const pm = findMember(p.id);
      if (pm && pm.address) {
        return {
          address: pm.address,
          source: `adresse de ${pm.first_name} ${pm.last_name}, parent`,
        };
      }
    }
  }

  return null;
}

function openMemberModal(id) {
  const m = findMember(id);
  if (!m) return;
  clearError(els.memberError);

  els.memberModalTitle.textContent = `${m.first_name} ${m.last_name}`;
  els.memberDetails.textContent = '';

  const dl = document.createElement('div');
  dl.className = 'detail-list';
  // Adresse affichée : celle du membre, sinon celle du conjoint,
  // ou du parent pour un mineur (jamais modifiée ici : le formulaire
  // n'édite que l'adresse propre au membre).
  const shownAddress = displayAddress(m);
  const rows = [
    { label: 'Sexe', value: SEX_LABEL[m.sex] || m.sex },
    { label: 'Naissance', value: formatDate(m.birth_date) },
    {
      label: 'Adresse',
      value: shownAddress ? shownAddress.address : null,
      href: shownAddress ? addressHref(shownAddress.address) : null,
      copy: shownAddress ? shownAddress.address : null,
      note: shownAddress ? shownAddress.source : null,
    },
    { label: 'Email', value: m.email, href: m.email ? `mailto:${m.email}` : null, copy: m.email },
    { label: 'Mariage', value: m.wedding_date ? formatDate(m.wedding_date) : null },
    { label: 'Décès', value: m.death_date ? formatDate(m.death_date) : null },
  ];
  for (const { label, value, href, copy, note } of rows) {
    if (value == null) continue;
    const row = document.createElement('div');
    const dt = document.createElement('dt');
    const dd = document.createElement('dd');
    dt.textContent = label;
    if (href) {
      const a = document.createElement('a');
      a.href = href;
      a.textContent = value;
      a.className = 'detail-link';
      dd.appendChild(a);
    } else {
      dd.textContent = value;
    }
    if (note) {
      const span = document.createElement('span');
      span.className = 'address-source';
      span.textContent = ` (${note})`;
      dd.appendChild(span);
    }
    if (copy) {
      const copyBtn = document.createElement('button');
      copyBtn.type = 'button';
      copyBtn.className = 'copy-mini';
      copyBtn.textContent = 'Copier';
      copyBtn.addEventListener('click', async () => {
        const ok = await copyToClipboard(copy);
        copyBtn.textContent = ok ? 'Copié !' : 'Erreur';
        setTimeout(() => { copyBtn.textContent = 'Copier'; }, 1500);
      });
      dd.appendChild(document.createTextNode(' '));
      dd.appendChild(copyBtn);
    }
    row.append(dt, dd);
    dl.appendChild(row);
  }
  els.memberDetails.appendChild(dl);

  for (const [key, label] of [
    ['parents', 'Parents'],
    ['children', 'Enfants'],
    ['siblings', 'Frères et sœurs'],
    ['spouse', 'Conjoint'],
  ]) {
    const group = relationItems(m, key, label);
    if (group) els.memberDetails.appendChild(group);
  }

  els.memberAdminActions.hidden = role !== 'admin';
  els.memberViewerActions.hidden = role === 'admin';
  els.editMemberBtn.onclick = () => {
    els.memberModal.close();
    openMemberForm(m);
  };
  // Bascule administration (rôle porté par le membre, migration 13).
  if (role === 'admin') {
    els.memberRoleBtn.textContent = m.role === 'admin'
      ? 'Retirer le rôle admin'
      : 'Donner le rôle admin';
    els.memberRoleBtn.onclick = async () => {
      try {
        await rpc('set_member_role', {
          p_member_id: m.id,
          p_role: m.role === 'admin' ? 'user' : 'admin',
        });
        els.memberModal.close();
        await loadMembers();
        showGlobalSuccess(m.role === 'admin'
          ? 'Rôle admin retiré.'
          : 'Rôle admin accordé.');
      } catch (err) {
        if (!els.memberModal.open) showGlobalError(err.message);
        else showError(els.memberError, err.message);
      }
    };
  }
  els.deleteMemberBtn.onclick = () => {
    deleteMember(m);
  };
  els.proposeBtn.onclick = () => {
    els.memberModal.close();
    openMemberForm(m, 'proposal');
  };
  els.memberModal.showModal();
}

// ------------------------------------------------------------
// Formulaire d'ajout / modification
// ------------------------------------------------------------
function fillParentSelect(selectId, currentParentId, excludeId) {
  const select = $(selectId);
  select.textContent = '';
  const none = document.createElement('option');
  none.value = '';
  none.textContent = '(aucun)';
  select.appendChild(none);
  for (const m of members) {
    if (m.id === excludeId) continue;
    if (selectId === 'f-pere' && m.sex !== 'M') continue;
    if (selectId === 'f-mere' && m.sex !== 'F') continue;
    const opt = document.createElement('option');
    opt.value = m.id;
    opt.textContent = `${m.first_name} ${m.last_name} (${formatDate(m.birth_date)})`;
    if (m.id === currentParentId) opt.selected = true;
    select.appendChild(opt);
  }
  return select;
}

function parentsOf(member, sex) {
  return (member.parents || []).find((p) => p.sex === sex) || null;
}

function fillSpouseSelect(currentSpouseId, excludeId) {
  const select = $('f-conjoint');
  select.textContent = '';
  const none = document.createElement('option');
  none.value = '';
  none.textContent = '(aucun)';
  select.appendChild(none);
  for (const m of members) {
    if (m.id === excludeId) continue;
    const opt = document.createElement('option');
    opt.value = m.id;
    opt.textContent = `${m.first_name} ${m.last_name} (${formatDate(m.birth_date)})`;
    if (m.id === currentSpouseId) opt.selected = true;
    select.appendChild(opt);
  }
}

function openMemberForm(member, mode = 'edit') {
  formMode = mode === 'proposal' ? 'proposal' : 'edit';
  clearError(els.formError);
  els.formNote.hidden = formMode !== 'proposal';
  if (formMode === 'proposal') {
    els.formTitle.textContent = member
      ? 'Proposer une modification'
      : "Proposer l'ajout d'un membre";
  } else {
    els.formTitle.textContent = member ? 'Modifier le membre' : 'Nouveau membre';
  }
  $('f-first-name').value = member ? member.first_name : '';
  $('f-last-name').value = member ? member.last_name : '';
  $('f-sex').value = member ? member.sex : '';
  $('f-birth-date').value = member ? member.birth_date : '';
  $('f-address').value = member ? member.address || '' : '';
  $('f-email').value = member ? member.email || '' : '';
  $('f-wedding-date').value = member ? member.wedding_date || '' : '';
  $('f-death-date').value = member ? member.death_date || '' : '';

  const father = member ? parentsOf(member, 'M') : null;
  const mother = member ? parentsOf(member, 'F') : null;
  fillParentSelect('f-pere', father ? father.id : null, member ? member.id : null);
  fillParentSelect('f-mere', mother ? mother.id : null, member ? member.id : null);
  const spouse = member && (member.spouse || [])[0];
  fillSpouseSelect(spouse ? spouse.id : null, member ? member.id : null);

  els.formSubmit.textContent = formMode === 'proposal'
    ? 'Envoyer la proposition'
    : (member ? 'Enregistrer' : 'Créer');
  els.form.onsubmit = (e) => {
    e.preventDefault();
    if (formMode === 'proposal') submitProposal(member);
    else saveMember(member);
  };
  els.formModal.showModal();
}

async function saveMember(existing) {
  clearError(els.formError);
  const payload = {
    id: existing ? existing.id : null,
    last_name: $('f-last-name').value.trim(),
    first_name: $('f-first-name').value.trim(),
    sex: $('f-sex').value,
    birth_date: $('f-birth-date').value,
    address: $('f-address').value.trim(),
    email: $('f-email').value.trim(),
    wedding_date: $('f-wedding-date').value || null,
    death_date: $('f-death-date').value || null,
  };
  const newFather = $('f-pere').value || null;
  const newMother = $('f-mere').value || null;
  const oldFather = existing ? (parentsOf(existing, 'M') || {}).id || null : null;
  const oldMother = existing ? (parentsOf(existing, 'F') || {}).id || null : null;
  const newSpouse = $('f-conjoint').value || null;
  const oldSpouse = existing && existing.spouse && existing.spouse[0] ? existing.spouse[0].id : null;

  try {
    els.formSubmit.disabled = true;
    const memberId = await rpc('upsert_member', { p_member: payload });
    if (newFather !== oldFather) {
      await rpc('set_parent', {
                p_child_id: memberId,
        p_parent_id: newFather,
        p_slot: 'pere',
      });
    }
    if (newMother !== oldMother) {
      await rpc('set_parent', {
                p_child_id: memberId,
        p_parent_id: newMother,
        p_slot: 'mere',
      });
    }
    if (newSpouse !== oldSpouse) {
      await rpc('set_spouse', {
                p_member_id: memberId,
        p_spouse_id: newSpouse,
      });
    }
    els.formModal.close();
    await loadMembers();
  } catch (err) {
    showError(els.formError, err.message);
  } finally {
    els.formSubmit.disabled = false;
  }
}

// ------------------------------------------------------------
// Proposals de modification (viewer) et revue (admin)
// ------------------------------------------------------------
const PROPOSAL_FIELDS = [
  ['first_name', 'Prénom'],
  ['last_name', 'Nom'],
  ['sex', 'Sexe'],
  ['birth_date', 'Date de naissance'],
  ['address', 'Adresse'],
  ['email', 'Adresse email'],
  ['wedding_date', 'Date de mariage'],
  ['death_date', 'Date de décès'],
  ['pere', 'Père'],
  ['mere', 'Mère'],
  ['spouse', 'Conjoint'],
];

const DATE_FIELDS = new Set(['birth_date', 'wedding_date', 'death_date']);
const RELATION_FIELDS = new Set(['pere', 'mere', 'spouse']);

// Valeur brute actuelle d'un champ (ids de relations inclus).
function currentFieldValue(member, key) {
  if (!member) return null;
  if (key === 'pere') return parentsOf(member, 'M') ? parentsOf(member, 'M').id : null;
  if (key === 'mere') return parentsOf(member, 'F') ? parentsOf(member, 'F').id : null;
  if (key === 'spouse') return member.spouse && member.spouse[0] ? member.spouse[0].id : null;
  return member[key] ?? null;
}

// Valeur lisible d'un champ brut (pour diff, tableau et email).
function formatProposalValue(key, raw) {
  if (raw == null || raw === '') return null;
  if (key === 'sex') return SEX_LABEL[raw] || raw;
  if (DATE_FIELDS.has(key)) return formatDate(raw);
  if (RELATION_FIELDS.has(key)) {
    const m = findMember(raw);
    return m ? `${m.first_name} ${m.last_name}` : '(membre inconnu)';
  }
  return raw;
}

// Soumission d'une proposition (modification ou ajout) par un
// utilisateur non admin. existing = membre concerné, null pour
// une proposition de création.
async function submitProposal(existing) {
  clearError(els.formError);
  const payload = {
    last_name: $('f-last-name').value.trim(),
    first_name: $('f-first-name').value.trim(),
    sex: $('f-sex').value,
    birth_date: $('f-birth-date').value,
    address: $('f-address').value.trim(),
    email: $('f-email').value.trim(),
    wedding_date: $('f-wedding-date').value || '',
    death_date: $('f-death-date').value || '',
    pere: $('f-pere').value || '',
    mere: $('f-mere').value || '',
    spouse: $('f-conjoint').value || '',
  };
  try {
    els.formSubmit.disabled = true;
    const res = await rpc('submit_proposal', {
      p_member_id: existing ? existing.id : null,
      p_proposal: payload,
    });
    // Notification email des admins : déclenchée côté base par le
    // trigger de la migration 12 (part de Postgres, jamais du
    // navigateur) ; son échec éventuel n'annule pas la proposition.
    els.formModal.close();
    showGlobalSuccess(existing
      ? 'Proposition envoyée : elle sera visible après validation par un administrateur.'
      : "Proposition d'ajout envoyée : le membre sera créé après validation par un administrateur.");
  } catch (err) {
    showError(els.formError, err.message);
  } finally {
    els.formSubmit.disabled = false;
  }
}

function showGlobalSuccess(message) {
  els.globalSuccess.textContent = message;
  els.globalSuccess.hidden = false;
  clearTimeout(successTimer);
  successTimer = setTimeout(() => { els.globalSuccess.hidden = true; }, 6000);
}

// Compteur sur le bouton admin (au chargement de session).
async function refreshProposalsCount() {
  try {
    proposals = (await rpc('list_proposals', {})) || [];
    updateProposalsBtnLabel();
  } catch {
    // Compteur indicatif : erreur ignorée.
  }
}

function updateProposalsBtnLabel() {
  els.proposalsBtn.textContent = proposals.length > 0
    ? `Modifications proposées (${proposals.length})`
    : 'Modifications proposées';
}

async function loadProposals() {
  proposals = (await rpc('list_proposals', {})) || [];
  updateProposalsBtnLabel();
  renderProposals();
}

function diffTableCell(className, value) {
  const td = document.createElement('td');
  if (className) td.className = className;
  td.textContent = value ?? '—';
  return td;
}

function renderProposals() {
  els.proposalsList.textContent = '';
  if (proposals.length === 0) {
    const p = document.createElement('p');
    p.className = 'hint';
    p.textContent = 'Aucune proposition en attente.';
    els.proposalsList.appendChild(p);
    return;
  }

  for (const prop of proposals) {
    const member = findMember(prop.member_id);
    const card = document.createElement('div');
    card.className = 'proposal-card';

    const head = document.createElement('div');
    head.className = 'proposal-head';
    const title = document.createElement('strong');
    title.textContent = prop.member_id
      ? (prop.member_name || 'Membre introuvable')
      : `Nouveau membre : ${prop.member_name}`;
    head.appendChild(title);
    const meta = document.createElement('span');
    meta.className = 'proposal-meta';
    meta.textContent = `proposé par ${prop.proposed_by} le ${new Date(prop.created_at).toLocaleString('fr-FR')}`;
    head.appendChild(meta);

    const acceptBtn = document.createElement('button');
    acceptBtn.type = 'button';
    acceptBtn.className = 'primary';
    acceptBtn.textContent = 'Accepter';
    acceptBtn.addEventListener('click', () => decideProposal(prop, true, acceptBtn, rejectBtn));
    const rejectBtn = document.createElement('button');
    rejectBtn.type = 'button';
    rejectBtn.className = 'danger';
    rejectBtn.textContent = 'Refuser';
    rejectBtn.addEventListener('click', () => decideProposal(prop, false, acceptBtn, rejectBtn));
    head.append(acceptBtn, rejectBtn);
    card.appendChild(head);

    const table = document.createElement('table');
    table.className = 'diff-table';
    const thead = document.createElement('thead');
    const headRow = document.createElement('tr');
    for (const label of ['Champ', 'Actuel', 'Proposé']) {
      const th = document.createElement('th');
      th.textContent = label;
      headRow.appendChild(th);
    }
    thead.appendChild(headRow);
    table.appendChild(thead);

    const tbody = document.createElement('tbody');
    // member_id NULL = proposition de création : tout est "nouveau".
    // Un member_id sans membre trouvé ne peut plus arriver (suppression
    // en cascade), mais on protège le rendu quand même.
    for (const [key, label] of PROPOSAL_FIELDS) {
      const before = member ? currentFieldValue(member, key) : null;
      const after = prop.payload[key] || null;
      const changed = (before ?? '') !== (after ?? '');
      const tr = document.createElement('tr');
      if (changed) tr.className = 'diff-row';
      tr.appendChild(diffTableCell('diff-label', label));
      tr.appendChild(diffTableCell(changed ? 'diff-old' : '', formatProposalValue(key, before)));
      tr.appendChild(diffTableCell(changed ? 'diff-new' : '', formatProposalValue(key, after)));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    card.appendChild(table);
    els.proposalsList.appendChild(card);
  }
}

async function decideProposal(prop, accept, acceptBtn, rejectBtn) {
  acceptBtn.disabled = true;
  rejectBtn.disabled = true;
  try {
    if (accept) {
      await rpc('accept_proposal', { p_proposal_id: prop.id });
    } else {
      await rpc('reject_proposal', { p_proposal_id: prop.id });
    }
    await loadMembers();
    await loadProposals();
    showGlobalSuccess(accept ? 'Modifications acceptées et appliquées.' : 'Proposition refusée.');
  } catch (err) {
    showError(els.proposalsError, err.message);
    acceptBtn.disabled = false;
    rejectBtn.disabled = false;
  }
}

async function deleteMember(member) {
  clearError(els.memberError);
  if (!confirm(`Supprimer ${member.first_name} ${member.last_name} ?`)) return;
  try {
    await rpc('delete_member', { p_member_id: member.id });
    els.memberModal.close();
    await loadMembers();
  } catch (err) {
    if (!els.memberModal.open) showGlobalError(err.message);
    else showError(els.memberError, err.message);
  }
}

els.proposalsBtn.addEventListener('click', async () => {
  clearError(els.proposalsError);
  if (els.proposalsSection.hidden) {
    try {
      await loadProposals();
      els.proposalsSection.hidden = false;
    } catch (err) {
      showError(els.proposalsError, err.message);
    }
  } else {
    els.proposalsSection.hidden = true;
  }
});

// ------------------------------------------------------------
// Écouteurs généraux
// ------------------------------------------------------------
// Étape 1 : demande du code.
els.loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  clearError(els.loginError);
  await sendLoginCode();
});

// Étape 2 : connexion avec le code.
els.codeForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  clearError(els.codeError);
  await loginWithCode();
});

// Étape 2 → étape 1 : changer d'adresse email.
els.resendBtn.addEventListener('click', () => showLoginStep('email'));

els.logoutBtn.addEventListener('click', logout);
els.addMemberBtn.addEventListener('click', () => openMemberForm(null));
els.proposeAddBtn.addEventListener('click', () => openMemberForm(null, 'proposal'));

// Colonnes triables
for (const th of document.querySelectorAll('#members-table th.sortable')) {
  th.addEventListener('click', () => {
    const key = th.dataset.sort;
    if (sortState.key === key) {
      sortState.dir = -sortState.dir;
    } else {
      sortState = { key, dir: 1 };
    }
    updateSortIndicators();
    renderTable();
  });
}

// Copie presse-papier avec repli si l'API est indisponible.
async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const area = document.createElement('textarea');
      area.value = text;
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      document.execCommand('copy');
      area.remove();
      return true;
    } catch {
      return false;
    }
  }
}

// Copie de la liste de diffusion email
els.copyEmailsBtn.addEventListener('click', async () => {
  const emails = [...new Set(getVisibleMembers().map((m) => m.email).filter(Boolean))];
  if (emails.length === 0) {
    alert('Aucune adresse email à copier.');
    return;
  }
  const ok = await copyToClipboard(emails.join('; '));
  if (!ok) {
    alert('La copie a échoué.');
    return;
  }
  const original = els.copyEmailsBtn.textContent;
  els.copyEmailsBtn.textContent = 'Copié !';
  els.copyEmailsBtn.disabled = true;
  setTimeout(() => {
    els.copyEmailsBtn.textContent = original;
    els.copyEmailsBtn.disabled = false;
  }, 2000);
});

els.exportBtn.addEventListener('click', () => openExportModal(getVisibleMembers()));
els.treeBtn.addEventListener('click', () => openTree(members));
els.treeCloseBtn.addEventListener('click', closeTree);
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !els.treeOverlay.hidden) closeTree();
});

// Clic sur une carte de l'arbre : ouverture de la fiche.
window.openMemberRecord = (id) => {
  closeTree();
  openMemberModal(id);
};

for (const btn of document.querySelectorAll('[data-close]')) {
  btn.addEventListener('click', () => {
    $(btn.dataset.close).close();
  });
}

// Fermeture d'un dialogue par clic sur le fond.
for (const dialog of document.querySelectorAll('dialog')) {
  dialog.addEventListener('click', (e) => {
    if (e.target === dialog) dialog.close();
  });
}

// ------------------------------------------------------------
// Keep-alive : génère du trafic pour éviter la mise en pause de la
// base gratuite (même stratégie que le projet "75 ans"). 50 pings
// discrets au chargement de la page, sans bloquer le reste.
// ------------------------------------------------------------
const KEEPALIVE_PING_COUNT = 50;

function getClientId() {
  let id = localStorage.getItem('family_admin_client_id');
  if (!id) {
    id = crypto.randomUUID
      ? crypto.randomUUID()
      : `c-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    localStorage.setItem('family_admin_client_id', id);
  }
  return id;
}

function sendKeepAlive() {
  if (!supabase) return;
  const clientId = getClientId();
  const calls = [];
  for (let i = 0; i < KEEPALIVE_PING_COUNT; i++) {
    calls.push(supabase.rpc('site_ping', { p_client_id: clientId }));
  }
  Promise.allSettled(calls).catch(() => {});
}

// ------------------------------------------------------------
// Démarrage : session existante ou écran de connexion
// ------------------------------------------------------------
async function init() {
  if (!isConfigured) {
    showError(els.configError, 'Supabase n\'est pas configuré. Éditez js/config.js (URL et clé anon).');
    return;
  }
  sendKeepAlive();
  await loadFamilyName();
  if (sessionToken) {
    try {
      // Reprise de session existante : aucun mot de passe transmis.
      const r = await rpc('session_role', {});
      if (r) {
        role = r;
        await loadMembers();
        showApp();
        return;
      }
    } catch {
      // token invalide : on retombe sur l'écran de connexion.
    }
    endSession();
  }
  els.loginEmail.focus();
}

init();
