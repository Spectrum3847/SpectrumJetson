// Chapter 05: the Jetson Orin Nano Super. Loaded as an ES module (three.js).
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/OrbitControls.js';
import { GLTFLoader } from 'three/addons/GLTFLoader.js';
import { RoomEnvironment } from 'three/addons/RoomEnvironment.js';
import { toCreasedNormals } from 'three/addons/BufferGeometryUtils.js';
import { MeshoptDecoder } from 'three/addons/meshopt_decoder.module.js';

Object.assign(Site.glossary, {
  'SO-DIMM': 'Small Outline DIMM: the slim slot laptops use for memory sticks. The Jetson module uses the same 260-pin shape.',
  'carrier board': 'The bigger board a computer module plugs into. It supplies power and turns the module\'s signals into real ports.',
  'M.2': 'A small slot for cards like SSDs and Wi-Fi. "Key M" slots carry PCIe for SSDs; "Key E" slots are for wireless cards.',
  'TOPS': 'Trillions of operations per second: a rough measure of how much AI math a chip can do.',
  'Tensor Core': 'A special unit inside an NVIDIA GPU that multiplies small grids of numbers very fast. Neural networks are mostly that.',
  'LPDDR5': 'Low-Power DDR5: a kind of fast memory built for phones and small computers.',
});

Site.chapter('jetson', (root) => {
  explodedView(root);
  busDiagram(root);
  thermalLab(root);
  compareCores(root);
  // tegrastats readout: hovering a field or its card lights both up
  const tg = root.querySelector('#j-tegra');
  const lite = (f) => tg.querySelectorAll('[data-f]').forEach((e) => e.classList.toggle('on', e.dataset.f === f));
  tg.addEventListener('mouseover', (e) => { const t = e.target.closest('[data-f]'); lite(t ? t.dataset.f : null); });
  tg.addEventListener('mouseleave', () => lite(null));
  tg.addEventListener('click', (e) => { const t = e.target.closest('[data-f]'); lite(t ? t.dataset.f : null); });
});

/* ═══════════════ 3D exploded view ═══════════════ */

// Materials by node name: [color (sRGB), metalness, roughness].
const STEEL = [0xa8adb4, 1, .33];
const MATS = {
  base: [0x1e1e23, 0, .7], standoffs: [0xb89a5e, .9, .35], pcb: [0x0f2219, .05, .68],
  carrier_parts: [0x2c2e34, .2, .6], module: [0x2b2e34, .1, .5], module_screws: [0xcfd3d8, 1, .3],
  heatsink: [0x202227, .7, .42], fan: [0x131315, .05, .55],
  usb_a1: STEEL, usb_a2: STEEL, ethernet: STEEL, usb_c: STEEL, displayport: STEEL,
  dc_jack: [0x18181b, .1, .5], csi: [0xd9d2bd, 0, .55], header40: [0x1a1a1d, .2, .45],
  sodimm: [0x141417, .05, .5], m2_key_m: [0x17171a, .05, .5], m2_key_e: [0x17171a, .05, .5],
  ssd: [0x25324f, .2, .45], wifi: [0xb3b7bd, .9, .34], antennas: [0x34343a, .1, .5],
};

// Clickable labels. Each covers one or more nodes.
const HOTS = [
  ['fan', 'Fan', ['fan'], 'Pulls air through the heatsink. On NVIDIA\'s quiet profile it turned at 775 rpm on our bench (43 °C). Full speed is about 5,600 rpm. Settings › Robot state › Cooling picks quiet, full or no fan; ours is sealed under a plate, so it\'s on No fan.'],
  ['heatsink', 'Heatsink', ['heatsink'], 'Metal fins spread the chip\'s heat into the air. A leaf spring presses it onto the module.'],
  ['module', 'Orin Nano module', ['module', 'module_screws'], 'The computer itself, 69.6 × 45 mm: the SoC (CPU, GPU, engines) and 8 GB of LPDDR5.'],
  ['sodimm', 'SO-DIMM socket', ['sodimm'], '260 pins, the shape laptops use for RAM. Power, PCIe, USB, Ethernet and camera signals all pass through it.'],
  ['pcb', 'Carrier board', ['pcb', 'carrier_parts'], 'NVIDIA\'s P3768: power regulators, the USB hub chip and all the connectors.'],
  ['usb', '4× USB-A', ['usb_a1', 'usb_a2'], 'Two stacked pairs of USB 3.2 ports (10 Gbps). Our cameras plug in here, through one hub.'],
  ['ethernet', 'Ethernet', ['ethernet'], 'Gigabit Ethernet to the robot. Static IP 10.85.15.15.'],
  ['usb_c', 'USB-C', ['usb_c'], 'Data only (no power in). Used to flash and back up the Jetson from a laptop.'],
  ['displayport', 'DisplayPort', ['displayport'], 'The only video output. On the robot the Jetson runs headless: no screen.'],
  ['dc_jack', 'DC jack', ['dc_jack'], 'Power in (5.5 × 2.5 mm barrel). Ours gets a steady 15 V from a boost regulator.'],
  ['csi', '2× CSI camera', ['csi'], 'MIPI CSI-2 connectors for ribbon-cable cameras. Empty on our robot: we use USB cameras.'],
  ['header40', '40-pin header', ['header40'], 'General-purpose I/O pins (GPIO, I²C, SPI, UART), laid out like a Raspberry Pi\'s.'],
  ['ssd', 'NVMe SSD', ['ssd'], 'Linux boots from here. Ours holds 256 GB. No SD card needed.'],
  ['m2', 'M.2 Key M slots', ['m2_key_m'], 'One 2280 slot (PCIe x4, our SSD) and one 2230 slot (PCIe x2, empty).'],
  ['wifi', 'Wi-Fi + Bluetooth', ['wifi', 'm2_key_e'], 'An M.2 Key E card. Wi-Fi uses PCIe; its Bluetooth sits on the shared USB 2.0 bus.'],
  ['antennas', 'Antennas', ['antennas'], 'Two flat antennas for the Wi-Fi card, stuck under the stand.'],
  ['base', 'Stand', ['base', 'standoffs'], 'A plastic stand and metal standoffs hold the carrier board up.'],
];
const HOT = Object.fromEntries(HOTS.map(([id, name, nodes, txt]) => [id, { id, name, nodes, txt }]));
const TOP_ANCHOR = new Set(['fan', 'heatsink', 'module', 'usb', 'ethernet', 'header40', 'displayport', 'dc_jack']);

