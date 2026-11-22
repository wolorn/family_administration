// Arbre généalogique en SVG, construit à partir des liens parent/enfant
// et des conjoints. Une forêt : chaque racine (membre sans parent connu)
// démarre un arbre, les arbres sont placés côte à côte.

import { formatDate } from './utils.js';

const CARD_W = 160;
const CARD_H = 46;
const COUPLE_GAP = 10;
const UNIT_GAP = 30;
const TREE_GAP = 50;
const LEVEL_H = 150;
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

    // Rattachement des enfants : un enfant pend sous le couple
    // uniquement s'il est déclaré enfant des DEUX conjoints ; sinon
    // il pend sous le unique parent déclaré (index de carte 0 ou 1).
    // Les enfants sont ordonnés du plus âgé au plus récent (gauche à droite).
    const m0 = byId.get(ids[0]);
    const m1 = ids[1] ? byId.get(ids[1]) : null;
    const childrenOf0 = new Set(childIds.get(m0.id) || []);
    const childrenOf1 = m1 ? new Set(childIds.get(m1.id) || []) : null;
    const candidates = new Set([...childrenOf0, ...(childrenOf1 || [])]);
    const anchorRank = { 0: 0, couple: 1, 1: 2 };
    const sortedChildren = [...candidates]
      .map((cid) => byId.get(cid))
      .filter(Boolean)
      .map((child) => {
        let anchor;
        if (childrenOf1) {
          if (childrenOf0.has(child.id) && childrenOf1.has(child.id)) anchor = 'couple';
          else if (childrenOf0.has(child.id)) anchor = 0;
          else anchor = 1;
        } else {
          anchor = 0;
        }
        return { child, anchor };
      })
      .sort((a, b) =>
        anchorRank[a.anchor] - anchorRank[b.anchor] ||
        (a.child.birth_date || '').localeCompare(b.child.birth_date || '')
      );

    for (const { child, anchor } of sortedChildren) {
      const childUnit = measure(child.id, level + 1);
      if (childUnit) {
        childUnit.anchor = anchor;
        unit.children.push(childUnit);
      }
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

  // Position horizontale (relative au centre de l'unité) du point de
  // départ d'une arête selon le rattachement : centre du couple ou
  // carte du parent déclaré (0 ou 1).
  function anchorRelX(unit, anchor) {
    if (anchor === 'couple') return 0;
    return -unit.unitWidth / 2 + anchor * (CARD_W + COUPLE_GAP) + CARD_W / 2;
  }

  const anchorRank = (a) => (a === 'couple' ? 1 : a === 0 ? 0 : 2);

  for (const unit of units) {
    if (!unit.children.length) continue;
    const fromY = unitY(unit) + CARD_H;
    const spanY = LEVEL_H - CARD_H;

    // Regroupe les enfants par rattachement : chaque groupe partage
    // un tronc horizontal unique d'où partent les descentes.
    const groups = new Map();
    for (const c of unit.children) {
      const key = String(c.anchor);
      if (!groups.has(key)) groups.set(key, { anchor: c.anchor, children: [] });
      groups.get(key).children.push(c);
    }
    const ordered = [...groups.values()].sort(
      (g1, g2) => anchorRank(g1.anchor) - anchorRank(g2.anchor)
    );

    ordered.forEach((group, gi) => {
      const railY = fromY + spanY * ((gi + 1) / (ordered.length + 1));
      const variant =
        group.anchor === 'couple' ? 'tree-edge-both' :
        group.anchor === 0 ? 'tree-edge-a0' : 'tree-edge-a1';
      const fromX = unit.centerX + anchorRelX(unit, group.anchor);
      // Le trait atterrit sur la carte du membre lui-même (pas le
      // centre de son couple) : seul le membre déclaré enfant est ciblé.
      const childAnchors = group.children
        .map((c) => {
          const cc = cardById.get(c.ids[0]);
          return cc ? { x: cc.x + CARD_W / 2, y: cc.y } : null;
        })
        .filter(Boolean);
      if (childAnchors.length === 0) return;

      if (childAnchors.length === 1) {
        const { x, y } = childAnchors[0];
        svg.appendChild(svgEl('path', {
          d: `M ${fromX} ${fromY} L ${fromX} ${railY} L ${x} ${railY} L ${x} ${y}`,
          fill: 'none',
          class: 'tree-edge ' + variant,
        }));
        return;
      }

      const xs = childAnchors.map((c) => c.x);
      const railMin = Math.min(fromX, ...xs);
      const railMax = Math.max(fromX, ...xs);
      const toY = childAnchors[0].y;

      svg.appendChild(svgEl('path', {
        d: `M ${fromX} ${fromY} L ${fromX} ${railY}`,
        fill: 'none',
        class: 'tree-edge ' + variant,
      }));
      svg.appendChild(svgEl('path', {
        d: `M ${railMin} ${railY} L ${railMax} ${railY}`,
        fill: 'none',
        class: 'tree-edge ' + variant,
      }));
      for (const { x, y } of childAnchors) {
        svg.appendChild(svgEl('path', {
          d: `M ${x} ${railY} L ${x} ${y}`,
          fill: 'none',
          class: 'tree-edge ' + variant,
        }));
      }
    });
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
  const viewport = document.getElementById('tree-viewport');
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
  if (!navInitialized) {
    initTreeNav();
    navInitialized = true;
  }
  empty.hidden = true;
  viewEls.svgWidth = parseFloat(svg.getAttribute('width'));
  viewEls.svgHeight = parseFloat(svg.getAttribute('height'));
  canvas.appendChild(svg);
  overlay.hidden = false;
  // Le viewport doit être mesuré une fois l'overlay affiché.
  fitView();
}

function closeTree() {
  document.getElementById('tree-overlay').hidden = true;
}

// ------------------------------------------------------------
// Navigation : conteneur de taille fixe, pas d'ascenseur.
// Le canvas est déplacé (translation) et zoomé via transform.
// ------------------------------------------------------------
const MIN_SCALE = 0.15;
const MAX_SCALE = 4;

const viewState = { x: 0, y: 0, scale: 1 };
let viewEls = null; // { viewport, canvas, svgWidth, svgHeight }
let navInitialized = false;

function applyView() {
  const { canvas } = viewEls;
  canvas.style.transform =
    `translate(${viewState.x}px, ${viewState.y}px) scale(${viewState.scale})`;
}

function fitView() {
  const { viewport, svgWidth, svgHeight } = viewEls;
  const vw = viewport.clientWidth;
  const vh = viewport.clientHeight;
  if (svgWidth === 0 || svgHeight === 0 || vw === 0) return;
  // Ajuster à l'écran, sans dépasser l'échelle 1.
  const scale = Math.min(1, (vw - 40) / svgWidth, (vh - 40) / svgHeight);
  viewState.scale = Math.max(scale, MIN_SCALE);
  viewState.x = (vw - svgWidth * viewState.scale) / 2;
  viewState.y = (vh - svgHeight * viewState.scale) / 2;
  applyView();
}

function zoomAt(cx, cy, factor) {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, viewState.scale * factor));
  if (next === viewState.scale) return;
  const k = next / viewState.scale;
  viewState.x = cx - (cx - viewState.x) * k;
  viewState.y = cy - (cy - viewState.y) * k;
  viewState.scale = next;
  applyView();
}

