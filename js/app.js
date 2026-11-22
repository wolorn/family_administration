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
let password = sessionStorage.getItem('family_admin_password') || '';
let role = null;
let members = [];

// ------------------------------------------------------------
// Raccourcis DOM
// ------------------------------------------------------------
const $ = (id) => document.getElementById(id);

const els = {
  familyName: $('family-name'),
  loginSection: $('login-section'),  loginForm: $('login-form'),
  loginPassword: $('login-password'),
  loginError: $('login-error'),
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
  treeOverlay: $('tree-overlay'),
  treeCloseBtn: $('tree-close-btn'),
  birthdayBanner: $('birthday-banner'),
  adminActions: $('admin-actions'),
  addMemberBtn: $('add-member-btn'),
  toggleUsersBtn: $('toggle-users-btn'),
  globalError: $('global-error'),
  tbody: $('members-tbody'),
  thActions: $('th-actions'),
  emptyMsg: $('empty-msg'),
  usersSection: $('users-section'),
  usersTbody: $('users-tbody'),
  usersError: $('users-error'),
  userForm: $('user-form'),
  userUsername: $('user-username'),
  memberModal: $('member-modal'),
  memberModalTitle: $('member-modal-title'),
  memberDetails: $('member-details'),
  memberAdminActions: $('member-admin-actions'),
  editMemberBtn: $('edit-member-btn'),
  deleteMemberBtn: $('delete-member-btn'),
  memberError: $('member-error'),
  formModal: $('member-form-modal'),
  formTitle: $('member-form-title'),
  form: $('member-form'),
  formError: $('form-error'),
  formSubmit: $('form-submit'),
};

