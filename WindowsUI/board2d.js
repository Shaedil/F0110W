// SVG drawing of the flat board, ported from the Mac's BoardCase and Keycap.
// Units are hundredths of a key unit. The viewBox handles scaling.

const NS = 'http://www.w3.org/2000/svg';
const BEZEL = { side: 125, top: 50, bottom: 50 };
const KEY_GAP = 7;
const PLATE_INSET = KEY_GAP / 2;
const PLATE_RADIUS = 13;
const SHELL_RADIUS = 22;

// The face sits high and narrow on the cap, like the M0110's sculpted caps.
const TOP_WALL = 3;
const BOTTOM_WALL = 13;
const SIDE_WALL = ((100 - KEY_GAP) - (100 - KEY_GAP - TOP_WALL - BOTTOM_WALL) / 1.2) / 2;
const OUTER_RADIUS = 9;
const FACE_RADIUS = 7;
const LEGEND_PAD = 6;
const LEGEND = { single: 26, pair: 25, word: 17 };
const MIN_SCALE = { single: 0.5, pair: 0.5, word: 0.4 };
/** Helvetica's ascent, used to place text from the top of its line like SwiftUI. */
const ASCENT = 0.77;

let ids = 0;

function el(name, attrs = {}, parent) {
  const node = document.createElementNS(NS, name);
  for (const [k, v] of Object.entries(attrs)) if (v != null) node.setAttribute(k, v);
  if (parent) parent.appendChild(node);
  return node;
}

function roundedPolygon(points, radius) {
  const n = points.length;
  let d = '';
  for (let i = 0; i < n; i++) {
    const p = points[i], prev = points[(i + n - 1) % n], next = points[(i + 1) % n];
    const inLen = Math.hypot(p[0] - prev[0], p[1] - prev[1]);
    const outLen = Math.hypot(next[0] - p[0], next[1] - p[1]);
    const r = Math.min(radius, inLen / 2, outLen / 2);
    const a = [p[0] + (prev[0] - p[0]) * r / inLen, p[1] + (prev[1] - p[1]) * r / inLen];
    const b = [p[0] + (next[0] - p[0]) * r / outLen, p[1] + (next[1] - p[1]) * r / outLen];
    d += `${i === 0 ? 'M' : 'L'}${a[0]},${a[1]} Q${p[0]},${p[1]} ${b[0]},${b[1]} `;
  }
  return `${d}Z`;
}

/** The plate is notched where the bottom row's bezel patches open into the case. */
function plateOutline(well, patches) {
  const plate = { minX: well.x - PLATE_INSET, minY: well.y - PLATE_INSET,
                  maxX: well.x + well.w + PLATE_INSET, maxY: well.y + well.h + PLATE_INSET };
  const near = (a, b) => Math.abs(a - b) < 0.5;
  const bottom = patches.filter((p) => near(p.y + p.h, plate.maxY));
  const left = bottom.find((p) => near(p.x, plate.minX));
  const right = bottom.find((p) => near(p.x + p.w, plate.maxX));
  const notchY = (left ?? right)?.y;
  if (notchY == null) {
    return [[plate.minX, plate.minY], [plate.maxX, plate.minY], [plate.maxX, plate.maxY], [plate.minX, plate.maxY]];
  }
  const pts = [[plate.minX, plate.minY], [plate.maxX, plate.minY]];
  if (right) pts.push([plate.maxX, notchY], [right.x, notchY], [right.x, plate.maxY]);
  else pts.push([plate.maxX, plate.maxY]);
  if (left) pts.push([left.x + left.w, plate.maxY], [left.x + left.w, notchY], [plate.minX, notchY]);
  else pts.push([plate.minX, plate.maxY]);
  return pts;
}

// Apple logo for the case badge, 100 wide by 120 tall.
const APPLE = 'M52,32 C46,32 40,28 32,28 C18,28 8,40 8,58 C8,80 22,108 36,108 C42,108 46,104 52,104 '
  + 'C58,104 62,108 68,108 C80,108 90,90 94,78 C84,74 78,66 78,56 C78,46 84,40 90,36 C84,30 76,28 70,28 '
  + 'C62,28 58,32 52,32 Z M52,26 C52,16 60,8 70,6 C70,16 62,24 52,26 Z';