// Scroll steps: highlighted labels, explode state, camera (degrees, meters).
const HEAT = { heat: .085, mod: .04 };
const UNDER = { heat: .012, mod: .006, under: 1 };
const STEPS = [
  { hl: [], ex: {}, az: 34, el: 30, d: .23, info: ['The whole kit', 'Scroll to take it apart.'] },
  { hl: ['heatsink', 'fan'], ex: { heat: .05 }, az: 22, el: 22, d: .26 },
  { hl: ['module'], ex: HEAT, az: 36, el: 24, d: .34 },
  { hl: ['sodimm'], ex: HEAT, az: 14, el: 46, d: .24 },
  { hl: ['pcb'], ex: HEAT, az: -32, el: 38, d: .27 },
  { hl: ['usb', 'ethernet', 'usb_c', 'displayport', 'dc_jack'], ex: {}, az: 12, el: 16, d: .19 },
  { hl: ['csi', 'header40'], ex: {}, az: -14, el: 52, d: .21 },
  { hl: ['ssd', 'm2'], ex: UNDER, az: 28, el: -28, d: .25 },
  { hl: ['wifi', 'antennas'], ex: UNDER, az: -24, el: -32, d: .25 },
  { hl: [], ex: {}, az: 214, el: 30, d: .23, info: ['Back together', 'Press 🖐 Explore to turn it yourself.'] },
];
const GROUP_OF = { heatsink: 'heat', fan: 'heat', module: 'mod', module_screws: 'mod' };
function offsetFor(name, ex) {
  if (GROUP_OF[name] === 'heat') return ex.heat || 0;
  if (name === 'module_screws') return (ex.mod || 0) * 1.35;
  if (GROUP_OF[name] === 'mod') return ex.mod || 0;
  if (ex.under) return { ssd: -.024, wifi: -.024, antennas: -.04, base: -.062, standoffs: -.05 }[name] || 0;
  return 0;
}

function webgl() {
  try { const c = document.createElement('canvas'); return !!(c.getContext('webgl2') || c.getContext('webgl')); } catch { return false; }
}

