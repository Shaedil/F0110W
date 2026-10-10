// prismorphism's Chronos engine, as the Mac's Chronos.swift ports it: where
// the real sun is, and the prismatic triad that goes with it. Dawn rose, noon
// prism, dusk amber, deep-indigo night. Colours are [r, g, b], 0...255.
//
// Times are read on the page's own clock and time zone, as the Mac reads
// TimeZone.current. Coordinates are guessed from the clock offset, so no
// location permission is needed.

const RAD = Math.PI / 180;

/** The static prism the engine settles on when the sun is high. */
export const NOON = {
  triad: [[255, 30, 140], [26, 229, 229], [255, 232, 59]],
  glowCap: 0.9, phase: 'day', elevation: 90, azimuth: 180, sunX: 0.5, sunY: 0.08,
};

/** Hours east of UTC at `date`: getTimezoneOffset, in hours and the other way round. */
function offsetHours(date) {
  return -date.getTimezoneOffset() / 60;
}

/** Longitude from the clock offset at a temperate latitude, the original's
 *  `tzGuess`. During daylight saving the guess sits 15° east of true, and
 *  `sunPosition` subtracts the same hour back out. */
export function guess(date) {
  return { lat: 40, lng: Math.round(offsetHours(date) * 15) };
}

/** NOAA's general solar position: elevation above the horizon and azimuth
 *  clockwise from north, both in degrees. */
export function sunPosition(date, coords) {
  const startOfYear = new Date(date.getFullYear(), 0, 1);
  const startOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const dayOfYear = Math.round((startOfDay - startOfYear) / 86400000) + 1;
  const hours = date.getHours() + date.getMinutes() / 60 + date.getSeconds() / 3600;
  const gamma = (2 * Math.PI / 365) * (dayOfYear - 1 + (hours - 12) / 24);

  const eqtime = 229.18 * (0.000075 + 0.001868 * Math.cos(gamma) - 0.032077 * Math.sin(gamma)
    - 0.014615 * Math.cos(2 * gamma) - 0.040849 * Math.sin(2 * gamma));
  const decl = 0.006918 - 0.399912 * Math.cos(gamma) + 0.070257 * Math.sin(gamma)
    - 0.006758 * Math.cos(2 * gamma) + 0.000907 * Math.sin(2 * gamma)
    - 0.002697 * Math.cos(3 * gamma) + 0.00148 * Math.sin(3 * gamma);

  const tst = hours * 60 + (eqtime + 4 * coords.lng - 60 * offsetHours(date));
  const ha = (tst / 4 - 180) * RAD;
  const lat = coords.lat * RAD;

  const cosZ = Math.sin(lat) * Math.sin(decl) + Math.cos(lat) * Math.cos(decl) * Math.cos(ha);
  const elevation = 90 - Math.acos(Math.min(1, Math.max(-1, cosZ))) / RAD;
  const az = Math.atan2(Math.sin(ha), Math.cos(ha) * Math.sin(lat) - Math.tan(decl) * Math.cos(lat));
  const azimuth = (az / RAD + 180) % 360;
  return { elevation, azimuth };
}

// ---- Sky ramps ----

const stop = (el, p1, p2, p3, glow) => ({ el, p1, p2, p3, glow });

/** The original's DEFAULT_RISE, morning colours from deep night up. */
export const RISE = [
  stop(-14, [26, 35, 71], [28, 62, 80], [62, 46, 96], 0.35),
  stop(-7, [44, 74, 124], [46, 107, 125], [176, 120, 158], 0.50),
  stop(-2, [224, 138, 170], [138, 160, 224], [255, 200, 150], 0.65),
  stop(4, [255, 150, 115], [140, 185, 228], [255, 214, 150], 0.75),
  stop(14, [255, 120, 175], [80, 205, 228], [255, 225, 150], 0.84),
  stop(45, [255, 30, 140], [26, 229, 229], [255, 232, 59], 0.90),
];