function appleBadge(svg, cell, defs) {
  const half = KEY_GAP / 2;
  const side = Math.min(cell.w, cell.h) - KEY_GAP * 2;
  const x = cell.x + half + BEZEL.side;
  const y = cell.y + cell.h - half - side + BEZEL.top;
  const id = `cut${ids++}`;
  const cut = el('linearGradient', { id, x1: 0, y1: 1, x2: 1, y2: 0 }, defs);
  el('stop', { offset: 0, 'stop-color': '#000', 'stop-opacity': 0.28 }, cut);
  el('stop', { offset: 1, 'stop-color': '#fff', 'stop-opacity': 0.38 }, cut);
  const stroke = 2.2;
  el('rect', { x, y, width: side, height: side, rx: 16, fill: 'var(--case-emboss)' }, svg);
  el('rect', { x: x + stroke / 2, y: y + stroke / 2, width: side - stroke, height: side - stroke, rx: 16 - stroke / 2,
               fill: 'none', stroke: `url(#${id})`, 'stroke-width': stroke }, svg);
  // Draw the logo three times, offset, so it looks embossed.
  const h = side * 0.62, w = h * 100 / 120;
  const gx = x + (side - w) / 2, gy = y + (side - h) / 2;
  const relief = 1.4;
  for (const [dx, dy, fill, opacity] of [[-relief, relief, '#fff', 0.62], [relief, -relief, '#000', 0.26],
                                          [0, 0, 'var(--case-emboss-face)', 1]]) {
    el('path', { d: APPLE, fill, 'fill-opacity': opacity,
                 transform: `translate(${gx + dx},${gy + dy}) scale(${w / 100})` }, svg);
  }
}

