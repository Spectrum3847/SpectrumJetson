import * as THREE from 'three';
import { OrbitControls } from 'three/addons/OrbitControls.js';

Object.assign(Site.glossary, {
  'Perspective-n-Point': 'PnP: finding a camera\'s position and rotation from known 3D points and where they appear in the image.',
  'multi-tag': 'Solving one pose from the corners of every tag in view at once, using the field layout. Much steadier than one tag.',
  'standard deviation': 'A measure of spread: how far a measurement typically is from the truth. Smaller means more trustworthy.',
});

/* ── Pose math shared by the labs ──────────────────────────────
   Field frame is WPILib's: x forward, y left, z up. A camera pose is {C, R}, where R's columns
   are the camera's forward, left and up directions. Pixels use TopRight's real calibration. */
const K = { fx: 736.985, fy: 737.214, cx: 597.901, cy: 371.578, w: 1280, h: 800 };
const TAG = 0.1651;
const dot3 = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const col = (R, i) => [R[i], R[3 + i], R[6 + i]];
const mat = (f, l, u) => [f[0], l[0], u[0], f[1], l[1], u[1], f[2], l[2], u[2]];
const mul3 = (A, B) => { const C = []; for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) C.push(A[i * 3] * B[j] + A[i * 3 + 1] * B[3 + j] + A[i * 3 + 2] * B[6 + j]); return C; };
const rod = (r) => {
  const th = Math.hypot(r[0], r[1], r[2]);
  if (th < 1e-12) return [1, 0, 0, 0, 1, 0, 0, 0, 1];
  const x = r[0] / th, y = r[1] / th, z = r[2] / th, c = Math.cos(th), s = Math.sin(th), C = 1 - c;
  return [c + x * x * C, x * y * C - z * s, x * z * C + y * s, y * x * C + z * s, c + y * y * C, y * z * C - x * s, z * x * C - y * s, z * y * C + x * s, c + z * z * C];
};
const Rz = (a) => [Math.cos(a), -Math.sin(a), 0, Math.sin(a), Math.cos(a), 0, 0, 0, 1];
// camera rotation from yaw and pitch (positive pitch = down, WPILib)
const camR = (yaw, pitch) => {
  const f = [Math.cos(pitch) * Math.cos(yaw), Math.cos(pitch) * Math.sin(yaw), -Math.sin(pitch)];
  const l = [-Math.sin(yaw), Math.cos(yaw), 0];
  return mat(f, l, [f[1] * l[2] - f[2] * l[1], f[2] * l[0] - f[0] * l[2], f[0] * l[1] - f[1] * l[0]]);
};
const project = (pose, P) => {
  const d = [P[0] - pose.C[0], P[1] - pose.C[1], P[2] - pose.C[2]];
  const zc = dot3(d, col(pose.R, 0));
  if (zc < 0.05) return null;
  return [K.fx * -dot3(d, col(pose.R, 1)) / zc + K.cx, K.fy * -dot3(d, col(pose.R, 2)) / zc + K.cy];
};
// tag = {x, y, z, yaw}: its face points along yaw. Corners of the black square (or scale s for the white border).
const tagCorners = (t, s = 1) => {
  const h = (TAG * s) / 2, ty = [-Math.sin(t.yaw), Math.cos(t.yaw)];
  // TL, TR, BR, BL as seen from in front of the tag
  return [[h, h], [-h, h], [-h, -h], [h, -h]].map(([a, b]) => [t.x + ty[0] * a, t.y + ty[1] * a, t.z + b]);
};
let seed = 12345;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const gauss = () => Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd());
const observe = (pose, tags, noise, truthTags = tags) => {
  const obs = [];
  tags.forEach((t, i) => {
    const P = tagCorners(truthTags[i]), L = tagCorners(t);
    const px = P.map((p) => project(pose, p));
    if (px.some((q) => !q || q[0] < 1 || q[1] < 1 || q[0] > K.w - 1 || q[1] > K.h - 1)) return;
    px.forEach((q, k) => obs.push({ P: L[k], uv: [q[0] + gauss() * noise, q[1] + gauss() * noise], tag: i }));
  });
  return obs;
};
const residuals = (pose, obs) => { const r = []; for (const o of obs) { const q = project(pose, o.P); if (!q) { r.push(1e3, 1e3); continue; } r.push(q[0] - o.uv[0], q[1] - o.uv[1]); } return r; };
const rms = (pose, obs) => { const r = residuals(pose, obs); let s = 0; for (let i = 0; i < r.length; i += 2) s += r[i] * r[i] + r[i + 1] * r[i + 1]; return Math.sqrt(s / (r.length / 2)); };
function solve6(A, b) {
  const n = 6, M = A.slice(), x = b.slice();
  for (let c = 0; c < n; c++) {
    let p = c; for (let r = c + 1; r < n; r++) if (Math.abs(M[r * n + c]) > Math.abs(M[p * n + c])) p = r;
    for (let k = 0; k < n; k++) { const t = M[c * n + k]; M[c * n + k] = M[p * n + k]; M[p * n + k] = t; } const t = x[c]; x[c] = x[p]; x[p] = t;
    const d = M[c * n + c] || 1e-12;
    for (let r = c + 1; r < n; r++) { const f = M[r * n + c] / d; for (let k = c; k < n; k++) M[r * n + k] -= f * M[c * n + k]; x[r] -= f * x[c]; }
  }
  for (let c = n - 1; c >= 0; c--) { let s = x[c]; for (let k = c + 1; k < n; k++) s -= M[c * n + k] * x[k]; x[c] = s / (M[c * n + c] || 1e-12); }
  return x;
}
const step = (pose, d) => ({ R: mul3(rod([d[0], d[1], d[2]]), pose.R), C: [pose.C[0] + d[3], pose.C[1] + d[4], pose.C[2] + d[5]] });
// Levenberg–Marquardt on the full 6-DOF camera pose.
function pnp(obs, init, iters = 40) {
  let pose = init, r0 = residuals(pose, obs), cost = r0.reduce((s, v) => s + v * v, 0), lam = 1e-3;
  for (let it = 0; it < iters; it++) {
    const J = [];
    for (let k = 0; k < 6; k++) { const d = [0, 0, 0, 0, 0, 0]; d[k] = 1e-6; const r = residuals(step(pose, d), obs); J.push(r.map((v, i) => (v - r0[i]) / 1e-6)); }
    const A = new Array(36).fill(0), g = new Array(6).fill(0);
    for (let i = 0; i < 6; i++) { for (let j = 0; j < 6; j++) { let s = 0; for (let m = 0; m < r0.length; m++) s += J[i][m] * J[j][m]; A[i * 6 + j] = s; } let s = 0; for (let m = 0; m < r0.length; m++) s += J[i][m] * r0[m]; g[i] = -s; }
    let ok = false;
    for (let t = 0; t < 8 && !ok; t++) {
      const Ad = A.slice(); for (let i = 0; i < 6; i++) Ad[i * 7] += lam * (A[i * 7] + 1e-9);
      const np = step(pose, solve6(Ad, g)), nr = residuals(np, obs), nc = nr.reduce((s, v) => s + v * v, 0);
      if (nc < cost) { const done = cost - nc < 1e-10 * cost; pose = np; r0 = nr; cost = nc; lam = Math.max(1e-9, lam / 4); ok = true; if (done) it = iters; } else lam *= 6;
    }
    if (!ok) break;
  }
  return pose;
}
// the other planar solution: turn the camera about the vertical line through the tag, to the other side of its normal
const mirror = (pose, t) => {
  const v = [pose.C[0] - t.x, pose.C[1] - t.y];
  let a = Math.atan2(v[1], v[0]) - t.yaw; a = Math.atan2(Math.sin(a), Math.cos(a));
  const Rm = Rz(-2 * a), c = Math.cos(-2 * a), s = Math.sin(-2 * a);
  return { R: mul3(Rm, pose.R), C: [t.x + c * v[0] - s * v[1], t.y + s * v[0] + c * v[1], pose.C[2]] };
};
const jitter = (pose, rot = 0.03, pos = 0.05) => step(pose, [gauss() * rot, gauss() * rot, gauss() * rot, gauss() * pos, gauss() * pos, gauss() * pos]);
// Solve one tag both ways; return best, alt, errors, ambiguity (best / alt), like PhotonVision.
function singleTag(obs, truth, tag) {
  const A = pnp(obs, jitter(truth)), B = pnp(obs, jitter(mirror(truth, tag), 0.01, 0.02));
  const ea = rms(A, obs), eb = rms(B, obs);
  const same = Math.hypot(A.C[0] - B.C[0], A.C[1] - B.C[1]) < 0.02;
  const [best, alt, e1, e2] = ea <= eb ? [A, B, ea, eb] : [B, A, eb, ea];
  return { A, B, ea, eb, best, alt, amb: same ? 0 : e1 / Math.max(e2, 1e-9), same, bestIsA: ea <= eb };
}
const yawOf = (pose) => Math.atan2(pose.R[3], pose.R[0]);
// our illustrative mount: camera 0.3 m ahead of the robot center, 0.5 m up, pitched 8° up
const MOUNT = { x: 0.3, z: 0.5, pitch: -8 * Math.PI / 180 };
const camFromRobot = (x, y, th) => ({ C: [x + MOUNT.x * Math.cos(th), y + MOUNT.x * Math.sin(th), MOUNT.z], R: camR(th, MOUNT.pitch) });
const robotFromCam = (pose) => { const th = yawOf(pose); return { x: pose.C[0] - MOUNT.x * Math.cos(th), y: pose.C[1] - MOUNT.x * Math.sin(th), th }; };

