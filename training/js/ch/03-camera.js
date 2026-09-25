// Chapter 03: inside the camera. 3D exploded CAD view, the journey of light (scrolly),
// global vs rolling shutter, Bayer vs mono, JPEG, field of view, and focusing.
Object.assign(Site.glossary, {
  'photodiode': 'A tiny light sensor. Each photon that hits it frees an electron; counting the electrons measures the light. Every pixel has one.',
  'ADC': 'Analog-to-digital converter: measures a voltage or charge and turns it into a number.',
  'Bayer filter': 'The checkerboard of tiny red, green and blue filters over a color sensor\'s pixels: half green, a quarter red, a quarter blue.',
  'UVC': 'USB Video Class: the standard way USB cameras describe themselves, send video and expose settings. Linux supports it with one driver, uvcvideo.',
});

Site.chapter('camera', (root) => {
  // Click-to-play video: no YouTube iframe loads until the student asks for it.
  root.addEventListener('click', (e) => {
    const b = e.target.closest('.yt-play');
    if (b) b.outerHTML = `<iframe class="video-embed" src="https://www.youtube-nocookie.com/embed/${b.dataset.yt}?autoplay=1" title="${b.getAttribute('aria-label')}" allow="autoplay; encrypted-media" allowfullscreen></iframe>`;
  });
  const $ = (s) => root.querySelector(s);
  const rng = (s) => () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
  const gauss = (r) => { let u = 0; for (let i = 0; i < 6; i++) u += r(); return (u - 3) / 0.7071; };
  const loadImg = (src) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src; });
  // one real frame from our TopLeft Thriftiest Cam (the camera's own JPEG), as grayscale, shared by several labs
  const FRAME = loadImg('assets/from-jetson/frames/tag-close_TopLeft.jpg').then((img) => {
    const W = img.width, H = img.height, c = document.createElement('canvas'); c.width = W; c.height = H;
    const x = c.getContext('2d'); x.drawImage(img, 0, 0);
    const d = x.getImageData(0, 0, W, H).data, g = new Float32Array(W * H);
    for (let i = 0; i < W * H; i++) g[i] = 0.299 * d[i * 4] + 0.587 * d[i * 4 + 1] + 0.114 * d[i * 4 + 2];
    return { W, H, g };
  });
  const grayCanvas = (g, W, H) => { const c = document.createElement('canvas'); c.width = W; c.height = H; const x = c.getContext('2d'), id = x.createImageData(W, H); for (let i = 0; i < W * H; i++) { const v = g[i]; id.data[i * 4] = id.data[i * 4 + 1] = id.data[i * 4 + 2] = v; id.data[i * 4 + 3] = 255; } x.putImageData(id, 0, 0); return c; };

  /* ── 3D exploded view ──────────────────────────────────── */
  (async () => {
    const box = $('#c-3d'), msg = box.querySelector('.msg');
    let THREE, OrbitControls, GLTFLoader, MeshoptDecoder, RoomEnvironment, gltf;
    try {
      THREE = await import('three');
      [{ OrbitControls }, { GLTFLoader }, { MeshoptDecoder }, { RoomEnvironment }] = await Promise.all([
        import('three/addons/OrbitControls.js'), import('three/addons/GLTFLoader.js'), import('three/addons/meshopt_decoder.module.js'), import('three/addons/RoomEnvironment.js')]);
      const loader = new GLTFLoader(); loader.setMeshoptDecoder(MeshoptDecoder);
      gltf = await loader.loadAsync('assets/models/thriftiest-cam.glb');
    } catch (e) { msg.textContent = 'The 3D view could not load here.'; return; }
    msg.remove();
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.toneMappingExposure = 1.1;
    box.prepend(renderer.domElement);
    const scene = new THREE.Scene();
    scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
    const key = new THREE.DirectionalLight(0xffffff, 1.6); key.position.set(0.3, 0.5, 0.6); scene.add(key);
    const rim = new THREE.DirectionalLight(0xc4b5fd, 1.2); rim.position.set(-0.4, 0.2, -0.5); scene.add(rim);
    const cam = new THREE.PerspectiveCamera(32, 4 / 3, 0.005, 2);
    const controls = new OrbitControls(cam, renderer.domElement);
    controls.enableDamping = true; controls.enablePan = false; controls.minDistance = 0.08; controls.maxDistance = 0.6;
    controls.autoRotate = !Site.reduced; controls.autoRotateSpeed = 0.8;
    renderer.domElement.addEventListener('pointerdown', () => (controls.autoRotate = false));
    // the model is Z-up with the lens along +Z; turn it so the lens points along world +X, world up = model Y
    const model = new THREE.Group(); model.rotation.y = Math.PI / 2; scene.add(model);
    const mat = (color, o = {}) => new THREE.MeshStandardMaterial({ color, roughness: 0.6, metalness: 0, side: THREE.DoubleSide, ...o });
    const parts = [];
    const part = (name, meshes, z, anchor, sim) => { const g = new THREE.Group(); meshes.forEach((m) => g.add(m)); model.add(g); parts.push({ name, g, z, anchor: new THREE.Vector3(...anchor), sim }); };
    const M = (g, m, pos, rot) => { const o = new THREE.Mesh(g, m); if (pos) o.position.set(...pos); if (rot) o.rotation.set(...rot); return o; };
    const cad = (name, material) => { const g = gltf.scene.getObjectByName(name); g.traverse((o) => { if (o.isMesh) o.material = material; }); return g; };
    const plastic = mat(0x1b1a1f, { roughness: 0.78 }); // black matte molded case
    // real CAD (each part is a Group holding one mesh)
    part('Back cover', [cad('back', plastic)], -0.032, [0, 0.026, 0.004]);
    part('Screws (4)', [cad('screws', mat(0xc9c9d2, { metalness: 1, roughness: 0.32 }))], -0.056, [0.0237, -0.012, 0.006]);
    part('Lens holder (M12 mount)', [cad('lens_mount', mat(0x26242b, { roughness: 0.55 }))], 0.006, [0, 0.026, 0.012]);
    part('Front case', [cad('front', plastic)], 0.062, [0, 0.026, 0.02]);
    // simplified internals (the CAD has none)
    const pcb = [
      M(new THREE.BoxGeometry(0.044, 0.036, 0.0016), mat(0x1d5b3a, { roughness: 0.7 }), [0, 0, 0.0065]),
      M(new THREE.BoxGeometry(0.0089, 0.0072, 0.0032), mat(0xc7c7d1, { metalness: 1, roughness: 0.28 }), [0, -0.0145, 0.0041]),
      M(new THREE.BoxGeometry(0.006, 0.006, 0.0012), mat(0x151515), [0.013, 0.008, 0.0079]),
    ];
    part('Circuit board + USB-C', pcb, -0.012, [0.012, -0.03, 0.0065], true);
    part('OV9281 sensor', [M(new THREE.BoxGeometry(0.0085, 0.0075, 0.0012), mat(0x1a1a1f), [0, 0, 0.0079]), M(new THREE.BoxGeometry(0.0062, 0.0046, 0.0003), mat(0x7c5cc4, { metalness: 0.8, roughness: 0.18 }), [0, 0, 0.0086])], -0.012, [0, 0.012, 0.0085], true);
    part('IR-cut filter', [M(new THREE.BoxGeometry(0.0095, 0.0095, 0.0006), mat(0x2dd4bf, { metalness: 0.7, roughness: 0.15 }), [0, 0, 0.0112])], 0.022, [0, -0.02, 0.0112], true);
    const barrel = new THREE.CylinderGeometry(0.006, 0.006, 0.016, 48, 1, true, 0.6, Math.PI * 1.5);
    const lensParts = [M(barrel, mat(0x18161c, { roughness: 0.5 }), [0, 0, 0.0195], [Math.PI / 2, 0, 0])];
    [[0.0145, 0.0018, 0x93c5fd], [0.0195, 0.0022, 0xc4b5fd], [0.0245, 0.0024, 0x93c5fd]].forEach(([z, h, c]) => lensParts.push(M(new THREE.CylinderGeometry(0.0049, 0.0049, h, 40), mat(c, { metalness: 0.35, roughness: 0.08 }), [0, 0, z], [Math.PI / 2, 0, 0])));
    part('Lens: 2 glass + 1 plastic', lensParts, 0.036, [0, -0.02, 0.022], true);
    // labels
    parts.forEach((p) => { p.el = document.createElement('div'); p.el.className = 'lbl' + (p.sim ? ' sim' : ''); p.el.textContent = p.name; box.appendChild(p.el); });
    let ex = 0.65;
    Site.range($('#c-explode'), (v) => (ex = v), (v) => Math.round(v * 100) + '%');
    const target = new THREE.Vector3(), tmp = new THREE.Vector3();
    cam.position.set(0.075, 0.06, 0.15);
    let w = 0, h = 0, cur = ex;
    const size = () => { w = box.clientWidth; h = box.clientHeight; renderer.setSize(w, h, false); cam.aspect = w / h; cam.updateProjectionMatrix(); };
    new ResizeObserver(size).observe(box); size();
    Site.loop(box, () => {
      cur += (ex - cur) * 0.15;
      parts.forEach((p) => (p.g.position.z = p.z * cur));
      target.set(0.013 + 0.004 * cur, 0, 0); // world coordinates (lens axis along x)
      controls.target.lerp(target, 0.2);
      controls.update();
      renderer.render(scene, cam);
      // project each label's anchor, then nudge labels apart so none overlap
      const placed = [];
      parts.map((p) => { tmp.copy(p.anchor); tmp.z += p.z * cur; tmp.applyMatrix4(model.matrixWorld).project(cam); p.lw = p.lw || p.el.offsetWidth; p.lh = p.lh || p.el.offsetHeight; return { p, x: ((tmp.x + 1) / 2) * w, y: ((1 - tmp.y) / 2) * h }; })
        .sort((a, b) => a.y - b.y)
        .forEach((q) => {
          const hit = (y) => placed.some((o) => Math.abs(o.x - q.x) < (o.p.lw + q.p.lw) / 2 + 4 && Math.abs(o.y - y) < (o.p.lh + q.p.lh) / 2 + 2);
          let y = q.y; for (let k = 0; k < 8 && hit(y); k++) y += q.p.lh + 3;
          q.y = Site.clamp(y, q.p.lh, h - q.p.lh); placed.push(q);
          q.p.el.style.transform = `translate(${Site.clamp(q.x, q.p.lw / 2 + 4, w - q.p.lw / 2 - 4)}px, ${q.y}px) translate(-50%, -50%)`;
          q.p.el.style.opacity = cur > 0.3 ? 1 : 0;
        });
    });
  })();

  /* ── Journey of light (scrolly) ────────────────────────── */
  (async () => {
    const st = Site.canvas($('#c-journey')); // height from CSS aspect-ratio (taller on phones)
    const F = await FRAME;
    let step = 0, t0 = 0;
    // real pixels: a patch around tag 3's top-left corner, and a tag crop for the JPEG step
    const patch = []; for (let y = 0; y < 9; y++) { const row = []; for (let x = 0; x < 13; x++) row.push(Math.round(F.g[(425 + y) * F.W + 409 + x])); patch.push(row); }
    const tagCrop = (() => { const W = 96, H = 64, g = new Float32Array(W * H); for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) g[y * W + x] = F.g[(440 + y) * F.W + 430 + x]; return grayCanvas(g, W, H); })();
    const tagG = Site.tagGrid(3);
    const r = rng(5);
    const drops = Array.from({ length: 70 }, () => ({ x: r(), y: r(), s: 0.5 + r() }));
    const TXT = '#f4efff', MUT = '#b8a9d4', AC = '#c4b5fd';
    const text = (ctx, s, x, y, o = {}) => { ctx.font = `${o.w || 600} ${o.size || 13}px ${o.mono ? 'JetBrains Mono, monospace' : 'Plus Jakarta Sans, sans-serif'}`; ctx.fillStyle = o.c || TXT; ctx.textAlign = o.a || 'left'; ctx.fillText(s, x, y); ctx.textAlign = 'left'; };
    // optical bench geometry (fractions of w/h)
    const optics = (ctx, w, h, t, s) => {
      const tagX = 0.05 * w, tagS = Math.min(0.17 * h, 0.2 * w), tagY = 0.5 * h - tagS / 2, xL = 0.47 * w, xF = 0.7 * w, xS = 0.8 * w, lh = 0.46 * h;
      // camera body
      ctx.strokeStyle = 'rgba(196,181,253,.35)'; ctx.lineWidth = 1.5; ctx.setLineDash([]);
      ctx.beginPath(); ctx.roundRect(0.4 * w, 0.14 * h, 0.5 * w, 0.72 * h, 14); ctx.stroke();
      text(ctx, 'camera', 0.41 * w, 0.14 * h - 8, { c: MUT, size: 12 });
      // tag
      ctx.fillStyle = '#fff'; ctx.fillRect(tagX - 4, tagY - 4, tagS + 8, tagS + 8);
      ctx.drawImage(Site.tagCanvas(3, 100), tagX, tagY, tagS, tagS);
      text(ctx, 'tag', tagX + tagS / 2, tagY + tagS + 22, { c: MUT, size: 12, a: 'center' });
      const P = [[tagX + tagS * 0.8, tagY + tagS * 0.25], [tagX + tagS * 0.8, tagY + tagS * 0.8]];
      const I = P.map(([, y]) => [xS, 0.5 * h - (y - 0.5 * h) * 1.35]);
      const cols = ['#fde68a', '#c4b5fd'];
      ctx.lineDashOffset = -t * 40;
      if (s === 0) {
        // light spreading out in every direction from two points
        P.forEach(([x, y], k) => { for (let i = 0; i < 11; i++) { const a = -1.1 + i * 0.22; ctx.strokeStyle = cols[k]; ctx.globalAlpha = 0.7; ctx.setLineDash([6, 8]); ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + Math.cos(a) * 0.3 * w, y + Math.sin(a) * 0.3 * w); ctx.stroke(); } });
        ctx.globalAlpha = 1; ctx.setLineDash([]);
        // lamp
        ctx.fillStyle = '#fde68a'; ctx.beginPath(); ctx.arc(0.2 * w, 0.14 * h, 10, 0, 7); ctx.fill();
        ctx.strokeStyle = 'rgba(253,230,138,.5)'; ctx.setLineDash([3, 6]); ctx.beginPath(); ctx.moveTo(0.2 * w, 0.14 * h); ctx.lineTo(tagX + tagS / 2, tagY); ctx.stroke(); ctx.setLineDash([]);
        text(ctx, 'field lights', 0.2 * w + 16, 0.14 * h + 4, { c: MUT, size: 12 });
      } else {
        P.forEach(([x, y], k) => {
          for (let i = 0; i < 5; i++) {
            const ly = 0.5 * h + (i - 2) * lh * 0.19;
            ctx.strokeStyle = cols[k]; ctx.globalAlpha = 0.85; ctx.lineWidth = 1.4; ctx.setLineDash([6, 8]);
            ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(xL, ly);
            // after the lens, towards the image point (IR light stops at the filter in step 3)
            ctx.lineTo(I[k][0], I[k][1]); ctx.stroke();
          }
        });
        ctx.globalAlpha = 1; ctx.setLineDash([]);
        I.forEach(([x, y], k) => { ctx.fillStyle = cols[k]; ctx.beginPath(); ctx.arc(x, y, 5, 0, 7); ctx.fill(); });
      }
      // lens: 3 elements
      const hiL = s === 1;
      [[-16, 0.9], [0, 1], [16, 0.8]].forEach(([dx, k], i) => {
        ctx.fillStyle = hiL ? (i === 1 ? 'rgba(196,181,253,.55)' : 'rgba(147,197,253,.55)') : 'rgba(147,197,253,.22)';
        ctx.strokeStyle = hiL ? '#e9e2ff' : 'rgba(196,181,253,.45)'; ctx.lineWidth = 1.2;
        ctx.beginPath(); ctx.ellipse(xL + dx, 0.5 * h, 7, lh * 0.5 * k, 0, 0, 7); ctx.fill(); ctx.stroke();
      });
      text(ctx, 'lens', xL, 0.5 * h + lh * 0.5 + 20, { c: hiL ? TXT : MUT, size: 12, a: 'center' });
      // IR filter
      const hiF = s === 2;
      ctx.fillStyle = hiF ? 'rgba(94,234,212,.6)' : 'rgba(94,234,212,.22)'; ctx.fillRect(xF - 3, 0.5 * h - lh * 0.42, 6, lh * 0.84);
      text(ctx, 'IR filter', xF, 0.5 * h + lh * 0.5 + 20, { c: hiF ? TXT : MUT, size: 12, a: 'center' });
      // sensor
      ctx.fillStyle = '#1f1b23'; ctx.fillRect(xS, 0.5 * h - lh * 0.45, 10, lh * 0.9);
      for (let i = 0; i < 18; i++) { ctx.fillStyle = i % 2 ? '#6b4fa3' : '#8b6fc9'; ctx.fillRect(xS, 0.5 * h - lh * 0.45 + (i * lh * 0.9) / 18, 4, (lh * 0.9) / 18 - 1); }
      text(ctx, 'sensor', xS + 5, 0.5 * h + lh * 0.5 + 20, { c: MUT, size: 12, a: 'center' });
      if (s === 1) text(ctx, 'the image lands upside down', xS - 6, I[1][1] - 16 < 0.2 * h ? I[0][1] + 24 : 0.2 * h + 16, { c: AC, size: 12, a: 'right' });
      if (s === 2) {
        // photons: visible ones pass, IR ones stop at the filter
        for (let i = 0; i < 16; i++) {
          const ir = i % 3 === 0, u = (t * 0.35 + i / 16) % 1, x = xL + 20 + u * (xS - xL - 20), y = 0.5 * h + ((i * 37) % 9 - 4) * lh * 0.08;
          if (ir && x > xF - 4) continue;
          const c = ir ? '#7f1d1d' : ['#60a5fa', '#4ade80', '#facc15', '#fb923c'][i % 4];
          ctx.fillStyle = c; ctx.beginPath(); ctx.arc(x, y, 4, 0, 7); ctx.fill();
          if (ir) { ctx.strokeStyle = '#ef4444'; ctx.lineWidth = 1; ctx.stroke(); }
        }
        // spectrum inset
        const sx = 0.06 * w, sy = 0.9 * h, sw = 0.34 * w, sh = 0.1 * h, nm = (v) => sx + ((v - 400) / 700) * sw;
        for (let v = 400; v < 1100; v += 5) { const c = v < 450 ? '#6d28d9' : v < 490 ? '#2563eb' : v < 560 ? '#16a34a' : v < 590 ? '#eab308' : v < 630 ? '#f97316' : v < 700 ? '#dc2626' : '#3f0d0d'; ctx.fillStyle = c; ctx.fillRect(nm(v), sy - 6, sw / 140 + 0.5, 6); }
        const T = (v) => (v < 430 ? 0.5 + (v - 400) / 60 * 0.8 : v <= 620 ? 0.9 : v < 700 ? 0.9 - ((v - 620) / 80) * 0.87 : 0.03);
        ctx.strokeStyle = '#5eead4'; ctx.lineWidth = 2; ctx.beginPath();
        for (let v = 400; v <= 1100; v += 5) { const x = nm(v), y = sy - 10 - T(v) * sh; v === 400 ? ctx.moveTo(x, y) : ctx.lineTo(x, y); }
        ctx.stroke();
        text(ctx, '400', sx, sy + 13, { c: MUT, size: 10, mono: true }); text(ctx, '700', nm(700), sy + 13, { c: MUT, size: 10, mono: true, a: 'center' }); text(ctx, '1100 nm', sx + sw, sy + 13, { c: MUT, size: 10, mono: true, a: 'right' });
        text(ctx, 'visible passes', nm(520), sy - sh - 16, { c: '#5eead4', size: 11, a: 'center' }); text(ctx, 'infrared blocked', nm(900), sy - 22, { c: '#fca5a5', size: 11, a: 'center' });
      }
    };
    // pixel buckets: 8 x 6 pixels over part of the tag
    const bucketVal = (x, y) => (tagG[2 + y][1 + x] ? 0.92 : 0.08);
    const buckets = (ctx, w, h, t, read) => {
      const cols = 8, rows = 6, bw = Math.min(0.8 * w / cols, 0.62 * h / rows) * 0.8, gap = bw * 0.25, ox = (w - cols * (bw + gap)) / 2 - (read ? 0.08 * w : 0), oy = 0.2 * h;
      const cycle = 5, ph = (t % cycle) / cycle, fill = read ? 1 : Math.min(1, ph / 0.7);
      const readRow = read ? Math.floor(ph * (rows + 1.5)) : -1;
      if (!read) {
        ctx.fillStyle = 'rgba(253,230,138,.8)';
        drops.forEach((d) => {
          const cx = Math.floor(d.x * cols), cy = Math.floor(d.y * rows), v = bucketVal(cx, cy);
          if (r() > v + 0.05 || ph > 0.7) return;
          const x = ox + cx * (bw + gap) + bw * (0.2 + 0.6 * ((d.x * cols) % 1)), yy = oy + cy * (bw + gap) - bw * 0.9 + ((t * d.s * 1.6 + d.y) % 1) * bw;
          ctx.fillRect(x, yy, 2, 6);
        });
      }
      for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
        const px = ox + x * (bw + gap), py = oy + y * (bw + gap), v = bucketVal(x, y);
        let lvl = v * fill;
        if (read && y < readRow) lvl = 0;
        ctx.strokeStyle = read && y === readRow ? '#f59e0b' : 'rgba(196,181,253,.6)'; ctx.lineWidth = read && y === readRow ? 2.5 : 1.2;
        ctx.beginPath(); ctx.roundRect(px, py, bw, bw, 4); ctx.stroke();
        ctx.fillStyle = 'rgba(96,165,250,.85)'; ctx.fillRect(px + 2, py + bw - 2 - (bw - 4) * lvl, bw - 4, (bw - 4) * lvl);
        if (read && y < readRow) text(ctx, String(Math.round(v * 255)), px + bw / 2, py + bw / 2 + 5, { mono: true, size: Math.max(10, bw * 0.32), a: 'center', c: v > 0.5 ? '#fff' : MUT });
      }
      const bottom = oy + rows * (bw + gap);
      if (!read) {
        text(ctx, ph <= 0.7 ? 'exposure: collecting light…' : 'exposure over: every pixel stops at once', w / 2, bottom + 22, { c: AC, size: 13, a: 'center' });
        text(ctx, 'blue = electrons stored in each pixel', w / 2, bottom + 42, { c: MUT, size: 12, a: 'center' });
      } else {
        const ax = ox + cols * (bw + gap) + 0.04 * w, ay = oy + Math.min(readRow, rows - 1) * (bw + gap) + bw / 2;
        ctx.fillStyle = '#251038'; ctx.strokeStyle = '#8b5cf6'; ctx.lineWidth = 2; ctx.beginPath(); ctx.roundRect(ax, ay - 22, 0.13 * w, 44, 8); ctx.fill(); ctx.stroke();
        text(ctx, 'ADC', ax + 0.065 * w, ay + 5, { a: 'center', w: 700 });
        text(ctx, 'reading row by row → numbers 0–255', w / 2, bottom + 22, { c: AC, size: 13, a: 'center' });
      }
    };
    const numbers = (ctx, w, h) => {
      const rows = patch.length, cols = patch[0].length, cs = Math.min((0.92 * w) / cols, (0.8 * h) / rows), ox = (w - cols * cs) / 2, oy = (h - rows * cs) / 2 - 8;
      patch.forEach((row, y) => row.forEach((v, x) => { ctx.fillStyle = `rgb(${v},${v},${v})`; ctx.fillRect(ox + x * cs, oy + y * cs, cs - 1, cs - 1); text(ctx, String(v), ox + x * cs + cs / 2, oy + y * cs + cs / 2 + 4, { mono: true, size: Math.max(9, cs * 0.3), a: 'center', c: v > 120 ? '#1f1b23' : '#f4efff', w: 500 }); }));
      text(ctx, 'real pixel values from our camera, at a tag corner', w / 2, oy + rows * cs + 22, { c: AC, size: 12, a: 'center' });
    };
    const jpeg = (ctx, w, h, t) => {
      const iw = 0.46 * w, ih = iw * (64 / 96), ox = 0.05 * w, oy = 0.12 * h;
      ctx.imageSmoothingEnabled = false; ctx.drawImage(tagCrop, ox, oy, iw, ih); ctx.imageSmoothingEnabled = true;
      ctx.strokeStyle = 'rgba(139,92,246,.8)'; ctx.lineWidth = 1;
      for (let i = 0; i <= 12; i++) { ctx.beginPath(); ctx.moveTo(ox + (i * iw) / 12, oy); ctx.lineTo(ox + (i * iw) / 12, oy + ih); ctx.stroke(); }
      for (let i = 0; i <= 8; i++) { ctx.beginPath(); ctx.moveTo(ox, oy + (i * ih) / 8); ctx.lineTo(ox + iw, oy + (i * ih) / 8); ctx.stroke(); }
      const bi = Math.floor(t * 0.8) % 12, bx = ox + (bi * iw) / 12, by = oy + (3 * ih) / 8;
      ctx.strokeStyle = '#f59e0b'; ctx.lineWidth = 2.5; ctx.strokeRect(bx, by, iw / 12, ih / 8);
      text(ctx, '8 × 8 pixel blocks', ox, oy + ih + 20, { c: MUT, size: 12 });
      // basis patterns
      const gx = 0.58 * w, gs = Math.min(0.36 * w, 0.5 * h) / 4;
      text(ctx, 'blocks are mixes of these', gx, oy - 8, { c: MUT, size: 12 });
      for (let v = 0; v < 4; v++) for (let u = 0; u < 4; u++) {
        const px = gx + u * gs, py = oy + v * gs, n = 8, c = gs / n - 0.2;
        for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) { const val = 128 + 110 * Math.cos(((2 * x + 1) * u * Math.PI) / 16) * Math.cos(((2 * y + 1) * v * Math.PI) / 16); ctx.fillStyle = `rgb(${val},${val},${val})`; ctx.fillRect(px + x * (gs - 3) / n, py + y * (gs - 3) / n, (gs - 3) / n + 0.5, (gs - 3) / n + 0.5); }
        if (u + v > 3) { ctx.fillStyle = 'rgba(14,5,24,.72)'; ctx.fillRect(px, py, gs - 3, gs - 3); }
      }
      text(ctx, 'dimmed: mostly dropped', gx, oy + 4 * gs + 16, { c: AC, size: 12 });
      // size bars
      const sy = 0.8 * h, bw = 0.9 * w;
      ctx.fillStyle = 'rgba(255,255,255,.12)'; ctx.fillRect(ox, sy, bw, 14); text(ctx, 'raw frame: 1,024,000 bytes', ox, sy - 6, { c: MUT, size: 12 });
      ctx.fillStyle = '#8b5cf6'; ctx.fillRect(ox, sy + 34, bw * 0.0516, 14); text(ctx, 'this frame as JPEG: 52,801 bytes (about 1/19)', ox, sy + 30, { c: TXT, size: 12 });
    };
    const usb = (ctx, w, h, t) => {
      const y = 0.38 * h, x0 = 0.2 * w, x1 = 0.78 * w;
      ctx.fillStyle = '#251038'; ctx.strokeStyle = '#8b5cf6'; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.roundRect(0.03 * w, y - 34, 0.15 * w, 68, 10); ctx.fill(); ctx.stroke(); text(ctx, 'camera', 0.105 * w, y + 5, { a: 'center', w: 700 });
      ctx.fillStyle = '#251038'; ctx.beginPath(); ctx.roundRect(0.8 * w, y - 34, 0.17 * w, 68, 10); ctx.fill(); ctx.stroke(); text(ctx, 'Jetson', 0.885 * w, y + 5, { a: 'center', w: 700 });
      ctx.strokeStyle = '#4c3a63'; ctx.lineWidth = 10; ctx.lineCap = 'round'; ctx.beginPath(); ctx.moveTo(x0, y); ctx.lineTo(x1, y); ctx.stroke(); ctx.lineCap = 'butt';
      text(ctx, 'USB 2.0 cable', (x0 + x1) / 2, y - 16, { c: MUT, size: 12, a: 'center' });
      for (let i = 0; i < 9; i++) { const u = (t * 0.5 + i / 9) % 1; ctx.fillStyle = '#c4b5fd'; ctx.fillRect(x0 + u * (x1 - x0) - 6, y - 5, 12, 10); }
      // microframe timeline
      const ty = 0.66 * h, tw = 0.9 * w, tx = 0.05 * w, n = 40, cw = tw / n, lit = Math.floor((t * 8) % (n + 8));
      for (let i = 0; i < n; i++) { ctx.fillStyle = i < lit ? '#8b5cf6' : 'rgba(255,255,255,.1)'; ctx.fillRect(tx + i * cw + 1, ty, cw - 2, 26); }
      text(ctx, 'each box = one 125 µs microframe (1,280 bytes)', tx, ty - 10, { c: MUT, size: 12 });
      text(ctx, `${Math.min(lit, n)} of 39 microframes · ${(Math.min(lit, 39) * 0.125).toFixed(2)} ms`, tx, ty + 48, { c: TXT, size: 13, mono: true });
      text(ctx, '50 KB frame ≈ 39 microframes ≈ 4.9 ms', tx, ty + 72, { c: AC, size: 13 });
    };
    const titles = ['Light bounces off the tag', 'The lens focuses it', 'The IR-cut filter', 'Photons fill the pixels', 'Readout and ADC', 'A grid of numbers', 'JPEG compression', 'Across USB'];
    Site.loop(st.cv, (t) => {
      const { ctx, w, h } = st; ctx.clearRect(0, 0, w, h);
      const tt = t - t0;
      if (step <= 2) optics(ctx, w, h, tt, step);
      else if (step === 3) buckets(ctx, w, h, tt, false);
      else if (step === 4) buckets(ctx, w, h, tt, true);
      else if (step === 5) numbers(ctx, w, h);
      else if (step === 6) jpeg(ctx, w, h, tt);
      else usb(ctx, w, h, tt);
      text(ctx, `${step + 1} / 8 · ${titles[step]}`, 14, 22, { c: AC, size: 12, w: 700 });
    });
    const bg = getComputedStyle(root).backgroundColor;
    $('#c-scrolly .vis').style.background = bg === 'rgba(0, 0, 0, 0)' ? '#fff' : bg;
    Site.scrolly($('#c-scrolly'), (i) => { step = i; t0 = performance.now() / 1000; });
  })();

  /* ── Global vs rolling shutter ─────────────────────────── */
  // Slow motion. One frame period at 30 fps takes FRAME30 seconds on screen; a rolling-shutter
  // sensor spends ~90% of each frame reading its rows out, so its scan (and the lean it causes)
  // shrinks as the frame rate goes up. The global-shutter photo is one instant per frame.
  {
    const N = 100, cvs = [0, 1, 2].map((i) => $('#c-rs' + i)), ctxs = cvs.map((c) => c.getContext('2d'));
    const bufs = [0, 1, 2].map(() => new ImageData(N, N)), small = document.createElement('canvas'); small.width = small.height = N;
    const sctx = small.getContext('2d');
    let mode = 'tag', speed = 1, fps = 30, tau = 0, frameT = 0, lastRow = 0;
    const FRAME30 = 2.0, READ = 0.9, TAG_V = 26, S = 44; // tag speed in image px per unit of scene time; tag size
    const period = () => (FRAME30 * 30) / fps; // on-screen seconds per frame
    const tagG = Site.tagGrid(3);
    // The robot keeps turning left, so the tag sweeps across the view from left to right, leaves,
    // and comes around again after the rest of the turn (the empty stretch, GAP px of scene).
    const GAP = 60;
    const tagX = (tm) => -S + (((tm * TAG_V) % (N + S + GAP)) + N + S + GAP) % (N + S + GAP);
    const scene = (x, y, tm) => {
      if (mode === 'prop') {
        const dx = x - 50, dy = y - 50, rr = Math.hypot(dx, dy), a = Math.atan2(dy, dx) - tm * 2.2;
        if (rr < 6) return [196, 181, 253];
        if (rr < 44 && Math.cos(3 * a) > 0.8 - rr * 0.004) return [244, 239, 255];
        return [26, 10, 43];
      }
      const X = x - tagX(tm), Y = y - 28;
      if (X >= 0 && X < S && Y >= 0 && Y < S) { const c = tagG[Math.floor((Y / S) * 10)][Math.floor((X / S) * 10)]; return c ? [240, 240, 240] : [10, 10, 10]; }
      return [40, 30, 55];
    };
    const paint = (img, y0, y1, tm, dim) => { for (let y = y0; y < y1; y++) for (let x = 0; x < N; x++) { const [r, g, b] = scene(x + 0.5, y + 0.5, tm), i = (y * N + x) * 4; img.data[i] = r * dim; img.data[i + 1] = g * dim; img.data[i + 2] = b * dim; img.data[i + 3] = 255; } };
    const show = (k, img, line) => {
      sctx.putImageData(img, 0, 0); const c = ctxs[k], W = cvs[k].width;
      c.imageSmoothingEnabled = true; c.drawImage(small, 0, 0, W, W);
      if (line != null) { c.fillStyle = '#f59e0b'; c.fillRect(0, (line / N) * W - 1.5, W, 3); }
    };
    const readouts = () => {
      $('#c-rsper').textContent = (1000 / fps).toFixed(1) + ' ms';
      if (mode === 'tag') {
        $('#c-rsmove').textContent = (TAG_V * speed * period()).toFixed(0) + ' px';
        $('#c-rslean').textContent = speed ? (TAG_V * speed * period() * READ * (S / N)).toFixed(1) + ' px' : 'none';
      } else { $('#c-rsmove').textContent = '–'; $('#c-rslean').textContent = speed ? 'blades bend' : 'none'; }
    };
    const restart = () => { frameT = 0; lastRow = 0; paint(bufs[1], 0, N, tau, 1); paint(bufs[2], 0, N, tau, 0.35); readouts(); };
    Site.seg($('#c-rsmode'), (v) => { mode = v; restart(); });
    Site.range($('#c-rsspeed'), (v) => { speed = v; readouts(); }, (v) => v.toFixed(2) + '×');
    Site.range($('#c-rsfps'), (v) => { fps = v; readouts(); }, (v) => v + ' fps');
    Site.loop(cvs[0], (t, dt) => {
      tau += dt * speed;
      paint(bufs[0], 0, N, tau, 1); show(0, bufs[0]);
      frameT += dt;
      const P = period(), scan = P * READ;
      if (frameT >= P) { frameT %= P; lastRow = 0; }
      if (lastRow === 0) { // a new frame: the global shutter catches everything now; the rolling photo starts over
        paint(bufs[1], 0, N, tau, 1);
        for (let i = 0; i < bufs[2].data.length; i += 4) { bufs[2].data[i] *= 0.35; bufs[2].data[i + 1] *= 0.35; bufs[2].data[i + 2] *= 0.35; }
        lastRow = 1e-9;
      }
      const row = Math.min(N, Math.floor((frameT / scan) * N));
      if (row > lastRow) { paint(bufs[2], Math.floor(lastRow), row, tau, 1); lastRow = row; }
      show(1, bufs[1]); show(2, bufs[2], row < N ? row : null);
    });
  }

  /* ── Mono vs Bayer color ──────────────────────────────── */
  (async () => {
    const F = await FRAME, N = 32, cv = [0, 1, 2].map((i) => $('#c-by' + i)), L = new Float32Array(N * N);
    // 32x32 sensor pixels over tag 4's top-left corner (each averages 2x2 frame pixels)
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) { let a = 0; for (let j = 0; j < 2; j++) for (let i = 0; i < 2; i++) a += F.g[(410 + y * 2 + j) * F.W + 395 + x * 2 + i]; L[y * N + x] = Math.min(1, a / 4 / 200); }
    const r = rng(21), z1 = Array.from({ length: N * N }, () => gauss(r)), z2 = Array.from({ length: N * N }, () => gauss(r));
    const filt = (x, y) => (y % 2 === 0 ? (x % 2 === 0 ? 1 : 0) : x % 2 === 0 ? 2 : 1); // 0 R, 1 G, 2 B (RGGB)
    const put = (c, px) => { const x = c.getContext('2d'), id = x.createImageData(N, N); px.forEach((p, i) => { id.data[i * 4] = p[0]; id.data[i * 4 + 1] = p[1]; id.data[i * 4 + 2] = p[2]; id.data[i * 4 + 3] = 255; }); x.putImageData(id, 0, 0); };
    Site.range($('#c-bylight'), (light) => {
      const full = 400 * light * light; // photons a white pixel collects (shot noise = sqrt of the count)
      const mono = [], raw = [], rv = new Float32Array(N * N);
      for (let i = 0; i < N * N; i++) {
        const n = full * L[i], m = (n + Math.sqrt(n + 4) * z1[i]) / full; // mono: all the light
        const nc = n / 3, c = (3 * (nc + Math.sqrt(nc + 4) * z2[i])) / full; // color: ~1/3 of the light, brightened 3x
        const v = Site.clamp(m, 0, 1) * 255; mono.push([v, v, v]);
        rv[i] = Site.clamp(c, 0, 1);
        const f = filt(i % N, Math.floor(i / N)), q = rv[i] * 255; raw.push([f === 0 ? q : 0, f === 1 ? q : 0, f === 2 ? q : 0]);
      }
      // bilinear demosaic: each missing color is the average of the neighbours that have it
      const dem = [];
      for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
        const s = [0, 0, 0], n = [0, 0, 0];
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const X = x + dx, Y = y + dy; if (X < 0 || Y < 0 || X >= N || Y >= N) continue; const f = filt(X, Y); if (f === filt(x, y) && (dx || dy)) continue; s[f] += rv[Y * N + X]; n[f]++; }
        dem.push(s.map((v, k) => Site.clamp(v / Math.max(1, n[k]), 0, 1) * 255));
      }
      put(cv[0], mono); put(cv[1], raw); put(cv[2], dem);
    }, (v) => Math.round(v * 100) + '%');
  })();

  /* ── JPEG lab ──────────────────────────────────────────── */
  (async () => {
    const F = await FRAME, W = F.W, H = F.H, BW = W / 8, BH = H / 8;
    const cv = $('#c-jpg'), zc = $('#c-jpgz'); cv.width = W; cv.height = H; zc.width = zc.height = 384;
    const ctx = cv.getContext('2d'), zctx = zc.getContext('2d');
    const C = Array.from({ length: 8 }, (_, u) => Array.from({ length: 8 }, (_, x) => (u ? Math.sqrt(2 / 8) : Math.sqrt(1 / 8)) * Math.cos(((2 * x + 1) * u * Math.PI) / 16)));
    const Q50 = [16,11,10,16,24,40,51,61,12,12,14,19,26,58,60,55,14,13,16,24,40,57,69,56,14,17,22,29,51,87,80,62,18,22,37,56,68,109,103,77,24,35,55,64,81,104,113,92,49,64,78,87,103,121,120,101,72,92,95,98,112,100,103,99];
    // forward DCT of every block, once
    const coef = new Float32Array(W * H), tmp = new Float32Array(64), blk = new Float32Array(64);
    for (let by = 0; by < BH; by++) for (let bx = 0; bx < BW; bx++) {
      for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) blk[y * 8 + x] = F.g[(by * 8 + y) * W + bx * 8 + x] - 128;
      for (let y = 0; y < 8; y++) for (let u = 0; u < 8; u++) { let s = 0; for (let x = 0; x < 8; x++) s += C[u][x] * blk[y * 8 + x]; tmp[y * 8 + u] = s; }
      const o = (by * BW + bx) * 64;
      for (let u = 0; u < 8; u++) for (let v = 0; v < 8; v++) { let s = 0; for (let y = 0; y < 8; y++) s += C[v][y] * tmp[y * 8 + u]; coef[o + v * 8 + u] = s; }
    }
    const out = ctx.createImageData(W, H), qv = new Float32Array(64);
    const run = (q) => {
      const sc = q < 50 ? 5000 / q : 200 - 2 * q, Q = Q50.map((v) => Math.max(1, Math.floor((v * sc + 50) / 100)));
      let bits = 0, nz = 0, prevDC = 0;
      for (let b = 0; b < BW * BH; b++) {
        const o = b * 64;
        for (let k = 0; k < 64; k++) { const v = Math.round(coef[o + k] / Q[k]); qv[k] = v * Q[k]; if (v) { nz++; if (k) bits += 5 + Math.floor(Math.log2(Math.abs(v))) + 1; } }
        const dc = Math.round(coef[o] / Q[0]), d = dc - prevDC; prevDC = dc; bits += 3 + (d ? Math.floor(Math.log2(Math.abs(d))) + 1 : 0) + 4; // DC + end of block
        // inverse DCT
        for (let v = 0; v < 8; v++) for (let x = 0; x < 8; x++) { let s = 0; for (let u = 0; u < 8; u++) s += C[u][x] * qv[v * 8 + u]; tmp[v * 8 + x] = s; }
        const bx = b % BW, by = Math.floor(b / BW);
        for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) { let s = 0; for (let v = 0; v < 8; v++) s += C[v][y] * tmp[v * 8 + x]; const i = ((by * 8 + y) * W + bx * 8 + x) * 4, p = s + 128; out.data[i] = out.data[i + 1] = out.data[i + 2] = p; out.data[i + 3] = 255; }
      }
      ctx.putImageData(out, 0, 0);
      zctx.imageSmoothingEnabled = false; zctx.drawImage(cv, 440, 448, 48, 48, 0, 0, 384, 384);
      zctx.strokeStyle = 'rgba(245,158,11,.75)'; zctx.lineWidth = 1.5;
      for (let i = 0; i <= 6; i++) { zctx.beginPath(); zctx.moveTo(i * 64, 0); zctx.lineTo(i * 64, 384); zctx.moveTo(0, i * 64); zctx.lineTo(384, i * 64); zctx.stroke(); }
      const kb = bits / 8 / 1000;
      $('#c-jkb').textContent = '≈ ' + Math.round(kb) + ' KB';
      $('#c-jnz').textContent = ((100 * nz) / (W * H)).toFixed(1) + '%';
      $('#c-jbar').style.width = Math.min(100, kb / 10) + '%';
    };
    let pend = 0;
    Site.range($('#c-q'), (q) => { cancelAnimationFrame(pend); pend = requestAnimationFrame(() => run(q)); });
  })();

  /* ── Field of view vs range ────────────────────────────── */
  {
    const st = Site.canvas($('#c-fov'), 0.62);
    let f = 2.21;
    const draw = () => {
      const { ctx, w, h } = st, hf = Math.atan(1.92 / f), fpx = f / 0.003, range = (fpx * 0.1651) / 8 / 2, M = 16, k = (w - 50) / M, cx = 26, cy = h / 2;
      ctx.clearRect(0, 0, w, h); ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.12)'; ctx.lineWidth = 1; ctx.font = '10px JetBrains Mono, monospace'; ctx.fillStyle = '#b8a9d4';
      for (let m = 2; m <= M; m += 2) { const x = cx + m * k; ctx.beginPath(); ctx.moveTo(x, 12); ctx.lineTo(x, h - 18); ctx.stroke(); ctx.fillText(m + ' m', x - 10, h - 5); }
      // view wedge, bright up to the readable range
      const L = (w + h) / Math.cos(hf);
      const wedge = (len, fill) => { ctx.fillStyle = fill; ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + Math.cos(hf) * len, cy - Math.sin(hf) * len); ctx.lineTo(cx + Math.cos(hf) * len, cy + Math.sin(hf) * len); ctx.closePath(); ctx.fill(); };
      wedge(L, 'rgba(139,92,246,.12)');
      ctx.save(); ctx.beginPath(); ctx.rect(0, 0, cx + range * k, h); ctx.clip(); wedge(L, 'rgba(163,230,53,.18)'); ctx.restore();
      ctx.strokeStyle = '#a3e635'; ctx.setLineDash([5, 5]); ctx.beginPath(); ctx.moveTo(cx + range * k, 10); ctx.lineTo(cx + range * k, h - 20); ctx.stroke(); ctx.setLineDash([]);
      ctx.fillStyle = '#a3e635'; ctx.font = '600 12px Plus Jakarta Sans, sans-serif'; ctx.textAlign = cx + range * k > w - 90 ? 'right' : 'left';
      ctx.fillText('tags readable to here', cx + range * k + (ctx.textAlign === 'left' ? 6 : -6), 24); ctx.textAlign = 'left';
      // tags along the middle
      for (let m = 2; m <= 14; m += 2) { const x = cx + m * k, ok = m <= range; ctx.fillStyle = ok ? '#a3e635' : '#f43f5e'; ctx.fillRect(x - 3, cy - 8, 6, 16); }
      ctx.fillStyle = '#c4b5fd'; ctx.fillRect(cx - 14, cy - 9, 14, 18);
      $('#c-hfov').textContent = ((2 * hf * 180) / Math.PI).toFixed(0) + '°';
      $('#c-fpx').textContent = Math.round(fpx) + ' px';
      $('#c-range').textContent = range.toFixed(1) + ' m';
    };
    Site.range($('#c-f'), (v) => { f = v; draw(); }, (v) => v.toFixed(2) + ' mm');
    new ResizeObserver(draw).observe(st.cv);
  }

  /* ── Focus lab ─────────────────────────────────────────── */
  (async () => {
    let redraw = () => {}; // repaint when the lab is shown (it starts hidden in short mode)
    const F = await FRAME, W = 320, H = 180, st = Site.canvas($('#c-focus'), H / W, () => redraw());
    // the frame's middle, at quarter size
    const base = new Float32Array(W * H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { let a = 0; for (let j = 0; j < 2; j++) for (let i = 0; i < 2; i++) a += F.g[(290 + y * 2 + j) * F.W + 170 + x * 2 + i]; base[y * W + x] = a / 4; }
    const r = rng(9), noise = Float32Array.from({ length: W * H }, () => gauss(r) * 1.6);
    const boxBlur = (src, rad) => { // two passes of a separable box blur ≈ a soft defocus
      if (rad < 0.5) return src.slice();
      const R = Math.round(rad), a = new Float32Array(W * H), b = new Float32Array(W * H);
      for (let pass = 0; pass < 2; pass++) {
        const s = pass ? b : src;
        for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { let acc = 0, n = 0; for (let d = -R; d <= R; d++) { const X = x + d; if (X >= 0 && X < W) { acc += s[y * W + X]; n++; } } a[y * W + x] = acc / n; }
        for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { let acc = 0, n = 0; for (let d = -R; d <= R; d++) { const Y = y + d; if (Y >= 0 && Y < H) { acc += a[Y * W + x]; n++; } } b[y * W + x] = acc / n; }
      }
      return b;
    };
    const grid = $('#c-fgrid'); for (let i = 0; i < 9; i++) grid.insertAdjacentHTML('beforeend', '<div></div>');
    let lens = 25, tilt = false, best = Array(9).fill(0);
    const img = document.createElement('canvas'); img.width = W; img.height = H;
    const draw = () => {
      const bestAt = (col) => 62 + (tilt ? (col - 1) * 14 : 0);
      const cache = {}, pix = new Float32Array(W * H);
      for (let col = 0; col < 3; col++) {
        const rad = Math.abs(lens - bestAt(col)) * 0.16, key = Math.round(rad);
        const b = cache[key] || (cache[key] = boxBlur(base, rad));
        for (let y = 0; y < H; y++) for (let x = Math.floor((col * W) / 3); x < Math.floor(((col + 1) * W) / 3); x++) pix[y * W + x] = b[y * W + x] + noise[y * W + x];
      }
      // focus score: variance of the Laplacian, per cell of a 3x3 grid (like photonvision-34)
      const score = [];
      for (let cy = 0; cy < 3; cy++) for (let cx = 0; cx < 3; cx++) {
        let s = 0, s2 = 0, n = 0;
        for (let y = Math.max(1, Math.floor((cy * H) / 3)); y < Math.min(H - 1, Math.floor(((cy + 1) * H) / 3)); y++) for (let x = Math.max(1, Math.floor((cx * W) / 3)); x < Math.min(W - 1, Math.floor(((cx + 1) * W) / 3)); x++) {
          const i = y * W + x, l = pix[i - 1] + pix[i + 1] + pix[i - W] + pix[i + W] - 4 * pix[i]; s += l; s2 += l * l; n++;
        }
        score.push(s2 / n - (s / n) ** 2);
      }
      best = best.map((b, i) => Math.max(b, score[i]));
      const x = img.getContext('2d'), id = x.createImageData(W, H);
      for (let i = 0; i < W * H; i++) { const v = pix[i]; id.data[i * 4] = id.data[i * 4 + 1] = id.data[i * 4 + 2] = v; id.data[i * 4 + 3] = 255; }
      x.putImageData(id, 0, 0);
      const { ctx, w, h } = st; ctx.drawImage(img, 0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.5)'; ctx.lineWidth = 1;
      for (let i = 1; i < 3; i++) { ctx.beginPath(); ctx.moveTo((i * w) / 3, 0); ctx.lineTo((i * w) / 3, h); ctx.moveTo(0, (i * h) / 3); ctx.lineTo(w, (i * h) / 3); ctx.stroke(); }
      const pct = score.map((s, i) => Math.round((100 * s) / best[i]));
      [...grid.children].forEach((d, i) => { d.textContent = pct[i] + '%'; d.style.color = pct[i] >= 97 ? '#a3e635' : pct[i] >= 85 ? '#f59e0b' : '#fb7185'; });
      $('#c-fscore').textContent = 'Center ' + pct[4] + '%';
    };
    // start as if the lens had been swept once, so the percentages mean something right away
    const keep = lens; for (let v = 0; v <= 100; v += 4) { lens = v; draw(); } lens = keep;
    Site.range($('#c-lens'), (v) => { lens = v; draw(); }, (v) => v.toFixed(0));
    redraw = draw;
    $('#c-freset').onclick = () => { best = Array(9).fill(0); draw(); };
    $('#c-tilt').onchange = (e) => { tilt = e.target.checked; best = Array(9).fill(0); draw(); };
  })();
});
