// The window has a fixed size like the Mac one, and grows when the key picker opens.

import { listen, send } from './bridge.js';
import { ditheredTitle, pixelIcon, racingStripes } from './art.js';
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

/** The Mac window's sizes, minus its title bar. */
const SIZE = { expanded: 1340, collapsed: 1110, board: 585, picker: 792 };
/** The page's own title bar, matching --titlebar in app.css. */
const TITLEBAR = 32;

const app = {
  fixed: null,
  state: null,
  ui: {
    pane: 'keys',
    sidebar: true,
    pickerOpen: false,
    keyboard3D: saved('keyboard3D', 'true') === 'true',
  },
  send,
  relayout() { requestLayout(); },
};

function saved(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}
app.remember = (key, value) => { try { localStorage.setItem(key, String(value)); } catch { /* not saved, which is fine */ } };

let pane = null;
let stage = null;

function renderSidebar() {
  const nav = document.getElementById('panes');
  nav.replaceChildren(...PANES.map((p) => h(`button${p.id === app.ui.pane ? '.active' : ''}`,
    { onclick: () => showPane(p.id) },
    h('span.icon', {}, pixelIcon(p.icon, p.tint)), p.title)));
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
  const toggle = document.getElementById('sidebar-toggle');
  toggle.title = toggle.ariaLabel = visible ? 'Hide Sidebar' : 'Show Sidebar';
  requestLayout();
}

let lastSize = '';
/** Tallest the picker has been since it opened, so the window does not jump. */
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
  send('layout', { width, height: height + TITLEBAR });
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

document.getElementById('sidebar-toggle').addEventListener('click', () => setSidebar(!app.ui.sidebar));
document.getElementById('window-minimize').addEventListener('click', () => send('window.minimize'));
document.getElementById('window-close').addEventListener('click', () => send('window.close'));
// Older WebView2 runtimes ignore app-region, so the app starts the move instead.
document.querySelector('#titlebar .drag').addEventListener('mousedown', (event) => {
  if (event.button === 0 && window.chrome?.webview && !window.m0110AppRegion) send('window.drag');
});
addEventListener('blur', () => document.body.classList.add('inactive'));
addEventListener('focus', () => document.body.classList.remove('inactive'));
document.addEventListener('keydown', (event) => {
  // Ctrl+Shift+S here, Ctrl+Cmd+S on the Mac.
  if (event.ctrlKey && event.shiftKey && event.key.toLowerCase() === 's') setSidebar(!app.ui.sidebar);
});

try {
  app.board3d = new Board3D();
} catch (error) {
  console.warn('3D board unavailable', error);
  app.board3d = null;
}
app.stage = stage = new Stage(document.getElementById('stage-column'), app);
// Preview options when the page is opened in a browser, e.g. ?pane=battery&select=24.
const preview = window.chrome?.webview ? new URLSearchParams() : new URLSearchParams(location.search);
if (!window.chrome?.webview) window.m0110 = app;
if (preview.has('select')) app.ui.selected = Number(preview.get('select'));
if (preview.has('layer')) app.ui.layer = Number(preview.get('layer'));
if (preview.get('sidebar') === '0') setSidebar(false);
followDiagonals();
// Updates the sky every minute. ?sky=HH:MM fixes the time for previews.
followSky((prism) => {
  app.prism = prism;
  const p = PANES.find((x) => x.id === app.ui.pane);
  if (p) renderHeader(p);
}, preview.get('sky'));
showPane(preview.get('pane') ?? 'keys');
send('ready');
