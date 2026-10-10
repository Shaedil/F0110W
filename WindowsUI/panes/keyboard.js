// The Keyboard pane, matching KeysPane on the Mac.

import { drawBoard } from '../board2d.js';
import { h, panel, pill, segments } from '../ui.js';

const DOT = { unlocked: 'var(--good)', locked: 'var(--warn)', connecting: 'var(--warn)',
              failed: 'var(--bad)', disconnected: 'var(--text-dim)', bluetooth: 'var(--good)' };

const SVG = 'http://www.w3.org/2000/svg';
function icon(paths, { width = 14, height = 14, stroke = 1.6 } = {}) {
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16');
  svg.setAttribute('width', width);
  svg.setAttribute('height', height);
  svg.innerHTML = paths;
  svg.style.cssText = `flex:none;fill:none;stroke:currentColor;stroke-width:${stroke};`
    + 'stroke-linecap:round;stroke-linejoin:round';
  return svg;
}
const USB = () => icon('<path d="M5 2h6v5H5z"/><path d="M7 4h0M9 4h0"/><path d="M4 7h8v3a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3z"/><path d="M8 13v2"/>');
const LOCKED = () => icon('<rect x="3.5" y="7" width="9" height="7" rx="1.5" fill="currentColor"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>', { width: 12, height: 12 });
const BLUETOOTH = () => icon('<path d="M4 4.8 12 11.2 8 15V1l4 3.8L4 11.2"/>');
const DESKTOP = () => icon('<rect x="2" y="2.5" width="12" height="8.5" rx="1.2"/><path d="M6 14h4M8 11v3"/>',
                           { width: 13, height: 13 });
const ARROW = () => icon('<path d="M3 8h10M9 4l4 4-4 4"/>', { width: 11, height: 11, stroke: 1.9 });
const UNLOCKED = () => icon('<rect x="3.5" y="7" width="9" height="7" rx="1.5" fill="currentColor"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5-.5"/>', { width: 12, height: 12 });

function typingTo(device) {
  const profile = device?.linked ? device.profile : null;
  return profile && profile.own != null ? profile : null;
}

function typingSummary(profile) {
  const number = `Profile ${profile.active + 1}`;
  if (profile.active === profile.own) return `Typing to this PC (${profile.name})`;
  return profile.name === number ? `Typing to ${profile.name}` : `Typing to ${profile.name} (${number})`;
}

// Windows has no Studio over Bluetooth, so without USB the route shown is the
// keyboard's own Bluetooth link, and there is no lock to show.
function connectionBadge(keyboard, device) {
  const c = keyboard.connection;
  const connected = c.state === 'connected';
  const bluetooth = !connected && !!device?.linked;
  const dot = connected ? (keyboard.locked ? DOT.locked : DOT.unlocked) : bluetooth ? DOT.bluetooth : DOT[c.state];
  const link = connected ? `${c.label}, Studio ${keyboard.locked ? 'locked' : 'unlocked'}`
    : bluetooth ? 'Bluetooth; the keymap is edited over USB'
    : c.state === 'failed' ? c.detail
    : c.state === 'connecting' ? 'Looking for the keyboard' : 'Not connected';
  const profile = typingTo(device);
  const title = profile ? `${link}\n${typingSummary(profile)}` : link;
  const children = [h('span.dot', { style: { background: dot } }),
                    h('span.name', {}, connected ? c.device || 'M0110' : bluetooth ? device.name : 'M0110')];
  if (connected || bluetooth) {
    children.push(h('span.route', { style: { color: 'var(--text-dim)', display: 'inline-flex' } },
      connected ? USB() : BLUETOOTH()));
  }
  if (connected) {
    children.push(h('span', { style: { color: keyboard.locked ? 'var(--warn)' : 'var(--text-dim)', display: 'inline-flex' } },
      keyboard.locked ? LOCKED() : UNLOCKED()));
  } else if (!bluetooth) {
    children.push(h('span.dim', { style: { fontSize: '13px' } },
      c.state === 'connecting' ? 'Connecting…' : 'Not connected'));
  }
  // Shown even when Studio is not connected. Studio only answers on the profile
  // being typed to, so a keyboard switched elsewhere is the likely reason.
  if (profile) {
    children.push(profile.active === profile.own
      ? h('span', { style: { color: 'var(--text-dim)', display: 'inline-flex' } }, DESKTOP())
      : h('span', { style: { color: 'var(--warn)', display: 'inline-flex', alignItems: 'center', gap: '4px',
                             fontSize: '13px' } }, ARROW(), profile.name));
  }
  return h('div.badge', { title }, children);
}

