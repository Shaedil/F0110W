// Ports of the Mac window's PixelIcon, DitheredTitle and RacingStripes. They are
// drawn one dot per CSS pixel and scaled up without smoothing.

const ATKINSON = [[1, 0], [2, 0], [-1, 1], [0, 1], [1, 1], [0, 2]];

/** Atkinson dithering. Changes `level` (0 to 1 per pixel) in place.
 *  `keep(y)` limits which rows the error can spread to. */
function dither(level, width, height, keep = () => true) {
  const lit = new Uint8Array(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = y * width + x;
      const on = level[i] >= 0.5;
      if (on) lit[i] = 1;
      const share = (level[i] - (on ? 1 : 0)) / 8;
      for (const [dx, dy] of ATKINSON) {
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= width || ny >= height || !keep(ny)) continue;
        level[ny * width + nx] += share;
      }
    }
  }
  return lit;
}

function canvas(width, height) {
  const c = document.createElement('canvas');
  c.width = width;
  c.height = height;
  c.style.width = `${width}px`;
  c.style.height = `${height}px`;
  c.style.imageRendering = 'pixelated';
  return c;
}

/** `ink` is [r, g, b] or a function of x that returns one. */
function paint(c, lit, ink) {
  const ctx = c.getContext('2d');
  const image = ctx.createImageData(c.width, c.height);
  const at = typeof ink === 'function' ? ink : () => ink;
  for (let i = 0; i < lit.length; i++) {
    if (!lit[i]) continue;
    const [r, g, b] = at(i % c.width);
    image.data.set([r, g, b, 255], i * 4);
  }
  ctx.putImageData(image, 0, 0);
}

function gradient(colours, width) {
  return (x) => {
    const t = (width > 1 ? x / (width - 1) : 0) * (colours.length - 1);
    const i = Math.min(Math.floor(t), colours.length - 2), f = t - i;
    const a = colours[i], b = colours[i + 1] ?? a;
    return a.map((c, k) => Math.round(c + (b[k] - c) * f));
  };
}

export function rgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

// ---- Sidebar icons ----

const ICONS = {
  keys(fill) {
    fill(0, 3, 16, 1); fill(0, 12, 16, 1); fill(0, 3, 1, 10); fill(15, 3, 1, 10);
    for (let row = 0; row < 3; row++)
      for (let col = 0; col < 6; col++) fill(2 + col * 2.2, 5 + row * 2, 1.4, 1.4, 0.85);
    fill(5, 10, 6, 1.4, 0.85);
  },
  bluetooth(fill) {
    fill(7, 1, 1.6, 14);
    fill(8.6, 2, 1.4, 1.4); fill(10, 3.4, 1.4, 1.4); fill(11.4, 4.8, 1.4, 1.4);
    fill(10, 6.2, 1.4, 1.4); fill(8.6, 7.6, 1.4, 1.4);
    fill(10, 9, 1.4, 1.4); fill(11.4, 10.4, 1.4, 1.4); fill(10, 11.8, 1.4, 1.4);
    fill(8.6, 13.2, 1.4, 1.4);
    fill(5.6, 4.8, 1.4, 1.4, 0.8); fill(4.2, 3.4, 1.4, 1.4, 0.8);
    fill(5.6, 10.4, 1.4, 1.4, 0.8); fill(4.2, 11.8, 1.4, 1.4, 0.8);
  },
  battery(fill) {
    fill(1, 4, 12, 1); fill(1, 11, 12, 1); fill(1, 4, 1, 8); fill(12, 4, 1, 8);
    fill(13, 6, 2, 4);
    fill(3, 6, 6.5, 4, 0.85);
  },
  gestures(fill) {
    fill(7, 1, 2, 7);
    fill(4, 8, 8, 1); fill(4, 13, 8, 1); fill(4, 8, 1, 6); fill(11, 8, 1, 6);
    fill(6, 10, 4, 2, 0.7);
  },
  settings(fill) {
    fill(3, 3, 10, 1); fill(3, 12, 10, 1); fill(3, 3, 1, 10); fill(12, 3, 1, 10);
    fill(5, 5.5, 6, 1.6, 0.9);
    fill(5, 9, 6, 1.6, 0.6);
  },
};

export function pixelIcon(kind, tint) {
  const scale = window.devicePixelRatio || 1;
  const size = 16;
  const c = document.createElement('canvas');
  c.width = Math.round(size * scale);
  c.height = Math.round(size * scale);
  c.style.width = c.style.height = `${size}px`;
  const ctx = c.getContext('2d');
  const u = c.width / 16;
  ctx.fillStyle = tint;
  ICONS[kind]((x, y, w, h, alpha = 1) => {
    ctx.globalAlpha = alpha;
    ctx.fillRect(x * u, y * u, w * u, h * u);
  });
  return c;
}

// ---- Racing stripes ----

/** `inks` is a "#rrggbb" string or a list of [r, g, b] colours spread left to right. */
export function racingStripes(width, inks, height = 13) {
  width = Math.max(1, Math.floor(width));
  const level = new Float64Array(width * height);
  for (let y = 0; y < height; y++) {
    if (y % 3 === 2) continue;
    for (let x = 0; x < width; x++) level[y * width + x] = 0.9 * Math.pow(1 - x / width, 1.4);
  }
  const lit = dither(level, width, height, (y) => y % 3 !== 2);
  const c = canvas(width, height);
  paint(c, lit, typeof inks === 'string' ? rgb(inks) : gradient(inks, width));
  return c;
}

// ---- Dithered titles ----

const titles = new Map();

export function ditheredTitle(text, ink = [247, 244, 236]) {
  const key = `${text}|${ink}`;
  if (!titles.has(key)) titles.set(key, titleDots(text));
  const { lit, width, height } = titles.get(key);
  const c = canvas(width, height);
  c.setAttribute('role', 'img');
  c.setAttribute('aria-label', text);
  paint(c, lit, ink);
  return c;
}

function titleDots(text) {

  const font = '42px Georgia, Cambria, serif';
  const probe = document.createElement('canvas').getContext('2d');
  probe.font = font;
  const metrics = probe.measureText(text);
  const ascent = Math.ceil(metrics.fontBoundingBoxAscent ?? 38);
  const descent = Math.ceil(metrics.fontBoundingBoxDescent ?? 10);
  const width = Math.ceil(metrics.width) + 2;
  const height = ascent + descent;

  const mask = document.createElement('canvas');
  mask.width = width;
  mask.height = height;
  const ctx = mask.getContext('2d');
  ctx.font = font;
  ctx.fillStyle = '#fff';
  ctx.textBaseline = 'alphabetic';
  ctx.fillText(text, 1, ascent);
  const alpha = ctx.getImageData(0, 0, width, height).data;

  const level = new Float64Array(width * height);
  for (let y = 0; y < height; y++) {
    const shade = 1 - 0.5 * y / Math.max(height - 1, 1);
    for (let x = 0; x < width; x++) level[y * width + x] = alpha[(y * width + x) * 4 + 3] / 255 * shade;
  }
  return { lit: dither(level, width, height), width, height };
}