const LAB = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', RED = '#f43f5e', GREEN = '#a3e635', AMBER = '#f59e0b', LAV = '#c4b5fd';
const line = (ctx, a, b) => { ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke(); };
const dot = (ctx, p, r, c) => { ctx.fillStyle = c; ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 7); ctx.fill(); };
const quad = (ctx, pts, stroke, w = 1.5) => { ctx.strokeStyle = stroke; ctx.lineWidth = w; ctx.beginPath(); pts.forEach((p, i) => (i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]))); ctx.closePath(); ctx.stroke(); ctx.lineWidth = 1; };
// robot (square + heading) and camera wedge in a top-down view; T maps field (x, y) -> canvas
const drawBot = (ctx, T, k, r, color, fill, wedge = true) => {
  const p = T(r.x, r.y), a = Math.atan2(T(r.x + Math.cos(r.th), r.y + Math.sin(r.th))[1] - p[1], T(r.x + Math.cos(r.th), r.y + Math.sin(r.th))[0] - p[0]);
  ctx.save(); ctx.translate(p[0], p[1]); ctx.rotate(a);
  const s = Math.max(10, 0.8 * k);
  if (wedge) { ctx.fillStyle = color === '#fff' ? 'rgba(255,255,255,.07)' : color + '22'; ctx.beginPath(); ctx.moveTo(s * 0.35, 0); ctx.lineTo(s * 0.35 + 1.4 * s * Math.cos(0.7), 1.4 * s * Math.sin(0.7)); ctx.lineTo(s * 0.35 + 1.4 * s * Math.cos(0.7), -1.4 * s * Math.sin(0.7)); ctx.fill(); }
  ctx.fillStyle = fill; ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.fillRect(-s / 2, -s / 2, s, s); ctx.strokeRect(-s / 2, -s / 2, s, s);
  ctx.fillStyle = color; ctx.beginPath(); ctx.moveTo(s / 2, 0); ctx.lineTo(s / 2 - 6, -4); ctx.lineTo(s / 2 - 6, 4); ctx.fill();
  ctx.restore(); ctx.lineWidth = 1;
};