function emptyState(keyboard, app) {
  const locked = keyboard.connection.state === 'connected' && keyboard.locked;
  const bluetooth = keyboard.connection.state !== 'connected' && !!app.state?.device?.linked;
  return panel(h('div.empty', {},
    h('div.section-title', {}, locked ? 'Keyboard locked' : bluetooth ? 'Connected over Bluetooth' : 'No layout loaded'),
    h('div.body.dim', {}, locked
      ? 'ZMK Studio refuses reads as well as writes while locked, so the keymap cannot be shown yet. '
        + 'Press the key bound to &studio_unlock and it will load on its own. The lock re-arms after ten '
        + 'minutes idle and whenever the link drops.'
      : bluetooth
      ? 'This PC edits the keymap over USB only. Plug the keyboard in and switch its output to USB with the '
        + 'Fn-layer &out key: the firmware answers Studio only on the endpoint it is typing on.'
      : 'Connect the keyboard over USB. The firmware binds Studio’s RPC to whichever endpoint it is '
        + 'currently typing on, so a board typing over Bluetooth will not answer on USB. Switch its output '
        + 'to USB with the Fn-layer &out key to edit its keymap.'),
    h('div', { style: { paddingTop: '2px' } },
      pill('Reload', () => app.send('keyboard.reload'), { prominent: true }))));
}

function picker(app, slot, position, canEdit) {
  const ui = app.ui;
  const header = h('div.row', { style: { gap: '8px' } },
    h('span', { style: { fontSize: '16px', fontWeight: 600 } }, `Key ${position}`),
    h('span.dim', { style: { fontSize: '13px' } }, slot?.behavior ?? '—'),
    slot?.keycodeName ? h('span.dim', { style: { fontSize: '13px' } }, `· ${slot.keycodeName}`) : null,
    h('span.spacer'),
    pill('Done', () => select(app, null), { style: { fontSize: '13px' } }));
  if (!slot?.editable) {
    return panel(h('div.stack', {}, header, h('div.body.dim', {},
      `This slot is bound to ${slot?.behavior ?? 'nothing'}, whose parameter is not a keycode, so it cannot be `
      + 'remapped by picking a key. Changing the behaviour itself is not implemented.')));
  }
  const groups = app.fixed?.picker ?? [];
  const group = groups.find((g) => g.name === ui.pickerGroup) ?? groups[0];
  const tabs = segments(groups.map((g) => [g.name, g.name]), group?.name, (name) => {
    ui.pickerGroup = name;
    render(app);
  }, { style: { fontSize: '13px', padding: '6px 13px' } });
  const grid = h('div.keygrid', {}, (group?.keys ?? []).map((key) => pill(key.label,
    () => app.send('keyboard.rebind', { layer: ui.layer, position, value: key.value }),
    { disabled: !canEdit, title: key.name, style: { borderRadius: '9px', padding: '9px 12px', fontSize: '14px' } })));
  return panel(h('div.stack', {}, header, tabs, grid));
}

function select(app, position) {
  const ui = app.ui;
  const next = ui.selected === position ? null : position;
  if (next != null && ui.selected == null) ui.pickerGroup = 'Letters';
  ui.selected = next;
  render(app);
}

let host = null;