function explodedView(root) {
  const stage = root.querySelector('#j-stage'), cv = root.querySelector('#j-cv');
  const load = root.querySelector('#j-load'), info = root.querySelector('#j-info');
  const labels = root.querySelector('#j-labels'), hint = root.querySelector('#j-hint');
  const freeBtn = root.querySelector('#j-free');
  let step = 0, free = false, selected = null;

  const setInfo = (title, txt) => { info.innerHTML = `<b>${title}</b><span>${txt}</span>`; };
  const stepInfo = () => {
    const s = STEPS[step];
    if (selected) return setInfo(HOT[selected].name, HOT[selected].txt);
    if (s.info) return setInfo(...s.info);
    const h = HOT[s.hl[0]];
    setInfo(s.hl.length > 1 && s.hl[0] === 'usb' ? 'Ports' : h.name, s.hl.length > 1 && s.hl[0] === 'usb' ? 'USB-A, Ethernet, USB-C, DisplayPort and power, all along the front edge.' : h.txt);
  };

  if (!webgl()) {
    load.innerHTML = '<div><b>3D needs WebGL</b>Your browser has WebGL switched off, so here is the real board instead.<img src="assets/photos/bench-setup.jpg" alt="The Jetson devkit on a desk" style="margin:12px auto 0;max-height:60%;border-radius:10px;object-fit:cover;object-position:20% 85%;aspect-ratio:4/3;width:80%"></div>';
    Site.scrolly(root.querySelector('#j-scrolly'), (i) => { step = i; stepInfo(); });
    freeBtn.disabled = true;
    return;
  }

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas: cv, antialias: true, alpha: true, powerPreference: 'high-performance' });
  } catch (e) {
    load.innerHTML = '<div><b>3D couldn\'t start</b>WebGL failed to start in this browser.</div>';
    return;
  }
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.25;

  const scene = new THREE.Scene();
  const pmrem = new THREE.PMREMGenerator(renderer);
  // set per material (not scene.environment) so envMapIntensity can fade dimmed parts
  const envTex = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  const key = new THREE.DirectionalLight(0xffffff, 2.2); key.position.set(.3, .6, .4); scene.add(key);
  const rim = new THREE.DirectionalLight(0xc4b5fd, 1.1); rim.position.set(-.5, .2, -.5); scene.add(rim);
  scene.add(new THREE.HemisphereLight(0xf4efff, 0x1a0a2b, .5));

  const camera = new THREE.PerspectiveCamera(32, 1, 0.005, 5);
  const controls = new OrbitControls(camera, cv);
  controls.enabled = false; controls.enableDamping = true; controls.dampingFactor = .08;
  controls.minDistance = .08; controls.maxDistance = .6; controls.enablePan = true;

  // Soft shadow under the model.
  const sh = document.createElement('canvas'); sh.width = sh.height = 128;
  const sx = sh.getContext('2d'), g = sx.createRadialGradient(64, 64, 4, 64, 64, 64);
  g.addColorStop(0, 'rgba(0,0,0,.55)'); g.addColorStop(1, 'rgba(0,0,0,0)');
  sx.fillStyle = g; sx.fillRect(0, 0, 128, 128);
  const shadow = new THREE.Mesh(new THREE.PlaneGeometry(.2, .16), new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(sh), transparent: true, depthWrite: false }));
  shadow.rotation.x = -Math.PI / 2; scene.add(shadow);

  const parts = {}; // name -> { mesh, mat, base color, off, dim, glow (current + target) }
  const hotEls = {};
  const cam = { az: 34, el: 30, d: .27, t: new THREE.Vector3() }, camT = { az: 34, el: 30, d: .27, t: new THREE.Vector3() };
  let ready = false, dirty = true, narrow = false;
  const accent = new THREE.Color(0x8b5cf6), ACC2 = new THREE.Color(0xc4b5fd), DIM = new THREE.Color(0x1a0f28);

  // Labels
  for (const h of HOTS) {
    const b = document.createElement('button');
    b.className = 'j-hot hide';
    b.innerHTML = `<i>${HOTS.indexOf(h) + 1}</i><span>${h[1]}</span>`;
    b.setAttribute('aria-label', h[1]);
    b.onclick = () => select(selected === h[0] ? null : h[0]);
    labels.appendChild(b);
    hotEls[h[0]] = b;
  }

  function select(id) {
    selected = id;
    applyStep();
  }

  function applyStep() {
    const s = STEPS[step];
    const hl = selected ? [selected] : s.hl;
    const hlNodes = new Set(hl.flatMap((id) => HOT[id].nodes));
    // in free mode, open the kit up enough to see the part you picked
    const ex = !(free && selected) ? s.ex
      : ['ssd', 'm2', 'wifi', 'antennas', 'base'].includes(selected) ? UNDER
      : ['module', 'sodimm', 'pcb'].includes(selected) ? HEAT
      : ['heatsink', 'fan'].includes(selected) ? { heat: .05 } : s.ex;
    for (const [name, p] of Object.entries(parts)) {
      p.offT = offsetFor(name, ex);
      p.glowT = hlNodes.has(name) ? 1 : 0;
      p.dimT = hlNodes.size && !hlNodes.has(name) ? 1 : 0;
    }
    if (!free) { camT.az = s.az; camT.el = s.el; camT.d = s.d; }
    for (const [id, el] of Object.entries(hotEls)) {
      const show = free || hl.includes(id);
      el.classList.toggle('hide', !show);
      el.classList.toggle('on', hl.includes(id) && (free ? !!selected : true));
    }
    stepInfo();
    dirty = true;
  }

  // Scroll steps
  Site.scrolly(root.querySelector('#j-scrolly'), (i) => {
    step = i;
    if (!free) selected = null;
    if (ready) applyStep(); else stepInfo();
  });

  // Free-orbit mode
  freeBtn.onclick = () => {
    free = !free;
    freeBtn.classList.toggle('primary', free);
    freeBtn.setAttribute('aria-pressed', free);
    freeBtn.textContent = free ? '↺ Back to tour' : '🖐 Explore';
    stage.classList.toggle('free', free);
    controls.enabled = free;
    hint.textContent = '';
    root.querySelector('#j-do').innerHTML = free ? '<b>Drag</b> to turn · <b>pinch or scroll</b> to zoom · <b>tap a label or part</b> · ↺ Back to tour' : '<b>Scroll</b> to take it apart. Press <b>🖐 Explore</b> to turn it yourself and tap parts.';
    if (free) {
      controls.target.copy(cam.t);
      controls.update();
    } else {
      // continue the tour camera smoothly from wherever the user left it
      const v = camera.position.clone().sub(controls.target);
      cam.d = v.length(); cam.el = THREE.MathUtils.radToDeg(Math.asin(v.y / cam.d));
      cam.az = THREE.MathUtils.radToDeg(Math.atan2(v.x, v.z));
      const s = STEPS[step]; while (cam.az - s.az > 180) cam.az -= 360; while (s.az - cam.az > 180) cam.az += 360;
      cam.t.copy(controls.target);
      selected = null;
    }
    applyStep();
  };
  controls.addEventListener('change', () => (dirty = true));

  // Click a part in the 3D view
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
  let down = null;
  cv.addEventListener('pointerdown', (e) => (down = [e.clientX, e.clientY]));
  cv.addEventListener('pointerup', (e) => {
    if (!ready || !down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 5) return;
    const r = cv.getBoundingClientRect();
    ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const hit = ray.intersectObjects(Object.values(parts).flatMap((p) => p.meshes), false)[0];
    const name = hit && hit.object.name;
    const h = name && HOTS.find((x) => x[2].includes(name));
    select(h && h[0] !== selected ? h[0] : null);
  });

  // Outline only the real edges (faces meeting at > 30°), built the first time a part is highlighted.
  function buildEdges(p) {
    const mat = new THREE.LineBasicMaterial({ color: 0xe9e0ff, transparent: true, opacity: 0 });
    const objs = [];
    for (const m of p.meshes) {
      if (m.geometry.index ? m.geometry.index.count > 300000 : m.geometry.attributes.position.count > 300000) continue;
      const e = new THREE.LineSegments(new THREE.EdgesGeometry(m.geometry, 30), mat);
      e.raycast = () => {};
      m.add(e); objs.push(e);
    }
    p.edges = { mat, objs };
  }

  // Size
  const fit = () => {
    const w = stage.clientWidth, h = stage.clientHeight;
    if (!w || !h) return;
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    // keep the model filling narrow (portrait) stages too
    camera.fov = w / h < 1 ? 32 / Math.max(.62, w / h) : 32;
    camera.updateProjectionMatrix();
    narrow = w < 520;
    stage.classList.toggle('narrow', narrow);
    dirty = true;
  };
  new ResizeObserver(fit).observe(stage);
  fit();

  // Load the model
  const bar = load.querySelector('.bar i');
  new GLTFLoader().setMeshoptDecoder(MeshoptDecoder).load('assets/models/jetson-devkit.glb', (gltf) => {
    const model = gltf.scene;
    model.rotation.x = -Math.PI / 2; // CAD is Z-up
    model.traverse((o) => {
      if (!o.isMesh) return;
      // gltfpack may nest the mesh under its named node: use the nearest named ancestor
      let node = o;
      while (node && !MATS[node.name]) node = node.parent;
      if (!node) return;
      const name = node.name;
      if (!o.geometry.attributes.normal) o.geometry = toCreasedNormals(o.geometry, THREE.MathUtils.degToRad(35));
      let p = parts[name];
      if (!p) {
        const [c, m, r] = MATS[name];
        const mat = name === 'pcb'
          ? new THREE.MeshPhysicalMaterial({ color: c, metalness: m, roughness: r, clearcoat: .12, clearcoatRoughness: .5, envMap: envTex, side: THREE.DoubleSide })
          : new THREE.MeshStandardMaterial({ color: c, metalness: m, roughness: r, envMap: envTex, side: THREE.DoubleSide });
        p = parts[name] = { node, meshes: [], mat, col: mat.color.clone(), off: 0, offT: 0, dim: 0, dimT: 0, glow: 0, glowT: 0, z0: node.position.z, edges: null };
      }
      o.material = p.mat;
      o.name = name;
      p.meshes.push(o);
    });
    const pivot = new THREE.Group();
    pivot.add(model);
    const box = new THREE.Box3().setFromObject(model);
    const c = box.getCenter(new THREE.Vector3());
    model.position.sub(c);
    shadow.position.y = box.min.y - c.y - .066;
    scene.add(pivot);
    ready = true;
    load.style.transition = 'opacity .5s'; load.style.opacity = 0;
    setTimeout(() => load.remove(), 600);
    applyStep();
  }, (e) => { if (e.total) bar.style.width = (100 * e.loaded / e.total) + '%'; }, (err) => {
    console.error('jetson model', err);
    load.innerHTML = '<div><b>Couldn\'t load the model</b>Check your connection and reload the page.</div>';
  });

  // Animate: ease every value toward its target; render only when something moved.
  const tmp = new THREE.Vector3(), box = new THREE.Box3();
  const hlCenter = new THREE.Vector3();
  Site.loop(stage, (t, dt) => {
    if (!ready) return;
    const k = 1 - Math.exp(-(dt || .016) * (Site.reduced ? 30 : 5));
    let moving = false;
    const ease = (o, a, b) => { const d = o[b] - o[a]; if (Math.abs(d) > 1e-4) { o[a] += d * k; moving = true; } else o[a] = o[b]; };
    for (const p of Object.values(parts)) {
      ease(p, 'off', 'offT'); ease(p, 'dim', 'dimT'); ease(p, 'glow', 'glowT');
      p.node.position.z = p.z0 + p.off;
      // highlighted parts get a purple tint and a crisp outline; the rest fade toward the background
      p.mat.color.copy(p.col).lerp(ACC2, p.glow * .1).lerp(DIM, p.dim * .6);
      p.mat.emissive.copy(accent).multiplyScalar(p.glow * .1);
      p.mat.envMapIntensity = .85 - .55 * p.dim;
      if (p.glowT > 0 && !p.edges) buildEdges(p);
      if (p.edges) { p.edges.mat.opacity = p.glow * .85; p.edges.objs.forEach((e) => (e.visible = p.glow > .02)); }
    }
    if (!free) {
      // aim at the highlighted parts
      const hl = selected ? [selected] : STEPS[step].hl;
      hlCenter.set(0, 0, 0);
      if (hl.length) {
        box.makeEmpty();
        for (const id of hl) for (const n of HOT[id].nodes) if (parts[n]) box.expandByObject(parts[n].node);
        box.getCenter(hlCenter).multiplyScalar(.55);
      } else {
        // center of everything, following the explode
        box.makeEmpty();
        for (const p of Object.values(parts)) box.expandByObject(p.node);
        box.getCenter(hlCenter).multiplyScalar(.8);
      }
      camT.t.copy(hlCenter);
      for (const key of ['az', 'el', 'd']) { const d = camT[key] - cam[key]; if (Math.abs(d) > 1e-3) { cam[key] += d * k * .8; moving = true; } }
      if (cam.t.distanceTo(camT.t) > 1e-5) { cam.t.lerp(camT.t, k); moving = true; }
      const az = THREE.MathUtils.degToRad(cam.az), el = THREE.MathUtils.degToRad(cam.el);
      camera.position.set(cam.t.x + cam.d * Math.cos(el) * Math.sin(az), cam.t.y + cam.d * Math.sin(el), cam.t.z + cam.d * Math.cos(el) * Math.cos(az));
      camera.lookAt(cam.t);
    } else {
      controls.update();
    }
    if (!moving && !dirty) return;
    dirty = false;
    renderer.render(scene, camera);
    // place labels, then nudge overlapping ones apart
    const W = stage.clientWidth, H = stage.clientHeight, pos = [];
    for (const [id, el] of Object.entries(hotEls)) {
      if (el.classList.contains('hide')) continue;
      box.makeEmpty();
      for (const n of HOT[id].nodes) if (parts[n]) box.expandByObject(parts[n].node);
      box.getCenter(tmp);
      if (TOP_ANCHOR.has(id)) tmp.y = box.max.y;
      tmp.project(camera);
      const off = tmp.z > 1 || Math.abs(tmp.x) > 1.05 || Math.abs(tmp.y) > 1.05;
      el.style.visibility = off ? 'hidden' : 'visible';
      if (!off) pos.push({ el, x: ((tmp.x + 1) / 2) * W, y: ((1 - tmp.y) / 2) * H - 12, w: el.offsetWidth, h: el.offsetHeight });
    }
    pos.sort((a, b) => a.y - b.y);
    for (let i = 0; i < pos.length; i++) for (let j = 0; j < i; j++) {
      const a = pos[j], b = pos[i];
      if (Math.abs(a.x - b.x) < (a.w + b.w) / 2 + 4 && Math.abs(a.y - b.y) < a.h + 3) b.y = a.y + a.h + 3;
    }
    for (const p of pos) p.x = Site.clamp(p.x, p.w / 2 + 4, W - p.w / 2 - 4);
    for (const p of pos) p.el.style.transform = `translate(${p.x}px, ${p.y}px) translate(-50%, -100%)`;
  });
}

