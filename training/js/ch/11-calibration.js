Object.assign(Site.glossary, {
  'pinhole camera': 'The simplest camera model: light travels in straight lines through one tiny hole onto the sensor. Real lenses are described as a pinhole plus distortion.',
  'focal length': 'How far the sensor sits behind the pinhole. In computer vision it is measured in pixels (ours: about 737 px). Bigger means more zoomed in.',
  'principal point': 'The pixel directly behind the pinhole: the true optical center of the image. Usually a little off the middle of the picture.',
  'intrinsic matrix': 'K: a 3×3 grid holding fx, fy, cx and cy. It turns a direction in front of the camera into a pixel.',
  'ArUco': 'A family of square black-and-white markers, like AprilTags, used on calibration boards so each corner can be named.',
  'least squares': 'Finding the numbers that make a model fit noisy measurements best, by making the sum of the squared misses as small as possible.',
  'bundle adjustment': 'One big least-squares solve that adjusts camera poses and the positions of what they saw, all at once, until every view agrees.',
});

/* Calibration math: OpenCV's 8-coefficient rational lens model, a simulated camera with TopRight's
   real calibration, and Levenberg–Marquardt with a Schur complement. Checked in node: with 100 spread
   snapshots it recovers fx within 1 px; with center-only snapshots the edges are tens of px off. */
const CAL = (() => {
  // [fx, fy, cx, cy, k1, k2, p1, p2, k3, k4, k5, k6]: TopRight, 1280x800 (tools/fieldcal/fieldcal/synth.py)
  const TRUE = [736.985, 737.214, 597.901, 371.578, 0.1313, 0.0912, 5.2e-05, -0.000437, -0.0969, 0.0520, 0.0949, 0.0682];
  const W = 1280, H = 800, SQ = 0.03, NX = 11, NY = 8;
  const radial = (p, r2) => (1 + p[4] * r2 + p[5] * r2 * r2 + p[8] * r2 * r2 * r2) / (1 + p[9] * r2 + p[10] * r2 * r2 + p[11] * r2 * r2 * r2);
  const distortN = (p, x, y) => {
    const r2 = x * x + y * y, k = radial(p, r2);
    return [x * k + 2 * p[6] * x * y + p[7] * (r2 + 2 * x * x), y * k + p[6] * (r2 + 2 * y * y) + 2 * p[7] * x * y];
  };
  const toPx = (p, x, y) => { const d = distortN(p, x, y); return [p[0] * d[0] + p[2], p[1] * d[1] + p[3]]; };
  const undistortPx = (p, u, v) => {
    const xd = (u - p[2]) / p[0], yd = (v - p[3]) / p[1];
    let x = xd, y = yd;
    for (let i = 0; i < 30; i++) {
      const r2 = x * x + y * y, k = radial(p, r2);
      x = (xd - 2 * p[6] * x * y - p[7] * (r2 + 2 * x * x)) / k;
      y = (yd - p[6] * (r2 + 2 * y * y) - 2 * p[7] * x * y) / k;
    }
    return [x, y];
  };
  // largest ideal radius where the model still maps outward (past it the curve turns back)
  const turnR = (p) => { let best = 0, r = 0; for (; r < 3; r += 0.005) { const d = r * radial(p, r * r); if (d < best) break; best = d; } return r; };
  const RT = turnR(TRUE);
  const rod = (r) => {
    const th = Math.hypot(r[0], r[1], r[2]);
    if (th < 1e-12) return [1, 0, 0, 0, 1, 0, 0, 0, 1];
    const x = r[0] / th, y = r[1] / th, z = r[2] / th, c = Math.cos(th), s = Math.sin(th), C = 1 - c;
    return [c + x * x * C, x * y * C - z * s, x * z * C + y * s, y * x * C + z * s, c + y * y * C, y * z * C - x * s, z * x * C - y * s, z * y * C + x * s, c + z * z * C];
  };
  const unrod = (R) => {
    const th = Math.acos(Site.clamp((R[0] + R[4] + R[8] - 1) / 2, -1, 1));
    if (th < 1e-9) return [0, 0, 0];
    const s = 2 * Math.sin(th);
    return [(R[7] - R[5]) / s * th, (R[2] - R[6]) / s * th, (R[3] - R[1]) / s * th];
  };
  const mul = (A, B) => { const C = []; for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) C.push(A[i * 3] * B[j] + A[i * 3 + 1] * B[3 + j] + A[i * 3 + 2] * B[6 + j]); return C; };
  const project = (p, pose, R, X, Y) => {
    const cz = R[6] * X + R[7] * Y + pose[5];
    return toPx(p, (R[0] * X + R[1] * Y + pose[3]) / cz, (R[3] * X + R[4] * Y + pose[4]) / cz);
  };
  const corners = []; for (let j = 0; j < NY; j++) for (let i = 0; i < NX; i++) corners.push([(i + 1) * SQ, (j + 1) * SQ]);
  const BC = [6 * SQ, 4.5 * SQ];
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const gauss = () => Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd());

  // The board held d meters away, centered on pixel (u, v), tilted up to `tilt` radians.
  function snapshot(u, v, d, tilt, noise = 0.7) {
    const [x, y] = undistortPx(TRUE, u, v), n = Math.hypot(x, y, 1);
    const ez = [x / n, y / n, 1 / n];
    let ex = [ez[2], 0, -ez[0]]; const m = Math.hypot(...ex); ex = ex.map((q) => q / m);
    const ey = [ez[1] * ex[2] - ez[2] * ex[1], ez[2] * ex[0] - ez[0] * ex[2], ez[0] * ex[1] - ez[1] * ex[0]];
    const a = rnd() * 2 * Math.PI, t = tilt * (0.5 + 0.5 * rnd());
    const R = mul([ex[0], ey[0], ez[0], ex[1], ey[1], ez[1], ex[2], ey[2], ez[2]], rod([Math.cos(a) * t, Math.sin(a) * t, (rnd() - 0.5) * 0.4]));
    const pose = [...unrod(R), ez[0] * d - (R[0] * BC[0] + R[1] * BC[1]), ez[1] * d - (R[3] * BC[0] + R[4] * BC[1]), ez[2] * d - (R[6] * BC[0] + R[7] * BC[1])];
    const obs = [], all = [];
    for (const [X, Y] of corners) {
      const pc = [R[0] * X + R[1] * Y + pose[3], R[3] * X + R[4] * Y + pose[4], R[6] * X + R[7] * Y + pose[5]];
      const r = Math.hypot(pc[0] / pc[2], pc[1] / pc[2]);
      const px = r < RT ? toPx(TRUE, pc[0] / pc[2], pc[1] / pc[2]) : null;
      all.push(px);
      if (!px || r > RT * 0.98 || px[0] < 2 || px[1] < 2 || px[0] > W - 2 || px[1] > H - 2) continue;
      obs.push([X, Y, px[0] + gauss() * noise, px[1] + gauss() * noise]);
    }
    return { pose: pose.map((q, i) => q + (i < 3 ? 0.03 : 0.02) * gauss()), obs, all };
  }

  function solveN(A, b, n) {
    const M = A.slice(), x = b.slice();
    for (let c = 0; c < n; c++) {
      let piv = c; for (let r = c + 1; r < n; r++) if (Math.abs(M[r * n + c]) > Math.abs(M[piv * n + c])) piv = r;
      if (piv !== c) { for (let k = 0; k < n; k++) { const t = M[c * n + k]; M[c * n + k] = M[piv * n + k]; M[piv * n + k] = t; } const t = x[c]; x[c] = x[piv]; x[piv] = t; }
      const d = M[c * n + c] || 1e-12;
      for (let r = c + 1; r < n; r++) { const f = M[r * n + c] / d; if (!f) continue; for (let k = c; k < n; k++) M[r * n + k] -= f * M[c * n + k]; x[r] -= f * x[c]; }
    }
    for (let c = n - 1; c >= 0; c--) { let s = x[c]; for (let k = c + 1; k < n; k++) s -= M[c * n + k] * x[k]; x[c] = s / (M[c * n + c] || 1e-12); }
    return x;
  }
  const inv6 = (V) => { const I = []; for (let c = 0; c < 6; c++) { const e = [0, 0, 0, 0, 0, 0]; e[c] = 1; I.push(solveN(V, e, 6)); } return (b) => { const r = [0, 0, 0, 0, 0, 0]; for (let c = 0; c < 6; c++) for (let k = 0; k < 6; k++) r[k] += I[c][k] * b[c]; return r; }; };
  const cost = (p, views) => { let s = 0; for (const v of views) { const R = rod(v.pose); for (const o of v.obs) { const q = project(p, v.pose, R, o[0], o[1]); s += (q[0] - o[2]) ** 2 + (q[1] - o[3]) ** 2; } } return s; };

  function calibrate(input, iters = 40) {
    const NP = 12;
    let p = [700, 700, 640, 400, 0, 0, 0, 0, 0, 0, 0, 0];
    let views = input.map((v) => ({ pose: v.pose.slice(), obs: v.obs }));
    let lam = 1e-3, cur = cost(p, views);
    for (let it = 0; it < iters; it++) {
      const U = new Float64Array(NP * NP), gp = new Float64Array(NP), per = [];
      for (const v of views) {
        const R = rod(v.pose), Vm = new Float64Array(36), Wm = new Float64Array(NP * 6), gv = new Float64Array(6);
        const Rs = []; for (let k = 0; k < 6; k++) { const q = v.pose.slice(); q[k] += 1e-7; Rs.push([q, rod(q)]); }
        for (const o of v.obs) {
          const q0 = project(p, v.pose, R, o[0], o[1]), r = [q0[0] - o[2], q0[1] - o[3]], Jp = [], Jv = [];
          for (let k = 0; k < NP; k++) { const h = 1e-6 * Math.max(1, Math.abs(p[k])), pp = p.slice(); pp[k] += h; const q = project(pp, v.pose, R, o[0], o[1]); Jp.push([(q[0] - q0[0]) / h, (q[1] - q0[1]) / h]); }
          for (let k = 0; k < 6; k++) { const q = project(p, Rs[k][0], Rs[k][1], o[0], o[1]); Jv.push([(q[0] - q0[0]) / 1e-7, (q[1] - q0[1]) / 1e-7]); }
          for (let a = 0; a < 2; a++) {
            for (let i = 0; i < NP; i++) { gp[i] += Jp[i][a] * r[a]; for (let j = 0; j < NP; j++) U[i * NP + j] += Jp[i][a] * Jp[j][a]; for (let j = 0; j < 6; j++) Wm[i * 6 + j] += Jp[i][a] * Jv[j][a]; }
            for (let i = 0; i < 6; i++) { gv[i] += Jv[i][a] * r[a]; for (let j = 0; j < 6; j++) Vm[i * 6 + j] += Jv[i][a] * Jv[j][a]; }
          }
        }
        per.push({ Vm, Wm, gv });
      }
      let improved = false;
      for (let tries = 0; tries < 6 && !improved; tries++) {
        const S = Array.from(U), b = Array.from(gp, (g) => -g);
        for (let i = 0; i < NP; i++) S[i * NP + i] += lam * (U[i * NP + i] + 1e-9);
        const Vi = per.map(({ Vm, Wm, gv }) => {
          const V = Array.from(Vm); for (let i = 0; i < 6; i++) V[i * 6 + i] += lam * (Vm[i * 6 + i] + 1e-9);
          const iv = inv6(V), WVi = [];
          for (let i = 0; i < NP; i++) WVi.push(iv(Array.from(Wm.slice(i * 6, i * 6 + 6))));
          for (let i = 0; i < NP; i++) {
            for (let j = 0; j < NP; j++) { let s = 0; for (let k = 0; k < 6; k++) s += WVi[i][k] * Wm[j * 6 + k]; S[i * NP + j] -= s; }
            let s = 0; for (let k = 0; k < 6; k++) s += WVi[i][k] * gv[k]; b[i] += s;
          }
          return iv;
        });
        const dp = solveN(S, b, NP), np = p.map((q, i) => q + dp[i]);
        const nv = views.map((v, j) => {
          const { Wm, gv } = per[j], rhs = [];
          for (let k = 0; k < 6; k++) { let s = -gv[k]; for (let i = 0; i < NP; i++) s -= Wm[i * 6 + k] * dp[i]; rhs.push(s); }
          const dv = Vi[j](rhs);
          return { pose: v.pose.map((q, k) => q + dv[k]), obs: v.obs };
        });
        const c = cost(np, nv);
        if (c < cur && isFinite(c)) { p = np; views = nv; lam = Math.max(1e-9, lam / 3); cur = c; improved = true; } else lam *= 5;
      }
      if (!improved) break;
    }
    const res = [];
    for (const v of views) { const R = rod(v.pose); for (const o of v.obs) { const q = project(p, v.pose, R, o[0], o[1]); res.push([o[2], o[3], q[0] - o[2], q[1] - o[3]]); } }
    return { p, res, mean: res.reduce((s, r) => s + Math.hypot(r[2], r[3]), 0) / Math.max(1, res.length) };
  }
  // Fitted lens vs the true lens at pixel (u, v), or null where the true model can't reach.
  const modelErr = (p, u, v) => {
    const [x, y] = undistortPx(TRUE, u, v);
    if (Math.hypot(x, y) > RT * 0.98) return null;
    const t = toPx(TRUE, x, y); if (Math.hypot(t[0] - u, t[1] - v) > 0.5) return null;
    const q = toPx(p, x, y); return Math.hypot(q[0] - u, q[1] - v);
  };
  return { TRUE, W, H, RT, snapshot, calibrate, modelErr, toPx, undistortPx, turnR, radial, rnd };
})();

