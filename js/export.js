// Export des membres au format Excel (.xlsx) ou Word (.doc).

import { formatDate, ageOf, SEX_LABEL } from './utils.js';

const FIELDS = [
  { id: 'first_name', label: 'Prénom' },
  { id: 'last_name', label: 'Nom' },
  { id: 'sex', label: 'Sexe' },
  { id: 'birth_date', label: 'Date de naissance' },
  { id: 'age', label: 'Âge' },
  { id: 'address', label: 'Adresse' },
  { id: 'email', label: 'Adresse email' },
  { id: 'wedding_date', label: 'Date de mariage' },
  { id: 'death_date', label: 'Date de décès' },
  { id: 'parents', label: 'Père / mère' },
  { id: 'spouse', label: 'Conjoint' },
  { id: 'children', label: 'Enfants' },
  { id: 'siblings', label: 'Frères et sœurs' },
];

function relationNames(member, key) {
  return (member[key] || [])
    .map((r) => `${r.first_name} ${r.last_name}`)
    .join(', ');
}

function valueOf(member, fieldId) {
  switch (fieldId) {
    case 'first_name': return member.first_name || '';
    case 'last_name': return member.last_name || '';
    case 'sex': return SEX_LABEL[member.sex] || member.sex || '';
    case 'birth_date': return member.birth_date ? formatDate(member.birth_date) : '';
    case 'age': {
      const a = ageOf(member);
      if (a == null) return '';
      return member.death_date ? `${a} ans (décédé·e)` : `${a} ans`;
    }
    case 'address': return member.address || '';
    case 'email': return member.email || '';
    case 'wedding_date': return member.wedding_date ? formatDate(member.wedding_date) : '';
    case 'death_date': return member.death_date ? formatDate(member.death_date) : '';
    case 'parents': return relationNames(member, 'parents');
    case 'spouse': return relationNames(member, 'spouse');
    case 'children': return relationNames(member, 'children');
    case 'siblings': return relationNames(member, 'siblings');
    default: return '';
  }
}

function fileStamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function exportXlsx(members, fields) {
  if (!window.XLSX) {
    throw new Error('La librairie XLSX n\'est pas chargée (connexion internet requise).');
  }
  const headers = fields.map((f) => f.label);
  const rows = members.map((m) => fields.map((f) => valueOf(m, f.id)));
  const sheet = window.XLSX.utils.aoa_to_sheet([headers, ...rows]);
  sheet['!cols'] = headers.map((h, i) => ({
    wch: Math.max(14, ...rows.map((r) => String(r[i]).length + 2)),
  }));
  const workbook = window.XLSX.utils.book_new();
  window.XLSX.utils.book_append_sheet(workbook, sheet, 'Famille');
  window.XLSX.writeFile(workbook, `famille-${fileStamp()}.xlsx`);
}

function exportWord(members, fields) {
  const headerCells = fields
    .map((f) => `<th style="background:#eef2ff">${escapeHtml(f.label)}</th>`)
    .join('');
  const bodyRows = members
    .map(
      (m) =>
        '<tr>' +
        fields.map((f) => `<td>${escapeHtml(valueOf(m, f.id))}</td>`).join('') +
        '</tr>'
    )
    .join('\n');
  const html =
    '<!DOCTYPE html>' +
    '<html xmlns:o="urn:schemas-microsoft-com:office:office" ' +
    'xmlns:w="urn:schemas-microsoft-com:office:word" ' +
    'xmlns="http://www.w3.org/TR/REC-html40">' +
    '<head><meta charset="utf-8"><title>Administration familiale</title></head>' +
    '<body><table border="1" cellspacing="0" cellpadding="4">' +
    `<tr>${headerCells}</tr>${bodyRows}</table></body></html>`;
  const blob = new Blob(['\ufeff', html], { type: 'application/msword' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `famille-${fileStamp()}.doc`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(a.href);
}

function openExportModal(members) {
  const modal = document.getElementById('export-modal');
  const fieldList = document.getElementById('export-fields');
  const countLabel = document.getElementById('export-count');
  const error = document.getElementById('export-error');
  const submit = document.getElementById('export-submit');

  fieldList.textContent = '';
  for (const field of FIELDS) {
    const label = document.createElement('label');
    label.className = 'checkbox-label';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = true;
    box.dataset.field = field.id;
    label.append(box, document.createTextNode(` ${field.label}`));
    fieldList.appendChild(label);
  }

  countLabel.textContent = `${members.length} membre${members.length > 1 ? 's' : ''} exporté${members.length > 1 ? 's' : ''} (selon la recherche courante).`;
  error.hidden = true;

  submit.onclick = () => {
    error.hidden = true;
    const selected = [
      ...fieldList.querySelectorAll('input[type=checkbox]:checked'),
    ].map((box) => FIELDS.find((f) => f.id === box.dataset.field));
    if (selected.length === 0) {
      error.textContent = 'Sélectionnez au moins un champ.';
      error.hidden = false;
      return;
    }
    const format = document.querySelector('input[name=export-format]:checked').value;
    try {
      if (format === 'xlsx') exportXlsx(members, selected);
      else exportWord(members, selected);
      modal.close();
    } catch (err) {
      error.textContent = err.message;
      error.hidden = false;
    }
  };

  modal.showModal();
}

export { openExportModal };