/* ═══════════════ Bus / block diagram ═══════════════ */

function busDiagram(root) {
  const svg = root.querySelector('#j-bus-svg'), desc = root.querySelector('#j-bus-desc');
  // SoC-relative boxes (SoC is 400 wide, 350 tall): id, x, y, w, h, title, sub, groups
  const SOC = [
    ['memctrl', 20, 18, 360, 40, 'Memory controller', '', 'mem'],
    ['cpu', 20, 75, 165, 108, '6 CPU cores', 'Cortex-A78AE, 1.7 GHz', 'mem'],
    ['gpu', 215, 75, 165, 108, 'GPU', '1,024 CUDA cores', 'mem'],
    ['jpg1', 20, 198, 80, 50, 'NVJPG', 'JPEG', 'mem eng'],
    ['jpg2', 105, 198, 80, 50, 'NVJPG', 'JPEG', 'mem eng'],
    ['dec', 215, 198, 80, 50, 'NVDEC', 'video', 'mem eng'],
    ['enc', 300, 198, 80, 50, 'NVENC', 'none!', 'eng'],
    ['pcie', 20, 282, 68, 50, 'PCIe', '', 'pcie'],
    ['usb', 94, 282, 68, 50, 'USB', 'xHCI', 'usb2 usb3'],
    ['eth', 168, 282, 68, 50, 'GbE', '', 'io'],
    ['disp', 242, 282, 68, 50, 'Display', '', 'io'],
    ['csiin', 316, 282, 64, 50, 'CSI', '', 'io'],
  ];
  const DEV = [
    ['ssd', 'NVMe SSD, 256 GB', 'M.2 Key M 2280 · Linux boots here', 'pcie'],
    ['m2e', 'Empty M.2 slot', 'Key M 2230', 'pcie'],
    ['wifi', 'Wi-Fi + Bluetooth card', 'M.2 Key E', 'pcie usb2'],
    ['hub', 'USB hub → 4× USB-A', 'our cameras: port 1-2.x', 'usb2 usb3'],
    ['usbc', 'USB-C port', 'port 1-1', 'usb2 usb3'],
    ['ethj', 'Ethernet jack', 'to the robot, 10.85.15.15', 'io'],
    ['dpj', 'DisplayPort', '', 'io'],
    ['csij', '2× CSI connectors', 'ribbon cameras (unused)', 'io'],
  ];
  // links: from SoC block to device, class, lane, label, target y nudge, source x nudge
  const LINKS = [
    ['pcie', 'ssd', 'pcie', 0, 'x4', 0, 0], ['pcie', 'm2e', 'pcie', 0, 'x2', 0, 0], ['pcie', 'wifi', 'pcie', 0, 'x1', -8, 0],
    ['usb', 'wifi', 'usb2', 1, 'BT', 8, -14], ['usb', 'hub', 'usb2', 1, '', -8, -14], ['usb', 'usbc', 'usb2', 1, '', -8, -14],
    ['usb', 'hub', 'usb3', 2, '', 8, 14], ['usb', 'usbc', 'usb3', 2, '', 8, 14],
    ['eth', 'ethj', 'io', 3, '', 0, 0], ['disp', 'dpj', 'io', 4, '', 0, 0], ['csiin', 'csij', 'io', 5, '', 0, 0],
  ];
  const DESC = {
    lpddr: '<b>8 GB LPDDR5 memory.</b> 128 wires wide, moving up to 102 GB a second. The CPU, GPU and engines all share it (unified memory), so a camera frame never has to be copied to a separate graphics card. A whole 1280×800 gray frame (1 MB) could cross in about 10 µs.',
    memctrl: '<b>Memory controller.</b> The traffic cop between every block on the chip and the RAM. Everything that reads or writes memory goes through it.',
    cpu: '<b>6 CPU cores</b> (Arm Cortex-A78AE, up to 1.7 GHz; we lock 1728 MHz). Flexible and fast one at a time: Linux, Java, PhotonVision, the pose math. 1.5 MB of L2 and 4 MB of L3 cache keep recent data close.',
    gpu: '<b>GPU:</b> NVIDIA Ampere, 1,024 CUDA cores in 8 groups (SMs) of 128, plus 32 Tensor Cores, at 1020 MHz. Our AprilTag detector runs here in about 2 ms a frame, and the game-piece neural network too.',
    jpg1: '<b>NVJPG</b>, a hardware JPEG decoder. There are two. Each unpacks a 1280×800 camera JPEG in about 2.3 ms while the CPU does almost nothing. We decode every camera frame on them (chapter 10).',
    dec: '<b>NVDEC</b> decodes compressed video streams (H.264, H.265). Our cameras send separate JPEGs instead, so we don\'t use it.',
    enc: '<b>No video encoder.</b> Unlike bigger Jetsons, the Orin Nano has no NVENC: encoding video takes 1–2 CPU cores. Our Rewind recorder saves the cameras\' own JPEGs, so it doesn\'t need one (3% of one core).',
    pcie: '<b>PCIe Gen3 controller.</b> High-speed lanes to the M.2 slots: 4 lanes to the SSD slot, 2 to the empty slot, 1 to the Wi-Fi card.',
    usb: '<b>One USB controller (xHCI), two buses.</b> USB 2.0 is <code>Bus 1</code> (480 Mbps, shared by every USB 2.0 device). USB 3 is <code>Bus 2</code> (10 Gbps). Our cameras are USB 2.0, so they all share Bus 1.',
    eth: '<b>Gigabit Ethernet.</b> Results go to the robot over NetworkTables through this port.',
    disp: '<b>Display controller</b> drives the DisplayPort. Unused on the robot (headless).',
    csiin: '<b>Camera interface (MIPI CSI-2)</b> for ribbon-cable cameras. We use USB cameras, so it\'s idle.',
    ssd: '<b>NVMe SSD, 256 GB</b>, in the long M.2 Key M slot with 4 PCIe lanes. Linux, PhotonVision and Rewind recordings live here.',
    m2e: '<b>Empty M.2 Key M 2230 slot</b> (PCIe x2). A PCIe USB controller card here would add a second USB 2.0 bus for more cameras: an idea we haven\'t tested.',
    wifi: '<b>Wi-Fi + Bluetooth card</b> (M.2 Key E). Wi-Fi rides PCIe, but its Bluetooth is a USB 2.0 device on Bus 1 (port 1-3), sharing the cameras\' budget. We keep Bluetooth off.',
    hub: '<b>USB hub</b> on the carrier board (port 1-2). All four USB-A ports hang off it, so four cameras share one hub, and its USB 2.0 side shares Bus 1 with USB-C and Bluetooth.',
    usbc: '<b>USB-C port</b> (port 1-1). Also on Bus 1: we measured that a camera here does <em>not</em> add bandwidth.',
    ethj: '<b>Ethernet jack</b>: the cable to the robot\'s network. The Jetson is 10.85.15.15.',
    dpj: '<b>DisplayPort</b>: plug in a monitor for debugging.',
    csij: '<b>Two 22-pin CSI connectors</b> for ribbon cameras.',
  };
  DESC.jpg2 = DESC.jpg1;
  const GROUP_DESC = {
    all: 'Click any box to see what it does.',
    mem: '<b>Memory:</b> the CPU, GPU and both JPEG engines all read and write the same 8 GB of RAM through one memory controller. Nothing gets copied between separate memories.',
    pcie: '<b>PCIe:</b> fast point-to-point lanes. The SSD gets 4, the empty slot 2, the Wi-Fi card 1.',
    usb2: '<b>The one USB 2.0 bus:</b> USB-C, the hub with all four USB-A ports, and the Wi-Fi card\'s Bluetooth. Every camera on any of them shares about 6700 bytes per 125 µs microframe.',
    usb3: '<b>The USB 3 bus:</b> a separate, much faster road (10 Gbps) to the same ports. A USB 3 camera would use it and leave the USB 2.0 budget alone.',
    eng: '<b>Special engines:</b> two JPEG decoders and a video decoder do one job each, in hardware, without the CPU. The Orin Nano has no video encoder.',
  };

  const LAY = {
    wide: { W: 1000, H: 566, soc: [40, 120], lp: [40, 50], mod: [20, 14, 440, 478], car: [540, 14, 440, 480], dev: (i) => [560, 48 + i * 54, 400, 44], laneY: (k) => 506 + k * 8, laneX: (k) => 482 + k * 9, fs: 1 },
    tall: { W: 460, H: 1036, soc: [30, 120], lp: [30, 50], mod: [10, 14, 440, 478], car: [10, 540, 440, 486], dev: (i) => [118, 574 + i * 54, 312, 44], laneY: (k) => 496 + k * 7, laneX: (k) => 28 + k * 14, fs: 1.12 },
  };
  let mode = null, group = 'all', sel = null;

  function render() {
    const L = LAY[svg.clientWidth && svg.clientWidth < 640 ? 'tall' : 'wide'];
    const m = L === LAY.tall ? 'tall' : 'wide';
    if (m === mode) return;
    mode = m;
    const [sx, sy] = L.soc, f = L.fs;
    const box = {};
    let h = '';
    const txt = (x, y, s, cls = '', anchor = 'start') => `<text class="${cls}" x="${x}" y="${y}" text-anchor="${anchor}"${cls === 's' ? ` style="font-size:${11.5 * f}px"` : ` style="font-size:${14 * f}px"`}>${s}</text>`;
    // frames
    h += `<rect class="frame" x="${L.mod[0]}" y="${L.mod[1]}" width="${L.mod[2]}" height="${L.mod[3]}" rx="16"/><text class="frame-l" x="${L.mod[0] + 16}" y="${L.mod[1] + 24}">Orin Nano module</text>`;
    h += `<rect class="frame" x="${L.car[0]}" y="${L.car[1]}" width="${L.car[2]}" height="${L.car[3]}" rx="16"/><text class="frame-l" x="${m === 'tall' ? L.car[0] + L.car[2] - 16 : L.car[0] + 16}" y="${L.car[1] + 24}" text-anchor="${m === 'tall' ? 'end' : 'start'}">Carrier board</text>`;
    h += `<rect class="soc" x="${sx}" y="${sy}" width="400" height="350" rx="14"/><text class="frame-l" x="${sx + 400}" y="${sy - 8}" text-anchor="end" style="fill:#a78bfa">SoC (one chip)</text>`;
    // lines first (under boxes)
    let lines = '';
    // memory bus + fabric
    lines += `<path class="ln mem hl-mem" d="M${sx + 200} ${L.lp[1] + 46} V${sy + 18}"/><text class="lnl hl-mem" x="${sx + 188}" y="${sy - 8}" text-anchor="end" fill="#c4b5fd">128-bit · 102 GB/s</text>`;
    lines += `<path class="ln mem hl-mem" style="stroke-width:4" d="M${sx + 200} ${sy + 58} V${sy + 268} M${sx + 20} ${sy + 268} H${sx + 380} M${sx + 185} ${sy + 129} H${sx + 215} M${sx + 185} ${sy + 223} H${sx + 215}"/>`;
    for (const b of SOC) box[b[0]] = [sx + b[1], sy + b[2], b[3], b[4]];
    // stubs from the I/O row up to the fabric
    for (const id of ['pcie', 'usb', 'eth', 'disp', 'csiin']) { const [x, y, w] = box[id]; lines += `<path class="ln mem hl-mem" style="stroke-width:3;opacity:.7" d="M${x + w / 2} ${y} V${sy + 268}"/>`; }
    DEV.forEach((d, i) => { box[d[0]] = L.dev(i); });
    for (const [a, b, cls, k, lab, dy, dx] of LINKS) {
      const [x, y, w, hh] = box[a], [tx, ty, , th] = box[b];
      const px = x + w / 2 + dx, ly = L.laneY(k), lx = L.laneX(k), yy = ty + th / 2 + dy;
      lines += `<path class="ln ${cls} flow hl-${cls}" d="M${px} ${y + hh} V${ly} H${lx} V${yy} H${tx}"/>`;
      if (lab) lines += `<text class="lnl hl-${cls}" x="${tx - 6}" y="${cls === 'usb2' ? yy + 13 : yy - 5}" text-anchor="end" fill="${{ pcie: '#22d3ee', usb2: '#f59e0b' }[cls]}">${lab}</text>`;
    }
    h += lines;
    // LPDDR5
    h += `<g class="blk core" data-id="lpddr" data-g="mem"><rect x="${L.lp[0]}" y="${L.lp[1]}" width="400" height="46" rx="8"/>${txt(L.lp[0] + 16, L.lp[1] + 28, '8 GB LPDDR5 RAM')}${txt(L.lp[0] + 384, L.lp[1] + 28, 'shared by everyone', 's', 'end')}</g>`;
    for (const [id, , , , , title, sub, grp] of SOC) {
      const [x, y, w, hh] = box[id];
      let inner = '';
      if (id === 'cpu') for (let i = 0; i < 6; i++) inner += `<rect x="${x + 14 + (i % 3) * 48}" y="${y + 52 + Math.floor(i / 3) * 27}" width="40" height="21" rx="4" style="fill:#c4b5fd;stroke:none;opacity:.85"/>`;
      if (id === 'gpu') for (let i = 0; i < 8; i++) inner += `<rect x="${x + 12 + (i % 4) * 36}" y="${y + 52 + Math.floor(i / 4) * 27}" width="31" height="21" rx="3" style="fill:#a3e635;stroke:none;opacity:.8"/><text x="${x + 27.5 + (i % 4) * 36}" y="${y + 66 + Math.floor(i / 4) * 27}" text-anchor="middle" style="font:700 ${10 * f}px var(--mono);fill:#1a0a2b">128</text>`;
      const big = id === 'cpu' || id === 'gpu' || id === 'memctrl';
      h += `<g class="blk ${big ? 'core' : ''} ${id === 'enc' ? 'none' : ''}" data-id="${id}" data-g="${grp}"><rect x="${x}" y="${y}" width="${w}" height="${hh}" rx="8"/>${inner}`;
      if (id === 'memctrl') h += txt(x + w / 2, y + 26, title, '', 'middle');
      else if (big) h += txt(x + 12, y + 22, title) + txt(x + 12, y + 40, sub, 's');
      else h += txt(x + w / 2, y + (sub ? 22 : 30), title, '', 'middle') + (sub ? txt(x + w / 2, y + 40, sub, 's', 'middle') : '');
      if (id === 'enc') h += `<path d="M${x + 8} ${y + 8} L${x + w - 8} ${y + hh - 8}" stroke="#f43f5e" stroke-width="2"/>`;
      h += '</g>';
    }
    for (const [id, title, sub, grp] of DEV) {
      const [x, y, w, hh] = box[id];
      h += `<g class="blk" data-id="${id}" data-g="${grp}"><rect x="${x}" y="${y}" width="${w}" height="${hh}" rx="8"/>${txt(x + 14, y + (sub ? 19 : 27), title)}${sub ? txt(x + 14, y + 36, sub, 's') : ''}</g>`;
    }
    svg.setAttribute('viewBox', `0 0 ${L.W} ${L.H}`);
    svg.innerHTML = h;
    paint();
  }

  function paint() {
    const active = sel ? (svg.querySelector(`.blk[data-id="${sel}"]`)?.dataset.g || '').split(' ') : group === 'all' ? [] : [group];
    svg.classList.toggle('dim', !!(sel || group !== 'all'));
    svg.querySelectorAll('.blk').forEach((b) => {
      const gs = b.dataset.g.split(' ');
      b.classList.toggle('hl', b.dataset.id === sel || (!sel && gs.some((x) => active.includes(x))) || (sel && sel === b.dataset.id));
      b.classList.toggle('sel', b.dataset.id === sel);
    });
    svg.querySelectorAll('.ln, .lnl').forEach((l) => {
      const on = active.some((a) => l.classList.contains('hl-' + a));
      l.classList.toggle('hl', on);
    });
    // a selected block also lights its direct partners
    if (sel) {
      const links = LINKS.filter((l) => l[0] === sel || l[1] === sel);
      for (const l of links) { svg.querySelector(`.blk[data-id="${l[0]}"]`).classList.add('hl'); svg.querySelector(`.blk[data-id="${l[1]}"]`).classList.add('hl'); }
      if (['cpu', 'gpu', 'jpg1', 'jpg2', 'dec', 'memctrl'].includes(sel)) { svg.querySelector('.blk[data-id="lpddr"]').classList.add('hl'); svg.querySelector('.blk[data-id="memctrl"]').classList.add('hl'); }
      if (sel === 'lpddr') svg.querySelectorAll('.blk[data-g~="mem"]').forEach((b) => b.classList.add('hl'));
    }
    desc.innerHTML = sel ? DESC[sel] : GROUP_DESC[group];
  }

  svg.addEventListener('click', (e) => {
    const b = e.target.closest('.blk');
    sel = b && b.dataset.id !== sel ? b.dataset.id : null;
    paint();
  });
  Site.seg(root.querySelector('#j-bus-seg'), (v) => { group = v; sel = null; paint(); });
  new ResizeObserver(render).observe(svg);
  render();
}

