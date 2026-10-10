// A three.js port of the Mac's BoardStage (SceneKit), using the same model. Parts the Mac
// builds in code go inside a zUp() group, so the Mac's Z-up numbers work unchanged.

import * as THREE from 'three';
import { GLTFLoader } from './vendor/GLTFLoader.js';

const D = Math.PI / 180;

/** Same curve as CSS cubic-bezier(x1, y1, x2, y2). */
function bezier(x1, y1, x2, y2) {
  const sample = (a1, a2, t) => ((1 - 3 * a2 + 3 * a1) * t + (3 * a2 - 6 * a1)) * t * t + 3 * a1 * t;
  return (x) => {
    if (x <= 0 || x >= 1) return x;
    let lo = 0, hi = 1, t = x;
    for (let i = 0; i < 24; i++) {
      const v = sample(x1, x2, t);
      if (Math.abs(v - x) < 1e-5) break;
      if (v < x) lo = t; else hi = t;
      t = (lo + hi) / 2;
    }
    return sample(y1, y2, t);
  };
}
const FLIGHT = bezier(0.45, 0, 0.15, 1);
const smooth = (t) => t * t * (3 - 2 * t);
const easeIn = (t) => t * t;
const easeOut = (t) => 1 - (1 - t) * (1 - t);

// ---- Constants copied from BoardStage ----

const POSES = {
  editor: { target: [0, -0.004, -0.014], yaw: 0, pitch: 52, distance: 0.76 },
  overview: { target: [0, 0, 0.01], yaw: 0, pitch: 34, distance: 0.62 },
  popup: { target: [0, 0, 0.01], yaw: -22, pitch: 30, distance: 0.58 },
};
const XRAY_FOCUSES = new Set(['gestures', 'battery', 'radio']);
const TRAVEL = 0.004;
const BATTERY_SCALE = 1.6;
const BATTERY_HALF_HEIGHT = 0.003;
const FACE_INSET = { side: 0.0021, front: 0.0030, back: 0.0014 };
const SOLI_SCALE = 0.55;
const SOLI_CHIP_HEIGHT = 0.018 * SOLI_SCALE / 2 + 0.0012 + 0.0025 * SOLI_SCALE;
/** Cap face drawing scale (points per metre, as in the Mac's CapFace) and render scale. */
const POINTS_PER_METRE = 10000;
const FACE_RENDER_SCALE = 1.5;
const UNIT = 0.0001846 * POINTS_PER_METRE;

function zUp() {
  const g = new THREE.Group();
  g.rotation.x = -Math.PI / 2;
  return g;
}

