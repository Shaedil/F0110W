// The window's shell: the sidebar, the pane on show, and the window size the
// layout needs, which the app applies (the window is fixed-size, as the Mac's
// is, and grows when the key picker opens).

import { listen, send } from './bridge.js';
import { ditheredTitle, pixelIcon, racingStripes, rgb } from './art.js';
import { followDiagonals, followSky } from './prism.js';
import { h } from './ui.js';
import { keyboardPane } from './panes/keyboard.js';
import { bluetoothPane, batteryPane, gesturesPane } from './panes/side.js';
import { settingsPane } from './panes/settings.js';
import { Stage } from './stage.js';
import { Board3D } from './board3d.js';

const PANES = [
  { id: 'keys', title: 'Keyboard', icon: 'keys', tint: '#d9b880', make: keyboardPane },
  { id: 'bluetooth', title: 'Bluetooth', icon: 'bluetooth', tint: '#80aded', make: bluetoothPane },
  { id: 'battery', title: 'Battery', icon: 'battery', tint: '#8cd17a', make: batteryPane },
  { id: 'gestures', title: 'Gestures', icon: 'gestures', tint: '#ed8c4d', make: gesturesPane },
  { id: 'settings', title: 'Settings', icon: 'settings', tint: '#e6735c', make: settingsPane },
];

/** The Mac window's sizes, less its title bar. */
const SIZE = { expanded: 1340, collapsed: 1110, board: 585, picker: 792 };

const app = {
  /** From the app: board geometry and the picker's groups, sent once. */
  fixed: null,
  /** From the app: everything that changes. */
  state: null,
  /** The window's own: which pane, the sidebar, and what each pane keeps. */
  ui: {
    pane: 'keys',
    sidebar: true,
    pickerOpen: false,
    keyboard3D: saved('keyboard3D', 'true') === 'true',
  },
  send,
  /** Panes call this when something they show changes the window's size. */
  relayout() { requestLayout(); },
};

/** A remembered view choice, or `fallback`. Per viewer, and lost without
 *  harm. */
function saved(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}
app.remember = (key, value) => { try { localStorage.setItem(key, String(value)); } catch { /* per viewer */ } };

let pane = null;
let stage = null;
const light = matchMedia('(prefers-color-scheme: light)');

function iconTint(tint) {
  // Theme.sidebarIcon: the tint as is in dark mode, darkened in light.
  if (!light.matches) return tint;
  return `rgb(${rgb(tint).map((c) => Math.round(c * 0.68)).join(',')})`;
}

function renderSidebar() {
  const nav = document.getElementById('panes');
  nav.replaceChildren(...PANES.map((p) => h(`button${p.id === app.ui.pane ? '.active' : ''}`,
    { onclick: () => showPane(p.id) },
    h('span.icon', {}, pixelIcon(p.icon, iconTint(p.tint))), p.title)));
}

function renderHeader(p) {
  document.getElementById('title').replaceChildren(ditheredTitle(p.title));
  const stripes = document.getElementById('stripes');
  stripes.replaceChildren();
  requestAnimationFrame(() => stripes.replaceChildren(
    racingStripes(Math.min(220, stripes.clientWidth || 220), app.prism?.marks ?? p.tint)));
}

function showPane(id) {
  const p = PANES.find((x) => x.id === id);
  app.ui.pane = id;
  document.body.dataset.pane = id;
  renderSidebar();
  renderHeader(p);
  pane?.unmount?.();
  const host = document.getElementById('pane');
  host.replaceChildren();
  pane = p.make(host, app);
  stage?.focus(id === 'keys' ? null : pane.stageFocus?.() ?? null);
  if (app.state) pane.update?.(app);
  requestLayout();
}

function setSidebar(visible) {
  app.ui.sidebar = visible;
  document.body.classList.toggle('sidebar-hidden', !visible);
  document.getElementById('sidebar-show').hidden = visible;
  requestLayout();
}

let lastSize = '';
/** The tallest the picker has needed since it opened, so the window grows
 *  to fit its groups but does not bounce between them. */
let pickerHeight = 0;
function requestLayout() {
  const width = app.ui.sidebar ? SIZE.expanded : SIZE.collapsed;
  const picker = app.ui.pane === 'keys' && app.ui.pickerOpen;
  if (picker) pickerHeight = Math.max(pickerHeight, SIZE.picker, document.getElementById('column').scrollHeight);
  else pickerHeight = 0;
  const height = picker ? pickerHeight : SIZE.board;
  const size = `${width}x${height}`;
  if (size === lastSize) return;
  lastSize = size;
  send('layout', { width, height });
}

listen((message) => {
  switch (message.type) {
    case 'fixed':
      app.fixed = message;
      stage?.setBoard(message.board);
      if (message.pane && PANES.some((p) => p.id === message.pane)) showPane(message.pane);
      break;
    case 'state':
      app.state = message;
      pane?.update?.(app);
      stage?.update(app);
      break;
  }
});

document.getElementById('sidebar-hide').addEventListener('click', () => setSidebar(false));
document.getElementById('sidebar-show').addEventListener('click', () => setSidebar(true));
document.addEventListener('keydown', (event) => {
  // ⌃⌘S on the Mac; Ctrl+Shift+S here.
  if (event.ctrlKey && event.shiftKey && event.key.toLowerCase() === 's') setSidebar(!app.ui.sidebar);
});
light.addEventListener('change', renderSidebar);

try {
  app.board3d = new Board3D();
} catch (error) {
  // No WebGL: the flat drawing stands in.
  console.warn('3D board unavailable', error);
  app.board3d = null;
}
app.stage = stage = new Stage(document.getElementById('stage-column'), app);
// Preview options, for the page opened in a browser: ?pane=battery&select=24.
const preview = window.chrome?.webview ? new URLSearchParams() : new URLSearchParams(location.search);
if (!window.chrome?.webview) window.m0110 = app;
if (preview.has('select')) app.ui.selected = Number(preview.get('select'));
if (preview.has('layer')) app.ui.layer = Number(preview.get('layer'));
if (preview.get('sidebar') === '0') setSidebar(false);
followDiagonals();
// The sky, kept current each minute; ?sky=HH:MM pins it, to review any time
// of day.
followSky((prism) => {
  app.prism = prism;
  const p = PANES.find((x) => x.id === app.ui.pane);
  if (p) renderHeader(p);
}, preview.get('sky'));
showPane(preview.get('pane') ?? 'keys');
send('ready');