/* ═══════════════ Fanless thermal lab ═══════════════ */

function thermalLab(root) {
  // One RC node fitted to our two fan-off runs (TECHNICAL.md "Fanless"): steady state
  // T = 40.3 °C + R·P, time constant 6.6 min. Stock heatsink R = 6.2 °C/W.
  const T0 = 40, OFFSET = 40.3, TAU = 6.6, P_IDLE = 7.2, P_FULL = 9.46, MATCH = 4;
  const cv = root.querySelector('#j-therm-cv');
  let st = null;
  st = Site.canvas(cv, 0.58, () => st && draw());
  const wait = root.querySelector('#j-t-wait'), rr = root.querySelector('#j-t-r');
  const peakEl = root.querySelector('#j-t-peak');
  let W = 10, R = 6.2;
  Site.range(wait, (v) => { W = v; draw(); }, (v) => v + ' min');
  const presets = [...root.querySelectorAll('#j-t-seg button')];
  Site.range(rr, (v) => { R = v; draw(); presets.forEach((b) => b.classList.toggle('on', Math.abs(+b.dataset.v - v) < .05)); }, (v) => v.toFixed(1) + ' °C/W');
  Site.seg(root.querySelector('#j-t-seg'), (v) => { rr.value = v; rr.dispatchEvent(new Event('input')); });

  function temp(t) {
    const ssI = OFFSET + R * P_IDLE, ssF = OFFSET + R * P_FULL;
    if (t <= W) return ssI + (T0 - ssI) * Math.exp(-t / TAU);
    const Tw = ssI + (T0 - ssI) * Math.exp(-W / TAU);
    return ssF + (Tw - ssF) * Math.exp(-(t - W) / TAU);
  }
  function draw() {
    const { ctx, w, h } = st;
    if (!w) return;
    const total = W + MATCH, pl = 42, pr = 12, pt = 14, pb = 30;
    const X = (t) => pl + (t / total) * (w - pl - pr), Y = (T) => pt + (1 - (T - 30) / 80) * (h - pt - pb);
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
    // phases
    ctx.fillStyle = 'rgba(139,92,246,.10)'; ctx.fillRect(X(0), pt, X(W) - X(0), h - pt - pb);
    ctx.fillStyle = 'rgba(245,158,11,.14)'; ctx.fillRect(X(W), pt, X(total) - X(W), h - pt - pb);
    ctx.font = '600 11px Plus Jakarta Sans, sans-serif'; ctx.textAlign = 'center';
    ctx.fillStyle = '#b8a9d4';
    if (W >= 3) ctx.fillText('on, disabled', (X(0) + X(W)) / 2, h - pb - 8);
    ctx.fillStyle = '#fbbf24'; ctx.fillText('match', (X(W) + X(total)) / 2, h - pb - 8);
    // grid
    ctx.strokeStyle = 'rgba(196,181,253,.12)'; ctx.lineWidth = 1; ctx.textAlign = 'right'; ctx.fillStyle = '#b8a9d4';
    for (let T = 30; T <= 110; T += 20) { ctx.beginPath(); ctx.moveTo(pl, Y(T)); ctx.lineTo(w - pr, Y(T)); ctx.stroke(); ctx.fillText(T + '°', pl - 6, Y(T) + 4); }
    ctx.textAlign = 'center';
    const stepT = total > 20 ? 5 : total > 8 ? 2 : 1;
    for (let t = 0; t <= total + 1e-6; t += stepT) ctx.fillText(t + (t === 0 ? ' min' : ''), X(t), h - 10);
    // limits
    const hline = (T, col, label) => { ctx.strokeStyle = col; ctx.setLineDash([5, 4]); ctx.beginPath(); ctx.moveTo(pl, Y(T)); ctx.lineTo(w - pr, Y(T)); ctx.stroke(); ctx.setLineDash([]); ctx.fillStyle = col; ctx.textAlign = 'left'; ctx.fillText(label, pl + 6, Y(T) - 5); };
    hline(99, '#f43f5e', '99 °C: throttling starts');
    hline(95, '#f59e0b', '');
    ctx.textAlign = 'right'; ctx.fillText('95 °C: fanless mode caps cameras at 60 fps', w - pr - 6, Y(95) + 15);
    hline(43, '#22d3ee', '');
    ctx.textAlign = 'right'; ctx.fillText('fan on, quiet profile: 43 °C (measured)', w - pr - 6, Y(43) + 15);
    // curve
    let peak = 0;
    ctx.lineWidth = 3; ctx.lineJoin = 'round';
    const N = 160;
    for (let i = 0; i < N; i++) {
      const t0 = (i / N) * total, t1 = ((i + 1) / N) * total, a = temp(t0), b = temp(t1);
      peak = Math.max(peak, a, b);
      ctx.strokeStyle = b > 90 ? '#f43f5e' : b > 75 ? '#f59e0b' : '#a3e635';
      ctx.beginPath(); ctx.moveTo(X(t0), Y(a)); ctx.lineTo(X(t1), Y(b)); ctx.stroke();
    }
    ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(X(total), Y(temp(total)), 5, 0, 7); ctx.fill();
    peakEl.textContent = peak.toFixed(0) + ' °C';
    peakEl.style.color = peak >= 99 ? '#f43f5e' : peak > 85 ? '#f59e0b' : '#a3e635';
  }
}

