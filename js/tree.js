// Arbre généalogique en SVG, construit à partir des liens parent/enfant
// et des conjoints. Une forêt : chaque racine (membre sans parent connu)
// démarre un arbre, les arbres sont placés côte à côte.

import { formatDate } from './utils.js';

const CARD_W = 160;
const CARD_H = 46;
const COUPLE_GAP = 10;
const UNIT_GAP = 30;
const TREE_GAP = 50;
const LEVEL_H = 120;
const PADDING = 32;

const SVG_NS = 'http://www.w3.org/2000/svg';

function svgEl(tag, attrs = {}, text = null) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  if (text != null) el.textContent = text;
  return el;
}

function drawTree(members) {
  const byId = new Map(members.map((m) => [m.id, m]));
  const childIds = new Map();
  for (const m of members) {
    for (const p of m.parents || []) {
      if (byId.has(p.id)) {
        childIds.set(p.id, [...(childIds.get(p.id) || []), m.id]);
      }
    }
  }
  const hasParent = new Set();
  for (const m of members) {
    for (const p of m.parents || []) {
      if (byId.has(p.id)) {
        hasParent.add(m.id);
        break;
      }
    }
  }

  const visited = new Set();
  const units = [];
  let maxLevel = 0;

  // Mesure d'une "unité" = un membre + son conjoint éventuel, et sa descendance.
  function measure(memberId, level) {
    if (visited.has(memberId)) return null;
    const m = byId.get(memberId);
    if (!m) return null;
    visited.add(memberId);

    const spouse =
      m.spouse && m.spouse[0] && !visited.has(m.spouse[0].id)
        ? byId.get(m.spouse[0].id)
        : null;
    if (spouse) visited.add(spouse.id);

    const ids = [m.id, spouse ? spouse.id : null].filter(Boolean);
    const unit = { ids, level, children: [], width: 0, unitWidth: 0, childrenWidth: 0, centerX: 0 };

    // Enfants des deux membres de l'unité, dédupliqués et triés par
    // date de naissance décroissante (de gauche à droite).
    const childIdSet = new Set();
    for (const id of ids) {
      for (const cid of childIds.get(id) || []) childIdSet.add(cid);
    }
    const sortedChildIds = [...childIdSet]
      .map((cid) => byId.get(cid))
      .filter(Boolean)
      .sort((a, b) => (a.birth_date || '').localeCompare(b.birth_date || ''))
      .map((c) => c.id);
    for (const cid of sortedChildIds) {
      const child = measure(cid, level + 1);
      if (child) unit.children.push(child);
    }

    unit.unitWidth = ids.length * CARD_W + (ids.length - 1) * COUPLE_GAP;
    if (unit.children.length) {
      unit.childrenWidth =
        unit.children.reduce((sum, c) => sum + c.width, 0) +
        (unit.children.length - 1) * UNIT_GAP;
      unit.width = Math.max(unit.unitWidth, unit.childrenWidth);
    } else {
      unit.width = unit.unitWidth;
    }

    maxLevel = Math.max(maxLevel, level);
    units.push(unit);
    return unit;
  }

  const roots = members
    .filter((m) => !hasParent.has(m.id))
    .sort((a, b) => (a.birth_date || '').localeCompare(b.birth_date || ''));

  const rootUnits = [];
  for (const r of roots) {
    const u = measure(r.id, 0);
    if (u) rootUnits.push(u);
  }
  // Sécurité : membres non atteints depuis les racines.
  for (const m of members) {
    const u = measure(m.id, 0);
    if (u) rootUnits.push(u);
  }

  if (rootUnits.length === 0) return null;

  function assign(unit, left) {
    if (unit.children.length) {
      let childLeft = left + (unit.width - unit.childrenWidth) / 2;
      let firstCenter = null;
      let lastCenter = null;
      for (const c of unit.children) {
        assign(c, childLeft);
        childLeft += c.width + UNIT_GAP;
        if (firstCenter == null) firstCenter = c.centerX;
        lastCenter = c.centerX;
      }
      unit.centerX = (firstCenter + lastCenter) / 2;
    } else {
      unit.centerX = left + unit.width / 2;
    }
  }

  const svgWidth = 2 * PADDING + rootUnits.reduce((s, u) => s + u.width, 0) + (rootUnits.length - 1) * TREE_GAP;
  const svgHeight = 2 * PADDING + (maxLevel + 1) * LEVEL_H;

  const svg = svgEl('svg', {
    width: svgWidth,
    height: svgHeight,
    viewBox: `0 0 ${svgWidth} ${svgHeight}`,
  });

  // Arêtes d'abord (dessinées sous les cartes).
  let cursorX = PADDING;
  for (const root of rootUnits) {
    assign(root, cursorX);
    cursorX += root.width + TREE_GAP;
  }

  const unitY = (unit) => PADDING + unit.level * LEVEL_H;

  const cards = [];
  for (const unit of units) {
    let cardX = unit.centerX - unit.unitWidth / 2;
    let prevCard = null;
    for (const id of unit.ids) {
      const m = byId.get(id);
      const card = { x: cardX, y: unitY(unit), m };
      cards.push(card);

      // Lien conjoint entre les deux cartes de l'unité.
      if (prevCard) {
        const y = card.y + CARD_H / 2;
        svg.appendChild(svgEl('line', {
          x1: prevCard.x + CARD_W, y1: y,
          x2: card.x, y2: y,
          class: 'tree-spouse-link',
        }));
      }
      prevCard = card;
      cardX += CARD_W + COUPLE_GAP;
    }
  }

  const cardById = new Map(cards.map((c) => [c.m.id, c]));

  for (const unit of units) {
    if (!unit.children.length) continue;
    const fromX = unit.centerX;
    const fromY = unitY(unit) + CARD_H;
    for (const c of unit.children) {
      const childCard = cardById.get(c.ids[0]);
      if (!childCard) continue;
      const toX = c.centerX;
      const toY = childCard.y;
      const midY = (fromY + toY) / 2;
      svg.appendChild(svgEl('path', {
        d: `M ${fromX} ${fromY} L ${fromX} ${midY} L ${toX} ${midY} L ${toX} ${toY}`,
        fill: 'none',
        class: 'tree-edge',
      }));
    }
  }

  for (const card of cards) {
    const m = card.m;
    const g = svgEl('g');
    g.appendChild(svgEl('rect', {
      x: card.x, y: card.y,
      width: CARD_W, height: CARD_H,
      rx: 6,
      class: 'tree-card' + (m.death_date ? ' deceased' : ''),
    }));
    g.appendChild(svgEl('text', {
      x: card.x + CARD_W / 2, y: card.y + 19,
      'text-anchor': 'middle', class: 'tree-name',
    }, `${m.first_name} ${m.last_name}`.trim()));
    const lifeLine = m.death_date
      ? `${formatDate(m.birth_date)} – ${formatDate(m.death_date)}`
      : `${formatDate(m.birth_date)}`;
    g.appendChild(svgEl('text', {
      x: card.x + CARD_W / 2, y: card.y + 35,
      'text-anchor': 'middle', class: 'tree-dates',
    }, lifeLine));
    g.addEventListener('click', () => {
      window.openMemberRecord && window.openMemberRecord(m.id);
    });
    svg.appendChild(g);
  }

  return svg;
}