function render(app) {
  if (!host) return;
  const ui = app.ui;
  const keyboard = app.state?.keyboard ?? { connection: { state: 'disconnected' }, locked: true, layers: [],
                                             pendingEdits: 0 };
  const layers = keyboard.layers ?? [];
  const hasKeymap = layers.length > 0 && !!app.fixed;
  // Wait for the first state message before checking the layer and selection.
  if (app.state) {
    if (ui.layer >= layers.length) ui.layer = 0;
    if (!hasKeymap) ui.selected = null;
  }
  const canEdit = keyboard.connection.state === 'connected' && !keyboard.locked;

  const toolbar = h('div.toolbar', {},
    layers.length > 1 ? segments(layers.map((l, i) => [i, l.name || `Layer ${i}`]), ui.layer, (i) => {
      ui.layer = i;
      render(app);
    }, { style: { fontSize: '13px', padding: '6px 14px' } }) : null,
    keyboard.status ? h('span.status', { title: keyboard.status }, keyboard.status) : null,
    h('span.spacer'),
    app.board3d ? segments([[false, '2D'], [true, '3D']], ui.keyboard3D, (v) => {
      ui.keyboard3D = v;
      app.remember('keyboard3D', v);
      render(app);
    }, { style: { fontSize: '13px', padding: '6px 12px' } }) : null,
    connectionBadge(keyboard, app.state?.device),
    keyboard.connection.state === 'connected' && keyboard.locked
      ? pill('Unlock check', () => app.send('keyboard.unlockCheck')) : null,
    keyboard.pendingEdits > 0 ? pill('Discard', () => app.send('keyboard.discard')) : null,
    keyboard.pendingEdits > 0
      ? pill(`Save ${keyboard.pendingEdits}`, () => app.send('keyboard.save'), { prominent: true, title: 'Ctrl+S' })
      : null);

  const children = [toolbar];
  if (!hasKeymap) {
    children.push(emptyState(keyboard, app));
  } else {
    const width = Math.min(990, Math.max(420, host.clientWidth - 28));
    const boardHost = h('div.board-host');
    const slots = layers[ui.layer]?.slots;
    if (ui.keyboard3D && app.board3d) {
      // Same shape as the flat board: the case is 1750 x 600 units.
      boardHost.style.width = `${width}px`;
      boardHost.style.height = `${width * 600 / 1750}px`;
      children.push(h('div.panel.board-panel-3d', { style: { width: `${width + 28}px` } }, boardHost));
      const board3d = app.board3d;
      boardHost.append(board3d.canvas);
      board3d.onPick = ({ tag, position }) => {
        if (position == null || position === app.fixed.board.unmapped) return;
        board3d.press(tag);
        select(app, position);
      };
      board3d.setFocus('editor');
      board3d.paint(slots, ui.selected, canEdit, app.fixed.board.spacebarPosition);
      board3d.wake();
    } else {
      children.push(h('div.panel.board-panel', { style: { width: `${width + 28}px` } }, boardHost));
      drawBoard(boardHost, {
        board: app.fixed.board,
        slots,
        selected: ui.selected,
        canEdit,
        width,
        onSelect: (position) => select(app, position),
      });
    }
    if (ui.selected != null) {
      children.push(picker(app, layers[ui.layer]?.slots?.[String(ui.selected)], ui.selected, canEdit));
    }
  }
  host.replaceChildren(h('div.stack', {}, children));

  const open = ui.selected != null;
  if (open !== ui.pickerOpen) {
    ui.pickerOpen = open;
    app.relayout();
  }
}

export function keyboardPane(node, app) {
  host = node;
  const ui = app.ui;
  ui.layer ??= 0;
  ui.selected ??= null;
  ui.pickerGroup ??= 'Letters';
  const onKey = (event) => {
    if (event.ctrlKey && !event.shiftKey && event.key.toLowerCase() === 's'
        && (app.state?.keyboard?.pendingEdits ?? 0) > 0) {
      event.preventDefault();
      app.send('keyboard.save');
    }
  };
  document.addEventListener('keydown', onKey);
  render(app);
  return {
    update: render,
    unmount() {
      document.removeEventListener('keydown', onKey);
      host = null;
      if (ui.pickerOpen) { ui.pickerOpen = false; }
    },
  };
}