Site.chapter('calibration', (root) => {
  // Click-to-play video: no YouTube iframe loads until the student asks for it.
  root.addEventListener('click', (e) => {
    const b = e.target.closest('.yt-play');
    if (b) b.outerHTML = `<iframe class="video-embed" src="https://www.youtube-nocookie.com/embed/${b.dataset.yt}?autoplay=1" title="${b.getAttribute('aria-label')}" allow="autoplay; encrypted-media" allowfullscreen></iframe>`;
  });
  const $ = (s) => root.querySelector(s);
  const LAB = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', LINE = 'rgba(196,181,253,.25)';
  const RED = '#f43f5e', GREEN = '#a3e635', AMBER = '#f59e0b', LAV = '#c4b5fd', VIO = '#8b5cf6';

  // A tiny 3D viewer: p = [x fwd, y left, z up] -> [sx, sy, depth]. az, el in radians.
  const viewer = (az, el, F, D, ox, oy) => {
    const d = [Math.cos(el) * Math.cos(az), Math.cos(el) * Math.sin(az), Math.sin(el)];
    const r = [-Math.sin(az), Math.cos(az), 0];
    const u = [d[1] * r[2] - d[2] * r[1], d[2] * r[0] - d[0] * r[2], d[0] * r[1] - d[1] * r[0]];
    return (p) => {
      const dep = p[0] * d[0] + p[1] * d[1] + p[2] * d[2], s = F / (D - dep);
      return [ox + (p[0] * r[0] + p[1] * r[1] + p[2] * r[2]) * s, oy - (p[0] * u[0] + p[1] * u[1] + p[2] * u[2]) * s, dep];
    };
  };
  const orbit = (cv, st, onChange) => {
    let drag = null;
    cv.addEventListener('pointerdown', (e) => { drag = [e.clientX, e.clientY, st.az, st.el]; cv.setPointerCapture(e.pointerId); cv.classList.add('dragging'); });
    cv.addEventListener('pointermove', (e) => { if (!drag) return; st.az = drag[2] - (e.clientX - drag[0]) * 0.01; st.el = Site.clamp(drag[3] + (e.clientY - drag[1]) * 0.01, -0.2, 1.4); onChange(); });
    const end = () => { drag = null; cv.classList.remove('dragging'); };
    cv.addEventListener('pointerup', end); cv.addEventListener('pointercancel', end);
  };
  const line = (ctx, a, b) => { ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke(); };
  const poly = (ctx, pts, fill, stroke) => { ctx.beginPath(); pts.forEach((p, i) => (i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]))); ctx.closePath(); if (fill) { ctx.fillStyle = fill; ctx.fill(); } if (stroke) { ctx.strokeStyle = stroke; ctx.stroke(); } };
  const dot = (ctx, p, r, c) => { ctx.fillStyle = c; ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 7); ctx.fill(); };

  /* ── Why: two lenses, one pixel ───────────────────────── */
  {
    const svg = $('#cal-why');
    const cam = (x0, f, label, sub) => {
      const px = 22, sy = 250, ang = Math.atan(px / f);
      const far = 150, ex = x0 + far * Math.sin(ang) * -1, ey = sy - f - far * Math.cos(ang);
      // sensor at bottom (y = sy), pinhole at (x0, sy - f)
      const hx = x0, hy = sy - f;
      const fov = Math.atan(60 / f);
      return `<g>
        <path d="M${hx} ${hy} L${hx - 250 * Math.tan(fov)} ${hy - 250} M${hx} ${hy} L${hx + 250 * Math.tan(fov)} ${hy - 250}" stroke="#d4c0ee" stroke-dasharray="4 4" fill="none"/>
        <rect x="${x0 - 70}" y="${hy}" width="140" height="${sy - hy + 14}" rx="8" fill="#f3e8ff" stroke="#6b1199" stroke-width="1.5"/>
        <rect x="${x0 - 60}" y="${sy}" width="120" height="8" fill="#3c0060"/>
        <circle cx="${hx}" cy="${hy}" r="4" fill="#fff" stroke="#3c0060" stroke-width="2"/>
        <line x1="${x0 + px}" y1="${sy}" x2="${ex}" y2="${ey}" stroke="#f43f5e" stroke-width="2.5"/>
        <circle cx="${x0 + px}" cy="${sy + 4}" r="5" fill="#f43f5e"/>
        <text x="${x0}" y="${sy + 40}" text-anchor="middle" font-family="Outfit" font-weight="700" font-size="16" fill="#4c0070">${label}</text>
        <text x="${x0}" y="${sy + 60}" text-anchor="middle" font-size="13" fill="#635a72">${sub}</text>
        <path d="M${hx} ${hy - 46} A46 46 0 0 0 ${hx - 46 * Math.sin(ang)} ${hy - 46 * Math.cos(ang)}" fill="none" stroke="#f43f5e" stroke-width="1.5"/><line x1="${hx}" y1="${hy}" x2="${hx}" y2="${hy - 70}" stroke="#635a72" stroke-dasharray="3 3"/>
        <text x="${hx - 50 * Math.sin(ang / 2) - 6}" y="${hy - 54}" text-anchor="end" font-size="14" font-weight="700" fill="#f43f5e">${Math.round((ang * 180) / Math.PI)}°</text>
      </g>`;
    };
    svg.innerHTML = `<rect width="560" height="340" fill="#fff"/>` + cam(140, 40, 'Wide lens', 'short focal length') + cam(420, 80, 'Narrow lens', 'long focal length') +
      `<text x="280" y="332" text-anchor="middle" font-size="12" fill="#635a72">the red pixel is the same distance right of center in both</text>`;
  }

  /* ── Pinhole lab ──────────────────────────────────────── */
  {
    const c3 = $('#cal-pin3d'), ci = $('#cal-pinimg');
    const s3 = Site.canvas(c3, 0.8, () => requestAnimationFrame(draw)), si = Site.canvas(ci, 0.625, () => requestAnimationFrame(draw));
    const P = { fx: 737, fy: 737, cx: 597.9, cy: 371.6, X: 0.35, Y: -0.15, Z: 2 };
    const vw = { az: 2.35, el: 0.42 };
    const eq = $('#cal-eq'), hfov = $('#cal-hfov'), fmm = $('#cal-fmm');
    const ids = ['fx', 'fy', 'cx', 'cy', 'X', 'Y', 'Z'];
    const inputs = {};
    ids.forEach((k) => { inputs[k] = $('#cal-' + k); Site.range(inputs[k], (v) => { P[k] = v; draw(); }, (v) => (k.length === 1 ? v.toFixed(2) + ' m' : v.toFixed(1) + ' px')); });
    const set = (vals) => { for (const k in vals) { inputs[k].value = vals[k]; inputs[k].dispatchEvent(new Event('input')); } };
    $('#cal-ours').onclick = () => set({ fx: 737.0, fy: 737.2, cx: 597.9, cy: 371.6 });
    $('#cal-ideal').onclick = () => set({ fx: 737, fy: 737, cx: 640, cy: 400 });
    orbit(c3, vw, () => draw());
    Site.seg($('#cal-pintab'), (v) => { $('#cal-duo').dataset.show = v; requestAnimationFrame(draw); });
    // drag the point in the image
    let dragI = false;
    const fromImg = (e) => {
      const r = ci.getBoundingClientRect(), u = ((e.clientX - r.left) / r.width) * 1280, v = ((e.clientY - r.top) / r.height) * 800;
      set({ X: Site.clamp(((u - P.cx) * P.Z) / P.fx, -1.2, 1.2), Y: Site.clamp(((v - P.cy) * P.Z) / P.fy, -0.8, 0.8) });
    };
    ci.addEventListener('pointerdown', (e) => { dragI = true; ci.setPointerCapture(e.pointerId); ci.classList.add('dragging'); fromImg(e); });
    ci.addEventListener('pointermove', (e) => dragI && fromImg(e));
    const endI = () => { dragI = false; ci.classList.remove('dragging'); };
    ci.addEventListener('pointerup', endI); ci.addEventListener('pointercancel', endI);

    function draw() {
      if (!s3.w && !si.w) return; // on phones only one view is shown at a time
      const u = (P.fx * P.X) / P.Z + P.cx, v = (P.fy * P.Y) / P.Z + P.cy;
      // 3D: camera frame (X right, Y down, Z fwd) -> world (fwd, left, up) = (Z, -X, -Y)
      if (s3.w) { const { ctx, w, h } = s3;
        ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
        const V = viewer(vw.az, vw.el, w * 2.1, 7, w * 0.5, h * 0.5);
        const W3 = (x, y, z) => V([z - 1.1, -x, -y]);
        const k = 0.0008, zp = P.fx * k, ys = P.fx / P.fy;
        const pl = [[-P.cx, -P.cy], [1280 - P.cx, -P.cy], [1280 - P.cx, 800 - P.cy], [-P.cx, 800 - P.cy]].map(([a, b]) => [a * k, b * k * ys, zp]);
        // floor grid for depth
        ctx.strokeStyle = 'rgba(196,181,253,.08)'; ctx.lineWidth = 1;
        for (let i = -3; i <= 3; i++) { line(ctx, W3(i * 0.4, 0.9, 0), W3(i * 0.4, 0.9, 3.2)); }
        for (let j = 0; j <= 8; j++) line(ctx, W3(-1.2, 0.9, j * 0.4), W3(1.2, 0.9, j * 0.4));
        // frustum
        ctx.strokeStyle = 'rgba(139,92,246,.35)';
        for (const q of pl) line(ctx, W3(0, 0, 0), W3(q[0] * 3.2 / zp, q[1] * 3.2 / zp, 3.2));
        const farR = pl.map((q) => W3(q[0] * 3.2 / zp, q[1] * 3.2 / zp, 3.2));
        poly(ctx, farR, 'rgba(139,92,246,.05)', 'rgba(139,92,246,.35)');
        // camera body
        const b = 0.09;
        const box = [[-b, -b, -0.22], [b, -b, -0.22], [b, b, -0.22], [-b, b, -0.22]].map((q) => W3(...q));
        const fr = [[-b * .5, -b * .5, 0], [b * .5, -b * .5, 0], [b * .5, b * .5, 0], [-b * .5, b * .5, 0]].map((q) => W3(...q));
        ctx.strokeStyle = '#6b5a8c'; for (let i = 0; i < 4; i++) line(ctx, box[i], fr[i]);
        poly(ctx, box, '#2a1840', '#6b5a8c'); poly(ctx, fr, null, '#6b5a8c');
        // optical axis
        ctx.setLineDash([4, 4]); ctx.strokeStyle = 'rgba(196,181,253,.5)'; line(ctx, W3(0, 0, 0), W3(0, 0, 3.2)); ctx.setLineDash([]);
        // image plane with pixel grid
        const PL = pl.map((q) => W3(...q));
        poly(ctx, PL, 'rgba(196,181,253,.16)', LAV);
        ctx.strokeStyle = 'rgba(196,181,253,.25)';
        for (let i = 1; i < 8; i++) { const a = -P.cx + i * 160; line(ctx, W3(a * k, -P.cy * k * ys, zp), W3(a * k, (800 - P.cy) * k * ys, zp)); }
        for (let i = 1; i < 5; i++) { const a = -P.cy + i * 160; line(ctx, W3(-P.cx * k, a * k * ys, zp), W3((1280 - P.cx) * k, a * k * ys, zp)); }
        const pp = W3(0, 0, zp); ctx.strokeStyle = LAV; line(ctx, [pp[0] - 6, pp[1]], [pp[0] + 6, pp[1]]); line(ctx, [pp[0], pp[1] - 6], [pp[0], pp[1] + 6]);
        // the point, its ray, its image
        const Pw = W3(P.X, P.Y, P.Z), Pi = W3((P.X / P.Z) * zp, (P.Y / P.Z) * zp, zp), O = W3(0, 0, 0);
        const drop = W3(P.X, 0.9, P.Z);
        ctx.setLineDash([2, 3]); ctx.strokeStyle = 'rgba(245,158,11,.5)'; line(ctx, Pw, drop); ctx.setLineDash([]);
        ctx.strokeStyle = AMBER; ctx.lineWidth = 2; line(ctx, Pw, O); ctx.lineWidth = 1;
        dot(ctx, O, 3.5, '#fff'); dot(ctx, Pw, 6, AMBER); dot(ctx, Pi, 4.5, RED);
        ctx.font = '600 12px Plus Jakarta Sans'; ctx.fillStyle = AMBER; ctx.fillText('P (X, Y, Z)', Pw[0] + 9, Pw[1] - 6);
        ctx.fillStyle = INK; ctx.fillText('pinhole', O[0] + 8, O[1] + 16);
        ctx.fillStyle = LAV; ctx.fillText('image plane', PL[0][0] + 4, PL[0][1] - 6);
        const fl = W3(0, 0, zp / 2); ctx.fillStyle = MUTED; ctx.font = '11px JetBrains Mono'; ctx.fillText('f', fl[0] + 5, fl[1] - 4);
      }
      // image
      if (si.w) { const { ctx, w, h } = si, s = w / 1280;
        ctx.fillStyle = '#16092a'; ctx.fillRect(0, 0, w, h);
        ctx.strokeStyle = 'rgba(196,181,253,.12)';
        for (let x = 160; x < 1280; x += 160) line(ctx, [x * s, 0], [x * s, h]);
        for (let y = 160; y < 800; y += 160) line(ctx, [0, y * s], [w, y * s]);
        ctx.setLineDash([3, 4]); ctx.strokeStyle = 'rgba(255,255,255,.35)'; line(ctx, [640 * s, 0], [640 * s, h]); line(ctx, [0, 400 * s], [w, 400 * s]); ctx.setLineDash([]);
        ctx.strokeStyle = LAV; ctx.lineWidth = 2; line(ctx, [P.cx * s - 9, P.cy * s], [P.cx * s + 9, P.cy * s]); line(ctx, [P.cx * s, P.cy * s - 9], [P.cx * s, P.cy * s + 9]); ctx.lineWidth = 1;
        ctx.font = '10px JetBrains Mono'; ctx.fillStyle = 'rgba(255,255,255,.5)'; ctx.fillText('image center', 640 * s + 4, h - 6);
        ctx.fillStyle = LAV; ctx.fillText('(cx, cy)', P.cx * s - 52, P.cy * s + 16);
        const inside = u >= 0 && u <= 1280 && v >= 0 && v <= 800;
        if (inside) { dot(ctx, [u * s, v * s], 6, RED); ctx.fillStyle = '#fff'; ctx.font = '11px JetBrains Mono'; const tx = `(${u.toFixed(0)}, ${v.toFixed(0)})`; ctx.fillText(tx, Math.min(u * s + 9, w - ctx.measureText(tx).width - 4), Math.max(14, v * s - 9)); }
        else { ctx.fillStyle = AMBER; ctx.font = '600 12px Plus Jakarta Sans'; ctx.fillText('The point is outside the picture', 10, 20); }
        ctx.strokeStyle = LINE; ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
      }
      const hf = (Math.atan(P.cx / P.fx) + Math.atan((1280 - P.cx) / P.fx)) * 180 / Math.PI;
      hfov.textContent = hf.toFixed(0) + '°'; fmm.textContent = (P.fx * 0.003).toFixed(2) + ' mm';
      const f1 = (x) => x.toFixed(1), f2 = (x) => x.toFixed(2);
      eq.innerHTML = `<b>u</b> = fx·X/Z + cx = ${f1(P.fx)}·(${f2(P.X)}/${f2(P.Z)}) + ${f1(P.cx)} = <span class="v">${f1(u)} px</span><br>` +
        `<b>v</b> = fy·Y/Z + cy = ${f1(P.fy)}·(${f2(P.Y)}/${f2(P.Z)}) + ${f1(P.cy)} = <span class="v">${f1(v)} px</span><br>` +
        `<b>K</b> =<span class="kmat"><span class="hl">${f1(P.fx)}</span><span>0</span><span class="hl">${f1(P.cx)}</span><span>0</span><span class="hl">${f1(P.fy)}</span><span class="hl">${f1(P.cy)}</span><span>0</span><span>0</span><span>1</span></span>`;
    }
    draw();
  }

  /* ── Distortion lab ───────────────────────────────────── */
  {
    const cv = $('#cal-dist');
    const st = Site.canvas(cv, 0.625, () => requestAnimationFrame(render));
    const KTR = CAL.TRUE.slice(0, 4), KTL = [737.84, 737.67, 650.49, 362.44];
    let K = KTR;
    const PRE = {
      none: [0, 0, 0, 0, 0, 0, 0, 0],
      barrel: [-0.28, 0.07, 0, 0, -0.008, 0, 0, 0],
      pin: [0.22, 0.06, 0, 0, 0.01, 0, 0, 0],
      ours: CAL.TRUE.slice(4),
      tl: [0.124195, 0.0503841, 0.000782376, -5.20496e-05, -0.0127028, 0.0343885, 0.109998, 0.0847799], // TopLeft, from our Jetson
    };
    let D = PRE.tl.slice(), mode = 'raw', quiet = true;
    const P = () => [...K, ...D];
    const sl = { k1: 0, k2: 1, p1: 2, p2: 3, k3: 4 };
    const note = $('#cal-dnote');
    const off = document.createElement('canvas');
    const tags = [[-0.62, -0.3, 0.24, 3], [0.02, 0.06, 0.2, 7], [0.64, 0.3, 0.22, 12]];
    for (const k in sl) Site.range($('#cal-' + k), (v) => { if (quiet) return; D[sl[k]] = v; D[5] = D[6] = D[7] = 0; root.querySelectorAll('#cal-preset button').forEach((b) => b.classList.remove('on')); render(); }, (v) => v.toFixed(k[0] === 'p' ? 4 : 3));
    const setSliders = () => { quiet = true; for (const k in sl) { const el = $('#cal-' + k); el.value = D[sl[k]]; el.dispatchEvent(new Event('input')); } quiet = false; };
    quiet = false;
    Site.seg($('#cal-preset'), (v) => { D = PRE[v].slice(); K = v === 'tl' ? KTL : KTR; setSliders(); render(); });
    Site.seg($('#cal-undist'), (v) => { mode = v; render(); });

    // draw the scene into ctx through map(x, y) -> [px, py] (in 1280x800 units, scaled by s)
    function scene(ctx, w, h, map, clipR) {
      const s = w / 1280;
      const M = (x, y) => { if (clipR && Math.hypot(x, y) > clipR) return null; const q = map(x, y); return [q[0] * s, q[1] * s]; };
      const stroke = (pts) => { ctx.beginPath(); let pen = false; for (const q of pts) { if (!q) { pen = false; continue; } if (pen) ctx.lineTo(q[0], q[1]); else { ctx.moveTo(q[0], q[1]); pen = true; } } ctx.stroke(); };
      ctx.fillStyle = '#241536'; ctx.fillRect(0, 0, w, h);
      ctx.lineWidth = 1.2; ctx.strokeStyle = 'rgba(196,181,253,.55)';
      for (let i = -16; i <= 16; i++) { const a = i * 0.1, pts = [], pts2 = []; for (let j = 0; j <= 60; j++) { const b = -1.6 + j * 3.2 / 60; pts.push(M(a, b)); pts2.push(M(b, a)); } stroke(pts); stroke(pts2); }
      // tags, cell by cell
      for (const [tx, ty, sz, id] of tags) {
        const g = Site.tagGrid(id), c = sz / 10;
        for (let r = 0; r < 10; r++) for (let q = 0; q < 10; q++) {
          const x0 = tx - sz / 2 + q * c, y0 = ty - sz / 2 + r * c, pts = [];
          for (let t = 0; t < 3; t++) pts.push(M(x0 + t * c / 3, y0));
          for (let t = 0; t < 3; t++) pts.push(M(x0 + c, y0 + t * c / 3));
          for (let t = 0; t < 3; t++) pts.push(M(x0 + c - t * c / 3, y0 + c));
          for (let t = 0; t < 3; t++) pts.push(M(x0, y0 + c - t * c / 3));
          if (pts.some((p) => !p)) continue;
          ctx.fillStyle = g[r][q] ? '#fff' : '#000'; ctx.strokeStyle = ctx.fillStyle; ctx.lineWidth = 0.6;
          ctx.beginPath(); pts.forEach((p, i) => (i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]))); ctx.closePath(); ctx.fill(); ctx.stroke();
        }
      }
    }
    function render() {
      if (!st.w) return;
      const { ctx, w, h, dpr } = st, p = P(), RTp = CAL.turnR(p);
      const pin = (x, y) => [K[0] * x + K[2], K[1] * y + K[3]];
      const lens = (x, y) => CAL.toPx(p, x, y);
      if (mode === 'raw') {
        scene(ctx, w, h, lens, RTp * 0.96);
        // corner markers: pinhole position (hollow) -> lens position (red)
        const [tx, ty, sz] = tags[0];
        for (const [a, b] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
          const x = tx + a * sz * 0.4, y = ty + b * sz * 0.4, q0 = pin(x, y), q1 = lens(x, y), s = w / 1280;
          ctx.strokeStyle = 'rgba(163,230,53,.9)'; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.arc(q0[0] * s, q0[1] * s, 5, 0, 7); ctx.stroke();
          ctx.strokeStyle = AMBER; line(ctx, [q0[0] * s, q0[1] * s], [q1[0] * s, q1[1] * s]);
          dot(ctx, [q1[0] * s, q1[1] * s], 3.5, RED);
        }
        ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = 'rgba(14,5,24,.85)'; ctx.fillRect(6, h - 44, 236, 38); ctx.fillStyle = GREEN; ctx.fillText('○ where a pinhole would put a corner', 12, h - 29); ctx.fillStyle = RED; ctx.fillText('● where this lens puts it', 12, h - 13);
      } else {
        // undistort by remapping pixels, like cv2.undistort: for each output pixel, look up the lens pixel
        off.width = Math.round(w * dpr); off.height = Math.round(h * dpr);
        const oc = off.getContext('2d'); oc.setTransform(dpr, 0, 0, dpr, 0, 0);
        scene(oc, w, h, lens, RTp * 0.96);
        const src = oc.getImageData(0, 0, off.width, off.height), out = ctx.createImageData(off.width, off.height);
        const SW = off.width, SH = off.height, sc = SW / 1280;
        for (let j = 0; j < SH; j++) for (let i = 0; i < SW; i++) {
          const x = (i / sc - K[2]) / K[0], y = (j / sc - K[3]) / K[1], o = (j * SW + i) * 4;
          let q = null;
          if (Math.hypot(x, y) < RTp * 0.96) q = lens(x, y);
          if (q && q[0] >= 0 && q[1] >= 0 && q[0] < 1280 && q[1] < 800) {
            const si = ((Math.floor(q[1] * sc) * SW) + Math.floor(q[0] * sc)) * 4;
            out.data[o] = src.data[si]; out.data[o + 1] = src.data[si + 1]; out.data[o + 2] = src.data[si + 2]; out.data[o + 3] = 255;
          } else { out.data[o] = 8; out.data[o + 1] = 3; out.data[o + 2] = 14; out.data[o + 3] = 255; }
        }
        ctx.putImageData(out, 0, 0);
        ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = 'rgba(14,5,24,.85)'; ctx.fillRect(6, h - 26, 262, 20); ctx.fillStyle = MUTED; ctx.fillText('Black: no pixels from the camera land here', 12, h - 12);
      }
      ctx.strokeStyle = LINE; ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
      const shift = (x, y) => { const a = pin(x, y), b = lens(x, y); return Math.hypot(a[0] - b[0], a[1] - b[1]); };
      const cx0 = -K[2] / K[0], cy0 = -K[3] / K[1];
      $('#cal-dshift').textContent = Math.hypot(cx0, cy0) < RTp ? shift(cx0, cy0).toFixed(0) + ' px' : 'off the model';
      $('#cal-dtag').textContent = shift(tags[0][0] - tags[0][2] * 0.4, tags[0][1] - tags[0][2] * 0.4).toFixed(1) + ' px';
      note.textContent = D[5] || D[6] || D[7] ? `Plus the rational model's k4, k5, k6 = ${D[5].toFixed(3)}, ${D[6].toFixed(3)}, ${D[7].toFixed(3)}, which divide instead of multiply. Moving a slider drops them.` : 'The 5-coefficient model: k1, k2, k3 radial, p1, p2 tangential.';
    }
    render();
  }

  /* ── Turn-back chart (in a Go deeper) ─────────────────── */
  {
    const cv = $('#cal-turn');
    Site.canvas(cv, 0.5, (st) => {
      const { ctx, w, h } = st; if (!w) return;
      const p = CAL.TRUE, L = 46, B = 30, R = 12, T = 14, X = (a) => L + (a / 70) * (w - L - R), Y = (r) => h - B - (r / 900) * (h - B - T);
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.strokeStyle = 'rgba(196,181,253,.12)';
      for (let a = 0; a <= 70; a += 10) { line(ctx, [X(a), T], [X(a), h - B]); ctx.fillText(a + '°', X(a) - 8, h - B + 14); }
      for (let r = 0; r <= 900; r += 200) { line(ctx, [L, Y(r)], [w - R, Y(r)]); ctx.fillText(r, 6, Y(r) + 3); }
      ctx.fillText('degrees off-axis', w - 120, h - 4);
      // pinhole reference and the image-corner radius
      ctx.strokeStyle = 'rgba(255,255,255,.35)'; ctx.setLineDash([4, 4]); ctx.beginPath();
      for (let a = 0; a <= 52; a += 1) { const q = [X(a), Y(Math.tan(a * Math.PI / 180) * p[0])]; a ? ctx.lineTo(...q) : ctx.moveTo(...q); } ctx.stroke();
      ctx.strokeStyle = AMBER; line(ctx, [L, Y(805)], [w - R, Y(805)]); ctx.setLineDash([]);
      ctx.fillStyle = AMBER; ctx.fillText('farthest image corner: 805 px from center', L + 6, Y(805) - 5);
      ctx.fillStyle = 'rgba(255,255,255,.6)'; ctx.fillText('pinhole', X(52) + 6, Y(Math.tan(52 * Math.PI / 180) * p[0]) + 4);
      ctx.strokeStyle = GREEN; ctx.lineWidth = 2; ctx.beginPath();
      let peak = [0, 0];
      for (let a = 0; a <= 70; a += 0.5) { const r = Math.tan(a * Math.PI / 180), rd = r * CAL.radial(p, r * r) * p[0]; if (rd > peak[1]) peak = [a, rd]; const q = [X(a), Y(rd)]; a ? ctx.lineTo(...q) : ctx.moveTo(...q); }
      ctx.stroke(); ctx.lineWidth = 1;
      dot(ctx, [X(peak[0]), Y(peak[1])], 4, RED);
      ctx.fillStyle = RED; ctx.fillText(`turns back at ${peak[0].toFixed(0)}°, ${peak[1].toFixed(0)} px`, X(peak[0]) + 10, Y(peak[1]) - 8);
      ctx.fillStyle = GREEN; ctx.fillText('our lens model', X(12), Y(CAL.radial(p, 0.045) * 0.21 * p[0]) - 10);
    });
  }

  /* ── Mount lab ────────────────────────────────────────── */
  {
    const cv = $('#cal-mount'), st = Site.canvas(cv, 0.62, () => requestAnimationFrame(draw));
    const M = { x: 0.26, y: 0.26, z: 0.45, p: -15, yaw: 30 }, vw = { az: -2.3, el: 0.55 };
    const code = $('#cal-mcode');
    [['mx', 'x', ' m'], ['my', 'y', ' m'], ['mz', 'z', ' m'], ['mp', 'p', '°'], ['myaw', 'yaw', '°']].forEach(([id, k, u]) =>
      Site.range($('#cal-' + id), (v) => { M[k] = v; draw(); }, (v) => (u === ' m' ? v.toFixed(2) : v.toFixed(0)) + u));
    orbit(cv, vw, () => draw());
    function draw() {
      if (!st.w) return;
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      const V = viewer(vw.az, vw.el, w * 2.3, 9, w * 0.5, h * 0.5);
      const S = (p) => V([p[0] - 0.9, p[1], p[2] - 0.2]);
      ctx.strokeStyle = 'rgba(196,181,253,.1)';
      for (let i = -2; i <= 6; i++) { line(ctx, S([i * 0.5, -1.5, 0]), S([i * 0.5, 1.5, 0])); }
      for (let j = -3; j <= 3; j++) line(ctx, S([-1, j * 0.5, 0]), S([3, j * 0.5, 0]));
      const yaw = M.yaw * Math.PI / 180, pit = M.p * Math.PI / 180;
      const rot = (v) => { // Rz(yaw) * Ry(pitch) applied to v
        const x1 = v[0] * Math.cos(pit) + v[2] * Math.sin(pit), z1 = -v[0] * Math.sin(pit) + v[2] * Math.cos(pit);
        return [x1 * Math.cos(yaw) - v[1] * Math.sin(yaw), x1 * Math.sin(yaw) + v[1] * Math.cos(yaw), z1];
      };
      const C = [M.x, M.y, M.z];
      // floor patch the camera sees
      const hf = Math.tan(41 * Math.PI / 180), vf = Math.tan(28.5 * Math.PI / 180), rays = [];
      const edge = (a, b) => { for (let t = 0; t <= 12; t++) rays.push([1, hf * (a[0] + (b[0] - a[0]) * t / 12), vf * (a[1] + (b[1] - a[1]) * t / 12)]); };
      edge([1, 1], [-1, 1]); edge([-1, 1], [-1, -1]); edge([-1, -1], [1, -1]); edge([1, -1], [1, 1]);
      const patch = rays.map((r) => { const d = rot(r); let t = d[2] < -1e-3 ? -C[2] / d[2] : 99; const horiz = Math.hypot(d[0], d[1]) * t; if (horiz > 2.2) t = 2.2 / Math.hypot(d[0], d[1]); return S([C[0] + d[0] * t, C[1] + d[1] * t, 0]); });
      poly(ctx, patch, 'rgba(163,230,53,.12)', 'rgba(163,230,53,.45)');
      // robot: 0.8 m square frame, bumpers 0.15 m tall
      const hw = 0.4, bh = 0.15;
      const box = (x0, x1, y0, y1, z0, z1, fill, stroke) => {
        const P = (x, y, z) => S([x, y, z]);
        const faces = [
          [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]], [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]],
          [[x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1]], [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]],
          [[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]],
        ].map((f) => ({ pts: f.map((q) => P(...q)), d: f.reduce((s, q) => s + S(q)[2], 0) / 4 }));
        faces.sort((a, b) => a.d - b.d).forEach((f) => poly(ctx, f.pts, fill, stroke));
      };
      box(-hw, hw, -hw, hw, 0.03, bh, '#4c0070', '#8b5cf6');
      box(-hw + 0.05, hw - 0.05, -hw + 0.05, hw - 0.05, bh, bh + 0.02, '#2a1840', '#6b5a8c');
      // mast to the camera
      ctx.strokeStyle = '#6b5a8c'; ctx.lineWidth = 3; line(ctx, S([M.x, M.y, bh]), S(C)); ctx.lineWidth = 1;
      // frustum
      const far = 1.1, cs = [[1, 1], [-1, 1], [-1, -1], [1, -1]].map(([a, b]) => { const d = rot([1, hf * a, vf * b]); return S([C[0] + d[0] * far, C[1] + d[1] * far, C[2] + d[2] * far]); });
      const c0 = S(C);
      ctx.strokeStyle = 'rgba(139,92,246,.7)'; cs.forEach((q) => line(ctx, c0, q)); poly(ctx, cs, 'rgba(139,92,246,.18)', 'rgba(196,181,253,.8)');
      // camera axes (x forward red, y left green, z up blue)
      [[[0.25, 0, 0], '#ef4444'], [[0, 0.18, 0], '#22c55e'], [[0, 0, 0.18], '#3b82f6']].forEach(([v, c]) => { const d = rot(v); ctx.strokeStyle = c; ctx.lineWidth = 2.5; line(ctx, c0, S([C[0] + d[0], C[1] + d[1], C[2] + d[2]])); });
      ctx.lineWidth = 1; dot(ctx, c0, 4, '#fff');
      // robot axes on the floor
      ctx.font = '600 11px Plus Jakarta Sans';
      const o = S([0, 0, 0.005]), ax = S([0.7, 0, 0.005]), ay = S([0, 0.7, 0.005]);
      ctx.setLineDash([3, 3]); ctx.strokeStyle = 'rgba(239,68,68,.8)'; line(ctx, o, ax); ctx.strokeStyle = 'rgba(34,197,94,.8)'; line(ctx, o, ay); ctx.setLineDash([]);
      ctx.fillStyle = '#ef4444'; ctx.fillText('robot x', ax[0] + 4, ax[1]); ctx.fillStyle = '#22c55e'; ctx.fillText('robot y', ay[0] + 4, ay[1]);
      ctx.fillStyle = INK; ctx.fillText('camera', c0[0] + 8, c0[1] - 8);
      code.innerHTML = `<span class="c">// the camera's mount, in robot code</span>\nrobotToCamera = new Transform3d(\n    new Translation3d(<span class="n">${M.x.toFixed(2)}</span>, <span class="n">${M.y.toFixed(2)}</span>, <span class="n">${M.z.toFixed(2)}</span>),\n    new Rotation3d(<span class="n">0</span>, Units.degreesToRadians(<span class="n">${M.p}</span>),\n                   Units.degreesToRadians(<span class="n">${M.yaw}</span>)));`;
    }
    draw();
  }

  /* ── ChArUco vs chessboard ────────────────────────────── */
  {
    const cv = $('#cal-board'), st = Site.canvas(cv, 0.72, () => requestAnimationFrame(draw));
    let type = 'charuco', slide = 30;
    const marks = {};
    let sd = 99; const r2 = () => ((sd = (sd * 16807) % 2147483647) / 2147483647);
    for (let r = 0; r < 9; r++) for (let c = 0; c < 12; c++) if ((c + r) % 2 === 0) marks[r * 12 + c] = Array.from({ length: 25 }, () => r2() > 0.5);
    Site.seg($('#cal-btype'), (v) => { type = v; draw(); });
    Site.range($('#cal-bslide'), (v) => { slide = v; draw(); }, (v) => v + '%');
    let drag = null;
    cv.addEventListener('pointerdown', (e) => { drag = [e.clientX, slide]; cv.setPointerCapture(e.pointerId); cv.classList.add('dragging'); });
    cv.addEventListener('pointermove', (e) => { if (!drag) return; const el = $('#cal-bslide'); el.value = Site.clamp(drag[1] + ((e.clientX - drag[0]) / cv.clientWidth) * 140, 0, 75); el.dispatchEvent(new Event('input')); });
    const endB = () => { drag = null; cv.classList.remove('dragging'); };
    cv.addEventListener('pointerup', endB); cv.addEventListener('pointercancel', endB);
    function draw() {
      if (!st.w) return;
      const { ctx, w, h } = st;
      ctx.fillStyle = '#120720'; ctx.fillRect(0, 0, w, h);
      const fr = [w * 0.05, h * 0.07, w * 0.72, h * 0.93];
      const sq = Math.min((w * 0.6) / 12, (h * 0.7) / 9), bw = sq * 12, bh = sq * 9;
      const bx = fr[0] + (fr[2] - fr[0] - bw) / 2 + (slide / 100) * bw, by = (h - bh) / 2;
      const inF = (x, y) => x >= fr[0] && x <= fr[2] && y >= fr[1] && y <= fr[3];
      // board
      ctx.fillStyle = '#fff'; ctx.fillRect(bx - sq * 0.3, by - sq * 0.3, bw + sq * 0.6, bh + sq * 0.6);
      const mOK = {};
      for (let r = 0; r < 9; r++) for (let c = 0; c < 12; c++) {
        const x = bx + c * sq, y = by + r * sq;
        if ((c + r) % 2 === 1) { ctx.fillStyle = '#000'; ctx.fillRect(x, y, sq + 0.5, sq + 0.5); continue; }
        if (type === 'chess') continue;
        const ms = sq * 22 / 30, mx = x + (sq - ms) / 2, my = y + (sq - ms) / 2, cell = ms / 7, bits = marks[r * 12 + c];
        ctx.fillStyle = '#000'; ctx.fillRect(mx, my, ms, ms); ctx.fillStyle = '#fff';
        for (let i = 0; i < 25; i++) if (bits[i]) ctx.fillRect(mx + (1 + (i % 5)) * cell, my + (1 + Math.floor(i / 5)) * cell, cell + 0.3, cell + 0.3);
        mOK[r * 12 + c] = inF(mx, my) && inF(mx + ms, my + ms);
      }
      // outside the camera's view: dim it
      ctx.fillStyle = 'rgba(18,7,32,.78)';
      ctx.fillRect(0, 0, w, fr[1]); ctx.fillRect(0, fr[3], w, h - fr[3]); ctx.fillRect(0, fr[1], fr[0], fr[3] - fr[1]); ctx.fillRect(fr[2], fr[1], w - fr[2], fr[3] - fr[1]);
      ctx.strokeStyle = LAV; ctx.setLineDash([6, 4]); ctx.lineWidth = 2; ctx.strokeRect(fr[0], fr[1], fr[2] - fr[0], fr[3] - fr[1]); ctx.setLineDash([]); ctx.lineWidth = 1;
      ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = LAV; ctx.fillText("camera's view", fr[0] + 6, fr[1] - 6);
      ctx.fillStyle = MUTED; ctx.fillText('outside the picture', fr[2] + 6, fr[1] + 14);
      // corners
      let found = 0, all = true;
      for (let j = 0; j < 8; j++) for (let i = 0; i < 11; i++) if (!inF(bx + (i + 1) * sq, by + (j + 1) * sq)) all = false;
      let nm = 0; for (const k in mOK) if (mOK[k]) nm++;
      for (let j = 0; j < 8; j++) for (let i = 0; i < 11; i++) {
        const x = bx + (i + 1) * sq, y = by + (j + 1) * sq;
        let ok;
        if (type === 'chess') ok = all;
        else { ok = inF(x, y) && [[i, j], [i + 1, j], [i, j + 1], [i + 1, j + 1]].some(([c, r]) => mOK[r * 12 + c]); }
        if (!ok) continue;
        found++;
        dot(ctx, [x, y], Math.max(2.5, sq * 0.12), GREEN);
        if (type === 'charuco' && sq > 24) { ctx.fillStyle = '#16a34a'; ctx.font = '600 9px JetBrains Mono'; ctx.fillText(j * 11 + i, x + 3, y - 3); }
      }
      if (type === 'chess' && !all) { ctx.fillStyle = 'rgba(14,5,24,.85)'; ctx.fillRect(fr[0] + 10, fr[3] - 38, 250, 28); ctx.fillStyle = AMBER; ctx.font = '600 12px Plus Jakarta Sans'; ctx.fillText("Can't count corners: pattern cut off", fr[0] + 18, fr[3] - 19); }
      $('#cal-bfound').textContent = found + ' of 88';
      $('#cal-bmark').textContent = type === 'chess' ? 'none' : nm + ' of 54';
    }
    draw();
  }

  /* ── Calibration coverage lab ─────────────────────────── */
  {
    const cv = $('#cal-cov'), st = Site.canvas(cv, 0.625, () => requestAnimationFrame(draw));
    let snaps = [], result = null, view = 'cov', dist = 0.7, tilt = 0.78, msg = '', msgT = 0, heat = null, timer = 0;
    const legend = $('#cal-legend');
    const heatCol = (e) => { const t = Site.clamp(Math.log10(Math.max(e, 0.1) / 0.1) / 2, 0, 1); const hue = 120 - 120 * t; return `hsla(${hue},85%,50%,${0.25 + 0.5 * t})`; };
    Site.seg($('#cal-view'), (v) => { view = v; draw(); });
    Site.seg($('#cal-dist-seg'), (v) => (dist = +v));
    Site.seg($('#cal-tilt-seg'), (v) => (tilt = +v));
    const add = (u, v, d, t) => {
      if (snaps.length >= 150) { flash('That\'s plenty: 150 snapshots'); return; }
      const s = CAL.snapshot(u, v, d, t);
      if (s.obs.length < 10) { flash('Board not found there (too little of it in view)'); return false; }
      snaps.push(s); return true;
    };
    const flash = (m) => { msg = m; msgT = performance.now(); status.textContent = m; draw(); setTimeout(draw, 1700); };
    const status = $('#cal-status'), busyBtns = ['#cal-auto', '#cal-lazy'].map((q) => $(q));
    const recal = () => {
      clearTimeout(timer);
      draw(); // the new board outline appears at once
      if (snaps.length < 4) { result = null; heat = null; status.textContent = `${snaps.length} snapshot${snaps.length === 1 ? '' : 's'}: take at least 4 to calibrate.`; draw(); return; }
      status.textContent = `Solving ${snaps.length} snapshots…`;
      busyBtns.forEach((b) => b.setAttribute('aria-busy', 'true'));
      // two frames later, so the "Solving" line paints before the solver blocks the page
      timer = setTimeout(() => requestAnimationFrame(() => setTimeout(() => {
        const t0 = performance.now();
        result = CAL.calibrate(snaps);
        heat = null;
        if (result) {
          heat = []; let worst = 0;
          for (let j = 0; j < 20; j++) for (let i = 0; i < 32; i++) { const e = CAL.modelErr(result.p, (i + 0.5) * 40, (j + 0.5) * 40); heat.push(e); if (e != null) worst = Math.max(worst, e); }
          heat.worst = worst;
        }
        busyBtns.forEach((b) => b.removeAttribute('aria-busy'));
        status.textContent = `Solved ${snaps.length} snapshots in ${((performance.now() - t0) / 1000).toFixed(1)} s. Tap to add more.`;
        draw();
      }, 0)), 0);
    };
    cv.addEventListener('click', (e) => {
      const r = cv.getBoundingClientRect();
      if (add(((e.clientX - r.left) / r.width) * 1280, ((e.clientY - r.top) / r.height) * 800, dist, tilt)) recal();
    });
    $('#cal-auto').onclick = () => { for (let i = 0; i < 10; i++) add(60 + CAL.rnd() * 1160, 50 + CAL.rnd() * 700, 0.42 + CAL.rnd() * 0.65, 0.78); recal(); };
    $('#cal-lazy').onclick = () => { for (let i = 0; i < 10; i++) add(640 + (CAL.rnd() - 0.5) * 240, 400 + (CAL.rnd() - 0.5) * 180, 0.75 + CAL.rnd() * 0.2, 0.15); recal(); };
    $('#cal-reset').onclick = () => { clearTimeout(timer); snaps = []; result = null; heat = null; busyBtns.forEach((b) => b.removeAttribute('aria-busy')); status.textContent = 'Cleared. Tap the picture to start again.'; draw(); };

    function draw() {
      if (!st.w) return;
      const { ctx, w, h } = st, s = w / 1280;
      ctx.fillStyle = '#16092a'; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.07)';
      for (let x = 80; x < 1280; x += 80) line(ctx, [x * s, 0], [x * s, h]);
      for (let y = 80; y < 800; y += 80) line(ctx, [0, y * s], [w, y * s]);
      if (view === 'cov') {
        const cnt = new Array(160).fill(0);
        for (const sn of snaps) for (const o of sn.obs) cnt[Math.min(9, Math.floor(o[3] / 80)) * 16 + Math.min(15, Math.floor(o[2] / 80))]++;
        for (let k = 0; k < 160; k++) { if (!cnt[k]) continue; ctx.fillStyle = `rgba(163,230,53,${Math.min(0.55, 0.08 + cnt[k] / 40)})`; ctx.fillRect((k % 16) * 80 * s, Math.floor(k / 16) * 80 * s, 80 * s - 1, 80 * s - 1); }
        legend.innerHTML = '<span><i style="background:rgba(163,230,53,.5)"></i>corners measured in that part of the image (brighter = more)</span>';
      } else if (view === 'model') {
        if (heat) {
          for (let k = 0; k < heat.length; k++) {
            const x = (k % 32) * 40 * s, y = Math.floor(k / 32) * 40 * s, e = heat[k];
            if (e == null) { ctx.fillStyle = 'rgba(120,110,140,.35)'; ctx.fillRect(x, y, 40 * s, 40 * s); ctx.strokeStyle = 'rgba(0,0,0,.4)'; line(ctx, [x, y + 40 * s], [x + 40 * s, y]); continue; }
            ctx.fillStyle = heatCol(e); ctx.fillRect(x, y, 40 * s + 0.5, 40 * s + 0.5);
          }
        }
        legend.innerHTML = '<span><i style="background:hsla(120,85%,50%,.4)"></i>under 0.3 px</span><span><i style="background:hsla(60,85%,50%,.6)"></i>about 1 px</span><span><i style="background:hsla(0,85%,50%,.75)"></i>10 px or more</span><span><i style="background:rgba(120,110,140,.5)"></i>beyond what the lens model can reach</span>';
      } else {
        legend.innerHTML = '<span><i style="background:#f43f5e"></i>each corner\'s miss, drawn 15× longer</span>';
      }
      // snapshot outlines
      snaps.forEach((sn, i) => {
        const q = [sn.all[0], sn.all[10], sn.all[87], sn.all[77]];
        if (q.some((p) => !p)) return;
        const last = i === snaps.length - 1;
        poly(ctx, q.map((p) => [p[0] * s, p[1] * s]), last ? 'rgba(196,181,253,.12)' : null, last ? '#fff' : 'rgba(196,181,253,.3)');
      });
      if (view === 'err' && result) {
        ctx.strokeStyle = 'rgba(244,63,94,.6)'; ctx.lineWidth = 1;
        for (const r of result.res) line(ctx, [r[0] * s, r[1] * s], [(r[0] + r[2] * 15) * s, (r[1] + r[3] * 15) * s]);
      }
      const last = snaps[snaps.length - 1];
      if (last) for (const o of last.obs) dot(ctx, [o[2] * s, o[3] * s], 2, GREEN);
      // principal point found vs true
      if (result) {
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; const t = CAL.TRUE;
        line(ctx, [t[2] * s - 7, t[3] * s], [t[2] * s + 7, t[3] * s]); line(ctx, [t[2] * s, t[3] * s - 7], [t[2] * s, t[3] * s + 7]);
        ctx.strokeStyle = AMBER; ctx.beginPath(); ctx.arc(result.p[2] * s, result.p[3] * s, 6, 0, 7); ctx.stroke(); ctx.lineWidth = 1;
      }
      ctx.font = '600 12px Plus Jakarta Sans';
      if (!snaps.length) { ctx.fillStyle = MUTED; ctx.textAlign = 'center'; ctx.fillText('Tap anywhere to take a snapshot of the board there', w / 2, h / 2); ctx.textAlign = 'left'; }
      else if (!result) { ctx.fillStyle = MUTED; ctx.fillText(`Take at least 4 snapshots to calibrate (${snaps.length} so far)`, 10, h - 10); }
      else if (view !== 'cov') { ctx.fillStyle = MUTED; ctx.font = '11px Plus Jakarta Sans'; ctx.fillText('+ true center   ○ found center', 10, h - 10); }
      if (msg && performance.now() - msgT < 1600) { ctx.fillStyle = 'rgba(14,5,24,.9)'; ctx.fillRect(8, 8, ctx.measureText(msg).width + 20, 26); ctx.fillStyle = AMBER; ctx.fillText(msg, 18, 26); }
      ctx.strokeStyle = LINE; ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
      $('#cal-n').textContent = snaps.length;
      $('#cal-nc').textContent = snaps.reduce((a, sn) => a + sn.obs.length, 0).toLocaleString();
      $('#cal-rms').textContent = result ? result.mean.toFixed(2) + ' px' : '–';
      $('#cal-ffx').textContent = result ? result.p[0].toFixed(1) : '–';
      $('#cal-fc').textContent = result ? `${result.p[2].toFixed(0)}, ${result.p[3].toFixed(0)}` : '–';
      const wv = $('#cal-worst');
      wv.textContent = heat ? (heat.worst < 10 ? heat.worst.toFixed(1) : heat.worst.toFixed(0)) + ' px' : '–';
      wv.style.color = heat ? (heat.worst > 3 ? AMBER : GREEN) : '';
    }
    draw();
  }

  /* ── Field calibration animation ──────────────────────── */
  {
    const cv = $('#cal-field'), st = Site.canvas(cv, 0.72);
    const FW = 8.27, FH = 8.04;
    // illustrative half field: tags on walls and two field elements
    const tags = [[0.05, 1.0, 0], [0.05, 4.0, 0], [0.05, 7.0, 0], [2.0, 0.05, 1], [5.5, 0.05, 1], [2.0, 7.99, 3], [5.5, 7.99, 3], [4.6, 3.6, 2], [4.6, 4.4, 2], [7.6, 2.2, 2], [7.6, 5.8, 2]];
    const moved = { 7: [0.14, -0.1], 10: [-0.12, 0.16] };
    const spots = [[1.4, 1.5, 0.6], [1.6, 4.0, 0], [1.4, 6.5, -0.6], [3.0, 2.4, 0.3], [3.2, 5.6, -0.3], [2.6, 4.0, 2.8], [5.8, 1.6, 1.8], [6.3, 4.0, 3.14], [5.8, 6.4, -1.8], [3.6, 1.2, 1.2], [3.6, 6.8, -1.2], [2.2, 3.0, -0.8]];
    const msgEl = $('#cal-fmsg');
    const seen = new Array(tags.length).fill(0);
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st; if (!w) return;
      const k = Math.min(w / FW, h / FH), ox = (w - FW * k) / 2, oy = (h - FH * k) / 2;
      const X = (x) => ox + x * k, Y = (y) => oy + (FH - y) * k;
      ctx.fillStyle = '#1b0d2c'; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.35)'; ctx.lineWidth = 2; ctx.strokeRect(X(0), Y(FH), FW * k, FH * k); ctx.lineWidth = 1;
      ctx.fillStyle = 'rgba(196,181,253,.12)'; ctx.fillRect(X(4.3), Y(4.7), 0.6 * k, 1.4 * k);
      const cycle = 16, T = Site.reduced ? 15 : t % cycle, per = 0.95, nav = spots.length * per;
      let rx, ry, rh, still = false, phase;
      if (T < nav) {
        const i = Math.floor(T / per), f = (T % per) / per, a = spots[i], b = spots[(i + 1) % spots.length];
        const m = Site.clamp((f - 0.55) / 0.45, 0, 1), e = Site.ease(m);
        rx = a[0] + (b[0] - a[0]) * e; ry = a[1] + (b[1] - a[1]) * e; rh = a[2] + (b[2] - a[2]) * e; still = f < 0.55; phase = `Recording: spot ${i + 1} of ${spots.length}`;
        if (i === 0 && f < 0.05) seen.fill(0);
      } else { const a = spots[0]; rx = a[0]; ry = a[1]; rh = a[2]; phase = T < nav + 2 ? 'Solving: every tag, spot and mount at once' : 'Solved: two tags were not where the layout said'; }
      const solveF = Site.clamp((T - nav) / 2, 0, 1);
      // tags
      tags.forEach(([x, y, face], i) => {
        const mv = moved[i] && moved[i].map((q) => q * 4);
        const tx = x + (mv ? mv[0] : 0), ty = y + (mv ? mv[1] : 0);
        if (mv) {
          ctx.fillStyle = AMBER; ctx.globalAlpha = 0.25 + 0.75 * solveF; ctx.fillRect(X(tx) - 4, Y(ty) - 4, 8, 8); ctx.globalAlpha = 1;
          if (solveF > 0) { ctx.strokeStyle = AMBER; line(ctx, [X(x), Y(y)], [X(x + mv[0] * solveF), Y(y + mv[1] * solveF)]); }
          if (solveF >= 1) { ctx.fillStyle = AMBER; ctx.font = '600 10px Plus Jakarta Sans'; ctx.fillText(`moved ${Math.round(Math.hypot(...mv) * 25)} cm`, X(tx) + 7, Y(ty) + 4); }
        }
        ctx.fillStyle = '#fff'; ctx.fillRect(X(x) - 4, Y(y) - 4, 8, 8); ctx.fillStyle = '#000'; ctx.fillRect(X(x) - 2, Y(y) - 2, 4, 4);
        ctx.fillStyle = 'rgba(184,169,212,.8)'; ctx.font = '9px JetBrains Mono'; ctx.fillText(seen[i] ? '×' + seen[i] : '', X(x) + 6, Y(y) - 6);
      });
      // rays from the robot's 4 cameras while holding still
      const cams = [[0.3, 0.3, 0.7], [0.3, -0.3, -0.7], [-0.3, 0.3, 2.4], [-0.3, -0.3, -2.4]];
      if (still && T < nav) {
        cams.forEach(([cxr, cyr, cyaw]) => {
          const px = rx + cxr * Math.cos(rh) - cyr * Math.sin(rh), py = ry + cxr * Math.sin(rh) + cyr * Math.cos(rh), ca = rh + cyaw;
          tags.forEach(([x, y], i) => {
            const mv = moved[i] && moved[i].map((q) => q * 4), tx = x + (mv ? mv[0] : 0), ty = y + (mv ? mv[1] : 0);
            const d = Math.hypot(tx - px, ty - py); let da = Math.atan2(ty - py, tx - px) - ca; da = Math.atan2(Math.sin(da), Math.cos(da));
            if (d < 5 && Math.abs(da) < 0.7) { ctx.strokeStyle = 'rgba(163,230,53,.55)'; line(ctx, [X(px), Y(py)], [X(tx), Y(ty)]); if (T % per < 0.02) seen[i]++; }
          });
        });
      }
      // robot
      ctx.save(); ctx.translate(X(rx), Y(ry)); ctx.rotate(-rh); const s = 0.8 * k;
      ctx.fillStyle = 'rgba(124,58,237,.85)'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.fillRect(-s / 2, -s / 2, s, s); ctx.strokeRect(-s / 2, -s / 2, s, s);
      ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.moveTo(s / 2, 0); ctx.lineTo(s / 2 - 6, -4); ctx.lineTo(s / 2 - 6, 4); ctx.fill();
      ctx.restore();
      phase += '. Illustration; tag moves drawn 4× larger.';
      if (msgEl.textContent !== phase) msgEl.textContent = phase;
    });
  }
  /* ── TopLeft's real calibration (from our Jetson) ─────── */
  {
    const cs = $('#cal-real-snap'), cr = $('#cal-real');
    let s1 = null, s2 = null, data = null, pick = 'img22', view = 'cov';
    const vw = { az: 2.1, el: 0.4 };
    const imgs = {}, files = { img22: 'nearest_img22', img15: 'farthest_img15', img23: 'most-tilted_img23' };
    const qrot = ([w, x, y, z]) => [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y), 2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x), 2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)];
    const meanErr = (sn) => { const u = sn.c.filter((c) => c[4]); return u.reduce((a, c) => a + Math.hypot(c[2], c[3]), 0) / u.length; };
    const tilt = (sn) => (Math.acos(Math.abs(qrot(sn.q)[8])) * 180) / Math.PI;
    const drawSnap = () => {
      if (!s1 || !s1.w || !data) return;
      const { ctx, w, h } = s1, s = w / 1280, sn = data.snaps.find((x) => x.n === pick), img = imgs[pick];
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      if (img && img.complete && img.naturalWidth) ctx.drawImage(img, 0, 0, w, h);
      for (const c of sn.c) dot(ctx, [c[0] * s, c[1] * s], Math.max(2, w / 260), c[4] ? GREEN : AMBER);
      const used = sn.c.filter((c) => c[4]).length;
      $('#cal-rs-d').textContent = sn.t[2].toFixed(2) + ' m';
      $('#cal-rs-t').textContent = tilt(sn).toFixed(0) + '°';
      $('#cal-rs-c').textContent = `${used} of 88`;
      $('#cal-rs-e').textContent = meanErr(sn).toFixed(2) + ' px';
    };
    const drawAll = () => {
      if (!s2 || !s2.w || !data) return;
      const { ctx, w, h } = s2, s = w / 1280, legend = $('#cal-real-legend');
      ctx.fillStyle = '#16092a'; ctx.fillRect(0, 0, w, h);
      if (view !== '3d') {
        ctx.strokeStyle = 'rgba(196,181,253,.07)';
        for (let x = 80; x < 1280; x += 80) line(ctx, [x * s, 0], [x * s, h]);
        for (let y = 80; y < 800; y += 80) line(ctx, [0, y * s], [w, y * s]);
        const K = data.K;
        ctx.strokeStyle = LAV; ctx.lineWidth = 1.5; line(ctx, [K[2] * s - 7, K[3] * s], [K[2] * s + 7, K[3] * s]); line(ctx, [K[2] * s, K[3] * s - 7], [K[2] * s, K[3] * s + 7]); ctx.lineWidth = 1;
        data.snaps.forEach((sn, i) => {
          const hue = (i * 360) / 43;
          for (const c of sn.c) {
            if (view === 'cov') dot(ctx, [c[0] * s, c[1] * s], 1.6, c[4] ? `hsla(${hue},80%,65%,.8)` : AMBER);
            else { ctx.strokeStyle = c[4] ? 'rgba(244,63,94,.65)' : AMBER; line(ctx, [c[0] * s, c[1] * s], [(c[0] + c[2] * 15) * s, (c[1] + c[3] * 15) * s]); }
          }
        });
        legend.innerHTML = view === 'cov'
          ? '<span><i style="background:hsl(200,80%,65%)"></i>one color per snapshot</span><span><i style="background:#f59e0b"></i>thrown out</span><span><i style="background:#c4b5fd"></i>+ principal point</span>'
          : '<span><i style="background:#f43f5e"></i>each corner\'s leftover error, drawn 15× longer</span><span><i style="background:#f59e0b"></i>thrown out</span>';
      } else {
        const V = viewer(vw.az, vw.el, w * 3.2, 6, w * 0.5, h * 0.5);
        const W3 = (p) => V([p[2] - 0.25, -p[0] + 0.12, -p[1] + 0.08]);
        const K = data.K, hf = [-K[2] / K[0], (1280 - K[2]) / K[0]], vf = [-K[3] / K[1], (800 - K[3]) / K[1]], Z = 0.62;
        const fr = [[hf[0], vf[0]], [hf[1], vf[0]], [hf[1], vf[1]], [hf[0], vf[1]]].map(([a, b]) => W3([a * Z, b * Z, Z]));
        ctx.strokeStyle = 'rgba(139,92,246,.4)'; fr.forEach((q) => line(ctx, W3([0, 0, 0]), q)); poly(ctx, fr, 'rgba(139,92,246,.05)', 'rgba(139,92,246,.4)');
        const boards = data.snaps.map((sn) => {
          const Rm = qrot(sn.q), T = (x, y) => [Rm[0] * x + Rm[1] * y + sn.t[0], Rm[3] * x + Rm[4] * y + sn.t[1], Rm[6] * x + Rm[7] * y + sn.t[2]];
          const pts = [[-0.03, -0.03], [0.33, -0.03], [0.33, 0.24], [-0.03, 0.24]].map(([x, y]) => T(x, y));
          return { pts, d: pts.reduce((a, p) => a + W3(p)[2], 0), e: meanErr(sn) };
        }).sort((a, b) => a.d - b.d);
        for (const b of boards) { const t = Site.clamp((b.e - 0.45) / 1, 0, 1); poly(ctx, b.pts.map(W3), `hsla(${100 - 70 * t},80%,55%,.13)`, `hsla(${100 - 70 * t},80%,60%,.75)`); }
        dot(ctx, W3([0, 0, 0]), 4, '#fff');
        ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = INK; ctx.fillText('camera', W3([0, 0, 0])[0] + 8, W3([0, 0, 0])[1] + 14);
        legend.innerHTML = '<span><i style="background:hsl(100,80%,55%)"></i>board with a low mean error</span><span><i style="background:hsl(30,80%,55%)"></i>higher error</span><span>drag to turn</span>';
      }
      ctx.strokeStyle = LINE; ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
    };
    orbit(cr, vw, () => view === '3d' && drawAll());
    s1 = Site.canvas(cs, 0.625, () => requestAnimationFrame(drawSnap));
    s2 = Site.canvas(cr, 0.625, () => requestAnimationFrame(drawAll));
    Site.seg($('#cal-real-pick'), (v) => {
      pick = v;
      if (!imgs[v]) { imgs[v] = new Image(); imgs[v].onload = drawSnap; imgs[v].src = `assets/from-jetson/calibration-snapshots/calibration-snapshot-${files[v]}.webp`; }
      drawSnap();
    });
    Site.seg($('#cal-real-view'), (v) => { view = v; cr.classList.toggle('drag', v === '3d'); drawAll(); });
    fetch('assets/from-jetson/calibration/TopLeft-compact.json').then((r) => r.json()).then((j) => {
      data = j;
      let kept = 0, all = 0, sum = 0;
      for (const sn of j.snaps) for (const c of sn.c) { all++; if (c[4]) { kept++; sum += Math.hypot(c[2], c[3]); } }
      let x0 = 1e9, x1 = 0, y0 = 1e9, y1 = 0;
      j.snaps.forEach((sn) => sn.c.forEach((c) => { x0 = Math.min(x0, c[0]); x1 = Math.max(x1, c[0]); y0 = Math.min(y0, c[1]); y1 = Math.max(y1, c[1]); }));
      $('#cal-real-kept').textContent = `${kept.toLocaleString()} of ${all.toLocaleString()} (${Math.round((kept / all) * 100)}%)`;
      $('#cal-real-mean').textContent = (sum / kept).toFixed(2) + ' px';
      $('#cal-real-f').textContent = `${j.K[0].toFixed(1)}, ${j.K[1].toFixed(1)}`;
      $('#cal-real-c').textContent = `${j.K[2].toFixed(1)}, ${j.K[3].toFixed(1)}`;
      $('#cal-real-note').textContent = `The corners only reach x ${x0.toFixed(0)}–${x1.toFixed(0)} px and y ${y0.toFixed(0)}–${y1.toFixed(0)} px, and none landed in the image's four corners. That's why this lens model can't be trusted in the far corners (see "where it gives up" above). The next calibration should reach them.`;
      drawSnap(); drawAll();
    });
  }
});
