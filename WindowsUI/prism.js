// The prismatic triad of one moment, as the window draws it: the Mac's
// Prism.swift, driven by chronos.js. The colours go to CSS as custom
// properties on :root, each an "r, g, b" triple for rgba():
//
//   --prism-t1..3  tints, for glows, rims, shines and washes
//   --prism-m1..3  marks, for the few things that carry a value
//   --prism-glow   what glows are multiplied by
//   --sun-x/-y     where the ambient glow centres
//
// Both sets keep the sky's hues but not its darkness. Night's triad sinks to
// navy, which on a near-black window is no colour at all, so tints are held
// to a middle lightness and marks to a light one, both with a floor of
// saturation: night comes out indigo, teal and violet rather than grey.

import { state, withLightness } from './chronos.js';

export class Prism {
  constructor(sky) {
    this.state = sky;
    this.tints = sky.triad.map((c) => withLightness(c, 0.62, 1, 0.13));
    this.marks = sky.triad.map((c) => withLightness(c, 0.72, 1, 0.11));
  }

  /** The sky over this PC's time zone at a moment. */
  static at(date) { return new Prism(state(date)); }

  /** The original scales glows by the glow cap outright, which leaves a third
   *  of the glow at night; this keeps night calmer than day but still
   *  visibly prismatic. */
  get glowScale() { return 0.6 + 0.4 * this.state.glowCap; }

  /** The original parks a set sun on the bottom corner, where most of its
   *  glow falls outside the window; held in from the edges, it stays on
   *  screen. */
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

/** The boxes whose triad runs corner to corner. */
const DIAGONAL = '.panel, #sidebar, .pill.prominent, .segments button.active';

/** Gives each corner-to-corner box its own diagonal's angle as --diag, kept
 *  as it resizes and as boxes come and go. SwiftUI's topLeading to
 *  bottomTrailing gradient runs along that diagonal; CSS's "to bottom right"
 *  runs across the other one, which turns a wide box's triad top to bottom. */
export function followDiagonals(root = document.body) {
  const watched = new Set();
  const sizes = new ResizeObserver((entries) => {
    for (const entry of entries) {
      const box = entry.borderBoxSize?.[0];
      const width = box?.inlineSize ?? entry.contentRect.width;
      const height = box?.blockSize ?? entry.contentRect.height;
      if (!width || !height) continue;
      // CSS angles run clockwise from "to top"; this one points down the
      // diagonal, at 135deg for a square.
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
  // Classes only: the --diag writes themselves change style, not class.
  new MutationObserver(scan).observe(root, { subtree: true, childList: true, attributes: true,
                                             attributeFilter: ['class'] });
  scan();
}

/** Keeps the sky current: once now, then each minute, the original's own
 *  cadence. `pinned` ("HH:MM") holds it to a time of day instead, as the
 *  Mac's --snapshot-time does. `changed` hears each new Prism. */
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
