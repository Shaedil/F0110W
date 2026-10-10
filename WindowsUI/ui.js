// Copies of the Mac theme's controls.

/** Usage: `h('div.panel', {onclick}, child, 'text', ...)`. */
export function h(tag, props = {}, ...children) {
  const [name, ...classes] = tag.split('.');
  const node = document.createElement(name || 'div');
  if (classes.length) node.className = classes.join(' ');
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value == null || value === false) continue;
    if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (key === 'style') Object.assign(node.style, value);
    else if (key === 'text') node.textContent = value;
    else if (key in node && key !== 'list') node[key] = value;
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child == null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function panel(...children) {
  return h('div.panel', {}, ...children);
}

export function pill(label, onclick, { prominent = false, disabled = false, title, style } = {}) {
  return h(`button.pill${prominent ? '.prominent' : ''}`, { onclick, disabled, title, style }, label);
}

/** Options as [value, label] pairs. */
export function segments(options, selected, onchange, { style } = {}) {
  return h('div.segments', {},
    options.map(([value, label]) => h(`button${value === selected ? '.active' : ''}`,
      { style, onclick: () => value !== selected && onchange(value) }, label)));
}

export function toggle(on, onchange, { disabled = false } = {}) {
  return h(`button.switch${on ? '.on' : ''}`, {
    role: 'switch', 'aria-checked': String(on), disabled,
    style: disabled ? { opacity: 0.4 } : undefined,
    onclick: () => onchange(!on),
  });
}

export function slider(value, { min, max, step }, oninput, onchange) {
  const fill = h('div.fill');
  const knob = h('div.knob');
  const node = h('div.slider', {}, h('div.track'), fill, knob);
  let current = value;
  const place = (v) => {
    const fraction = (v - min) / (max - min);
    // 6.5px is half the knob's width, so the knob stays inside the track.
    knob.style.left = `calc(6.5px + (100% - 13px) * ${fraction})`;
    fill.style.width = `calc(6.5px + (100% - 13px) * ${fraction})`;
  };
  const at = (event) => {
    const box = node.getBoundingClientRect();
    const fraction = Math.min(1, Math.max(0, (event.clientX - box.left - 6.5) / (box.width - 13)));
    const raw = min + fraction * (max - min);
    return Math.min(max, Math.max(min, Math.round((raw - min) / step) * step + min));
  };
  node.addEventListener('pointerdown', (event) => {
    node.setPointerCapture(event.pointerId);
    node.dataset.dragging = '1';
    current = at(event);
    place(current);
    oninput?.(current);
  });
  node.addEventListener('pointermove', (event) => {
    if (!node.dataset.dragging) return;
    const next = at(event);
    if (next === current) return;
    current = next;
    place(current);
    oninput?.(current);
  });
  node.addEventListener('pointerup', () => {
    delete node.dataset.dragging;
    onchange?.(current);
  });
  place(value);
  node.set = (v) => { if (!node.dataset.dragging) { current = v; place(v); } };
  return node;
}

export function stepper(value, { min, max }, onchange) {
  return h('div.stepper', {},
    h('button', { disabled: value <= min, onclick: () => onchange(value - 1), 'aria-label': 'Decrease' }, '−'),
    h('button', { disabled: value >= max, onclick: () => onchange(value + 1), 'aria-label': 'Increase' }, '+'));
}

export function fixed(value, digits) {
  return Number(value).toFixed(digits);
}
