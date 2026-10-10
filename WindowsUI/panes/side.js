// The Bluetooth, Battery and Gestures panes, matching the Mac's.

import { h, panel, stepper } from '../ui.js';

function group(title, ...children) {
  return panel(h('div.group', {}, h('div.section-title', {}, title), ...children));
}

export function bluetoothPane(host, app) {
  const fields = [];
  for (let i = 0; i < 5; i++) {
    const field = h('input.field', {
      type: 'text', placeholder: `Profile ${i + 1}`, spellcheck: false,
      oninput: (event) => app.send('profiles.set', { index: i, name: event.target.value }),
    });
    fields.push(field);
  }
  host.append(h('div.stack', {}, group('Profiles',
    ...fields.map((field, i) => h('div.row', {}, h('span.label', {}, `Profile ${i + 1}`), h('span.spacer'), field)),
    h('div.note', {}, 'Shown when the keyboard switches away, as in “Moved to Work Laptop”.'),
    h('div.note', {}, 'Kept on the keyboard, so every computer paired with it shows the same names. '
      + 'A computer with the app names its own profile when it has none.'))));
  return {
    stageFocus: () => 'radio',
    update(app) {
      const names = app.state?.profiles ?? [];
      fields.forEach((field, i) => {
        if (document.activeElement !== field) field.value = names[i] ?? '';
      });
    },
  };
}

function stepperRow(label, key, range, app) {
  const value = h('span.value');
  const holder = h('span');
  const row = h('div.row', {}, h('span.label', {}, label), h('span.spacer'), value, holder);
  return {
    row,
    update(settings) {
      const v = settings[key];
      value.textContent = `${v}%`;
      holder.replaceChildren(stepper(v, range, (next) => app.send('settings.set', { key, value: next })));
    },
  };
}

export function batteryPane(host, app) {
  const low = stepperRow('Low battery at', 'lowThreshold', { min: 5, max: 60 }, app);
  const rearm = stepperRow('Re-arm alert at', 'rearmThreshold', { min: 10, max: 90 }, app);
  const warning = h('div.warning', { hidden: true }, h('span', {}, '⚠'),
    h('span', {}, 'Re-arm must exceed the low threshold, or the alert latches off. It is clamped to low + 10 at launch.'));
  host.append(h('div.stack', {}, group('Low battery alert', low.row, rearm.row, warning)));
  return {
    stageFocus: () => 'battery',
    update(app) {
      const settings = app.state?.settings;
      if (!settings) return;
      low.update(settings);
      rearm.update(settings);
      warning.hidden = settings.rearmThreshold > settings.lowThreshold;
    },
  };
}

function bullets(title, items, colour) {
  return panel(h('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } },
    h('div.section-title', { style: colour ? { color: colour } : undefined }, title),
    h('div', { style: { display: 'flex', flexDirection: 'column', gap: '6px' } }, items.map((item) =>
      h('div', { style: { display: 'flex', gap: '7px' } },
        h('span', { style: { flex: 'none', width: '3px', height: '3px', marginTop: '6px', borderRadius: '50%',
                             background: 'var(--text-dim)' } }),
        h('span.body.dim', {}, item))))));
}

export function gesturesPane(host) {
  host.append(h('div.stack', { style: { maxWidth: '620px' } },
    panel(h('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } },
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '7px' } },
        h('span', { style: { color: 'var(--warn)', fontSize: '11px' } }, '⚠'),
        h('span.section-title', {}, 'No supporting hardware on this build')),
      h('div.body.dim', {}, 'The M0110 is a 1984 matrix keyboard that talks to the converter over a two-wire '
        + 'clock/data protocol. It reports key make and break codes and nothing else. There is no touch surface, '
        + 'dial, or trackpad to read gestures from.'))),
    bullets('Would require', [
      'A capacitive touch surface, encoder, or dial wired to spare nice!nano GPIO',
      'A ZMK input driver for that sensor (pointing or encoder subsystem)',
    ]),
    bullets('Firmware', [
      'The kscan driver in config/drivers/kscan/kscan_m0110.c decodes the M0110 serial protocol only. Gesture '
      + 'input would be a separate device, not an extension of it.',
    ]),
    bullets('Available today', [
      'Per-key tap versus hold already works in firmware via ZMK hold-tap behaviours, with no new hardware. That '
      + 'is a keymap feature rather than gesture sensing, and could be surfaced in the Keys pane.',
    ], 'var(--good)')));
  return { stageFocus: () => 'gestures' };
}
