// The Settings pane: the Mac's SettingsPane, with its Popup and Clipboard
// tabs. Popup settings apply to the next popup; the Mac reads them at launch.

import { fixed, h, panel, segments, slider, toggle } from '../ui.js';

const SLIDERS = [
  { key: 'scale', label: 'Scale', min: 0.5, max: 2.5, step: 0.05, format: (v) => `${fixed(v, 2)}×` },
  { key: 'insetX', label: 'Inset from right edge', min: 0, max: 400, step: 2, format: (v) => `${fixed(v, 0)} px` },
  { key: 'insetY', label: 'Gap above taskbar', min: 0, max: 40, step: 1, format: (v) => `${fixed(v, 0)} px` },
  { key: 'hudDuration', label: 'Visible for', min: 1, max: 12, step: 0.2, format: (v) => `${fixed(v, 1)} s` },
];

const TOGGLES = [
  { key: 'showDisconnect', label: 'Show a popup on disconnect' },
  { key: 'suppressInitial', label: 'Stay quiet if already connected at launch' },
];

function group(title, ...children) {
  return panel(h('div.group', {}, h('div.section-title', {}, title), ...children));
}

function savedTab() {
  try { return localStorage.getItem('settingsTab') ?? 'Popup'; } catch { return 'Popup'; }
}

export function settingsPane(host, app) {
  let tab = savedTab();
  let rows = [];
  /** Slider values while dragging, so the readout and the preview follow
   *  the knob before the app has written them. */
  const live = {};
  app.ui.previewSettings = live;

  function build() {
    rows = [];
    const tabs = segments([['Popup', 'Popup'], ['Clipboard', 'Clipboard']], tab, (next) => {
      tab = next;
      try { localStorage.setItem('settingsTab', next); } catch { /* per-viewer only */ }
      build();
      app.stage?.focus(tab === 'Popup' ? 'popup' : null);
      update(app);
    });
    let body;
    if (tab === 'Popup') {
      const sliders = SLIDERS.map((spec) => {
        const value = h('span.value');
        const control = slider(1, spec, (v) => {
          live[spec.key] = v;
          value.textContent = spec.format(v);
          app.stage?.update(app);
        }, (v) => {
          app.send('settings.set', { key: spec.key, value: v });
        });
        rows.push({ update: (s) => { const v = live[spec.key] ?? s[spec.key]; value.textContent = spec.format(v); control.set(v); } });
        return h('div', { style: { display: 'flex', flexDirection: 'column', gap: '3px' } },
          h('div.row', {}, h('span.label', {}, spec.label), h('span.spacer'), value), control);
      });
      const toggles = TOGGLES.map((spec) => {
        const holder = h('span');
        rows.push({ update: (s) => holder.replaceChildren(toggle(!!s[spec.key],
          (on) => app.send('settings.set', { key: spec.key, value: on }))) });
        return h('div.row', {}, h('span.label', {}, spec.label), h('span.spacer'), holder);
      });
      body = [group('Popup', ...sliders), group('Events', ...toggles,
        h('div.note', {}, 'Changes apply to the next popup. Command-line flags still override them for a single run.'))];
    } else {
      const holder = h('span');
      rows.push({ update: (s) => holder.replaceChildren(toggle(s.clipboardSync !== false,
        (on) => app.send('settings.set', { key: 'clipboardSync', value: on }))) });
      body = [group('Clipboard',
        h('div.row', {}, h('span.label', {}, 'Carry copied text to the keyboard’s other computers'),
          h('span.spacer'), holder),
        h('div.note', {}, 'Text copied here goes with the keyboard when it switches computers: onto that '
          + 'computer’s clipboard if this app runs there, typed out if not. Concealed passwords are never sent.'),
        h('div.note', {}, 'Images go too, through the keyboard, scaled down to about 40 KB on the way.'))];
    }
    host.replaceChildren(h('div.stack', {}, tabs, ...body));
  }

  function update(app) {
    const settings = app.state?.settings;
    if (!settings) return;
    for (const key of Object.keys(live)) if (settings[key] === live[key]) delete live[key];
    for (const row of rows) row.update(settings);
  }

  build();
  return {
    stageFocus: () => (tab === 'Popup' ? 'popup' : null),
    update,
    unmount() { delete app.ui.previewSettings; },
  };
}