// ------------------------------------------------------------
// Appel RPC générique : chaque requête porte le mot de passe.
// ------------------------------------------------------------
function rpc(name, args = {}) {
  if (!supabase) {
    return Promise.reject(new Error('Supabase non configuré. Éditez js/config.js.'));
  }
  return supabase.rpc(name, args).then(({ data, error }) => {
    if (error) throw new Error(error.message);
    return data;
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
async function login(pwd) {
  const verified = await rpc('verify_password', { p_password: pwd });
  if (!verified) throw new Error('Mot de passe invalide.');
  role = verified;
  password = pwd;
  sessionStorage.setItem('family_admin_password', pwd);
  await loadMembers();
  showApp();
}

function logout() {
  password = '';
  role = null;
  members = [];
  sessionStorage.removeItem('family_admin_password');
  els.appSection.hidden = true;
  els.sessionBar.hidden = true;
  els.loginSection.hidden = false;
  els.loginPassword.value = '';
}

function showApp() {
  els.loginSection.hidden = true;
  els.appSection.hidden = false;
  els.sessionBar.hidden = false;
  els.sessionUser.textContent = role === 'admin' ? 'Connecté : administrateur' : 'Connecté : lecture seule';
  const isAdmin = role === 'admin';
  els.adminActions.hidden = !isAdmin;
  els.readActions.hidden = false;
  els.thActions.hidden = !isAdmin;
  updateSortIndicators();
  renderTable();
}

function showGlobalError(message) {
  showError(els.globalError, message);
}

async function loadMembers() {
  members = (await rpc('get_members', { p_password: password })) || [];
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

function openMemberModal(id) {
  const m = findMember(id);
  if (!m) return;
  clearError(els.memberError);

  els.memberModalTitle.textContent = `${m.first_name} ${m.last_name}`;
  els.memberDetails.textContent = '';

  const dl = document.createElement('div');
  dl.className = 'detail-list';
  const rows = [
    { label: 'Sexe', value: SEX_LABEL[m.sex] || m.sex },
    { label: 'Naissance', value: formatDate(m.birth_date) },
    { label: 'Adresse', value: m.address, href: m.address ? addressHref(m.address) : null, copy: m.address },
    { label: 'Email', value: m.email, href: m.email ? `mailto:${m.email}` : null, copy: m.email },
    { label: 'Mariage', value: m.wedding_date ? formatDate(m.wedding_date) : null },
    { label: 'Décès', value: m.death_date ? formatDate(m.death_date) : null },
  ];
  for (const { label, value, href, copy } of rows) {
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
  els.editMemberBtn.onclick = () => {
    els.memberModal.close();
    openMemberForm(m);
  };
  els.deleteMemberBtn.onclick = () => {
    deleteMember(m);
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

function openMemberForm(member) {
  clearError(els.formError);
  els.formTitle.textContent = member ? 'Modifier le membre' : 'Nouveau membre';
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

  els.formSubmit.textContent = member ? 'Enregistrer' : 'Créer';
  els.form.onsubmit = (e) => {
    e.preventDefault();
    saveMember(member);
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
    const memberId = await rpc('upsert_member', { p_password: password, p_member: payload });
    if (newFather !== oldFather) {
      await rpc('set_parent', {
        p_password: password,
        p_child_id: memberId,
        p_parent_id: newFather,
        p_slot: 'pere',
      });
    }
    if (newMother !== oldMother) {
      await rpc('set_parent', {
        p_password: password,
        p_child_id: memberId,
        p_parent_id: newMother,
        p_slot: 'mere',
      });
    }
    if (newSpouse !== oldSpouse) {
      await rpc('set_spouse', {
        p_password: password,
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

async function deleteMember(member) {
  clearError(els.memberError);
  if (!confirm(`Supprimer ${member.first_name} ${member.last_name} ?`)) return;
  try {
    await rpc('delete_member', { p_password: password, p_member_id: member.id });
    els.memberModal.close();
    await loadMembers();
  } catch (err) {
    if (!els.memberModal.open) showGlobalError(err.message);
    else showError(els.memberError, err.message);
  }
}

// ------------------------------------------------------------
// Gestion des comptes (admin)
// ------------------------------------------------------------
async function loadUsers() {
  const users = (await rpc('list_users', { p_password: password })) || [];
  els.usersTbody.textContent = '';
  for (const u of users) {
    const tr = document.createElement('tr');
    if (!u.is_active) tr.className = 'users-row-active';

    const tdUser = document.createElement('td');
    tdUser.textContent = u.username;
    const tdRole = document.createElement('td');
    tdRole.textContent = u.role === 'admin' ? 'Administrateur' : 'Lecture seule';
    const tdActive = document.createElement('td');
    tdActive.textContent = u.is_active ? 'Oui' : 'Non';
    const tdCreated = document.createElement('td');
    tdCreated.textContent = new Date(u.created_at).toLocaleDateString('fr-FR');
    tr.append(tdUser, tdRole, tdActive, tdCreated);

    const tdActions = document.createElement('td');
    const passwordBtn = document.createElement('button');
    passwordBtn.type = 'button';
    passwordBtn.textContent = 'Mot de passe';
    passwordBtn.addEventListener('click', async () => {
      const newPwd = prompt(`Nouveau mot de passe pour « ${u.username} » (min. 8 caractères) :`);
      if (!newPwd) return;
      try {
        await rpc('set_user_password', { p_password: password, p_user_id: u.id, p_new_password: newPwd });
        clearError(els.usersError);
      } catch (err) {
        showError(els.usersError, err.message);
      }
    });

    const toggleBtn = document.createElement('button');
    toggleBtn.type = 'button';
    toggleBtn.textContent = u.is_active ? 'Désactiver' : 'Activer';
    toggleBtn.addEventListener('click', async () => {
      try {
        await rpc('set_user_active', { p_password: password, p_user_id: u.id, p_is_active: !u.is_active });
        await loadUsers();
      } catch (err) {
        showError(els.usersError, err.message);
      }
    });

    const deleteBtn = document.createElement('button');
    deleteBtn.type = 'button';
    deleteBtn.textContent = 'Supprimer';
    deleteBtn.classList.add('danger');
    deleteBtn.addEventListener('click', async () => {
      if (!confirm(`Supprimer le compte « ${u.username} » ?`)) return;
      try {
        await rpc('delete_user', { p_password: password, p_user_id: u.id });
        await loadUsers();
      } catch (err) {
        showError(els.usersError, err.message);
      }
    });

    tdActions.append(passwordBtn, toggleBtn, deleteBtn);
    tr.appendChild(tdActions);
    els.usersTbody.appendChild(tr);
  }
}

els.userForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  clearError(els.usersError);
  try {
    await rpc('create_user', {
      p_password: password,
      p_username: els.userUsername.value.trim(),
      p_new_password: $('user-password').value,
      p_role: $('user-role').value,
    });
    els.userForm.reset();
    await loadUsers();
  } catch (err) {
    showError(els.usersError, err.message);
  }
});

els.toggleUsersBtn.addEventListener('click', async () => {
  clearError(els.usersError);
  if (els.usersSection.hidden) {
    await loadUsers();
    els.usersSection.hidden = false;
  } else {
    els.usersSection.hidden = true;
  }
});

// ------------------------------------------------------------
// Écouteurs généraux
// ------------------------------------------------------------
els.loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  clearError(els.loginError);
  els.loginPassword.disabled = true;
  try {
    await login(els.loginPassword.value);
  } catch (err) {
    showError(els.loginError, err.message);
  } finally {
    els.loginPassword.disabled = false;
  }
});

els.logoutBtn.addEventListener('click', logout);
els.addMemberBtn.addEventListener('click', () => openMemberForm(null));

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
// Démarrage : session existante ou écran de connexion
// ------------------------------------------------------------
async function init() {
  if (!isConfigured) {
    showError(els.configError, 'Supabase n\'est pas configuré. Éditez js/config.js (URL et clé anon).');
    return;
  }
  await loadFamilyName();
  if (password) {
    try {
      await login(password);
      return;
    } catch {
      sessionStorage.removeItem('family_admin_password');
      password = '';
    }
  }
  els.loginPassword.focus();
}

init();
