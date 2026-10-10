// Settings preview: the popup on a corner of a Windows desktop, using the
// current settings. It is drawn the same way as HUDRaster in the Windows HUD.

import { h } from './ui.js';

const ROWS = [
  [100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 200],
  [150, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 150],
  [175, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 225],
  [225, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 275],
  [-100, 98, 149, 818, 140, 95],
];

/** The small M0110 drawing, copied from HUDArt.board. */
function boardGlyph(width) {
  const unit = width / 1580;
  const height = 580 * unit;
  let caps = '';
  ROWS.forEach((row, r) => {
    let x = 0;
    for (const w of row) {
      if (w > 0) {
        caps += `<rect x="${(40 + x) * unit + 8 * unit}" y="${(40 + r * 100) * unit + 8 * unit}" `
          + `width="${w * unit - 16 * unit}" height="${84 * unit}" rx="${Math.max(14 * unit, 0.6)}" `
          + 'fill="#beb4a3" stroke="rgba(120,110,94,0.55)" stroke-width="0.35"/>';
      }
      x += Math.abs(w);
    }
  });
  return `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`
    + `<rect x="0.5" y="0.5" width="${width - 1}" height="${height - 1}" rx="${30 * unit}" fill="#f1ebdd" `
    + `stroke="rgba(148,138,117,0.65)"/>${caps}</svg>`;
}

function ring(level, diameter, line, low) {
  const r = diameter / 2 - line / 2 - 0.5;
  const c = 2 * Math.PI * r;
  const fraction = Math.min(level, 100) / 100;
  const colour = low ? 'var(--hud-low)' : 'var(--hud-good)';
  return `<svg width="${diameter}" height="${diameter}" viewBox="0 0 ${diameter} ${diameter}">`
    + `<circle cx="${diameter / 2}" cy="${diameter / 2}" r="${r}" fill="none" stroke="var(--hud-track)" stroke-width="${line}"/>`
    + `<circle cx="${diameter / 2}" cy="${diameter / 2}" r="${r}" fill="none" stroke="${colour}" stroke-width="${line}" `
    + `stroke-linecap="round" stroke-dasharray="${c * fraction} ${c}" transform="rotate(-90 ${diameter / 2} ${diameter / 2})"/>`
    + `<text x="50%" y="50%" text-anchor="middle" dominant-baseline="central" font-size="${11 * diameter / 34}" `
    + `font-weight="600" fill="var(--hud-secondary)">${level}</text></svg>`;
}

function hud(sample, scale, lowThreshold) {
  const s = scale;
  const showRing = sample.battery != null && sample.kind !== 'movedAway';
  const node = h('div.hud', { style: {
    height: `${48 * s}px`, borderRadius: `${24 * s}px`, padding: `0 ${7 * s}px 0 ${14 * s}px`,
    gap: `${12 * s}px`, minWidth: `${220 * s}px`, maxWidth: `${380 * s}px`,
  } });
  node.innerHTML = boardGlyph(72 * s);
  node.append(h('div.hud-text', {},
    h('div', { style: { fontSize: `${14 * s}px`, fontWeight: 600, color: 'var(--hud-title)' } }, 'M0110'),
    h('div', { style: { fontSize: `${12 * s}px`, color: 'var(--hud-secondary)' } }, sample.status)));
  if (showRing) {
    const holder = h('div', { style: { marginLeft: 'auto', display: 'flex' } });
    holder.innerHTML = ring(sample.battery, 34 * s, 4 * s, sample.battery <= lowThreshold);
    node.append(holder);
  }
  return node;
}

export class PopupPreview {
  constructor(app) {
    this.app = app;
    this.desk = h('div.desk');
    this.taskbar = h('div.taskbar', {}, h('span.tray', {}, '⌃'), h('span.clock', {}, '9:41 AM'));
    this.node = h('div.popup-preview', {}, this.desk, this.taskbar,
      h('div.preview-label', {}, 'Preview at these settings'));
    this.node.hidden = true;
    this.sample = 0;
    this.timer = null;
  }

  setActive(active) {
    this.node.hidden = !active;
    clearTimeout(this.timer);
    this.desk.replaceChildren();
    if (active) this.timer = setTimeout(() => this.play(), 700);
  }

  update() { /* The next sample reads the new settings. */ }

  settings() {
    const base = this.app.state?.settings ?? { scale: 1, insetX: 12, insetY: 12, hudDuration: 7, lowThreshold: 20 };
    return { ...base, ...(this.app.ui.previewSettings ?? {}) };
  }

  play() {
    const s = this.settings();
    const names = this.app.state?.profiles ?? [];
    const away = names[1]?.trim() || 'Profile 2';
    const samples = [
      { kind: 'connected', status: 'Connected', battery: 72 },
      { kind: 'lowBattery', status: 'Low Battery', battery: 14 },
      { kind: 'movedAway', status: `Moved to ${away}`, battery: 64 },
    ];
    const sample = samples[this.sample++ % samples.length];
    const popup = hud(sample, s.scale, s.lowThreshold);
    popup.style.right = `${s.insetX}px`;
    popup.style.bottom = `${s.insetY}px`;
    popup.style.opacity = 0;
    popup.style.transform = `translateX(${26 * s.scale}px)`;
    this.desk.replaceChildren(popup);
    const room = this.desk.clientWidth;
    const needed = popup.offsetWidth + s.insetX + 8;
    this.desk.style.zoom = needed > room ? room / needed : 1;

    requestAnimationFrame(() => {
      popup.style.transition = 'opacity 0.4s cubic-bezier(0.19, 1, 0.22, 1), transform 0.4s cubic-bezier(0.19, 1, 0.22, 1)';
      popup.style.opacity = 1;
      popup.style.transform = 'none';
    });
    const hold = Math.max(0.5, s.hudDuration) * 1000;
    this.timer = setTimeout(() => {
      popup.style.transition = 'opacity 0.5s cubic-bezier(0.25, 0.1, 0.25, 1)';
      popup.style.opacity = 0;
      this.timer = setTimeout(() => this.play(), 500);
    }, 400 + hold);
  }
}
