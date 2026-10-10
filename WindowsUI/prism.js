// Sets the window's time-of-day colours on :root, ported from the Mac's Prism.swift.
// --prism-t1..3 (tints) and --prism-m1..3 (marks) are "r, g, b" triples for rgba().
// Lightness and saturation are clamped so night colours stay visible on the
// dark window instead of fading to navy.

import { state, withLightness } from './chronos.js';

export class Prism {
  constructor(sky) {
    this.state = sky;
    this.tints = sky.triad.map((c) => withLightness(c, 0.62, 1, 0.13));
    this.marks = sky.triad.map((c) => withLightness(c, 0.72, 1, 0.11));
  }

  static at(date) { return new Prism(state(date)); }

  /** The Mac uses glowCap directly, which makes night too dim here. */
  get glowScale() { return 0.6 + 0.4 * this.state.glowCap; }

  /** Clamped so the glow stays on screen. The Mac puts a set sun in the bottom corner. */
  get sun() {
    return { x: Math.min(Math.max(this.state.sunX, 0.15), 0.85), y: Math.min(this.state.sunY, 0.72) };
  }

  apply(root = document.documentElement) {
    const set = (name, value) => root.style.setProperty(name, value);
    this.tints.forEach((c, i) => set(`--prism-t${i + 1}`, c.join(', ')));
    this.marks.forEach((c, i) => set(`--prism-m${i + 1}`, c.join(', ')));
    set('--prism-glow', this.glowScale.toFixed(3));
    set('--sun-x', `${(this.sun.x * 100).toFixed(1)}%`);
    set('--sun-y', `${(this.sun.y * 100).toFixed(1)}%`);
    root.dataset.tod = this.state.phase;
  }
}

const DIAGONAL = '.panel, #sidebar, .pill.prominent, .segments button.active';

/** Sets --diag on each DIAGONAL box to the angle of its own diagonal. CSS's
 *  "to bottom right" does not follow the diagonal on wide boxes, but SwiftUI's
 *  topLeading to bottomTrailing gradient does. */
export function followDiagonals(root = document.body) {
  const watched = new Set();
  const sizes = new ResizeObserver((entries) => {
    for (const entry of entries) {
      const box = entry.borderBoxSize?.[0];
      const width = box?.inlineSize ?? entry.contentRect.width;
      const height = box?.blockSize ?? entry.contentRect.height;
      if (!width || !height) continue;
      // CSS angles go clockwise from "to top". A square gives 135deg.
      const angle = 180 - Math.atan(width / height) * 180 / Math.PI;
      entry.target.style.setProperty('--diag', `${angle.toFixed(2)}deg`);
    }
  });
  const scan = () => {
    for (const el of watched) {
      if (!el.isConnected || !el.matches(DIAGONAL)) { sizes.unobserve(el); watched.delete(el); }
    }
    for (const el of root.querySelectorAll(DIAGONAL)) {
      if (!watched.has(el)) { watched.add(el); sizes.observe(el); }
    }
  };
  // Watch class changes only, since writing --diag changes the style attribute.
  new MutationObserver(scan).observe(root, { subtree: true, childList: true, attributes: true,
                                             attributeFilter: ['class'] });
  scan();
}

/** Updates once a minute, like the Mac. `pinned` ("HH:MM") fixes the time
 *  of day, like the Mac's --snapshot-time. */
export function followSky(changed, pinned = null) {
  const now = () => {
    const date = new Date();
    const match = /^(\d{1,2}):(\d{2})$/.exec(pinned ?? '');
    if (match) date.setHours(Number(match[1]), Number(match[2]), 0, 0);
    return date;
  };
  const tick = () => {
    const prism = Prism.at(now());
    prism.apply();
    changed?.(prism);
  };
  tick();
  if (!pinned) setInterval(tick, 60_000);
}
