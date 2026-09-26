import * as THREE from 'three';
import { OrbitControls } from 'three/addons/OrbitControls.js';

/* Chapter 19: coordinate systems.
   Everything is computed in WPILib's frames (x forward, y left, z up; metres, radians).
   The 3D lab puts all objects inside a group rotated -90° about x, so three.js's y-up world
   shows WPILib's z-up frame without converting every point. */

Site.chapter('coords', (root) => {
  const $ = (s) => root.querySelector(s);
  const D2R = Math.PI / 180, R2D = 180 / Math.PI;
  const LAB = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', AMBER = '#f59e0b', GREEN = '#a3e635', LAV = '#c4b5fd';
  const wrapDeg = (a) => ((((a + 180) % 360) + 360) % 360) - 180;
  const later = (fn) => () => requestAnimationFrame(fn);

  /* ── The mount lab (three.js) ─────────────────────────── */
  {
    const wrap = $('#co-3d');
    let renderer = null;
    try { renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true }); } catch (e) { renderer = null; }
    const S = { x: 0.26, y: 0.26, z: 0.45, yaw: 30, p: -15, r: 0, mis: 'none', cv: false };

    // Pose math on THREE.Matrix4, in WPILib coordinates. Euler order 'ZYX' gives Rz·Ry·Rx,
    // which is exactly WPILib's Rotation3d(roll, pitch, yaw).
    const mk = (x, y, z, roll, pitch, yaw) => new THREE.Matrix4().compose(new THREE.Vector3(x, y, z), new THREE.Quaternion().setFromEuler(new THREE.Euler(roll, pitch, yaw, 'ZYX')), new THREE.Vector3(1, 1, 1));
    const truthR2C = () => mk(S.x, S.y, S.z, S.r * D2R, S.p * D2R, S.yaw * D2R);
    // What robot code believes the mount is, for each mistake.
    const believed = () => {
      if (S.mis === 'pitch') return mk(S.x, S.y, S.z, S.r * D2R, -S.p * D2R, S.yaw * D2R);
      if (S.mis === 'lr') return mk(S.x, -S.y, S.z, -S.r * D2R, S.p * D2R, -S.yaw * D2R);
      if (S.mis === 'deg') return mk(S.x, S.y, S.z, S.r, S.p, S.yaw); // degrees typed where radians belong
      return truthR2C();
    };
    // The robot really sits at the origin, so the camera's field pose (from the tags) is robotToCamera.
    // Robot code walks back: robot = camera · believed⁻¹ (or · believed, if it forgot .inverse()).
    const estimate = () => {
      const cam = truthR2C();
      if (S.mis === 'inv') return cam.clone().multiply(truthR2C());
      return cam.clone().multiply(believed().clone().invert());
    };

    const n3 = (v) => (Math.abs(v) < 0.0005 ? '0' : v.toFixed(Math.abs(v) >= 10 ? 1 : 3).replace(/\.?0+$/, '') || '0');
    const m2 = (v) => { const s = v.toFixed(2); return s === '-0.00' ? '0.00' : s; };
    // one angle argument: Units.degreesToRadians(d), or the raw number for the "Degrees" mistake;
    // bad marks the part that's wrong
    const ang = (d, bad) => {
      if (Math.abs(d) < 0.01) return '0';
      if (S.mis === 'deg') return `<span class="bad">${d}</span>`;
      return `Units.degreesToRadians(${bad ? `<span class="bad">${d}</span>` : d})`;
    };
    const code = () => {
      const m = S.mis, lr = m === 'lr';
      const rr = lr ? -S.r : S.r, rp = m === 'pitch' ? -S.p : S.p, ry = lr ? -S.yaw : S.yaw, y = lr ? -S.y : S.y;
      const yStr = lr && Math.abs(S.y) > 0.004 ? `<span class="bad">${m2(y)}</span>` : m2(y);
      const rollS = ang(rr, lr), pitchS = ang(rp, m === 'pitch'), yawS = ang(ry, lr);
      const rad = [rr, rp, ry].map((d) => n3(m === 'deg' ? d : d * D2R));
      let s = `<span class="c">// robot centre (on the floor) → camera lens. Metres; radians.</span>
Transform3d robotToCamera = <span class="k">new</span> Transform3d(
    <span class="k">new</span> Translation3d(${m2(S.x)}, ${yStr}, ${m2(S.z)}),
    <span class="k">new</span> Rotation3d(${rollS}, ${pitchS}, ${yawS}));
<span class="c">// = Rotation3d(${rad.join(', ')}) in radians</span>
`;
      s += m === 'inv'
        ? `\n<span class="c">// camera pose on the field → robot pose</span>\nPose3d robot = cameraPose.transformBy(<span class="bad">robotToCamera</span>);  <span class="c">// no .inverse()!</span>`
        : `\n<span class="c">// camera pose on the field → robot pose (PhotonLib does this)</span>\nPose3d robot = cameraPose.transformBy(robotToCamera.inverse());`;
      return s;
    };
    const WHY = {
      none: 'Correct. The camera\'s pose on the field, walked back through robotToCamera.inverse(), lands exactly on the robot.',
      pitch: 'The camera is tilted up, so its pitch is negative. With the sign flipped, robot code thinks it tips down, and walks back from the camera at the wrong angle: the robot comes out tilted by twice the pitch, shifted, and off the floor.',
      lr: 'y and yaw have the wrong sign: left and right mixed up. Robot code puts the camera on the wrong side, so the robot comes out turned by twice the camera\'s yaw, and moved.',
      deg: 'Rotation3d takes radians. Typing the degree numbers straight in turns "-15" into −15 radians, about −860°, so the robot ends up pointing somewhere random. Wrap degrees in Units.degreesToRadians().',
      inv: 'robotToCamera goes from the robot to the camera. To get from the camera back to the robot you need its inverse. Without it, robot code steps forward from the camera instead of back, so the robot lands twice as far away and turned twice as much.',
    };

    let render = () => {};
    const update = () => {
      $('#co-code').innerHTML = code();
      const why = $('#co-why'); why.textContent = WHY[S.mis]; why.className = 'why ' + (S.mis === 'none' ? 'ok' : 'bad');
      const E = estimate().elements; // column-major
      const exy = Math.hypot(E[12], E[13]), eh = wrapDeg(Math.atan2(E[1], E[0]) * R2D), ez = E[14], tilt = Math.acos(Site.clamp(E[10], -1, 1)) * R2D;
      const set = (id, txt, bad) => { const e = $(id); e.textContent = txt; e.style.color = bad ? AMBER : (S.mis === 'none' ? GREEN : ''); };
      set('#co-e-xy', exy < 1 ? (exy * 100).toFixed(1) + ' cm' : exy.toFixed(2) + ' m', exy > 0.02);
      set('#co-e-h', eh.toFixed(1) + '°', Math.abs(eh) > 1);
      set('#co-e-z', (ez * 100).toFixed(1) + ' cm', Math.abs(ez) > 0.02);
      set('#co-e-t', tilt.toFixed(1) + '°', tilt > 1);
      scene3d && scene3d();
      render();
    };

    let scene3d = null;
    if (!renderer) {
      wrap.innerHTML = '<p class="hint" style="padding:18px">This 3D view needs WebGL, which this browser has turned off. The Java and the numbers below still work.</p>';
      wrap.style.aspectRatio = 'auto';
    } else {
      renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
      wrap.prepend(renderer.domElement);
      const scene = new THREE.Scene();
      const cam = new THREE.PerspectiveCamera(40, 1.6, 0.05, 50);
      const W2T = (x, y, z) => new THREE.Vector3(x, z, -y);
      cam.position.copy(W2T(-1.25, -1.75, 1.35));
      const controls = new OrbitControls(cam, renderer.domElement);
      controls.target.copy(W2T(0.1, 0.05, 0.25)); controls.maxPolarAngle = Math.PI * 0.49; controls.minDistance = 0.9; controls.maxDistance = 6; controls.enablePan = false;
      controls.update();
      scene.add(new THREE.HemisphereLight(0xe9ddf7, 0x1a0a2b, 1.6));
      const dl = new THREE.DirectionalLight(0xffffff, 1.3); dl.position.set(3, 6, 2); scene.add(dl);
      const world = new THREE.Group(); world.rotation.x = -Math.PI / 2; scene.add(world); // WPILib frame inside

      // floor and grid (10 cm cells)
      const floor = new THREE.Mesh(new THREE.PlaneGeometry(4, 4), new THREE.MeshStandardMaterial({ color: 0x241536, roughness: 1 }));
      world.add(floor);
      const grid = new THREE.GridHelper(4, 40, 0x4a3270, 0x33224d); grid.rotation.x = Math.PI / 2; grid.position.z = 0.001; world.add(grid);

      // a text sprite sized to its text; h is the label's height in metres
      const label = (text, color, h = 0.06) => {
        const c = document.createElement('canvas'), x = c.getContext('2d'), font = '700 30px Plus Jakarta Sans, sans-serif';
        x.font = font; c.width = Math.ceil(x.measureText(text).width + 24); c.height = 48;
        x.font = font; x.fillStyle = 'rgba(14,5,24,.8)'; x.fillRect(0, 0, c.width, c.height); x.fillStyle = color; x.textAlign = 'center'; x.fillText(text, c.width / 2, 35);
        const tex = new THREE.CanvasTexture(c); tex.colorSpace = THREE.SRGBColorSpace;
        const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false })); sp.scale.set(h * c.width / c.height, h, 1); sp.renderOrder = 20; return sp;
      };
      const onTop = (o) => o.traverse((m) => { if (m.material) { m.material.depthTest = false; m.material.transparent = true; } m.renderOrder = 10; });
      // three arrows along the parent's local axes; dirs lets the OpenCV version point elsewhere
      const axes = (len, dirs = [[1, 0, 0], [0, 1, 0], [0, 0, 1]], names) => {
        const g = new THREE.Group();
        [0xef4444, 0x22c55e, 0x3b82f6].forEach((c, i) => {
          const d = new THREE.Vector3(...dirs[i]);
          g.add(new THREE.ArrowHelper(d, new THREE.Vector3(), len, c, len * 0.22, len * 0.12));
          if (names) { const l = label(names[i], ['#fca5a5', '#86efac', '#93c5fd'][i], len * 0.13); l.position.copy(d.clone().multiplyScalar(len * 1.22)); if (i === 2) l.position.set(0, -len * 0.3, len * 0.85); g.add(l); } // z label off to the right, clear of a camera mounted above
        });
        onTop(g); return g;
      };

      // the robot: origin at its centre on the floor
      const robot = new THREE.Group(); world.add(robot);
      const body = new THREE.Mesh(new THREE.BoxGeometry(0.8, 0.8, 0.14), new THREE.MeshStandardMaterial({ color: 0x6b1199, roughness: 0.6, transparent: true, opacity: 0.55 }));
      body.position.z = 0.1; robot.add(body);
      const top = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.7, 0.02), new THREE.MeshStandardMaterial({ color: 0x2a1840, transparent: true, opacity: 0.6 }));
      top.position.z = 0.18; robot.add(top);
      const arrow = new THREE.Mesh(new THREE.ConeGeometry(0.07, 0.18, 3), new THREE.MeshStandardMaterial({ color: 0xffffff })); arrow.rotation.z = -Math.PI / 2; arrow.position.set(0.3, 0, 0.2); robot.add(arrow);
      robot.add(axes(0.55, undefined, ['x forward', 'y left', 'z up']));
      const lo = label('robot origin: centre, on the floor', '#c4b5fd', 0.055); lo.position.set(0, -0.52, 0.02); robot.add(lo);

      // the mast and the camera rig
      const mast = new THREE.Mesh(new THREE.BoxGeometry(0.025, 0.025, 1), new THREE.MeshStandardMaterial({ color: 0x888899 })); robot.add(mast);
      const rig = new THREE.Group(); robot.add(rig);
      const cbody = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.09, 0.06), new THREE.MeshStandardMaterial({ color: 0x111111 })); rig.add(cbody);
      const lens = new THREE.Mesh(new THREE.CylinderGeometry(0.018, 0.018, 0.02, 16), new THREE.MeshStandardMaterial({ color: 0x4c0070 })); lens.rotation.z = -Math.PI / 2; lens.position.x = 0.034; rig.add(lens);
      // view frustum out to 0.6 m: our cameras see ±41° across and ±28° up/down (fx 737, 1280x800)
      const hx = 640 / 737, hz = 400 / 737, F = 0.6, fpts = [];
      const fc = [[1, hx, hz], [1, -hx, hz], [1, -hx, -hz], [1, hx, -hz]].map(([a, b, c]) => new THREE.Vector3(a * F, b * F, c * F));
      fc.forEach((c, i) => fpts.push(new THREE.Vector3(), c, c, fc[(i + 1) % 4]));
      rig.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(fpts), new THREE.LineBasicMaterial({ color: 0x8b5cf6 })));
      const camAxNWU = axes(0.22, undefined, ['x', 'y', 'z']);
      const camAxCV = axes(0.22, [[0, -1, 0], [0, 0, -1], [1, 0, 0]], ['x right', 'y down', 'z out']);
      rig.add(camAxNWU, camAxCV);
      const lc = label('camera', '#ffffff', 0.04); lc.position.set(0, 0, 0.13); rig.add(lc);

      // the translation, as three legs from the robot origin: x (red), then y (green), then z (blue)
      const leg = (color) => { const l = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineDashedMaterial({ color, dashSize: 0.04, gapSize: 0.025 })); onTop(l); robot.add(l); return l; };
      const legs = [leg(0xef4444), leg(0x22c55e), leg(0x3b82f6)];
      const setLeg = (l, a, b) => { l.geometry.dispose(); l.geometry = new THREE.BufferGeometry().setFromPoints([a, b]); l.computeLineDistances(); };

      // the ghost: where robot code thinks the robot is
      const ghost = new THREE.Group(); ghost.matrixAutoUpdate = false; world.add(ghost);
      const gm = new THREE.LineBasicMaterial({ color: 0xf59e0b });
      const gb = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(0.8, 0.8, 0.14)), gm); gb.position.z = 0.1; ghost.add(gb);
      ghost.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0.1, 0, 0.2), new THREE.Vector3(0.42, 0, 0.2), new THREE.Vector3(0.42, 0, 0.2), new THREE.Vector3(0.32, 0.07, 0.2), new THREE.Vector3(0.42, 0, 0.2), new THREE.Vector3(0.32, -0.07, 0.2)]), gm));
      const gax = axes(0.3); ghost.add(gax);
      const lg = label('robot code\'s robot', '#f59e0b', 0.06); lg.position.set(0, 0, 0.45); ghost.add(lg);

      scene3d = () => {
        rig.position.set(S.x, S.y, S.z);
        rig.rotation.set(S.r * D2R, S.p * D2R, S.yaw * D2R, 'ZYX');
        const mh = Math.max(0.01, S.z - 0.19);
        mast.visible = S.z > 0.2; mast.scale.z = mh; mast.position.set(S.x, S.y, 0.19 + mh / 2 - 0.03);
        camAxNWU.visible = !S.cv; camAxCV.visible = S.cv;
        const o = new THREE.Vector3(), a = new THREE.Vector3(S.x, 0, 0), b = new THREE.Vector3(S.x, S.y, 0), c = new THREE.Vector3(S.x, S.y, S.z);
        setLeg(legs[0], o, a); setLeg(legs[1], a, b); setLeg(legs[2], b, c);
        ghost.visible = S.mis !== 'none';
        ghost.matrix.copy(estimate()); ghost.matrixWorldNeedsUpdate = true;
      };
      render = () => renderer.render(scene, cam);
      const resize = () => { const r = wrap.getBoundingClientRect(); if (!r.width || !r.height) return; renderer.setSize(r.width, r.height, false); cam.aspect = r.width / r.height; cam.updateProjectionMatrix(); render(); };
      controls.addEventListener('change', render);
      new ResizeObserver(resize).observe(wrap);
      renderer.domElement.addEventListener('pointerdown', () => (renderer.domElement.style.cursor = 'grabbing'));
      addEventListener('pointerup', () => (renderer.domElement.style.cursor = 'grab'));
      // the tip fades after the first drag
      const tip = wrap.querySelector('.tip'); controls.addEventListener('start', () => tip && (tip.style.opacity = '0'), { once: true });
      resize();
    }

    const deg = (v) => (v > 0 ? '+' : '') + v + '°';
    Site.range($('#co-x'), (v) => { S.x = v; update(); }, (v) => v.toFixed(2) + ' m');
    Site.range($('#co-y'), (v) => { S.y = v; update(); }, (v) => v.toFixed(2) + ' m');
    Site.range($('#co-z'), (v) => { S.z = v; update(); }, (v) => v.toFixed(2) + ' m');
    Site.range($('#co-yaw'), (v) => { S.yaw = v; update(); }, (v) => deg(v) + (v > 0 ? ' (left)' : v < 0 ? ' (right)' : ''));
    Site.range($('#co-p'), (v) => { S.p = v; update(); }, (v) => deg(v) + (v < 0 ? ' (tilted up)' : v > 0 ? ' (tilted down)' : ''));
    Site.range($('#co-r'), (v) => { S.r = v; update(); }, deg);
    $('#co-cv').addEventListener('change', (e) => { S.cv = e.target.checked; update(); });
    Site.seg($('#co-mis'), (v) => { S.mis = v; update(); });
  }

  /* ── Which way is positive? (2D field) ────────────────────
     Image pixels follow chapter 2's field map: ix = (x + 1.1)·110, iy = (8.49 − y)·110, in a
     2059×980 image. On phones the field stands up, blue at the bottom, the way blue's drivers see it. */
  {
    const cv = $('#co-field'), L = 16.518, W = 8.043, IW = 2059, IH = 980;
    const IX = (x) => (x + 1.1) * 110, IY = (y) => (8.49 - y) * 110;
    const img = new Image();
    const S = { mode: 'explore', ex: { x: 3.0, y: 2.0, h: 45 }, q: null, pick: -1, right: 0, n: 0 };
    let st = null, M = [1, 0, 0, 1, 0, 0], sc = 1, vert = false;
    const toScreen = (ix, iy) => [M[0] * ix + M[2] * iy + M[4], M[1] * ix + M[3] * iy + M[5]];
    const fromScreen = (u, v) => { const ix = vert ? IW - v / sc : u / sc, iy = vert ? u / sc : v / sc; return [ix / 110 - 1.1, 8.49 - iy / 110]; };
    const r1 = (v) => (Math.round(v * 10) / 10).toFixed(1);
    const poseStr = (x, y, h) => `new Pose2d(${r1(x)}, ${r1(y)}, Rotation2d.fromDegrees(${Math.round(wrapDeg(h))}))`;

    const robotAt = (ctx, x, y, h, style) => {
      ctx.save(); ctx.translate(IX(x), IY(y)); ctx.rotate(-h * D2R);
      const s = 0.9 * 110 / 2, lw = 2.2 / sc;
      if (style === 'ghost' || style === 'wrong') {
        ctx.setLineDash(style === 'ghost' ? [10 / sc, 7 / sc] : []); ctx.strokeStyle = style === 'ghost' ? '#ef4444' : AMBER; ctx.lineWidth = lw * 1.3;
        ctx.strokeRect(-s, -s, 2 * s, 2 * s); ctx.setLineDash([]);
        ctx.beginPath(); ctx.moveTo(-s * 0.2, 0); ctx.lineTo(s * 0.75, 0); ctx.moveTo(s * 0.45, -s * 0.3); ctx.lineTo(s * 0.75, 0); ctx.lineTo(s * 0.45, s * 0.3); ctx.stroke();
      } else {
        ctx.fillStyle = 'rgba(107,17,153,.92)'; ctx.strokeStyle = '#fff'; ctx.lineWidth = lw; ctx.fillRect(-s, -s, 2 * s, 2 * s); ctx.strokeRect(-s, -s, 2 * s, 2 * s);
        ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.moveTo(s * 0.8, 0); ctx.lineTo(-s * 0.2, -s * 0.45); ctx.lineTo(-s * 0.2, s * 0.45); ctx.closePath(); ctx.fill();
      }
      ctx.restore();
    };
    const arrow = (ctx, a, b, color, w) => {
      const ang = Math.atan2(b[1] - a[1], b[0] - a[0]), hl = 11 * w / 3;
      ctx.strokeStyle = ctx.fillStyle = color; ctx.lineWidth = w; ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0] - Math.cos(ang) * hl * 0.6, b[1] - Math.sin(ang) * hl * 0.6); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(b[0], b[1]); ctx.lineTo(b[0] - hl * Math.cos(ang - 0.45), b[1] - hl * Math.sin(ang - 0.45)); ctx.lineTo(b[0] - hl * Math.cos(ang + 0.45), b[1] - hl * Math.sin(ang + 0.45)); ctx.closePath(); ctx.fill();
    };
    const text = (ctx, t, ix, iy, color, align = 'center', font = '700 12px Plus Jakarta Sans') => {
      const [u, v] = toScreen(ix, iy); ctx.font = font; ctx.textAlign = align; ctx.fillStyle = color; ctx.fillText(t, u, v); ctx.textAlign = 'left';
    };

    const draw = () => {
      if (!st || !st.w || !st.h) return;
      const { ctx, w, h } = st;
      vert = h > w * 1.2;
      sc = vert ? w / IH : w / IW;
      M = vert ? [0, -sc, sc, 0, 0, IW * sc] : [sc, 0, 0, sc, 0, 0];
      ctx.setTransform(st.dpr, 0, 0, st.dpr, 0, 0);
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.save(); ctx.transform(...M);
      // carpet, alliance zones, centre line, then the field drawing
      ctx.fillStyle = '#c9c6cf'; ctx.fillRect(IX(0), IY(W), L * 110, W * 110);
      ctx.fillStyle = 'rgba(59,130,246,.22)'; ctx.fillRect(IX(0), IY(W), 4.03 * 110, W * 110);
      ctx.fillStyle = 'rgba(239,68,68,.2)'; ctx.fillRect(IX(L - 4.03), IY(W), 4.03 * 110, W * 110);
      if (img.complete && img.naturalWidth) ctx.drawImage(img, 0, 0, IW, IH);
      // 1 m grid
      ctx.strokeStyle = 'rgba(76,0,112,.16)'; ctx.lineWidth = 1 / sc;
      for (let x = 1; x < L; x++) { ctx.beginPath(); ctx.moveTo(IX(x), IY(0)); ctx.lineTo(IX(x), IY(W)); ctx.stroke(); }
      for (let y = 1; y < W; y++) { ctx.beginPath(); ctx.moveTo(IX(0), IY(y)); ctx.lineTo(IX(L), IY(y)); ctx.stroke(); }
      // origin axes
      const o = [IX(0), IY(0)], aw = 5 / sc;
      arrow(ctx, o, [IX(2.2), IY(0)], '#dc2626', aw);
      arrow(ctx, o, [IX(0), IY(2.2)], '#16a34a', aw);
      ctx.fillStyle = '#3c0060'; ctx.beginPath(); ctx.arc(o[0], o[1], 8 / sc, 0, 7); ctx.fill();
      // robots
      if (S.mode === 'explore') {
        const e = S.ex;
        robotAt(ctx, L - e.x, W - e.y, e.h + 180, 'ghost');
        robotAt(ctx, e.x, e.y, e.h, 'robot');
      } else if (S.q) {
        const q = S.q;
        if (S.pick >= 0 && !q.opts[S.pick].ok) { const p = q.opts[S.pick]; robotAt(ctx, p.x, p.y, p.h, 'wrong'); }
        robotAt(ctx, q.x, q.y, q.h, 'robot');
      }
      ctx.restore();
      // labels, drawn upright in screen space
      const f = vert ? '700 11px Plus Jakarta Sans' : '700 12px Plus Jakarta Sans';
      text(ctx, 'x', IX(2.45), IY(-0.05), '#fca5a5', 'center', f);
      text(ctx, 'y', IX(0.05), IY(2.45), '#86efac', 'center', f);
      text(ctx, '(0, 0)', IX(-0.55), IY(-0.25), INK, vert ? 'right' : 'center', '600 11px JetBrains Mono');
      text(ctx, 'BLUE', IX(-0.55), IY(W / 2), '#93c5fd', 'center', f);
      text(ctx, 'RED', IX(L + 0.55), IY(W / 2), '#fca5a5', 'center', f);
      text(ctx, `(${L}, ${W})`, IX(L - 0.2), IY(W + 0.12), MUTED, vert ? 'left' : 'right', '600 11px JetBrains Mono');
    };

    // quiz: the right pose, and three wrong ones built from the usual mistakes
    const WRONG = {
      mirror: 'That one measures y from the wrong side wall. y = 0 is on the right as the blue drivers look down the field, and y grows to their left. The orange outline shows where that pose really is.',
      cw: 'That heading is clockwise-positive. WPILib angles are counter-clockwise positive: 0 faces the red wall and turning left makes the angle bigger. The orange outline shows that heading.',
      red: 'That pose is measured from the red corner. WPILib always measures from the blue corner, on both alliances, so poses never flip. The orange outline shows where that pose really is.',
    };
    const newQ = () => {
      const rnd = (a, b) => a + Math.random() * (b - a);
      let y; do { y = rnd(0.7, W - 0.7); } while (Math.abs(y - W / 2) < 1.1);
      const x = rnd(1.2, L - 1.2), hs = [30, 45, 60, 90, 120, 135, 150], h = hs[Math.floor(Math.random() * hs.length)] * (Math.random() < 0.5 ? -1 : 1);
      const opts = [
        { x, y, h, ok: true },
        { x, y: W - y, h, kind: 'mirror' },
        { x, y, h: -h, kind: 'cw' },
        { x: L - x, y: W - y, h: h + 180, kind: 'red' },
      ].sort(() => Math.random() - 0.5);
      S.q = { x, y, h, opts }; S.pick = -1;
      const box = $('#co-f-ans');
      box.innerHTML = opts.map((o, i) => `<button type="button" data-i="${i}">${poseStr(o.x, o.y, o.h)}</button>`).join('');
      $('#co-f-fb').textContent = 'Pick one. Positions are rounded to 0.1 m.';
      $('#co-f-fb').className = 'why';
      draw();
    };
    $('#co-f-ans').addEventListener('click', (e) => {
      const b = e.target.closest('button'); if (!b || S.pick >= 0) return;
      S.pick = +b.dataset.i; const o = S.q.opts[S.pick];
      S.n++; if (o.ok) S.right++;
      $('#co-f-ans').querySelectorAll('button').forEach((x, i) => { x.disabled = true; if (S.q.opts[i].ok) x.classList.add('right'); else if (i === S.pick) x.classList.add('wrong'); });
      const fb = $('#co-f-fb');
      fb.textContent = o.ok ? 'Right. x from the blue wall, y from the right-hand side wall (as the blue drivers see it), heading counter-clockwise from facing the red wall.' : WRONG[o.kind];
      fb.className = 'why ' + (o.ok ? 'ok' : 'bad');
      $('#co-f-score').textContent = `${S.right} of ${S.n} right`;
      draw();
    });
    $('#co-f-next').addEventListener('click', newQ);

    const exCode = () => {
      const e = S.ex;
      $('#co-f-code').innerHTML = `<span class="c">// the purple robot (blue origin, always)</span>\n${poseStr(e.x, e.y, e.h)}\n<span class="c">// red's matching spot (dashed): 16.518 − x, 8.043 − y, θ + 180°</span>\n${poseStr(L - e.x, W - e.y, e.h + 180)}`;
    };
    const place = (ev) => {
      if (S.mode !== 'explore') return;
      const r = cv.getBoundingClientRect(); const [x, y] = fromScreen(ev.clientX - r.left, ev.clientY - r.top);
      if (x < -0.3 || x > L + 0.3 || y < -0.3 || y > W + 0.3) return;
      S.ex.x = Site.clamp(x, 0.45, L - 0.45); S.ex.y = Site.clamp(y, 0.45, W - 0.45);
      exCode(); draw();
    };
    cv.addEventListener('click', place);
    cv.addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse' && e.buttons === 1) place(e); });

    st = Site.canvas(cv, null, later(draw));
    img.onload = draw; img.src = 'assets/field-2026-top.webp';
    Site.range($('#co-f-h'), (v) => { S.ex.h = v; exCode(); draw(); }, (v) => (v > 0 ? '+' : '') + v + '°' + (v === 0 ? ' (facing red)' : Math.abs(v) === 180 ? ' (facing blue)' : v > 0 ? ' (CCW)' : ' (CW)'));
    Site.seg($('#co-f-mode'), (v) => {
      S.mode = v;
      $('#co-f-explore').hidden = v !== 'explore'; $('#co-f-quiz').hidden = v !== 'quiz';
      cv.style.cursor = v === 'explore' ? 'crosshair' : 'default';
      if (v === 'quiz' && !S.q) newQ(); else draw();
    });
  }
});