function capDefs(defs) {
  const shadow = el('filter', { id: 'cap-shadow', x: '-20%', y: '-20%', width: '140%', height: '140%' }, defs);
  el('feDropShadow', { dx: 1, dy: -0.8, stdDeviation: 1.1, 'flood-color': '#000', 'flood-opacity': 0.34 }, shadow);
  const sheen = el('linearGradient', { id: 'cap-sheen', x1: 0, y1: 0, x2: 1, y2: 0 }, defs);
  el('stop', { offset: 0, 'stop-color': '#fff', 'stop-opacity': 0.22 }, sheen);
  el('stop', { offset: 1, 'stop-color': '#fff', 'stop-opacity': 0 }, sheen);
  for (const [id, colour] of [['skirt', 'var(--cap-skirt)'], ['skirt-space', 'var(--spacebar-skirt)'],
                              ['skirt-selected', 'var(--selected-cap-skirt)']]) {
    const g = el('linearGradient', { id, x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
    el('stop', { offset: 0, 'stop-color': colour, 'stop-opacity': 0.8 }, g);
    el('stop', { offset: 0.45, 'stop-color': colour, 'stop-opacity': 1 }, g);
    el('stop', { offset: 1, 'stop-color': colour, 'stop-opacity': 0.86 }, g);
  }
}

function legend(group, slot, face, ink) {
  const l = slot?.legend ?? { kind: 'blank' };
  if (l.kind === 'blank') return;
  const size = LEGEND[l.kind];
  const left = face.x + LEGEND_PAD;
  const top = face.y + LEGEND_PAD;
  const room = face.w - LEGEND_PAD * 2;
  const lines = l.kind === 'pair' ? [l.shifted, l.base] : [l.text];
  const text = el('text', { 'font-size': size, fill: ink, 'font-family': 'var(--font-cap)' }, group);
  lines.forEach((line, i) => {
    const span = el('tspan', { x: left, y: top + ASCENT * size + i * (size + 1) }, text);
    span.textContent = line;
  });
  text.dataset.room = room;
  text.dataset.min = MIN_SCALE[l.kind];
  text.dataset.top = top;
}

/** Shrinks legends that are too wide, like SwiftUI's minimumScaleFactor.
 *  The SVG must be in the document so text can be measured. */
function fitLegends(svg) {
  for (const text of svg.querySelectorAll('text[data-room]')) {
    const room = Number(text.dataset.room);
    const width = text.getComputedTextLength?.() ?? 0;
    if (width <= room || width === 0) continue;
    const factor = Math.max(Number(text.dataset.min), room / width);
    const size = Number(text.getAttribute('font-size')) * factor;
    const top = Number(text.dataset.top);
    text.setAttribute('font-size', size);
    [...text.children].forEach((span, i) => span.setAttribute('y', top + ASCENT * size + i * (size + 1)));
  }
}

/** Draws the board `width` CSS pixels wide. `slots` is keyed by position.
 *  `plain` draws every cap at full opacity, for a board that is not being edited. */
export function drawBoard(host, { board, slots, selected, canEdit, width, onSelect, plain = false }) {
  const unitsW = board.unitsWide + BEZEL.side * 2;
  const unitsH = board.unitsHigh + BEZEL.top + BEZEL.bottom;
  const svg = el('svg', { viewBox: `0 0 ${unitsW} ${unitsH}`, width, height: width * unitsH / unitsW,
                          class: 'board2d' });
  const defs = el('defs', {}, svg);
  capDefs(defs);

  el('rect', { width: unitsW, height: unitsH, rx: SHELL_RADIUS, fill: 'var(--case-flat)' }, svg);
  const plate = plateOutline({ x: 0, y: 0, w: board.unitsWide, h: board.unitsHigh }, board.bezelPatches)
    .map(([x, y]) => [x + BEZEL.side, y + BEZEL.top]);
  el('path', { d: roundedPolygon(plate, PLATE_RADIUS), fill: 'var(--plate)' }, svg);
  appleBadge(svg, board.logoCell, defs);

  for (const key of board.keys) {
    const slot = slots?.[String(key.position)];
    const isSelected = selected === key.position;
    const isSpace = key.position === board.spacebarPosition;
    const editable = plain || (canEdit && !!slot?.editable);
    const x = BEZEL.side + key.x + KEY_GAP / 2, y = BEZEL.top + key.y + KEY_GAP / 2;
    const w = key.w - KEY_GAP, h = key.h - KEY_GAP;
    const g = el('g', { class: 'cap', 'data-position': key.position,
                        opacity: editable || isSelected ? 1 : 0.62 }, svg);
    const skirt = isSelected ? 'skirt-selected' : isSpace ? 'skirt-space' : 'skirt';
    const ink = isSelected ? 'var(--selected-cap-ink)' : 'var(--cap-ink)';
    el('rect', { x, y, width: w, height: h, rx: OUTER_RADIUS, fill: `url(#${skirt})`, filter: 'url(#cap-shadow)' }, g);
    el('rect', { x, y, width: w, height: h, rx: OUTER_RADIUS, fill: 'none', stroke: ink, 'stroke-opacity': 0.22,
                 'stroke-width': 0.9 }, g);
    const face = { x: x + SIDE_WALL, y: y + TOP_WALL, w: w - SIDE_WALL * 2, h: h - TOP_WALL - BOTTOM_WALL };
    const top = isSelected ? 'var(--selected-cap-top)' : isSpace ? 'var(--spacebar-top)' : 'var(--cap-top)';
    el('rect', { x: face.x, y: face.y, width: face.w, height: face.h, rx: FACE_RADIUS, fill: top }, g);
    el('rect', { x: face.x, y: face.y, width: face.w, height: face.h, rx: FACE_RADIUS, fill: 'url(#cap-sheen)' }, g);
    legend(g, slot, face, ink);
    if (key.position !== board.unmapped) {
      g.style.cursor = 'pointer';
      g.addEventListener('click', () => onSelect?.(key.position));
    }
  }

  host.replaceChildren(svg);
  fitLegends(svg);
  return svg;
}