/* ═══════════════ Core-count comparison ═══════════════ */

function compareCores(root) {
  const BOARDS = {
    pi5: { cpu: [[4, 1]], other: [] },
    opi5: { cpu: [[4, 1], [4, .72]], other: ['Mali GPU', '6 TOPS NPU'] },
    jetson: { cpu: [[6, 1]], gpu: 1024, other: [] },
  };
  const cvs = [...root.querySelectorAll('#j-cmp canvas')];
  const states = cvs.map((cv) => {
    const s = { cv, ctx: cv.getContext('2d'), b: BOARDS[cv.dataset.cmp], w: 0, h: 0 };
    const fit = () => {
      const w = cv.parentElement.clientWidth - (cv.parentElement.clientWidth > 640 ? 164 : 0);
      s.w = Math.max(200, w - 28);
      const cpuW = 26 * s.b.cpu.reduce((a, [n]) => a + n, 0) + 16;
      s.cols = Math.max(16, Math.floor((s.w - (s.b.gpu ? cpuW : 0)) / 7));
      const rows = s.b.gpu ? Math.ceil(s.b.gpu / s.cols) : 0;
      if (s.b.gpu && s.cols < 32) { s.stack = true; s.cols = Math.floor(s.w / 7); } else s.stack = false;
      s.chipRow = s.b.other.length && s.w < 460;
      s.h = s.b.gpu ? (s.stack ? 36 + Math.ceil(s.b.gpu / s.cols) * 7 : Math.max(36, rows * 7)) : s.chipRow ? 66 : 36;
      const dpr = Math.min(devicePixelRatio || 1, 2);
      cv.width = s.w * dpr; cv.height = s.h * dpr; cv.style.width = s.w + 'px'; cv.style.height = s.h + 'px';
      s.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      s.drawn = -1;
    };
    new ResizeObserver(fit).observe(cv.parentElement);
    fit();
    return s;
  });
  let t0 = null;
  Site.loop(root.querySelector('#j-cmp'), (t) => {
    if (t0 === null) t0 = t;
    const p = Site.reduced ? 1 : Site.clamp((t - t0) / 1.6, 0, 1);
    for (const s of states) {
      if (s.drawn === 1 && p === 1) continue;
      const { ctx, w, h } = s;
      ctx.clearRect(0, 0, w, h);
      let x = 12;
      for (const [n, sc] of s.b.cpu) for (let i = 0; i < n; i++) {
        ctx.fillStyle = '#c4b5fd'; ctx.beginPath(); ctx.arc(x, 18, 10 * sc, 0, 7); ctx.fill(); x += 26;
      }
      x += 6;
      let cy = 7;
      if (s.chipRow) { x = 2; cy = 38; }
      for (const o of s.b.other) {
        ctx.font = '600 11px Plus Jakarta Sans, sans-serif';
        const tw = ctx.measureText(o).width + 18;
        ctx.fillStyle = 'rgba(100,116,139,.35)'; ctx.strokeStyle = '#64748b';
        ctx.beginPath(); ctx.roundRect(x, cy, tw, 22, 6); ctx.fill(); ctx.stroke();
        ctx.fillStyle = '#cbd5e1'; ctx.fillText(o, x + 9, cy + 15); x += tw + 8;
      }
      if (s.b.gpu) {
        const ox = s.stack ? 4 : x + 4, oy = s.stack ? 40 : 4;
        const n = Math.round(s.b.gpu * p);
        ctx.fillStyle = '#a3e635';
        for (let i = 0; i < n; i++) { ctx.fillRect(ox + (i % s.cols) * 7, oy + Math.floor(i / s.cols) * 7, 5, 5); }
        if (!s.stack) { ctx.fillStyle = '#b8a9d4'; ctx.font = '600 11px Plus Jakarta Sans, sans-serif'; }
      }
      s.drawn = p === 1 ? 1 : 0;
    }
  });
}
