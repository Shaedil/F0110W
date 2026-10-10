// WindowsUI/chronos.js held to the same values as the Mac's ChronosTests,
// which come from prismorphism's own engine. Run under New York time:
//
//     TZ=America/New_York node --test Tests/WindowsUI

import assert from 'node:assert/strict';
import test from 'node:test';
import { NOON, guess, mix, state, sunPosition, withLightness } from '../../WindowsUI/chronos.js';

const nyc = { lat: 40.71, lng: -74.0 };
const local = (y, mo, d, h, mi) => new Date(y, mo - 1, d, h, mi);
const near = (got, want, accuracy, what = '') =>
  assert.ok(Math.abs(got - want) <= accuracy, `${what} ${got} vs ${want}`);

/** Channels within one step of the original's output. */
function assertTriad(got, want) {
  assert.equal(got.length, want.length);
  got.forEach((g, i) => g.forEach((c, j) => near(c, want[i][j], 1, `${g} vs ${want[i]}`)));
}

test('runs in New York time', () => {
  assert.equal(new Date(2026, 6, 1).getTimezoneOffset(), 240, 'run with TZ=America/New_York');
});

test('sun position matches NOAA', () => {
  const sun = sunPosition(local(2026, 6, 21, 13, 0), nyc);
  near(sun.elevation, 72.733, 0.01);
  near(sun.azimuth, 182.058, 0.01);
  const night = sunPosition(local(2026, 12, 21, 2, 0), nyc);
  near(night.elevation, -58.398, 0.01);
  near(night.azimuth, 66.543, 0.01);
});

test('high sun is the noon prism', () => {
  const s = state(local(2026, 6, 21, 13, 0), nyc);
  assert.equal(s.phase, 'day');
  assert.deepEqual(s.triad, NOON.triad);
  near(s.glowCap, 0.9, 0.001);
});

test('deep night is the lowest stop', () => {
  const s = state(local(2026, 12, 21, 2, 0), nyc);
  assert.equal(s.phase, 'night');
  assert.deepEqual(s.triad, [[26, 35, 71], [28, 62, 80], [62, 46, 96]]);
  near(s.glowCap, 0.35, 0.001);
});

test('dawn mixes the rising ramp', () => {
  const s = state(local(2026, 6, 21, 5, 40), nyc);
  assert.equal(s.phase, 'dawn');
  near(s.elevation, 1.691, 0.01);
  assertTriad(s.triad, [[247, 143, 139], [138, 176, 227], [255, 208, 149]]);
  near(s.glowCap, 0.712, 0.001);
});

test('morning above ten degrees is day', () => {
  const s = state(local(2026, 6, 21, 7, 0), nyc);
  assert.equal(s.phase, 'day');
  assertTriad(s.triad, [[255, 117, 173], [78, 206, 228], [255, 225, 147]]);
  near(s.glowCap, 0.843, 0.001);
});

test('evening mixes the setting ramp', () => {
  const golden = state(local(2026, 6, 21, 20, 20), nyc);
  assert.equal(golden.phase, 'golden');
  assertTriad(golden.triad, [[253, 90, 63], [255, 96, 138], [119, 80, 179]]);
  near(golden.glowCap, 0.807, 0.001);

  const dusk = state(local(2026, 6, 21, 21, 10), nyc);
  assert.equal(dusk.phase, 'night');
  assertTriad(dusk.triad, [[60, 74, 141], [77, 100, 160], [179, 99, 129]]);
  near(dusk.glowCap, 0.482, 0.001);
});

test('guessed longitude follows the clock offset', () => {
  assert.deepEqual(guess(local(2026, 7, 1, 12, 0)), { lat: 40, lng: -60 });
  assert.deepEqual(guess(local(2026, 1, 1, 12, 0)), { lat: 40, lng: -75 });
  const s = state(local(2026, 3, 20, 7, 30), { lat: 40, lng: -60 });
  assert.equal(s.phase, 'day');
  assertTriad(s.triad, [[255, 118, 174], [79, 206, 228], [255, 225, 147]]);
});

test('sun sits where the original puts it', () => {
  const noon = state(local(2026, 6, 21, 13, 0), nyc);
  near(noon.sunX, 0.511, 0.001);
  near(noon.sunY, 0.221, 0.001);
  const dawn = state(local(2026, 6, 21, 5, 40), nyc);
  near(dawn.sunX, 0, 0.001);
  near(dawn.sunY, 0.884, 0.001);
  const dusk = state(local(2026, 6, 21, 21, 10), nyc);
  near(dusk.sunX, 1, 0.001);
  near(dusk.sunY, 0.9, 0.001);
});

test('lifting lightness keeps hue and clears the floor', () => {
  const lifted = withLightness([26, 35, 71], 0.72, 1);
  assert.ok(lifted[0] + lifted[1] + lifted[2] > 3 * 150, String(lifted));
  assert.ok(lifted[2] > lifted[0], `still blue: ${lifted}`);
  const pink = [255, 30, 140];
  assert.deepEqual(withLightness(pink, 0, 1), pink);
  assert.deepEqual(withLightness(pink, 0, 1, 0.1), pink);
});

test('chroma floor saturates without turning the hue', () => {
  const teal = [28, 62, 80];
  const vivid = withLightness(teal, 0.62, 1, 0.13);
  const lifted = withLightness(teal, 0.62, 1);
  const spread = (c) => Math.max(...c) - Math.min(...c);
  assert.ok(spread(vivid) > spread(lifted), `${vivid} vs ${lifted}`);
  assert.ok(vivid[0] < vivid[1] && vivid[0] < vivid[2], `still teal: ${vivid}`);
});

test('mix ends on its inputs, and a grey takes the colour\'s hue', () => {
  const a = [255, 30, 140], b = [26, 229, 229];
  assertTriad([mix(a, b, 0), mix(a, b, 1), mix(a, a, 0.5)], [a, b, a]);
  const m = mix([128, 128, 128], [255, 0, 0], 0.5);
  assert.ok(m[0] > m[1] && m[0] > m[2]);
});
