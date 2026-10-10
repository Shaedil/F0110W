// The prismatic triad of one moment, as the window draws it: the Mac's
// Prism.swift, driven by chronos.js. The colours go to CSS as custom
// properties on :root, each an "r, g, b" triple for rgba():
//
//   --prism-t1..3  tints, for glows, rims, shines and washes
//   --prism-m1..3  marks, for the few things that carry a value
//
// and the ground's glows are painted on a canvas behind the window.
//
// Both sets keep the sky's hues but not its darkness. Night's triad sinks to
// navy, which on a near-black window is no colour at all, so tints are held
// to a middle lightness and marks to a light one, both with a floor of
// saturation: night comes out indigo, teal and violet rather than grey.

import { state, withLightness } from './chronos.js';

/** --ink, the ground under the glows. */
const INK = [11, 10, 9];
/** The ground is painted at this fraction of the window and stretched. */
const GROUND_SCALE = 8;

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
    root.dataset.tod = this.state.phase;
  }

  /** The window's ground: near-black with prismorphism's sun-tracking
   *  ambient in it, pm-ambient-chronos. Three soft glows of the triad, the
   *  strongest centred where the sun is, so it climbs the window through the
   *  morning and sets at the far edge, and all of them dim, though not out,
   *  at night. Each is CSS's radial-gradient(ellipse rx ry at x y, colour,
   *  transparent 60%), as the Mac draws it, but worked out here as opaque
   *  pixels: Chromium's software renderer speckles the ring where a CSS
   *  gradient fades out. The glows are soft, so an eighth of the window's
   *  size, stretched, loses nothing. */
  paintGround(canvas) {
    const width = Math.max(1, Math.ceil(innerWidth / GROUND_SCALE));
    const height = Math.max(1, Math.ceil(innerHeight / GROUND_SCALE));
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
    const scale = this.glowScale, sun = this.sun;
    // Bottom to top, as they stack.
    const glows = [
      { x: 0.5, y: 0.6, rx: 0.8, ry: 0.7, ink: this.tints[2], alpha: 0.2 * scale },
      { x: sun.x + 0.18, y: sun.y + 0.12, rx: 0.6, ry: 0.5, ink: this.tints[1], alpha: 0.4 * scale },
      { x: sun.x, y: sun.y, rx: 0.7, ry: 0.55, ink: this.tints[0], alpha: 0.55 * scale },
    ];
    const ctx = canvas.getContext('2d');
    const image = ctx.createImageData(width, height);
    for (let py = 0, i = 0; py < height; py++) {
      const y = (py + 0.5) / height;
      for (let px = 0; px < width; px++, i += 4) {
        const x = (px + 0.5) / width;
        const pixel = [...INK];
        for (const glow of glows) {
          const d = Math.hypot((x - glow.x) / glow.rx, (y - glow.y) / glow.ry);
          const a = glow.alpha * Math.max(0, 1 - d / 0.6);
          for (let k = 0; k < 3; k++) pixel[k] += (glow.ink[k] - pixel[k]) * a;
        }
        image.data[i] = Math.round(pixel[0]);
        image.data[i + 1] = Math.round(pixel[1]);
        image.data[i + 2] = Math.round(pixel[2]);
        image.data[i + 3] = 255;
      }
    }
    ctx.putImageData(image, 0, 0);
  }
}

/** Keeps the sky current: once now, then each minute, the original's own
 *  cadence. `pinned` ("HH:MM") holds it to a time of day instead, as the
 *  Mac's --snapshot-time does. `changed` hears each new Prism. */
export function followSky(changed, pinned = null, ground = document.getElementById('ground')) {
  const now = () => {
    const date = new Date();
    const match = /^(\d{1,2}):(\d{2})$/.exec(pinned ?? '');
    if (match) date.setHours(Number(match[1]), Number(match[2]), 0, 0);
    return date;
  };
  let prism = null;
  const tick = () => {
    prism = Prism.at(now());
    prism.apply();
    if (ground) prism.paintGround(ground);
    changed?.(prism);
  };
  tick();
  if (!pinned) setInterval(tick, 60_000);
  // The page asks for its window's size, so the ground follows it.
  addEventListener('resize', () => { if (ground) prism.paintGround(ground); });
}