Site.chapter('pose', (root) => {
  const $ = (s) => root.querySelector(s);
  const later = (fn) => () => requestAnimationFrame(fn);

  /* ── Similar triangles ──────────────────────────────── */
  {
    const cv = $('#po-tri'); let st = null, d = 2;
    const draw = () => {
      if (!st || !st.w) return;
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      const px = (K.fy * TAG) / d, px1 = (K.fy * TAG) / (d + 0.0), mid = h * 0.5;
      const pin = [w * 0.2, mid], sensorX = w * 0.08;
      const X = (m) => pin[0] + (m / 8) * (w * 0.76);
      const tagH = h * 0.34; // drawn tag height (not to scale)
      const tx = X(d);
      // image height scales like 1/d
      const imgH = (tagH * (pin[0] - sensorX)) / (tx - pin[0]) * 1.0;
      ctx.strokeStyle = 'rgba(196,181,253,.12)';
      const ax = h - 30; for (let m = 1; m <= 8; m++) { line(ctx, [X(m), ax - 3], [X(m), ax + 3]); ctx.fillStyle = MUTED; ctx.font = '10px JetBrains Mono'; ctx.fillText(m + ' m', X(m) - 8, ax + 16); }
      line(ctx, [pin[0], ax], [X(8), ax]);
      // camera box
      ctx.fillStyle = '#2a1840'; ctx.strokeStyle = '#6b5a8c'; ctx.fillRect(sensorX - 6, mid - h * 0.3, pin[0] - sensorX + 6, h * 0.6); ctx.strokeRect(sensorX - 6, mid - h * 0.3, pin[0] - sensorX + 6, h * 0.6);
      ctx.fillStyle = LAV; ctx.fillRect(sensorX - 2, mid - h * 0.26, 4, h * 0.52);
      // rays
      ctx.strokeStyle = 'rgba(245,158,11,.8)'; ctx.lineWidth = 1.5;
      line(ctx, [tx, mid - tagH / 2], [sensorX, mid + imgH / 2]); line(ctx, [tx, mid + tagH / 2], [sensorX, mid - imgH / 2]); ctx.lineWidth = 1;
      dot(ctx, pin, 3, '#fff');
      // tag (side view) and its image
      ctx.fillStyle = '#fff'; ctx.fillRect(tx - 2, mid - tagH / 2, 4, tagH);
      ctx.fillStyle = RED; ctx.fillRect(sensorX - 3, mid - imgH / 2, 6, imgH);
      ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = INK; ctx.fillText('tag, 165.1 mm', Math.min(tx + 6, w - 90), mid - tagH / 2 - 6);
      ctx.fillStyle = MUTED; ctx.fillText('pinhole', pin[0] - 18, mid - h * 0.3 - 6); ctx.fillText('sensor', sensorX - 4, mid + h * 0.3 + 14);
      // 1-px error band on the distance
      const dN = (K.fy * TAG) / (px + 1), dF = (K.fy * TAG) / Math.max(1, px - 1);
      ctx.fillStyle = 'rgba(245,158,11,.35)'; ctx.fillRect(X(dN), ax - 8, Math.max(3, X(Math.min(8.5, dF)) - X(dN)), 16);
      ctx.fillStyle = AMBER; ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillText('range if 1 px off', Math.min(X(dN), w - 100), ax - 12);
      $('#po-tri-px').textContent = px.toFixed(1) + ' px';
      $('#po-tri-err').textContent = `±${(((dF - dN) / 2) * 100).toFixed(d < 2 ? 1 : 0)} cm`;
      void px1;
    };
    st = Site.canvas(cv, 0.55, later(draw));
    Site.range($('#po-tri-d'), (v) => { d = v; draw(); }, (v) => v.toFixed(2) + ' m');
  }

  /* ── Three clues ────────────────────────────────────── */
  {
    const ct = $('#po-clue-top'), ci = $('#po-clue-img'); let s1 = null, s2 = null;
    const P = { d: 1.2, b: 12, y: 35 };
    const tagImg = Site.tagCanvas(1, 200);
    const draw = () => {
      if (!s1 || !s2 || !s1.w) return;
      const b = (P.b * Math.PI) / 180, yw = (P.y * Math.PI) / 180;
      const cam = { C: [0, 0, 0.9], R: camR(0, 0) };
      const tag = { x: P.d * Math.cos(b), y: -P.d * Math.sin(b), z: 0.9, yaw: Math.PI - b + yw };
      // top view: camera at bottom center looking up the canvas
      { const { ctx, w, h } = s1, k = (h * 0.85) / 4.3, T = (x, y) => [w / 2 - y * k, h - 20 - x * k];
        ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
        ctx.strokeStyle = 'rgba(139,92,246,.35)'; const hf = Math.atan(K.cx / K.fx);
        line(ctx, T(0, 0), T(7 * Math.cos(hf), 7 * Math.sin(hf))); line(ctx, T(0, 0), T(7 * Math.cos(hf), -7 * Math.sin(hf)));
        ctx.setLineDash([3, 4]); ctx.strokeStyle = 'rgba(255,255,255,.25)'; line(ctx, T(0, 0), T(6.5, 0)); ctx.setLineDash([]);
        const c = tagCorners(tag);
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 4; line(ctx, T(c[0][0], c[0][1]), T(c[1][0], c[1][1])); ctx.lineWidth = 1;
        const tc = T(tag.x, tag.y), nrm = T(tag.x + 0.5 * Math.cos(tag.yaw), tag.y + 0.5 * Math.sin(tag.yaw));
        ctx.strokeStyle = LAV; ctx.setLineDash([2, 3]); line(ctx, tc, nrm); ctx.setLineDash([]);
        ctx.strokeStyle = 'rgba(245,158,11,.7)'; line(ctx, T(0, 0), tc);
        dot(ctx, T(0, 0), 5, '#fff');
        ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = INK; ctx.fillText('camera', T(0, 0)[0] + 8, T(0, 0)[1] - 2); ctx.fillText('tag', tc[0] + 8, tc[1] - 6);
        ctx.fillStyle = AMBER; ctx.fillText(P.d.toFixed(1) + ' m', (T(0, 0)[0] + tc[0]) / 2 + 6, (T(0, 0)[1] + tc[1]) / 2);
      }
      // image
      { const { ctx, w, h } = s2, s = w / 640, ox = K.cx - 320, oy = K.cy - 200, M = (q) => [(q[0] - ox) * s, (q[1] - oy) * s];
        ctx.fillStyle = '#16092a'; ctx.fillRect(0, 0, w, h);
        ctx.setLineDash([3, 4]); ctx.strokeStyle = 'rgba(255,255,255,.25)'; line(ctx, [320 * s, 0], [320 * s, h]); ctx.setLineDash([]);
        ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.fillText('center of the image, 2× zoom', 8, h - 8);
        const outer = tagCorners(tag, 10 / 8).map((p) => project(cam, p)), inner = tagCorners(tag).map((p) => project(cam, p));
        if (outer.every(Boolean)) {
          Site.drawQuad(ctx, tagImg, outer.map(M), 12);
          inner.forEach((q) => dot(ctx, M(q), 3.5, RED));
          const hL = Math.hypot(inner[0][0] - inner[3][0], inner[0][1] - inner[3][1]), hR = Math.hypot(inner[1][0] - inner[2][0], inner[1][1] - inner[2][1]);
          const wid = (Math.hypot(inner[0][0] - inner[1][0], inner[0][1] - inner[1][1]) + Math.hypot(inner[3][0] - inner[2][0], inner[3][1] - inner[2][1])) / 2, hh = (hL + hR) / 2;
          const uc = inner.reduce((a, q) => a + q[0], 0) / 4;
          // edge heights, drawn beside the tag
          ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED;
          const oL = M(outer[0]), oR = M(outer[1]);
          ctx.fillText(hL.toFixed(0) + ' px', Math.min(oL[0], oR[0]) - 44, M([0, (inner[0][1] + inner[3][1]) / 2])[1]);
          ctx.fillText(hR.toFixed(0) + ' px', Math.max(oL[0], oR[0]) + 6, M([0, (inner[1][1] + inner[2][1]) / 2])[1]);
          $('#po-c-r1').textContent = ((K.fy * TAG) / hh).toFixed(2) + ' m';
          const dir = (Math.atan((uc - K.cx) / K.fx) * 180) / Math.PI;
          $('#po-c-r2').textContent = Math.abs(dir).toFixed(0) + '° ' + (dir > 0.5 ? 'right' : dir < -0.5 ? 'left' : '');
          const ang = (Math.acos(Math.min(1, wid / hh)) * 180) / Math.PI;
          $('#po-c-r3').textContent = ang < 3 ? 'straight on' : `${ang.toFixed(0)}°, ${hL > hR ? 'left' : 'right'} edge nearer`;
        } else { ctx.fillStyle = AMBER; ctx.font = '600 12px Plus Jakarta Sans'; ctx.fillText('The tag is out of view', 10, 20); }
        ctx.strokeStyle = 'rgba(196,181,253,.25)'; ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
      }
    };
    s1 = Site.canvas(ct, 0.625, later(draw)); s2 = Site.canvas(ci, 0.625, later(draw));
    Site.range($('#po-c-d'), (v) => { P.d = v; draw(); }, (v) => v.toFixed(1) + ' m');
    Site.range($('#po-c-b'), (v) => { P.b = v; draw(); }, (v) => Math.abs(v) + '° ' + (v > 0 ? 'right' : v < 0 ? 'left' : ''));
    Site.range($('#po-c-y'), (v) => { P.y = v; draw(); }, (v) => v + '°');
  }

  /* ── Real frames ────────────────────────────────────── */
  {
    const cv = $('#po-real'), info = $('#po-real-info'); let st = null, det = null, cur = '2024-speaker-63in';
    const imgs = {};
    const draw = () => {
      if (!st || !st.w || !det) return;
      const d = det[cur], img = imgs[cur];
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      if (!img || !img.complete) return;
      const s = Math.min(w / d.width, h / d.height), ox = (w - d.width * s) / 2, oy = (h - d.height * s) / 2;
      ctx.drawImage(img, ox, oy, d.width * s, d.height * s);
      const P = (q) => [ox + q[0] * s, oy + q[1] * s];
      const lines = [], placed = [];
      for (const t of d.tags) {
        const c = t.corners.map(P);
        quad(ctx, c, GREEN, 2);
        c.forEach((q, i) => { dot(ctx, q, 3.5, RED); ctx.fillStyle = '#fff'; ctx.font = '700 10px JetBrains Mono'; ctx.fillText(i + 1, q[0] + 4, q[1] + (i < 2 ? 12 : -4)); });
        const wpx = Math.hypot(t.corners[0][0] - t.corners[1][0], t.corners[0][1] - t.corners[1][1]);
        const lab = `ID ${t.id} · ${wpx.toFixed(0)} px`, top = Math.min(...c.map((q) => q[1])), cx0 = c.reduce((a, q) => a + q[0], 0) / 4;
        ctx.font = '700 11px Plus Jakarta Sans'; const tw = ctx.measureText(lab).width + 10;
        const lx = Site.clamp(cx0 - tw / 2, 2, w - tw - 2); let ly = Math.max(16, top - 8);
        while (placed.some((q) => lx < q[0] + q[2] && lx + tw > q[0] && Math.abs(ly - q[1]) < 18)) ly -= 19;
        placed.push([lx, ly, tw]);
        ctx.fillStyle = 'rgba(14,5,24,.85)'; ctx.fillRect(lx, ly - 13, tw, 17); ctx.fillStyle = GREEN; ctx.fillText(lab, lx + 5, ly);
        lines.push(`tag ${t.id}: ${wpx.toFixed(0)} px wide, decision margin ${t.decision_margin}${t.hamming ? `, ${t.hamming} bits corrected` : ''}`);
      }
      info.textContent = lines.join(' · ') + '. Corners numbered in the order the detector reports them.';
    };
    st = Site.canvas(cv, 0.5625, later(draw));
    fetch('assets/field-images/detections.json').then((r) => r.json()).then((j) => { det = j; show(cur); });
    const show = (k) => {
      cur = k;
      if (!det) return;
      if (!imgs[k]) { imgs[k] = new Image(); imgs[k].onload = draw; imgs[k].src = 'assets/field-images/' + det[k].file; }
      draw();
    };
    Site.seg($('#po-real-seg'), show);
  }

  /* ── three.js PnP scene ─────────────────────────────── */
  {
    const wrap = $('#po-3d'), insetCv = $('#po-3d-img');
    // Tags 3 and 4 as on the 2026 AndyMark layout's red hub face: 0.3556 m apart, 1.124 m up, side by side
    // (tag 4 on tag 3's right as you face them). The wall is x = 0, facing +x.
    const TAGP = { x: 0, y: 4.1, z: 1.124, yaw: 0 }, TAG4 = { x: 0, y: 4.1 + 0.3556, z: 1.124, yaw: 0 };
    // default view: 1.7 m from tag 3, straight on; the single-tag solve is right in every noisy frame here (checked: 500 draws, worst 9.6 cm)
    const S = { x: 1.8, y: 3.6, th: Math.PI, noise: 0.5, chain: true, two: false };
    const W2T = (x, y, z) => new THREE.Vector3(x, z, -y);
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    wrap.prepend(renderer.domElement);
    const scene = new THREE.Scene();
    const cam = new THREE.PerspectiveCamera(45, 1.6, 0.05, 100);
    cam.position.copy(W2T(6.2, -0.6, 3.6));
    const controls = new OrbitControls(cam, renderer.domElement);
    controls.target.copy(W2T(1.6, 3.0, 0.5)); controls.maxPolarAngle = Math.PI * 0.48; controls.minDistance = 2; controls.maxDistance = 14;
    controls.update();
    scene.add(new THREE.HemisphereLight(0xe9ddf7, 0x1a0a2b, 1.6));
    const dl = new THREE.DirectionalLight(0xffffff, 1.4); dl.position.set(4, 8, 3); scene.add(dl);
    // floor, field grid, wall and tag
    const floor = new THREE.Mesh(new THREE.PlaneGeometry(9, 8), new THREE.MeshStandardMaterial({ color: 0x241536, roughness: 1 }));
    floor.rotation.x = -Math.PI / 2; floor.position.copy(W2T(3.5, 3.5, 0)); scene.add(floor);
    const grid = new THREE.GridHelper(8, 16, 0x5b3d85, 0x3a2757); grid.position.copy(W2T(4, 4, 0.002)); scene.add(grid);
    const wall = new THREE.Mesh(new THREE.BoxGeometry(0.08, 1.6, 2.6), new THREE.MeshStandardMaterial({ color: 0x3a3a44, roughness: 0.9 }));
    wall.position.copy(W2T(-0.04, TAGP.y + 0.18, 0.8)); scene.add(wall);
    const tagMeshOf = (id, t) => {
      const tex = new THREE.CanvasTexture(Site.tagCanvas(id, 100)); tex.magFilter = THREE.NearestFilter; tex.minFilter = THREE.NearestFilter; tex.colorSpace = THREE.SRGBColorSpace;
      const m = new THREE.Mesh(new THREE.PlaneGeometry(TAG * 10 / 8, TAG * 10 / 8), new THREE.MeshBasicMaterial({ map: tex }));
      m.position.copy(W2T(0.002, t.y, t.z)); m.rotation.y = Math.PI / 2; scene.add(m); return m;
    };
    tagMeshOf(3, TAGP);
    const tag4Mesh = tagMeshOf(4, TAG4); tag4Mesh.visible = false;
    const axes = (len, w = 3) => { const g = new THREE.Group(); [[1, 0, 0, 0xef4444], [0, 1, 0, 0x22c55e], [0, 0, 1, 0x3b82f6]].forEach(([x, y, z, c]) => g.add(new THREE.ArrowHelper(W2T(x, y, z).normalize(), new THREE.Vector3(), len, c, len * 0.25, len * 0.14))); void w; return g; };
    const tagAx = axes(0.35); tagAx.position.copy(W2T(0.01, TAGP.y, TAGP.z)); scene.add(tagAx);
    const originAx = axes(0.6); scene.add(originAx);
    const label = (text, color) => {
      const c = document.createElement('canvas'); c.width = 256; c.height = 64; const x = c.getContext('2d');
      x.font = '700 30px Plus Jakarta Sans, sans-serif'; x.fillStyle = 'rgba(14,5,24,.8)'; const tw = x.measureText(text).width + 24; x.fillRect((256 - tw) / 2, 8, tw, 48); x.fillStyle = color; x.textAlign = 'center'; x.fillText(text, 128, 43);
      const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(c), depthTest: false })); sp.scale.set(0.9, 0.225, 1); sp.renderOrder = 10; return sp;
    };
    const lOrigin = label('field origin', '#c4b5fd'); lOrigin.position.copy(W2T(0.2, -0.3, 0.3)); scene.add(lOrigin);
    const lTag = label('tag 3', '#ffffff'); lTag.position.copy(W2T(0.1, TAGP.y - 0.1, TAGP.z + 0.35)); scene.add(lTag);
    const lTag4 = label('tag 4', '#ffffff'); lTag4.position.copy(W2T(0.1, TAG4.y + 0.1, TAG4.z + 0.35)); lTag4.visible = false; scene.add(lTag4);
    // robot
    const mkRobot = (color, ghost) => {
      const g = new THREE.Group();
      const body = new THREE.BoxGeometry(0.8, 0.15, 0.8);
      if (ghost) {
        const e = new THREE.LineSegments(new THREE.EdgesGeometry(body), new THREE.LineBasicMaterial({ color })); e.position.y = 0.1; g.add(e);
        const m = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(0.08, 0.06, 0.1)), new THREE.LineBasicMaterial({ color })); m.position.set(MOUNT.x, MOUNT.z, 0); g.add(m);
      } else {
        const b = new THREE.Mesh(body, new THREE.MeshStandardMaterial({ color: 0x6b1199, roughness: 0.6 })); b.position.y = 0.1; g.add(b);
        const top = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.02, 0.7), new THREE.MeshStandardMaterial({ color: 0x2a1840 })); top.position.y = 0.185; g.add(top);
        const mast = new THREE.Mesh(new THREE.BoxGeometry(0.03, MOUNT.z - 0.18, 0.03), new THREE.MeshStandardMaterial({ color: 0x888899 })); mast.position.set(MOUNT.x, (MOUNT.z + 0.18) / 2, 0); g.add(mast);
        const camBox = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.06, 0.1), new THREE.MeshStandardMaterial({ color: 0x111111 })); camBox.position.set(MOUNT.x, MOUNT.z, 0); g.add(camBox);
        const arrow = new THREE.Mesh(new THREE.ConeGeometry(0.08, 0.2, 3), new THREE.MeshStandardMaterial({ color: 0xffffff })); arrow.rotation.z = -Math.PI / 2; arrow.position.set(0.25, 0.2, 0); g.add(arrow);
      }
      scene.add(g); return g;
    };
    const robot = mkRobot(0xffffff, false), ghost = mkRobot(0xa3e635, true);
    const pickBox = new THREE.Mesh(new THREE.BoxGeometry(1.3, 1.0, 1.3), new THREE.MeshBasicMaterial({ visible: false })); pickBox.position.y = 0.4; robot.add(pickBox);
    const setBot = (g, r) => { g.position.copy(W2T(r.x, r.y, 0)); g.rotation.y = r.th; };
    const camAx = axes(0.25); scene.add(camAx);
    // dynamic lines: frustum, rays, chain
    const lineObj = (color, dashed) => { const m = dashed ? new THREE.LineDashedMaterial({ color, dashSize: 0.08, gapSize: 0.06 }) : new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.9 }); const l = new THREE.LineSegments(new THREE.BufferGeometry(), m); scene.add(l); return l; };
    const frust = lineObj(0x8b5cf6), rays = lineObj(0xf43f5e), chainA = lineObj(0xc4b5fd, true), chainB = lineObj(0xa3e635, true), chainC = lineObj(0xf59e0b, true);
    const setLines = (l, pts) => { l.geometry.setFromPoints(pts); if (l.material.isLineDashedMaterial) l.computeLineDistances(); };
    const lL = label('layout', '#c4b5fd'), lP = label('PnP', '#a3e635'), lM = label('robotToCamera', '#f59e0b'); [lL, lP, lM].forEach((s) => scene.add(s));
    let ist = null, lastInset = null;
    const inset = (obs, sol) => {
      lastInset = [obs, sol];
      if (!ist || !ist.w) return;
      const { ctx, w, h } = ist, s = w / K.w;
      ctx.fillStyle = '#16092a'; ctx.fillRect(0, 0, w, h);
      const pose = camFromRobot(S.x, S.y, S.th), tags = S.two ? [[3, TAGP], [4, TAG4]] : [[3, TAGP]];
      const outers = tags.map(([id, t]) => [id, tagCorners(t, 10 / 8).map((p) => project(pose, p))]);
      const solCs = sol ? tags.map(([, t]) => tagCorners(t).map((p) => project(sol, p))) : [];
      const paint = (M, r) => {
        for (const [id, o] of outers) if (o.every(Boolean)) Site.drawQuad(ctx, Site.tagCanvas(id, 100), o.map(M), 6);
        for (const c of solCs) if (c.every(Boolean)) quad(ctx, c.map(M), GREEN, 1.2);
        obs.forEach((o) => dot(ctx, M(o.uv), r, RED));
      };
      paint((q) => [q[0] * s, q[1] * s], 2);
      if (obs.length) { // the tag again, magnified, bottom-left
        const xs = obs.map((o) => o.uv[0]), ys = obs.map((o) => o.uv[1]), cx0 = (Math.min(...xs) + Math.max(...xs)) / 2, cy0 = (Math.min(...ys) + Math.max(...ys)) / 2;
        const half = Math.max(4, (Math.max(...xs) - Math.min(...xs)) * 0.8), Z = h * 0.42, zx = 6, zy = h - Z - 6, zs = Z / (2 * half);
        ctx.save(); ctx.beginPath(); ctx.rect(zx, zy, Z, Z); ctx.fillStyle = '#16092a'; ctx.fill(); ctx.clip();
        paint((q) => [zx + (q[0] - cx0 + half) * zs, zy + (q[1] - cy0 + half) * zs], 3);
        ctx.restore(); ctx.strokeStyle = LAV; ctx.lineWidth = 1; ctx.strokeRect(zx, zy, Z, Z); ctx.strokeRect((cx0 - half) * s, (cy0 - half) * s, 2 * half * s, 2 * half * s);
      }
      if (!obs.length) { ctx.fillStyle = AMBER; ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillText(S.two ? 'No tag fully in view' : 'Tag not in view', 8, h - 8); }
    };
    ist = Site.canvas(insetCv, 0.625, later(() => lastInset && inset(...lastInset)));
    const resize = () => { const r = wrap.getBoundingClientRect(); if (!r.width) return; renderer.setSize(r.width, r.height, false); cam.aspect = r.width / r.height; cam.updateProjectionMatrix(); render(); };
    const render = () => renderer.render(scene, cam);
    function update() {
      // The corner noise comes from the scene itself: the same pose, noise level and tag count
      // always give the same noisy frame (and the same solve), so redrawing for something
      // unrelated, like the chain checkbox, can't make the solved robot jump.
      seed = 1 + (Math.abs(Math.round(S.x * 1000) * 73856093 ^ Math.round(S.y * 1000) * 19349663 ^ Math.round(S.th * 1000) * 83492791 ^ Math.round(S.noise * 100) * 2654435761 ^ (S.two ? 97 : 13)) % 2147483645);
      const truth = camFromRobot(S.x, S.y, S.th);
      setBot(robot, S);
      const cp = W2T(...truth.C); camAx.position.copy(cp);
      const f = col(truth.R, 0), l = col(truth.R, 1), u = col(truth.R, 2);
      camAx.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(W2T(...f), W2T(...l), W2T(...u)));
      const hf = K.cx / K.fx, vf = K.cy / K.fy, far = 1.2, fr = [];
      const corner = (a, b) => W2T(truth.C[0] + (f[0] + l[0] * a + u[0] * b) * far, truth.C[1] + (f[1] + l[1] * a + u[1] * b) * far, truth.C[2] + (f[2] + l[2] * a + u[2] * b) * far);
      const cs = [corner(hf, vf), corner(-hf, vf), corner(-hf, -vf), corner(hf, -vf)];
      cs.forEach((c, i) => fr.push(cp, c, c, cs[(i + 1) % 4]));
      setLines(frust, fr);
      const tagsIn = S.two ? [TAGP, TAG4] : [TAGP], names = S.two ? [3, 4] : [3];
      const obs = observe(truth, tagsIn, S.noise);
      const seen = [...new Set(obs.map((o) => o.tag))];
      tag4Mesh.visible = lTag4.visible = S.two;
      let sol = null, res = null, multi = false;
      const status = $('#po-3d-status');
      if (obs.length) {
        let flipped = false;
        if (seen.length > 1) {
          // multi-tag: one PnP over all 8 corners, in field coordinates (like PhotonVision's multi-tag)
          multi = true; sol = pnp(obs, jitter(truth));
          status.textContent = 'Two tags in view: one PnP over all 8 corners (multi-tag). Only one pose fits, so it can\'t flip.';
        } else {
          const t = tagsIn[seen[0]];
          res = singleTag(obs, truth, t); sol = res.best;
          flipped = !res.bestIsA && !res.same && Math.hypot(res.A.C[0] - res.B.C[0], res.A.C[1] - res.B.C[1]) > 0.3;
          status.textContent = S.two ? `Only tag ${names[seen[0]]} is fully in view, so this falls back to the single-tag solve (4 corners).` : 'One tag: PnP on its 4 corners.';
        }
        const rb = robotFromCam(sol);
        ghost.visible = true; setBot(ghost, rb);
        ghost.children.forEach((c) => c.material.color.set(flipped ? 0xf59e0b : 0xa3e635));
        setLines(rays, seen.flatMap((i) => tagCorners(tagsIn[i]).flatMap((p) => [cp, W2T(...p)])));
        $('#po-3d-sol').textContent = `${rb.x.toFixed(2)}, ${rb.y.toFixed(2)} m`;
        const err = Math.hypot(rb.x - S.x, rb.y - S.y);
        const e = $('#po-3d-err'); e.textContent = err < 1 ? (err * 100).toFixed(1) + ' cm' : err.toFixed(2) + ' m'; e.style.color = err > 0.3 ? AMBER : '';
        const a = $('#po-3d-amb');
        if (multi) { a.textContent = 'none (multi-tag)'; a.style.color = ''; } else { a.textContent = res.amb.toFixed(2); a.style.color = res.amb > 0.2 ? AMBER : ''; }
        const px = Math.hypot(obs[0].uv[0] - obs[1].uv[0], obs[0].uv[1] - obs[1].uv[1]);
        $('#po-3d-px').textContent = px.toFixed(0) + ' px';
        // chain: origin -> tag -> camera (solved) -> robot (solved)
        const t0 = tagsIn[seen[0]], sc = W2T(...sol.C), tg = W2T(t0.x, t0.y, t0.z), rc = W2T(rb.x, rb.y, 0.2);
        [chainA, chainB, chainC, lL, lP, lM].forEach((o) => (o.visible = S.chain));
        setLines(chainA, [new THREE.Vector3(0, 0.02, 0), tg]); setLines(chainB, [tg, sc]); setLines(chainC, [sc, rc]);
        lL.position.copy(tg.clone().multiplyScalar(0.5)).add(new THREE.Vector3(0, 0.25, 0)); lP.position.copy(tg.clone().add(sc).multiplyScalar(0.5)).add(new THREE.Vector3(0, 0.2, 0)); lM.position.copy(sc.clone().add(rc).multiplyScalar(0.5)).add(new THREE.Vector3(0, 0.35, 0));
      } else {
        ghost.visible = false; setLines(rays, []); [chainA, chainB, chainC, lL, lP, lM].forEach((o) => (o.visible = false));
        $('#po-3d-sol').textContent = '–'; $('#po-3d-err').textContent = 'no tag'; $('#po-3d-amb').textContent = '–'; $('#po-3d-px').textContent = '–';
        status.textContent = S.two ? 'Neither tag is fully in view: nothing to solve. Turn or move the robot.' : 'The tag isn\'t fully in view: nothing to solve. Turn or move the robot.';
      }
      $('#po-3d-true').textContent = `${S.x.toFixed(2)}, ${S.y.toFixed(2)} m`;
      $('#po-3d-dist').textContent = Math.hypot(truth.C[0] - TAGP.x, truth.C[1] - TAGP.y, truth.C[2] - TAGP.z).toFixed(2) + ' m';
      inset(obs, sol);
      render();
    }
    // drag the robot on the floor
    const ray = new THREE.Raycaster(), ndc = new THREE.Vector2(), plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0), hit = new THREE.Vector3();
    let dragging = false; const grabOff = [0, 0];
    const pick = (e) => { const r = renderer.domElement.getBoundingClientRect(); ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1); ray.setFromCamera(ndc, cam); };
    renderer.domElement.addEventListener('pointerdown', (e) => {
      pick(e);
      if (ray.intersectObject(robot, true).length) {
        dragging = true; controls.enabled = false; renderer.domElement.setPointerCapture(e.pointerId); renderer.domElement.style.cursor = 'grabbing';
        // keep the grab point under the pointer, so the robot doesn't jump
        if (ray.ray.intersectPlane(plane, hit)) { grabOff[0] = S.x - hit.x; grabOff[1] = S.y + hit.z; } else grabOff[0] = grabOff[1] = 0;
      }
      else renderer.domElement.style.cursor = 'grabbing';
    }, true);
    renderer.domElement.addEventListener('pointermove', (e) => {
      if (!dragging) { // hover: the robot shows a move cursor, the rest of the scene a grab (orbit) cursor
        if (e.buttons || e.pointerType !== 'mouse') return;
        pick(e); renderer.domElement.style.cursor = ray.intersectObject(robot, true).length ? 'move' : 'grab'; return;
      }
      pick(e);
      if (ray.ray.intersectPlane(plane, hit)) { S.x = Site.clamp(hit.x + grabOff[0], 0.7, 7.5); S.y = Site.clamp(-hit.z + grabOff[1], -0.5, 7.5); update(); }
    });
    const end = () => { renderer.domElement.style.cursor = 'grab'; if (dragging) { dragging = false; controls.enabled = true; } };
    renderer.domElement.addEventListener('pointerup', end); renderer.domElement.addEventListener('pointercancel', end);
    controls.addEventListener('change', render);
    new ResizeObserver(resize).observe(wrap);
    Site.range($('#po-3d-yaw'), (v) => { S.th = Math.PI + (v * Math.PI) / 180; update(); }, (v) => (v > 0 ? '+' : '') + v + '° from facing the wall');
    Site.range($('#po-3d-noise'), (v) => { S.noise = v; update(); }, (v) => v.toFixed(2) + ' px');
    Site.seg($('#po-3d-tags'), (v, b) => { S.two = v === '2'; b.parentElement.querySelectorAll('button').forEach((x) => x.setAttribute('aria-pressed', x === b)); update(); });
    $('#po-3d-chain').addEventListener('change', (e) => { S.chain = e.target.checked; update(); });
    resize(); update();
  }

  /* ── Chain of transforms (SVG): horizontal on wide screens, vertical on phones ── */
  {
    const svg = $('#po-chain');
    const nodes = [['Field origin', 'corner of the field'], ['Tag 3', 'its pose on the field'], ['Camera', 'where it must be'], ['Robot', 'what we want']];
    const arrows = [['tag pose', 'from the field layout JSON', '#6b1199'], ['camera-to-tag, inverted', 'from PnP (the corners)', '#16a34a'], ['robotToCamera, inverted', 'from CAD or field calibration', '#d97706']];
    const icon = (i, x, y) => {
      if (i === 0) return `<g transform="translate(${x - 26} ${y - 26})"><rect width="52" height="52" rx="6" fill="#f3e8ff" stroke="#d4c0ee"/><path d="M10 42 H40" stroke="#ef4444" stroke-width="3"/><path d="M10 42 V12" stroke="#22c55e" stroke-width="3"/></g>`;
      if (i === 1) return `<g transform="translate(${x - 26} ${y - 26})">${Site.tagSVG(3, 52)}</g>`;
      if (i === 2) return `<g transform="translate(${x - 30} ${y - 18})"><rect width="44" height="36" rx="6" fill="#1f1b23"/><path d="M44 10 L60 2 V34 L44 26z" fill="#1f1b23"/><circle cx="22" cy="18" r="9" fill="#4c0070" stroke="#c4b5fd" stroke-width="2"/></g>`;
      return `<g transform="translate(${x - 28} ${y - 28})"><rect width="56" height="56" rx="6" fill="#6b1199" stroke="#3c0060" stroke-width="2"/><path d="M40 28 L28 20 V36z" fill="#fff"/></g>`;
    };
    const marker = '<defs><marker id="po-ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" fill="#8b5cf6"/></marker></defs>';
    let paths = [], dt = null, mode = '';
    const build = () => {
      const vert = svg.parentElement.clientWidth < 620;
      if ((vert ? 'v' : 'h') === mode) return;
      mode = vert ? 'v' : 'h';
      let h = marker;
      if (!vert) {
        const X = [70, 370, 670, 970];
        svg.setAttribute('viewBox', '0 0 1100 250');
        nodes.forEach(([t, s], i) => { h += icon(i, X[i], 70) + `<text x="${X[i]}" y="130" text-anchor="middle" font-family="Outfit" font-weight="700" font-size="18" fill="#4c0070">${t}</text><text x="${X[i]}" y="150" text-anchor="middle" font-size="13" fill="#635a72">${s}</text>`; });
        arrows.forEach(([t, s, c], i) => {
          const x1 = X[i] + 45, x2 = X[i + 1] - 45, xm = (x1 + x2) / 2;
          h += `<path id="po-cp${i}" d="M${x1} 70 C${xm} 20 ${xm} 20 ${x2} 70" fill="none" stroke="${c}" stroke-width="2.5" marker-end="url(#po-ar)"/><text x="${xm}" y="26" text-anchor="middle" font-size="13" font-weight="700" fill="${c}">${t}</text><text x="${xm}" y="100" text-anchor="middle" font-size="12" fill="#635a72">${s}</text>`;
        });
        h += `<text x="550" y="200" text-anchor="middle" font-family="JetBrains Mono" font-size="15" fill="#4c0070">robot pose = tag pose · (camera-to-tag)⁻¹ · (robotToCamera)⁻¹</text>`;
      } else {
        const Y = [44, 204, 364, 524];
        svg.setAttribute('viewBox', '0 0 360 640');
        nodes.forEach(([t, s], i) => { h += icon(i, 50, Y[i]) + `<text x="96" y="${Y[i] - 2}" font-family="Outfit" font-weight="700" font-size="19" fill="#4c0070">${t}</text><text x="96" y="${Y[i] + 18}" font-size="14" fill="#635a72">${s}</text>`; });
        arrows.forEach(([t, s, c], i) => {
          const y1 = Y[i] + 36, y2 = Y[i + 1] - 36, ym = (y1 + y2) / 2;
          h += `<path id="po-cp${i}" d="M50 ${y1} C20 ${ym} 20 ${ym} 50 ${y2}" fill="none" stroke="${c}" stroke-width="2.5" marker-end="url(#po-ar)"/><text x="96" y="${ym - 2}" font-size="14" font-weight="700" fill="${c}">${t}</text><text x="96" y="${ym + 17}" font-size="13" fill="#635a72">${s}</text>`;
        });
        h += `<text x="180" y="598" text-anchor="middle" font-family="JetBrains Mono" font-size="12.5" fill="#4c0070">robot = tag · (cam-to-tag)⁻¹</text><text x="180" y="620" text-anchor="middle" font-family="JetBrains Mono" font-size="12.5" fill="#4c0070">· (robotToCamera)⁻¹</text>`;
      }
      svg.innerHTML = h + '<circle id="po-cdot" r="7" fill="#8b5cf6"/>';
      paths = [0, 1, 2].map((i) => svg.querySelector('#po-cp' + i)); dt = svg.querySelector('#po-cdot');
    };
    build();
    new ResizeObserver(build).observe(svg.parentElement);
    Site.loop(svg, (t) => {
      const u = (t * 0.35) % 3, i = Math.floor(u), p = paths[i]; if (!p) return;
      const q = p.getPointAtLength(p.getTotalLength() * Site.ease(u - i));
      dt.setAttribute('cx', q.x); dt.setAttribute('cy', q.y);
    });
  }

  /* ── Ambiguity figure (SVG) ─────────────────────────── */
  {
    const svg = $('#po-amb-fig');
    const tx = 260, ty = 80, L = 70, a = 0.45;
    const edge = (ang, c) => `<line x1="${tx - L * Math.cos(ang)}" y1="${ty - L * Math.sin(ang)}" x2="${tx + L * Math.cos(ang)}" y2="${ty + L * Math.sin(ang)}" stroke="${c}" stroke-width="7" stroke-linecap="round" opacity=".85"/>`;
    const trap = (x, d, c) => { const hL = 44 * (1 + d), hR = 44 * (1 - d), w = 40; return `<path d="M${x - w / 2} ${270 - hL / 2} L${x + w / 2} ${270 - hR / 2} L${x + w / 2} ${270 + hR / 2} L${x - w / 2} ${270 + hL / 2}z" fill="none" stroke="${c}" stroke-width="3"/>`; };
    svg.innerHTML = `<rect width="520" height="330" fill="#fff"/>
      <text x="${tx}" y="24" text-anchor="middle" font-size="13" font-weight="700" fill="#4c0070">from above</text>
      ${edge(a, '#16a34a')}${edge(-a, '#d97706')}
      <line x1="${tx}" y1="${ty}" x2="${tx}" y2="200" stroke="#8b5cf6" stroke-dasharray="4 4"/>
      <circle cx="${tx}" cy="212" r="9" fill="#1f1b23"/><text x="${tx + 16}" y="216" font-size="12" fill="#635a72">camera, far away</text>
      <text x="${tx + 82}" y="${ty + 36}" font-size="12" font-weight="700" fill="#16a34a">turned one way</text>
      <text x="${tx - 82}" y="${ty + 36}" text-anchor="end" font-size="12" font-weight="700" fill="#d97706">or the other</text>
      <text x="130" y="240" text-anchor="middle" font-size="12" fill="#635a72">what the camera sees:</text>
      ${trap(110, 0.06, '#16a34a')}${trap(180, -0.06, '#d97706')}
      <text x="270" y="256" font-size="13" fill="#4c0070">A 20° turn at 4.5 m makes the</text>
      <text x="270" y="276" font-size="13" fill="#4c0070">near edge only ~1% taller:</text>
      <text x="270" y="296" font-size="13" fill="#4c0070">under half a pixel on a 30 px tag.</text>`;
  }

  /* ── Ambiguity lab ──────────────────────────────────── */
  {
    const ctop = $('#po-amb-top'), cimg = $('#po-amb-img'); let s1 = null, s2 = null;
    const TG = { x: 0, y: 0, z: 0.9, yaw: 0 };
    const P = { d: 4.5, ang: 12, n: 0.6 };
    let cur = null, stats = '';
    const truthPose = () => { const a = (P.ang * Math.PI) / 180, C = [P.d * Math.cos(a), P.d * Math.sin(a), MOUNT.z]; return { C, R: camR(Math.atan2(-C[1], -C[0]), -Math.atan2(TG.z - C[2], P.d)) }; };
    const frame = () => { const truth = truthPose(), obs = observe(truth, [TG], P.n); cur = obs.length ? { truth, obs, ...singleTag(obs, truth, TG) } : null; draw(); };
    const draw = () => {
      if (!s1 || !s2 || !s1.w || !cur) return;
      const { truth, obs, A, B, ea, eb, amb, same } = cur;
      // top view: wall along the top, tag facing down the canvas
      { const { ctx, w, h } = s1, k = Math.min((h - 40) / 8.6, w / 11), T = (x, y) => [w / 2 - y * k, 22 + x * k];
        ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
        ctx.strokeStyle = 'rgba(196,181,253,.08)'; for (let m = 1; m <= 8; m++) { line(ctx, T(m, -6), T(m, 6)); }
        ctx.fillStyle = 'rgba(196,181,253,.35)'; ctx.fillRect(0, 12, w, 8);
        ctx.setLineDash([3, 4]); ctx.strokeStyle = 'rgba(196,181,253,.4)'; line(ctx, T(0, 0), T(8.5, 0)); ctx.setLineDash([]);
        const rT = robotFromCam(truth), rA = robotFromCam(A), rB = robotFromCam(B);
        [[rA, GREEN], [rB, AMBER]].forEach(([r, c]) => { ctx.strokeStyle = c + '88'; line(ctx, T(r.x, r.y), T(0, 0)); });
        drawBot(ctx, T, k, rT, '#fff', 'rgba(255,255,255,.15)', false);
        if (!same) drawBot(ctx, T, k, rB, AMBER, 'rgba(245,158,11,.2)');
        drawBot(ctx, T, k, rA, GREEN, 'rgba(163,230,53,.2)');
        ctx.fillStyle = '#fff'; ctx.fillRect(T(0, 0)[0] - 6, 14, 12, 8);
        ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = MUTED; ctx.fillText('tag on the wall', T(0, 0)[0] + 10, 36);
        ctx.fillText("tag's center line", T(7.5, 0)[0] + 6, T(7.5, 0)[1]);
      }
      // image: zoomed crop around the tag, with a pixel grid
      { const { ctx, w, h } = s2;
        const cx0 = obs.reduce((a, o) => a + o.uv[0], 0) / 4, cy0 = obs.reduce((a, o) => a + o.uv[1], 0) / 4;
        const span = Math.max(...obs.map((o) => Math.abs(o.uv[0] - cx0))) * 2.8 + 8, sc = w / span, ox = cx0 - span / 2, oy = cy0 - (h / sc) / 2;
        const M = (q) => [(q[0] - ox) * sc, (q[1] - oy) * sc];
        ctx.fillStyle = '#16092a'; ctx.fillRect(0, 0, w, h);
        const outer = tagCorners(TG, 10 / 8).map((p) => project(truth, p));
        if (outer.every(Boolean)) { ctx.imageSmoothingEnabled = false; Site.drawQuad(ctx, Site.tagCanvas(0, 100), outer.map(M), 8); ctx.imageSmoothingEnabled = true; }
        if (sc > 5) { ctx.strokeStyle = 'rgba(196,181,253,.13)'; for (let x = Math.ceil(ox); x < ox + span; x++) line(ctx, M([x, oy]), M([x, oy + h / sc])); for (let y = Math.ceil(oy); y < oy + h / sc; y++) line(ctx, M([ox, y]), M([ox + span, y])); }
        const pa = tagCorners(TG).map((p) => project(A, p)), pb = tagCorners(TG).map((p) => project(B, p));
        if (!same) quad(ctx, pb.map(M), AMBER, 1.5);
        quad(ctx, pa.map(M), GREEN, 1.5);
        obs.forEach((o) => dot(ctx, M(o.uv), 3.5, RED));
        // magnifier on corner 0
        const c0 = obs[0].uv, R = Math.min(w, h) * 0.2, mx = w - R - 8, my = h - R - 8, z = R / 3.2;
        ctx.save(); ctx.beginPath(); ctx.arc(mx, my, R, 0, 7); ctx.fillStyle = 'rgba(14,5,24,.92)'; ctx.fill(); ctx.clip();
        const Z = (q) => [mx + (q[0] - c0[0]) * z, my + (q[1] - c0[1]) * z];
        ctx.strokeStyle = 'rgba(196,181,253,.18)'; for (let i = -4; i <= 4; i++) { const gx = Math.floor(c0[0]) + i, gy = Math.floor(c0[1]) + i; line(ctx, Z([gx, c0[1] - 5]), Z([gx, c0[1] + 5])); line(ctx, Z([c0[0] - 5, gy]), Z([c0[0] + 5, gy])); }
        const tc = project(truth, tagCorners(TG)[0]);
        ctx.strokeStyle = 'rgba(255,255,255,.7)'; ctx.beginPath(); ctx.arc(...Z(tc), 5, 0, 7); ctx.stroke();
        if (!same) dot(ctx, Z(pb[0]), 4, AMBER);
        dot(ctx, Z(pa[0]), 4, GREEN); dot(ctx, Z(c0), 4, RED);
        ctx.restore(); ctx.strokeStyle = LAV; ctx.beginPath(); ctx.arc(mx, my, R, 0, 7); ctx.stroke();
        ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.fillText('grid = 1 pixel · ○ true corner', 8, 14);
      }
      const f = (e) => e.toFixed(2) + ' px';
      $('#po-a-ea').textContent = f(ea); $('#po-a-eb').textContent = same ? 'same as A' : f(eb);
      $('#po-a-amb').textContent = amb.toFixed(2);
      const rA = robotFromCam(A), rB = robotFromCam(B), apart = Math.hypot(rA.x - rB.x, rA.y - rB.y);
      $('#po-a-apart').textContent = same ? '0' : apart < 1 ? (apart * 100).toFixed(0) + ' cm' : apart.toFixed(2) + ' m';
      const v = $('#po-a-verdict'), wrong = !cur.bestIsA && !same && apart > 0.3;
      v.className = 'verdict ' + (amb > 0.2 || wrong ? 'bad' : 'ok');
      v.textContent = amb > 0.2 ? `Ambiguity ${amb.toFixed(2)} > 0.2: reject this pose` + (wrong ? ' (good thing: B won and it\'s the flip)' : '') : wrong ? 'Passed the 0.2 check, but the flipped solution won!' : 'Ambiguity under 0.2: solution ' + (cur.bestIsA ? 'A' : 'B') + ' is trusted';
      $('#po-a-stats').textContent = stats || `Frame ${nFrame}: fresh noise on the four corners.`;
    };
    let nFrame = 0;
    const runBtn = $('#po-a-run');
    const run = () => {
      // show the button busy first, then run the 200 solves on the next frame
      runBtn.setAttribute('aria-busy', 'true'); runBtn.textContent = 'Running…'; $('#po-a-stats').textContent = 'Solving 200 noisy frames…';
      requestAnimationFrame(() => setTimeout(runNow, 0));
    };
    const runNow = () => {
      let flips = 0, rej = 0, caught = 0, N = 200;
      for (let i = 0; i < N; i++) {
        const truth = truthPose(), obs = observe(truth, [TG], P.n); if (!obs.length) continue;
        const r = singleTag(obs, truth, TG), rA = robotFromCam(r.A), rB = robotFromCam(r.B);
        const wrong = !r.bestIsA && !r.same && Math.hypot(rA.x - rB.x, rA.y - rB.y) > 0.3;
        if (wrong) flips++; if (r.amb > 0.2) { rej++; if (wrong) caught++; }
      }
      stats = `Out of ${N} noisy frames: the flipped pose won ${flips} times (${Math.round(flips / N * 100)}%). The 0.2 rule rejected ${rej}${flips ? `, catching ${caught} of the ${flips} flips` : ''}.`;
      runBtn.removeAttribute('aria-busy'); runBtn.textContent = 'Run 200 frames';
      frame();
    };
    s1 = Site.canvas(ctop, 0.8, later(draw)); s2 = Site.canvas(cimg, 0.8, later(draw));
    const inputs = [['po-a-d', 'd', (v) => v.toFixed(1) + ' m'], ['po-a-ang', 'ang', (v) => v + '°'], ['po-a-n', 'n', (v) => '±' + v.toFixed(2) + ' px']];
    inputs.forEach(([id, k, fmt]) => Site.range($('#' + id), (v) => { P[k] = v; stats = ''; frame(); }, fmt));
    $('#po-a-new').onclick = () => { nFrame++; stats = ''; frame(); }; runBtn.onclick = run;
  }

  /* ── Multi-tag lab ──────────────────────────────────── */
  {
    const cv = $('#po-mt'); let st = null;
    const LAYOUT = [{ x: 0, y: 1.9, z: 1.2, yaw: 0 }, { x: 0, y: 0.6, z: 0.8, yaw: 0 }, { x: 0, y: -0.7, z: 1.3, yaw: 0 }, { x: 0, y: -2.0, z: 0.9, yaw: 0 }];
    const on = [false, true, false, false];
    const P = { d: 4.5, n: 0.5, bad: false, ex: false };
    let cloud = [], stat = {};
    const tb = $('#po-mt-tags');
    tb.innerHTML = LAYOUT.map((_, i) => `<button data-i="${i}" class="${on[i] ? 'on' : 'off'}" aria-pressed="${on[i]}" title="Tap to ${on[i] ? 'remove' : 'add'}">Tag ${i + 1}</button>`).join('');
    tb.addEventListener('click', (e) => { const b = e.target.closest('button'); if (!b) return; const i = +b.dataset.i; on[i] = !on[i]; b.className = on[i] ? 'on' : 'off'; b.setAttribute('aria-pressed', on[i]); b.title = `Tap to ${on[i] ? 'remove' : 'add'}`; compute(); });
    const truthRobot = () => ({ x: P.d, y: 0.2, th: Math.PI + 0.05 });
    function compute() {
      const rt = truthRobot(), truth = camFromRobot(rt.x, rt.y, rt.th);
      const real = LAYOUT.map((t, i) => (i === 1 && P.bad ? { ...t, y: t.y + 0.15 } : t));
      const use = LAYOUT.map((_, i) => on[i] && !(i === 1 && P.ex));
      const tagsL = LAYOUT.filter((_, i) => use[i]), tagsR = real.filter((_, i) => use[i]);
      cloud = [];
      let flips = 0, visibleTags = 0;
      for (let s = 0; s < 80; s++) {
        const obs = observe(truth, tagsL, P.n, tagsR);
        const n = new Set(obs.map((o) => o.tag)).size; visibleTags = Math.max(visibleTags, n);
        if (!n) continue;
        let pose;
        if (n === 1) { const t = tagsL[obs[0].tag]; pose = singleTag(obs, truth, t).best; }
        else pose = pnp(obs, jitter(truth));
        const r = robotFromCam(pose), flip = Math.hypot(r.x - rt.x, r.y - rt.y) > 0.4 && n === 1;
        if (flip) flips++;
        cloud.push({ ...r, flip });
      }
      const good = cloud.filter((c) => !c.flip);
      if (good.length) {
        const mx = good.reduce((a, c) => a + c.x, 0) / good.length, my = good.reduce((a, c) => a + c.y, 0) / good.length;
        const ds = good.map((c) => Math.hypot(c.x - mx, c.y - my)).sort((a, b) => a - b);
        const hs = good.map((c) => Math.abs(Math.atan2(Math.sin(c.th - rt.th), Math.cos(c.th - rt.th)))).sort((a, b) => a - b);
        stat = { sp: ds[Math.floor(ds.length * 0.95)], hs: (hs[Math.floor(hs.length * 0.95)] * 180) / Math.PI, bias: Math.hypot(mx - rt.x, my - rt.y), flips, n: visibleTags };
      } else stat = { flips, n: visibleTags };
      draw();
    }
    const draw = () => {
      if (!st || !st.w) return;
      const { ctx, w, h } = st, rt = truthRobot();
      const k = Math.min(w / 6.4, (h - 30) / 7.6), T = (x, y) => [w / 2 - y * k, 20 + x * k];
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.07)'; for (let m = 1; m <= 7; m++) line(ctx, T(m, -3.5), T(m, 3.5));
      ctx.fillStyle = 'rgba(196,181,253,.35)'; ctx.fillRect(0, 10, w, 8);
      LAYOUT.forEach((t, i) => {
        const p = T(0, t.y), used = on[i] && !(i === 1 && P.ex);
        ctx.fillStyle = used ? '#fff' : 'rgba(255,255,255,.25)'; ctx.fillRect(p[0] - 7, 12, 14, 8);
        if (i === 1 && P.bad) { ctx.fillStyle = AMBER; ctx.fillRect(T(0, t.y + 0.15)[0] - 7, 22, 14, 3); }
        ctx.fillStyle = used ? INK : MUTED; ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillText(i + 1, p[0] - 3, 36);
      });
      // camera view wedge
      const truth = camFromRobot(rt.x, rt.y, rt.th), hf = Math.atan(K.cx / K.fx), c0 = T(truth.C[0], truth.C[1]);
      ctx.strokeStyle = 'rgba(139,92,246,.35)';
      [hf, -hf].forEach((a) => { const d = [Math.cos(rt.th + a), Math.sin(rt.th + a)], t = truth.C[0] / -d[0]; line(ctx, c0, T(truth.C[0] + d[0] * t, truth.C[1] + d[1] * t)); });
      for (const c of cloud) dot(ctx, T(c.x, c.y), 2, c.flip ? AMBER : 'rgba(163,230,53,.8)');
      drawBot(ctx, T, k, rt, '#fff', 'rgba(255,255,255,.08)', false);
      // zoom inset around the true pose
      const R = Math.min(w, h) * 0.2, mx = w - R - 10, my = h - R - 10, zk = R / 0.3;
      ctx.save(); ctx.beginPath(); ctx.arc(mx, my, R, 0, 7); ctx.fillStyle = 'rgba(14,5,24,.95)'; ctx.fill(); ctx.clip();
      ctx.strokeStyle = 'rgba(196,181,253,.15)'; ctx.beginPath(); ctx.arc(mx, my, 0.1 * zk, 0, 7); ctx.stroke(); ctx.beginPath(); ctx.arc(mx, my, 0.2 * zk, 0, 7); ctx.stroke();
      for (const c of cloud) if (!c.flip) dot(ctx, [mx - (c.y - rt.y) * zk, my + (c.x - rt.x) * zk], 2, 'rgba(163,230,53,.85)');
      ctx.strokeStyle = '#fff'; line(ctx, [mx - 6, my], [mx + 6, my]); line(ctx, [mx, my - 6], [mx, my + 6]);
      ctx.restore(); ctx.strokeStyle = LAV; ctx.beginPath(); ctx.arc(mx, my, R, 0, 7); ctx.stroke();
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.fillText('zoom: rings at 10, 20 cm', mx - R, my - R - 6);
      const cm = (m) => (m < 1 ? (m * 100).toFixed(m < 0.1 ? 1 : 0) + ' cm' : m.toFixed(2) + ' m');
      $('#po-mt-sp').textContent = stat.sp != null ? cm(stat.sp) : '–';
      $('#po-mt-hs').textContent = stat.hs != null ? stat.hs.toFixed(1) + '°' : '–';
      const fl = $('#po-mt-fl'); fl.textContent = cloud.length ? `${stat.flips} of ${cloud.length}` : 'no tags'; fl.style.color = stat.flips ? AMBER : '';
      const bi = $('#po-mt-bias'); bi.textContent = stat.bias != null ? cm(stat.bias) : '–'; bi.style.color = stat.bias > 0.05 ? AMBER : '';
    };
    st = Site.canvas(cv, 0.9, later(draw));
    Site.range($('#po-mt-d'), (v) => { P.d = v; compute(); }, (v) => v.toFixed(1) + ' m');
    Site.range($('#po-mt-n'), (v) => { P.n = v; compute(); }, (v) => '±' + v.toFixed(2) + ' px');
    $('#po-mt-bad').addEventListener('change', (e) => { P.bad = e.target.checked; compute(); });
    $('#po-mt-ex').addEventListener('change', (e) => { P.ex = e.target.checked; compute(); });
  }

  /* ── Kalman blend ───────────────────────────────────── */
  {
    const cv = $('#po-kf'); let st = null;
    const P = { d: 3, n: 1, t: 3 };
    const draw = () => {
      if (!st || !st.w) return;
      const { ctx, w, h } = st;
      const so = 0.03 + 0.05 * P.t, mo = 0.04 * P.t;              // odometry: drifts and spreads (illustrative)
      const sv = Math.max(0.02, (0.01 * P.d * P.d) / (P.n * P.n)), mv = -0.3 * sv; // vision: 6328's rule of thumb
      const kg = (so * so) / (so * so + sv * sv), mf = mo + kg * (mv - mo), sf = Math.sqrt(1 / (1 / (so * so) + 1 / (sv * sv)));
      const X = (m) => w / 2 + (m / 0.9) * (w / 2 - 14), base = h - 28;
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.25)'; line(ctx, [8, base], [w - 8, base]);
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED;
      for (let m = -0.8; m <= 0.81; m += 0.4) { line(ctx, [X(m), base], [X(m), base + 5]); ctx.fillText((m > 0 ? '+' : '') + m.toFixed(1) + ' m', X(m) - 16, base + 18); }
      ctx.setLineDash([3, 3]); ctx.strokeStyle = 'rgba(255,255,255,.6)'; line(ctx, [X(0), 10], [X(0), base]); ctx.setLineDash([]);
      ctx.fillStyle = '#fff'; ctx.fillText('true position', X(0) + 4, base - 6);
      const peak = (s) => 1 / s;
      const top = Math.max(peak(so), peak(sv), peak(sf)), sy = (base - 30) / top;
      const bell = (m, s, c, fill) => {
        ctx.beginPath();
        for (let i = 0; i <= 200; i++) { const x = -0.9 + (1.8 * i) / 200, y = Math.exp(-((x - m) ** 2) / (2 * s * s)) / s; const p = [X(x), base - y * sy]; i ? ctx.lineTo(...p) : ctx.moveTo(...p); }
        ctx.strokeStyle = c; ctx.lineWidth = 2; ctx.stroke(); ctx.lineWidth = 1;
        if (fill) { ctx.lineTo(X(0.9), base); ctx.lineTo(X(-0.9), base); ctx.closePath(); ctx.fillStyle = fill; ctx.fill(); }
      };
      bell(mo, so, AMBER); bell(mv, sv, LAV); bell(mf, sf, GREEN, 'rgba(163,230,53,.15)');
      ctx.font = '600 11px Plus Jakarta Sans';
      const lab = (m, s, c, t, dx) => { const y = base - (sy / s) * 0.6; ctx.fillStyle = c; ctx.fillText(t, Site.clamp(X(m) + dx, 4, w - 70), Math.max(14, y)); };
      lab(mo, so, AMBER, 'odometry', Math.max(14, so * (w / 1.8) * 1.2)); lab(mv, sv, LAV, 'vision', -Math.max(14, sv * (w / 1.8) * 1.2) - 40); ctx.fillStyle = GREEN; ctx.fillText('blended', Site.clamp(X(mf) - 22, 4, w - 60), Math.max(14, base - sy / sf - 8));
      $('#po-kf-sv').textContent = (sv * 100).toFixed(sv < 0.1 ? 1 : 0) + ' cm';
      $('#po-kf-k').textContent = Math.round(kg * 100) + '%';
    };
    st = Site.canvas(cv, 0.55, later(draw));
    Site.range($('#po-kf-d'), (v) => { P.d = v; draw(); }, (v) => v.toFixed(1) + ' m');
    Site.range($('#po-kf-n'), (v) => { P.n = v; draw(); }, (v) => v);
    Site.range($('#po-kf-t'), (v) => { P.t = v; draw(); }, (v) => v.toFixed(1) + ' s');
  }
});