/** The original's DEFAULT_SET, evening colours from high sun down. */
export const SET = [
  stop(45, [255, 30, 140], [26, 229, 229], [255, 232, 59], 0.90),
  stop(14, [255, 160, 90], [255, 210, 140], [130, 165, 205], 0.88),
  stop(5, [255, 124, 63], [255, 176, 100], [120, 150, 200], 0.86),
  stop(1, [255, 92, 57], [255, 94, 140], [120, 80, 180], 0.82),
  stop(-2, [212, 71, 126], [255, 128, 108], [96, 80, 168], 0.60),
  stop(-7, [58, 74, 140], [74, 100, 158], [180, 100, 128], 0.48),
  stop(-14, [26, 35, 71], [28, 62, 80], [62, 46, 96], 0.35),
];

/** The ramp at an altitude: the end stops beyond either end, a mix of the two
 *  stops around it in between. */
export function sample(stops, el) {
  const asc = stops[0].el < stops[stops.length - 1].el ? stops : [...stops].reverse();
  const first = asc[0], last = asc[asc.length - 1];
  if (el <= first.el) return first;
  if (el >= last.el) return last;
  for (let i = 0; i + 1 < asc.length; i++) {
    const a = asc[i], b = asc[i + 1];
    if (el < a.el || el > b.el) continue;
    const t = (el - a.el) / (b.el - a.el);
    return stop(el, mix(a.p1, b.p1, t), mix(a.p2, b.p2, t), mix(a.p3, b.p3, t), a.glow + (b.glow - a.glow) * t);
  }
  return last;
}

/** The triad for a moment. With no coordinates, they are guessed from the
 *  clock offset. */
export function state(date, coords = guess(date)) {
  const sun = sunPosition(date, coords);
  const rising = sun.azimuth < 180;
  const s = sample(rising ? RISE : SET, sun.elevation);
  const phase = sun.elevation > 10 ? 'day' : sun.elevation <= -6 ? 'night' : rising ? 'dawn' : 'golden';
  return {
    triad: [s.p1, s.p2, s.p3],
    glowCap: s.glow,
    phase,
    elevation: sun.elevation,
    azimuth: sun.azimuth,
    sunX: Math.min(1, Math.max(0, (sun.azimuth - 90) / 180)),
    sunY: Math.min(0.95, Math.max(0.04, 0.9 - Math.max(0, sun.elevation) / 90 * 0.84)),
  };
}

// ---- OKLCH ----

/** Mix in OKLCH, so a transition stays luminous rather than passing through a
 *  muddy midpoint. Hue takes the short way round; a near-grey end takes the
 *  other end's hue. */
export function mix(a, b, t) {
  const A = lab(a), B = lab(b);
  const ca = Math.hypot(A.a, A.b), cb = Math.hypot(B.a, B.b);
  const ha = Math.atan2(A.b, A.a), hb = Math.atan2(B.b, B.a);
  const L = A.L + (B.L - A.L) * t;
  const C = ca + (cb - ca) * t;
  const h = ca < 0.004 ? hb : cb < 0.004 ? ha : lerpAngle(ha, hb, t);
  return toRGB(L, C * Math.cos(h), C * Math.sin(h));
}

/** The same hue at a lightness clamped into [lo, hi] and at least `minChroma`
 *  of colour, for a colour that has to show on a dark window. Already within
 *  both, it comes back untouched. */
export function withLightness(c, lo, hi, minChroma = 0) {
  const x = lab(c);
  const L = Math.min(Math.max(x.L, lo), hi);
  const chroma = Math.hypot(x.a, x.b);
  const boost = chroma > 0.004 && chroma < minChroma ? minChroma / chroma : 1;
  if (L === x.L && boost === 1) return c;
  return toRGB(L, x.a * boost, x.b * boost);
}

function lerpAngle(a, b, t) {
  let d = b - a;
  while (d > Math.PI) d -= 2 * Math.PI;
  while (d < -Math.PI) d += 2 * Math.PI;
  return a + d * t;
}

const linear = (c) => {
  const v = c / 255;
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
};

const encoded = (c) => {
  const v = c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
  return Math.max(0, Math.min(255, Math.round(v * 255)));
};

function lab([r, g, b]) {
  const lr = linear(r), lg = linear(g), lb = linear(b);
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return {
    L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  };
}

function toRGB(L, a, b) {
  const l = Math.pow(L + 0.3963377774 * a + 0.2158037573 * b, 3);
  const m = Math.pow(L - 0.1055613458 * a - 0.0638541728 * b, 3);
  const s = Math.pow(L - 0.0894841775 * a - 1.2914855480 * b, 3);
  return [
    encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
  ];
}