function css(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

// ---- Materials ----

/** Patches a material to fade into the Mac's rim-lit blue x-ray glass as `xray` goes from 0 to 1. */
function xrayable(material, haze = 0.03) {
  const m = material.clone();
  m.userData.xray = { value: 0 };
  m.userData.haze = { value: haze };
  m.transparent = true;
  m.onBeforeCompile = (shader) => {
    shader.uniforms.xray = m.userData.xray;
    shader.uniforms.haze = m.userData.haze;
    shader.fragmentShader = shader.fragmentShader
      .replace('void main() {', 'uniform float xray;\nuniform float haze;\nvoid main() {')
      .replace('#include <tonemapping_fragment>', `
        float facing = abs(dot(normalize(normal), normalize(vViewPosition)));
        float rim = pow(1.0 - clamp(facing, 0.0, 1.0), 2.2);
        float glassAlpha = haze + 0.42 * rim;
        vec3 glass = vec3(0.55, 0.80, 1.0) * (0.25 + 0.9 * rim);
        // Unpremultiplied: three's blending multiplies by alpha, where
        // SceneKit's shader returned the product itself.
        gl_FragColor.rgb = mix(gl_FragColor.rgb, glass, xray);
        gl_FragColor.a = mix(gl_FragColor.a, glassAlpha, xray);
        #include <tonemapping_fragment>`);
  };
  m.customProgramCacheKey = () => 'xray';
  return m;
}

function flat(colour) {
  return new THREE.MeshBasicMaterial({ color: colour });
}

function matte(colour, roughness = 0.6) {
  return new THREE.MeshStandardMaterial({ color: colour, roughness, metalness: 0 });
}

// ---- Cap faces ----

/** Draws a cap face. The clamped texture stretches the skirt-coloured border down the cap's sides. */
function paintFace(canvas, face, { legend, selected, editable, spacebar }) {
  const w = Math.max(8, Math.round(face.width * POINTS_PER_METRE * FACE_RENDER_SCALE));
  const h = Math.max(8, Math.round(face.height * POINTS_PER_METRE * FACE_RENDER_SCALE));
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  const s = FACE_RENDER_SCALE;
  const top = css(selected ? '--selected-cap-top' : spacebar ? '--spacebar-top' : '--cap-top');
  const skirt = css(selected ? '--selected-cap-skirt' : spacebar ? '--spacebar-skirt' : '--cap-skirt');
  const ink = css(selected ? '--selected-cap-ink' : '--cap-ink');
  ctx.fillStyle = top;
  ctx.fillRect(0, 0, w, h);
  const sheen = ctx.createLinearGradient(0, 0, w, 0);
  sheen.addColorStop(0, 'rgba(255,255,255,0.22)');
  sheen.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = sheen;
  ctx.fillRect(0, 0, w, h);

  const pad = 6 * UNIT * s;
  const font = (size) => `${size}px Helvetica, Arial, sans-serif`;
  ctx.fillStyle = ink;
  ctx.textBaseline = 'top';
  if (legend?.kind === 'single') {
    ctx.font = font(26 * UNIT * s);
    ctx.fillText(legend.text, pad, pad);
  } else if (legend?.kind === 'pair') {
    const size = 25 * UNIT * s;
    ctx.font = font(size);
    ctx.fillText(legend.shifted, pad, pad);
    ctx.fillText(legend.base, pad, pad + size * 1.15 + UNIT * s);
  } else if (legend?.kind === 'word') {
    let size = 17 * UNIT * s;
    ctx.font = font(size);
    const room = w - pad * 2;
    const width = ctx.measureText(legend.text).width;
    if (width > room) {
      size *= Math.max(0.4, room / width);
      ctx.font = font(size);
    }
    ctx.fillText(legend.text, pad, pad);
  }

  ctx.strokeStyle = skirt;
  ctx.lineWidth = 3 * s;
  ctx.strokeRect(1.5 * s, 1.5 * s, w - 3 * s, h - 3 * s);
  if (!editable && !selected) {
    ctx.globalAlpha = 0.38;
    ctx.fillStyle = css('--plate');
    ctx.fillRect(0, 0, w, h);
    ctx.globalAlpha = 1;
  }
}

/** Maps the texture onto a cap's top face. v = 1 is the back of the cap (the top
 *  row of the canvas, after flipY). In the Y-up mesh, Blender's y is -z. */
function topFaceUVs(geometry) {
  const position = geometry.attributes.position;
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (let i = 0; i < position.count; i++) {
    const x = position.getX(i), y = -position.getZ(i);
    minX = Math.min(minX, x); maxX = Math.max(maxX, x);
    minY = Math.min(minY, y); maxY = Math.max(maxY, y);
  }
  const x0 = minX + FACE_INSET.side, x1 = maxX - FACE_INSET.side;
  const y0 = minY + FACE_INSET.front, y1 = maxY - FACE_INSET.back;
  if (!(x1 > x0 && y1 > y0)) return null;
  const uv = new Float32Array(position.count * 2);
  for (let i = 0; i < position.count; i++) {
    uv[i * 2] = (position.getX(i) - x0) / (x1 - x0);
    uv[i * 2 + 1] = (-position.getZ(i) - y0) / (y1 - y0);
  }
  const faced = geometry.clone();
  faced.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
  return { geometry: faced, face: { width: x1 - x0, height: y1 - y0 } };
}

// ---- Waves ----

function ribbon(points, width) {
  const vertices = [];
  const indices = [];
  points.forEach((p, i) => {
    const a = points[Math.max(0, i - 1)], b = points[Math.min(points.length - 1, i + 1)];
    const dx = b[0] - a[0], dz = b[1] - a[1];
    const length = Math.max(Math.hypot(dx, dz), 1e-9);
    const nx = -dz / length * width / 2, nz = dx / length * width / 2;
    vertices.push([p[0] + nx, 0, p[1] + nz], [p[0] - nx, 0, p[1] - nz]);
    if (i > 0) {
      const v = i * 2;
      indices.push(v - 2, v - 1, v, v - 1, v + 1, v);
    }
  });
  return { vertices, indices };
}

let domes = null;
function waveDomes() {
  if (domes) return domes;
  const steps = 60, planes = 5;
  domes = [];
  for (let step = 0; step < steps; step++) {
    const r = 0.005 + 0.05 * step / (steps - 1);
    const span = 1.1;
    const count = 24 + Math.floor(r * 1200);
    const positions = [];
    const indices = [];
    for (let plane = 0; plane < planes; plane++) {
      const phi = Math.PI * plane / planes;
      const c = Math.cos(phi), s = Math.sin(phi);
      const points = [];
      for (let k = 0; k <= count; k++) {
        const angle = -span / 2 + span * k / count;
        const wiggle = 0.0007 * Math.sin(r * angle * 1800 + plane);
        points.push([Math.cos(angle) * (r + wiggle), Math.sin(angle) * (r + wiggle)]);
      }
      const strip = ribbon(points, 0.0005);
      const base = positions.length / 3;
      for (const [x, y, z] of strip.vertices) positions.push(x, y * c - z * s, y * s + z * c);
      for (const i of strip.indices) indices.push(i + base);
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setIndex(indices);
    domes.push(geometry);
  }
  return domes;
}

export class Board3D {
  constructor() {
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'board3d';
    this.renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;

    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(30, 1, 0.005, 10);
    this.rig = new THREE.Group();
    this.rig.rotation.order = 'YXZ';
    this.sway = new THREE.Group();
    this.scene.add(this.rig);
    this.rig.add(this.sway);
    this.sway.add(this.camera);
    this.lights();

    this.board = new THREE.Group();
    this.scene.add(this.board);
    this.keys = new Map();
    this.caseMaterials = [];
    this.effects = [];
    this.tweens = new Set();
    this.focus = null;
    this.xray = 0;
    // The level can arrive before the model has loaded.
    this.gaugeLevel = null;
    this.gaugeColour = '#59db6b';
    this.gaugeLow = false;
    this.faces = new Map();
    this.ready = this.load();

    this.resizer = new ResizeObserver(() => this.resize());
    this.resizer.observe(this.canvas);
    this.raycaster = new THREE.Raycaster();
    this.loop = this.loop.bind(this);
    this.running = false;
    /** Called with { tag, position } when a cap is clicked. */
    this.onPick = null;
    let down = null;
    this.canvas.addEventListener('pointerdown', (e) => { down = [e.clientX, e.clientY]; });
    this.canvas.addEventListener('pointerup', (e) => {
      if (!down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 4) return;
      down = null;
      const hit = this.pick(e);
      if (hit && this.onPick) this.onPick(hit);
    });
  }

  lights() {
    // SceneKit intensities divided by 1000, times PI to match three.js's physical lights.
    this.scene.add(new THREE.AmbientLight(0xffffff, 0.26 * Math.PI));
    const key = new THREE.DirectionalLight(0xffffff, 0.95 * Math.PI);
    key.position.set(-0.305, 0.841, 0.446);
    key.castShadow = true;
    key.shadow.mapSize.set(2048, 2048);
    key.shadow.radius = 4;
    key.shadow.bias = -0.0004;
    key.shadow.normalBias = 0.0006;
    const extent = 0.3;
    Object.assign(key.shadow.camera, { left: -extent, right: extent, top: extent, bottom: -extent, near: -1, far: 2 });
    this.scene.add(key);
    const rim = new THREE.DirectionalLight(new THREE.Color().setRGB(0.75, 0.85, 1, THREE.SRGBColorSpace), 0.38 * Math.PI);
    rim.position.set(0.475, 0.389, -0.789);
    this.scene.add(rim);
  }

  async load() {
    const loader = new GLTFLoader();
    const gltf = await loader.loadAsync('models/M0110.glb');
    const root = gltf.scene.getObjectByName('M0110');
    let top = root;
    while (top.parent && top.parent !== gltf.scene) top = top.parent;
    this.board.add(top);
    top.updateMatrixWorld(true);
    const box = new THREE.Box3().setFromObject(top);
    const centre = box.getCenter(new THREE.Vector3());
    top.position.sub(centre);
    this.root = root;
    this.board.updateMatrixWorld(true);
    this.collect(root);
    this.board.updateMatrixWorld(true);
    // Must load before the first focus, because the Gestures stage uses the hand.
    await this.loadHand();
  }

  async loadHand() {
    try {
      const gltf = await new GLTFLoader().loadAsync('models/Hand.glb');
      const skin = new THREE.MeshStandardMaterial({
        color: new THREE.Color().setRGB(0.86, 0.78, 0.72, THREE.SRGBColorSpace), roughness: 0.55,
      });
      this.handParts = {};
      for (const name of ['Hand', 'Thumb']) {
        const mesh = gltf.scene.getObjectByName(name);
        if (!mesh) continue;
        mesh.traverse((o) => { if (o.isMesh) { o.material = skin; o.renderOrder = 50; } });
        this.handParts[name] = mesh;
      }
      this.handScene = gltf.scene;
    } catch {
      this.handScene = null;
    }
  }

  byName(name) {
    return this.root.getObjectByName(name);
  }

  collect(root) {
    const shellMaterials = new Map();
    for (const name of ['Upper', 'Lower']) {
      const shell = this.byName(name);
      if (!shell) continue;
      // Skip the keys and switches, which are also children of Upper.
      const meshes = shell.isMesh ? [shell] : shell.children.filter((c) => c.isMesh && !c.name.startsWith('Key_'));
      for (const mesh of meshes) {
        mesh.material = (Array.isArray(mesh.material) ? mesh.material : [mesh.material]).map((m) => {
          if (!shellMaterials.has(m.uuid)) {
            const glass = xrayable(m);
            shellMaterials.set(m.uuid, glass);
            this.caseMaterials.push(glass);
          }
          return shellMaterials.get(m.uuid);
        });
        if (mesh.material.length === 1) mesh.material = mesh.material[0];
        mesh.renderOrder = 10;
      }
    }

    root.traverse((node) => {
      if (node.isMesh) { node.castShadow = true; node.receiveShadow = true; }
    });

    root.traverse((node) => {
      if (!node.name.startsWith('Key_')) return;
      // A cap is a mesh named Key_<tag> or a group of them, so skip meshes inside the group.
      if (node.parent?.name === node.name) return;
      const tag = node.name.slice(4);
      const mesh = node.isMesh ? node : node.children.find((c) => c.isMesh);
      let face = null;
      if (mesh) {
        const faced = topFaceUVs(mesh.geometry);
        const material = (Array.isArray(mesh.material) ? mesh.material[0] : mesh.material).clone();
        material.color.set(0xffffff);
        if (faced) {
          mesh.geometry = faced.geometry;
          face = faced.face;
          // Paint at full size before the first upload. WebGL cannot resize a texture in place.
          const canvas = document.createElement('canvas');
          paintFace(canvas, faced.face, { legend: null, selected: false, editable: true,
                                          spacebar: tag === '71_0' });
          const texture = new THREE.CanvasTexture(canvas);
          texture.colorSpace = THREE.SRGBColorSpace;
          texture.wrapS = texture.wrapT = THREE.ClampToEdgeWrapping;
          texture.anisotropy = 4;
          material.map = texture;
          this.faces.set(tag, { canvas, texture, face, key: '' });
        }
        mesh.material = material;
        mesh.renderOrder = 10;
      }
      const stem = this.byName(`Stem_${tag}`);
      const sw = this.byName(`Switch_${tag}`);
      let down = new THREE.Vector3(0, -1, 0);
      if (sw && sw.parent === node.parent) {
        const d = sw.position.clone().sub(node.position);
        if (d.lengthSq() > 0) down = d.normalize();
      }
      this.keys.set(tag, {
        cap: node, stem, down,
        rest: node.position.clone(), stemRest: stem?.position.clone(),
        position: tag === 'x_0' ? -1 : Number(tag.split('_')[0]),
      });
    });

    this.battery = this.byName('Battery');
    if (this.battery) {
      const up = new THREE.Vector3(0, 1, 0).applyQuaternion(this.battery.quaternion);
      this.battery.position.addScaledVector(up, BATTERY_HALF_HEIGHT * (BATTERY_SCALE - 1));
      this.battery.scale.multiplyScalar(BATTERY_SCALE);
      this.buildGauge();
    }
    this.nano = this.byName('NiceNano');
    this.buildSoli(root);
    const plate = this.byName('Plate');
    const plateMesh = plate?.isMesh ? plate : plate?.children.find((c) => c.isMesh);
    if (plateMesh) {
      plateMesh.material = plateMesh.material.clone();
      this.plateMaterial = plateMesh.material;
    }
    this.upper = this.byName('Upper');
    this.upperRest = this.upper?.position.clone();
    this.applyPalette();
  }

  applyPalette() {
    const shell = new THREE.Color(css('--case-flat'));
    for (const m of this.caseMaterials) m.color.copy(shell);
    if (this.plateMaterial) this.plateMaterial.color.set(css('--plate'));
  }

  // ---- Battery gauge ----

  buildGauge() {
    const holder = zUp();
    this.battery.add(holder);
    const count = 10, pitch = 0.0042, width = 0.0034;
    const track = new THREE.Mesh(new THREE.BoxGeometry(count * pitch + 0.002, 0.014, 0.0004), flat(0x141414));
    track.position.set(0, 0, 0.0032);
    holder.add(track);
    this.gauge = [];
    for (let i = 0; i < count; i++) {
      const segment = new THREE.Mesh(new THREE.BoxGeometry(width, 0.011, 0.0006), flat(0x000000));
      segment.position.set((i - (count - 1) / 2) * pitch, 0, 0.0035);
      holder.add(segment);
      this.gauge.push(segment);
    }
    this.showGauge(false);
  }

  setBattery(level, low, rearm) {
    const colour = (level ?? 100) <= low ? '#ed4d42' : (level ?? 100) <= rearm ? '#f5b338' : '#59db6b';
    const isLow = level != null && level <= low;
    if (level === this.gaugeLevel && colour === this.gaugeColour && isLow === this.gaugeLow) return;
    this.gaugeLevel = level;
    this.gaugeColour = colour;
    this.gaugeLow = isLow;
    if (this.gauge) this.showGauge(false);
  }

  showGauge(animated) {
    if (!this.gauge) return;
    const lit = this.gaugeLevel == null ? 0 : Math.ceil(this.gaugeLevel / 10);
    const start = performance.now();
    this.gaugeAnimation = animated ? { start, lit } : null;
    this.gauge.forEach((segment, i) => {
      segment.material.color.set(!animated && i < lit ? this.gaugeColour : '#292929');
    });
    this.wake();
  }

  tickGauge(now) {
    const a = this.gaugeAnimation;
    if (!a || !this.gauge) return;
    const t = (now - a.start) / 1000;
    this.gauge.forEach((segment, i) => {
      let on = i < a.lit && t >= 0.5 + i * 0.09;
      if (on && this.gaugeLow && i === a.lit - 1) {
        const since = t - (0.5 + i * 0.09);
        on = Math.floor(since / 0.5) % 2 === 0;
      }
      segment.material.color.set(on ? this.gaugeColour : '#292929');
    });
  }

  // ---- Soli ----

  buildSoli(root) {
    const space = zUp();
    root.add(space);
    const wall = 0.1495, thickness = 0.0012, side = 0.018;
    const node = new THREE.Group();
    node.position.set(wall - thickness / 2, 0, 0.0128);
    node.rotation.x = -11.508 * D;
    space.add(node);
    const board = new THREE.Group();
    board.scale.set(1, SOLI_SCALE, SOLI_SCALE);
    board.position.set(0, 0, side * SOLI_SCALE / 2 + 0.0012);
    node.add(board);
    const face = -thickness / 2;
    const part = (w, h, d, y, z, material) => {
      const mesh = new THREE.Mesh(new THREE.BoxGeometry(d, w, h), material);
      mesh.position.set(face - d / 2, y, z);
      board.add(mesh);
    };
    const pcb = new THREE.Mesh(new THREE.BoxGeometry(thickness, side, side), matte(new THREE.Color().setRGB(0.05, 0.07, 0.08, THREE.SRGBColorSpace)));
    board.add(pcb);
    const gold = new THREE.MeshStandardMaterial({ color: new THREE.Color().setRGB(0.95, 0.74, 0.36, THREE.SRGBColorSpace), metalness: 0.95, roughness: 0.25 });
    const mold = new THREE.MeshStandardMaterial({ color: 0x0a0a0a, roughness: 0.45 });
    const ceramic = matte(new THREE.Color().setRGB(0.62, 0.52, 0.40, THREE.SRGBColorSpace));
    const silver = new THREE.MeshStandardMaterial({ color: 0xcccccc, metalness: 1, roughness: 0.3 });
    part(0.0065, 0.005, 0.0009, 0, 0.0025, mold);
    for (const [py, pz] of [[-0.0018, 0.0038], [0, 0.0038], [0.0018, 0.0038], [0.0018, 0.002]]) {
      const pad = new THREE.Mesh(new THREE.BoxGeometry(0.0001, 0.0012, 0.0012), gold);
      pad.position.set(face - 0.00095, py, pz);
      board.add(pad);
    }
    part(0.0005, 0.0005, 0.0001, -0.0027, 0.0006, gold);
    for (const [py, pz] of [[-0.0055, 0.002], [-0.0055, 0.0035], [0.0055, 0.002], [0.0055, 0.0035],
                            [-0.0045, -0.001], [0.0045, -0.001]]) part(0.001, 0.0005, 0.0005, py, pz, ceramic);
    part(0.0032, 0.0025, 0.0008, -0.004, -0.0045, silver);
    part(0.0028, 0.0028, 0.0008, 0.0035, -0.0045, mold);
    for (let i = 0; i < 8; i++) part(0.0009, 0.0014, 0.00005, -0.0063 + i * 0.0018, -0.0078, gold);
    part(0.012, 0.0028, 0.0022, 0, -0.0068, matte(0xebebeb));
    this.soli = node;
  }

  scan() {
    if (!this.soli) return;
    const stage = new THREE.Group();
    this.soli.add(stage);
    this.effects.push(stage);
    const fan = new THREE.Group();
    fan.position.set(0, 0, SOLI_CHIP_HEIGHT);
    stage.add(fan);
    const shapes = waveDomes();
    const glow = () => new THREE.MeshBasicMaterial({
      color: new THREE.Color().setRGB(0.52, 0.80, 1, THREE.SRGBColorSpace), transparent: true,
      blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide,
    });
    const count = 8;
    const meshes = [];
    for (let i = 0; i < count; i++) {
      const dome = new THREE.Mesh(shapes[0], glow());
      dome.renderOrder = 40;
      fan.add(dome);
      meshes.push(dome);
    }
    const period = 3.2;
    const start = performance.now();
    // Frame times can be a little earlier than `start`, so wrap phases into 0 to 1.
    const phase = (x) => ((x % 1) + 1) % 1;
    this.waves = (now) => {
      const t = phase((now - start) / 1000 / period);
      meshes.forEach((dome, i) => {
        const u = phase(i / count + t);
        dome.geometry = shapes[Math.min(shapes.length - 1, Math.floor(u * shapes.length))];
        dome.material.opacity = Math.min(1, u * 10) * (1 - u) * 0.75;
      });
    };
    if (this.handScene) {
      const hand = new THREE.Group();
      // Same rotation as the HandModel node in the Mac's USDZ.
      const model = new THREE.Group();
      model.rotation.x = Math.PI / 2;
      hand.add(model);
      for (const part of Object.values(this.handParts)) model.add(part.clone());
      hand.position.set(0.08, -0.006, 0.016);
      hand.quaternion.setFromAxisAngle(new THREE.Vector3(0, 1, 0), -Math.PI / 2)
        .multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), -Math.PI / 2));
      hand.scale.setScalar(0.62);
      stage.add(hand);
      const thumb = model.getObjectByName('Thumb');
      if (thumb) {
        // Pivot at the first knuckle so the thumb tip slides along the index finger.
        const pivot = new THREE.Group();
        pivot.position.set(-0.017, -0.039, -0.012);
        thumb.position.set(0.017, 0.039, 0.012);
        model.add(pivot);
        pivot.add(thumb);
        this.thumb = (now) => {
          const t = phase((now - start) / 1000 / 0.72) * 0.72;
          const swing = t < 0.3 ? smooth(t / 0.3) : t < 0.6 ? 1 - smooth((t - 0.3) / 0.3) : 0;
          pivot.rotation.y = 0.16 * swing;
        };
      }
    }
  }

  radiate() {
    if (!this.nano) return;
    const origin = this.nano.getWorldPosition(new THREE.Vector3());
    const rings = [];
    for (let i = 0; i < 3; i++) {
      const ring = new THREE.Mesh(new THREE.TorusGeometry(0.012, 0.0005, 8, 64), new THREE.MeshBasicMaterial({
        color: new THREE.Color().setRGB(0.45, 0.75, 1, THREE.SRGBColorSpace), transparent: true, depthWrite: false,
      }));
      ring.rotation.x = Math.PI / 2;
      ring.position.set(origin.x, origin.y + 0.004, origin.z);
      ring.renderOrder = 20;
      ring.material.opacity = 0;
      this.scene.add(ring);
      this.effects.push(ring);
      rings.push(ring);
    }
    const period = 2.1;
    const start = performance.now();
    this.rings = (now) => {
      rings.forEach((ring, i) => {
        const elapsed = (now - start) / 1000 - i * period / 3;
        if (elapsed < 0) return;
        const t = (elapsed % period) / period;
        ring.scale.setScalar(0.3 + 3.2 * t);
        ring.material.opacity = (1 - t) * Math.min(1, t * 6);
      });
    };
  }

  // ---- Focus ----

  pose(focus) {
    const world = (node, lift = 0) => {
      const p = node ? node.getWorldPosition(new THREE.Vector3()) : new THREE.Vector3();
      p.y += lift;
      return p;
    };
    switch (focus) {
      case 'gestures': {
        const centre = world(this.soli, 0.012);
        centre.x += 0.045;
        return { target: centre, yaw: -38.7, pitch: 25.3, distance: 0.27 };
      }
      case 'battery': return { target: world(this.battery), yaw: -22, pitch: 36, distance: 0.30 };
      case 'radio': return { target: world(this.nano), yaw: 26, pitch: 38, distance: 0.21 };
      default: {
        const p = POSES[focus] ?? POSES.editor;
        return { ...p, target: new THREE.Vector3(...p.target) };
      }
    }
  }

  currentPose() {
    return { target: this.rig.position.clone(), yaw: this.rig.rotation.y / D, pitch: -this.rig.rotation.x / D,
             distance: this.camera.position.z };
  }

  applyPose(p) {
    this.rig.position.copy(p.target);
    this.rig.rotation.set(-p.pitch * D, p.yaw * D, 0, 'YXZ');
    this.camera.position.set(0, 0, p.distance);
  }

  async setFocus(focus, animated = true) {
    await this.ready;
    if (focus === this.focus) return;
    const first = this.focus == null;
    this.focus = focus;
    this.resetEffects();
    const from = this.currentPose();
    const to = this.pose(focus);
    const exploded = XRAY_FOCUSES.has(focus);
    // Lift the case top up and back, out of the camera's way.
    const upperFrom = this.upper?.position.clone();
    let upperTo = this.upperRest;
    if (this.upper && exploded) {
      this.upper.position.copy(this.upperRest);
      this.upper.updateMatrixWorld(true);
      const world = this.upper.getWorldPosition(new THREE.Vector3()).add(new THREE.Vector3(0, 0.16, -0.15));
      upperTo = this.upper.parent.worldToLocal(world);
      this.upper.position.copy(upperFrom);
    }
    const fly = animated && !first;
    this.tween(fly ? 1.15 : 0, (t) => {
      const e = FLIGHT(t);
      this.applyPose({
        target: from.target.clone().lerp(to.target, e),
        yaw: from.yaw + (to.yaw - from.yaw) * e,
        pitch: from.pitch + (to.pitch - from.pitch) * e,
        distance: from.distance + (to.distance - from.distance) * e,
      });
      if (this.upper && upperFrom) this.upper.position.lerpVectors(upperFrom, upperTo, e);
    });
    // Turn to glass right away, but turn solid only after the camera has mostly pulled out.
    const target = exploded ? 1 : 0;
    const solidifying = target < this.xray;
    const xFrom = this.xray;
    this.tween(fly ? (solidifying ? 0.28 : 0.7) : 0, (t) => this.setXray(xFrom + (target - xFrom) * smooth(t)),
               fly && solidifying ? 0.6 : 0);
    const settle = fly ? 0.9 : 0.2;
    if (focus === 'editor' || focus === 'overview') this.typeName(settle);
    else if (focus === 'battery') this.showGauge(true);
    else if (focus === 'radio') this.radiate();
    else if (focus === 'gestures') this.scan();
  }

  setXray(value) {
    this.xray = value;
    for (const m of this.caseMaterials) {
      m.userData.xray.value = value;
      m.depthWrite = value < 0.01;
    }
  }

  resetEffects() {
    for (const key of this.keys.values()) {
      key.cap.position.copy(key.rest);
      if (key.stem && key.stemRest) key.stem.position.copy(key.stemRest);
    }
    for (const t of this.tweens) if (t.tag === 'key') this.tweens.delete(t);
    for (const node of this.effects) node.removeFromParent();
    this.effects = [];
    this.waves = this.rings = this.thumb = null;
    if (this.gauge) this.showGauge(false);
  }

  // ---- Keys ----

  /** Times are in seconds. */
  press(tag, { delay = 0, down = 0.07, up = 0.18 } = {}) {
    const key = this.keys.get(tag);
    if (!key) return;
    const offset = key.down.clone().multiplyScalar(TRAVEL);
    this.tween(down + up, (t) => {
      const elapsed = t * (down + up);
      const depth = elapsed < down ? easeIn(elapsed / down) : 1 - easeOut((elapsed - down) / up);
      key.cap.position.copy(key.rest).addScaledVector(offset, depth);
      if (key.stem && key.stemRest) key.stem.position.copy(key.stemRest).addScaledVector(offset, depth);
    }, delay, 'key');
  }

  typeName(after) {
    ['60_0', '10_0', '1_0', '1_0', '10_0'].forEach((tag, n) => {
      this.press(tag, { delay: after + n * 0.24, down: 0.06, up: 0.14 });
    });
  }

  /** `slots` is keyed by position, or null for blank caps. Keys that cannot be rebound are dimmed. */
  async paint(slots, selected, canEdit, spacebarPosition = 71) {
    await this.ready;
    this.applyPalette();
    for (const [tag, entry] of this.faces) {
      const key = this.keys.get(tag);
      const position = key?.position;
      const slot = slots?.[String(position)];
      const state = {
        legend: slots ? slot?.legend : null,
        selected: slots != null && position === selected,
        editable: slots == null || (canEdit && !!slot?.editable),
        spacebar: position === spacebarPosition,
      };
      const id = JSON.stringify(state) + css('--cap-top');
      if (id === entry.key) continue;
      entry.key = id;
      const size = `${entry.canvas.width}x${entry.canvas.height}`;
      paintFace(entry.canvas, entry.face, state);
      if (`${entry.canvas.width}x${entry.canvas.height}` !== size) entry.texture.dispose();
      entry.texture.needsUpdate = true;
    }
    this.wake();
  }

  pick(event) {
    const box = this.canvas.getBoundingClientRect();
    const pointer = new THREE.Vector2(((event.clientX - box.left) / box.width) * 2 - 1,
                                      -((event.clientY - box.top) / box.height) * 2 + 1);
    this.raycaster.setFromCamera(pointer, this.camera);
    for (const hit of this.raycaster.intersectObject(this.board, true)) {
      let node = hit.object;
      while (node && !node.name.startsWith('Key_')) node = node.parent;
      if (node) {
        const tag = node.name.slice(4);
        return { tag, position: this.keys.get(tag)?.position ?? null };
      }
    }
    return null;
  }

  // ---- Running ----

  tween(duration, step, delay = 0, tag = '') {
    const t = { start: performance.now() + delay * 1000, duration: duration * 1000, step, tag };
    if (duration <= 0 && delay <= 0) { step(1); this.wake(); return; }
    this.tweens.add(t);
    this.wake();
  }

  resize() {
    const box = this.canvas.getBoundingClientRect();
    if (box.width < 2 || box.height < 2) return;
    this.renderer.setSize(box.width, box.height, false);
    this.camera.aspect = box.width / box.height;
    // SceneKit's field of view is horizontal (34 degrees). three.js's is vertical.
    this.camera.fov = 2 * Math.atan(Math.tan(17 * D) / this.camera.aspect) / D;
    this.camera.updateProjectionMatrix();
    this.wake();
  }

  wake() {
    if (this.running || !this.canvas.isConnected) return;
    this.running = true;
    requestAnimationFrame(this.loop);
  }

  /** True while something animates. When false, the loop draws once and stops until wake(). */
  get busy() {
    const gauge = this.gaugeAnimation && performance.now() - this.gaugeAnimation.start < 2000;
    return this.tweens.size > 0 || !!this.waves || !!this.rings || !!this.thumb || !!gauge
      || (this.gaugeAnimation && this.gaugeLow);
  }

  loop(now) {
    if (!this.canvas.isConnected) { this.running = false; return; }
    for (const t of [...this.tweens]) {
      if (now < t.start) continue;
      const p = t.duration > 0 ? Math.min(1, (now - t.start) / t.duration) : 1;
      t.step(p);
      if (p >= 1) this.tweens.delete(t);
    }
    this.tickGauge(now);
    this.waves?.(now);
    this.rings?.(now);
    this.thumb?.(now);
    this.renderer.render(this.scene, this.camera);
    if (this.busy) requestAnimationFrame(this.loop);
    else this.running = false;
  }
}