function openTree(members) {
  const overlay = document.getElementById('tree-overlay');
  const canvas = document.getElementById('tree-canvas');
  const empty = document.getElementById('tree-empty');
  canvas.textContent = '';
  if (!members.length) {
    empty.hidden = false;
    overlay.hidden = false;
    return;
  }
  const svg = drawTree(members);
  if (!svg) {
    empty.hidden = false;
    overlay.hidden = false;
    return;
  }
  empty.hidden = true;
  enablePan(overlay, canvas);
  canvas.appendChild(svg);
  overlay.hidden = false;
}

function closeTree() {
  document.getElementById('tree-overlay').hidden = true;
}

// Déplacement de l'arbre à la souris / au doigt (au lieu des ascenseurs).
// Le glissement est écouté sur l'élément qui défile réellement (scrollEl)
// et déclenché depuis la zone de l'arbre (dragEl).
function enablePan(scrollEl, dragEl) {
  if (scrollEl.dataset.panEnabled) return;
  scrollEl.dataset.panEnabled = 'true';

  let isDown = false;
  let moved = false;
  let startX = 0;
  let startY = 0;
  let scrollStartX = 0;
  let scrollStartY = 0;

  scrollEl.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    // La barre de titre (bouton Fermer) ne déclenche pas de déplacement.
    if (e.target.closest('.tree-bar')) return;
    if (!e.target.closest('.tree-canvas')) return;
    isDown = true;
    moved = false;
    startX = e.clientX;
    startY = e.clientY;
    scrollStartX = scrollEl.scrollLeft;
    scrollStartY = scrollEl.scrollTop;
    scrollEl.setPointerCapture(e.pointerId);
  });

  scrollEl.addEventListener('pointermove', (e) => {
    if (!isDown) return;
    const dx = e.clientX - startX;
    const dy = e.clientY - startY;
    if (!moved && Math.hypot(dx, dy) > 5) {
      moved = true;
      dragEl.classList.add('panning');
    }
    if (moved) {
      scrollEl.scrollLeft = scrollStartX - dx;
      scrollEl.scrollTop = scrollStartY - dy;
    }
  });

  const end = () => {
    isDown = false;
    dragEl.classList.remove('panning');
  };
  scrollEl.addEventListener('pointerup', end);
  scrollEl.addEventListener('pointercancel', end);

  // Un glissement ne doit pas déclencher le clic sur une carte.
  scrollEl.addEventListener(
    'click',
    (e) => {
      if (!moved) return;
      e.stopPropagation();
      e.preventDefault();
      moved = false;
    },
    true
  );
}

export { openTree, closeTree };