function initTreeNav() {
  const viewport = document.getElementById('tree-viewport');
  const canvas = document.getElementById('tree-canvas');
  viewEls = { viewport, canvas, svgWidth: 0, svgHeight: 0 };

  document.getElementById('zoom-in-btn').addEventListener('click', () => {
    zoomAt(viewport.clientWidth / 2, viewport.clientHeight / 2, 1.25);
  });
  document.getElementById('zoom-out-btn').addEventListener('click', () => {
    zoomAt(viewport.clientWidth / 2, viewport.clientHeight / 2, 1 / 1.25);
  });
  document.getElementById('zoom-reset-btn').addEventListener('click', fitView);

  viewport.addEventListener('wheel', (e) => {
    e.preventDefault();
    const rect = viewport.getBoundingClientRect();
    zoomAt(
      e.clientX - rect.left,
      e.clientY - rect.top,
      e.deltaY < 0 ? 1.15 : 1 / 1.15
    );
  }, { passive: false });

  let isDown = false;
  let moved = false;
  let startX = 0;
  let startY = 0;
  let viewStartX = 0;
  let viewStartY = 0;

  viewport.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    isDown = true;
    moved = false;
    startX = e.clientX;
    startY = e.clientY;
    viewStartX = viewState.x;
    viewStartY = viewState.y;
    viewport.setPointerCapture(e.pointerId);
  });

  viewport.addEventListener('pointermove', (e) => {
    if (!isDown) return;
    const dx = e.clientX - startX;
    const dy = e.clientY - startY;
    if (!moved && Math.hypot(dx, dy) > 5) {
      moved = true;
      viewport.classList.add('panning');
    }
    if (moved) {
      viewState.x = viewStartX + dx;
      viewState.y = viewStartY + dy;
      applyView();
    }
  });

  const end = () => {
    isDown = false;
    viewport.classList.remove('panning');
  };
  viewport.addEventListener('pointerup', end);
  viewport.addEventListener('pointercancel', end);

  // Un glissement ne doit pas déclencher le clic sur une carte.
  viewport.addEventListener(
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
