// Fakes the Windows app when the page is opened in a browser. fixture.json is
// made by tools/win-ui-fixture.sh.

const params = new URLSearchParams(location.search);

export async function start(deliver) {
  const fixture = await (await fetch('fixture.json')).json();
  const keyboardState = params.get('keyboard') ?? 'unlocked';
  const state = {
    type: 'state',
    device: { name: 'M0110', linked: keyboardState !== 'disconnected', battery: Number(params.get('battery') ?? 76),
              profile: { active: Number(params.get('active') ?? 1), own: 1,
                         name: params.get('active') === '0' ? 'MacBook Air' : 'Windows PC' } },
    keyboard: {
      connection: keyboardState === 'disconnected' || keyboardState === 'bluetooth' ? { state: 'disconnected' }
        : keyboardState === 'failed' ? { state: 'failed', detail: 'No keyboard answered over USB; retrying.' }
        : { state: 'connected', label: 'COM5', device: 'M0110' },
      locked: keyboardState === 'locked',
      status: null,
      pendingEdits: 0,
      layers: keyboardState === 'unlocked' ? fixture.layers : [],
    },
    settings: { scale: 1, insetX: 12, insetY: 12, hudDuration: 7, showDisconnect: true, suppressInitial: false,
                lowThreshold: 20, rearmThreshold: 30, clipboardSync: true },
    profiles: ['MacBook Air', 'Windows PC', '', '', ''],
  };
  const publish = () => deliver(structuredClone(state));

  return {
    receive(message) {
      switch (message.type) {
        case 'ready':
          deliver({ type: 'fixed', board: fixture.board, picker: fixture.picker });
          publish();
          break;
        case 'layout':
          document.title = `M0110 ${message.width}×${message.height}`;
          document.documentElement.style.width = `${message.width}px`;
          document.documentElement.style.height = `${message.height}px`;
          break;
        case 'settings.set':
          state.settings[message.key] = message.value;
          publish();
          break;
        case 'profiles.set':
          state.profiles[message.index] = message.name;
          publish();
          break;
        case 'keyboard.rebind': {
          const slot = state.keyboard.layers[message.layer]?.slots[String(message.position)];
          const key = fixture.picker.flatMap((g) => g.keys).find((k) => k.value === message.value);
          if (!slot || !key) break;
          Object.assign(slot, {
            behavior: 'Key Press', editable: true, keycode: key.value, keycodeName: key.name,
            legend: key.label.length === 1 ? { kind: 'single', text: key.label } : { kind: 'word', text: key.label },
          });
          state.keyboard.pendingEdits += 1;
          state.keyboard.status = `Set key ${message.position} to ${key.name}`;
          publish();
          break;
        }
        case 'keyboard.save':
          state.keyboard.pendingEdits = 0;
          state.keyboard.status = 'Saved to the keyboard’s flash';
          publish();
          break;
        case 'keyboard.discard':
          state.keyboard.pendingEdits = 0;
          state.keyboard.status = 'Discarded unsaved changes';
          publish();
          break;
      }
    },
  };
}
