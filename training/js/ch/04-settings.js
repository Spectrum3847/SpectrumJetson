// Chapter 04: camera settings. A camera simulator on a real frame (exposure, gain, brightness,
// contrast, gamma, sharpness, robot spin), the exposure timeline, and the flicker lab.
Object.assign(Site.glossary, {
  'histogram': 'A bar chart of how many pixels have each brightness, from black (left) to white (right).',
  'clipped': 'Pixels pushed past pure white (or pure black). Every clipped pixel reads the same, so any detail there is lost.',
  'flicker': 'Lights on mains power brighten and dim 120 times a second. Short exposures can catch different parts of that cycle in each frame.',
});

Site.chapter('settings', (root) => {
  const $ = (s) => root.querySelector(s);
  const rng = (s) => () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
  const gauss = (r) => { let u = 0; for (let i = 0; i < 6; i++) u += r(); return (u - 3) / 0.7071; };
  const loadImg = (src) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src; });
  const setRange = (id, v) => { const el = $(id); el.value = v; el.dispatchEvent(new Event('input')); };

  /* ── Camera simulator ──────────────────────────────────── */
  (async () => {
    // a real frame from our TopLeft Thriftiest Cam (probably 5 ms exposure; not recorded), at half size
    const NAME = 'tag-close_TopLeft', W = 640, H = 400, N = W * H;
    const [img, fr] = await Promise.all([loadImg(`assets/from-jetson/frames/${NAME}.jpg`), fetch('assets/from-jetson/frames/frames.json').then((r) => r.json())]);
    const c0 = document.createElement('canvas'); c0.width = W; c0.height = H; const x0 = c0.getContext('2d'); x0.drawImage(img, 0, 0, W, H);
    const px = x0.getImageData(0, 0, W, H).data, L = new Float32Array(N);
    // light per ms: the frame as shot is taken to be 5 ms (so at 5 ms the simulator reproduces it)
    for (let i = 0; i < N; i++) L[i] = Math.max(0, px[i * 4] - 8) / 5;
    // the real tags, half-size coordinates, corners TL TR BR BL (the library gives BL BR TR TL)
    const tags = fr.find((f) => f.file === NAME).detections.map((t) => { const c = t.corners_px; return { id: t.id, quad: [c[3], c[2], c[1], c[0]].map(([x, y]) => [x / 2, y / 2]), truth: Site.tagGrid(t.id).slice(2, 8).flatMap((r) => r.slice(2, 8)) }; });
    const r = rng(77), Z = Float32Array.from({ length: N + 4099 }, () => gauss(r));
    const view = $('#s-view'); view.width = W; view.height = H;
    const vctx = view.getContext('2d'), out = vctx.createImageData(W, H);
    let pend = 0;
    const later = () => { cancelAnimationFrame(pend); pend = requestAnimationFrame(() => render()); };
    const hist = Site.canvas($('#s-hist'), 0, later);
    const S = { exp: 5, gain: 1, bri: 0, con: 1, gam: 1, sharp: 5, spin: 3 };
    const s = new Float32Array(N), row = new Float64Array(W + 1), v = new Float32Array(N), sh = new Float32Array(N);
    let zoff = 0;
    const render = () => {
      const { exp, gain, bri, con, gam, sharp, spin } = S;
      // 1. light collected: linear in exposure
      const k = exp;
      // 2. motion blur while the shutter is open: 737 px x spin x exposure at 1280 wide, half that here
      const bl = Math.max(1, (737 * spin * exp) / 1000 / 2);
      for (let y = 0; y < H; y++) {
        row[0] = 0; for (let x = 0; x < W; x++) row[x + 1] = row[x] + L[y * W + x] * k;
        const P = (p) => { p = Site.clamp(p, 0, W); const i = Math.floor(p), f = p - i; return i >= W ? row[W] : row[i] + (row[i + 1] - row[i]) * f; };
        for (let x = 0; x < W; x++) { const a = Math.max(0, x + 0.5 - bl / 2), b = Math.min(W, x + 0.5 + bl / 2); s[y * W + x] = (P(b) - P(a)) / (b - a); }
      }
      // 3. photon + read noise, then gain amplifies signal and noise alike; 4. black level, contrast, gamma
      for (let i = 0; i < N; i++) {
        const sig = s[i], n = Math.sqrt(0.25 * sig + 1) * (gain > 1 || exp < 5 ? 1 : 0.35) * Z[i + zoff];
        let q = 8 + gain * (sig + n) + bri;           // 8 = the sensor's small black-level offset
        q = 128 + (q - 128) * con;
        q = q <= 0 ? 0 : 255 * Math.pow(Math.min(q, 400) / 255, 1 / gam);
        v[i] = q;
      }
      // 5. sharpening (unsharp mask): the camera's default is a little; high values ring around edges
      const amt = (sharp - 5) * 0.3; // the frame already has the camera's default sharpening
      for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
        const i = y * W + x;
        if (x === 0 || y === 0 || x === W - 1 || y === H - 1) { sh[i] = v[i]; continue; }
        const b = (v[i - W - 1] + v[i - W] + v[i - W + 1] + v[i - 1] + v[i] + v[i + 1] + v[i + W - 1] + v[i + W] + v[i + W + 1]) / 9;
        sh[i] = v[i] + amt * (v[i] - b);
      }
      // quantize, histogram, clipping
      const hb = new Uint32Array(256); let hiC = 0, loC = 0;
      for (let i = 0; i < N; i++) {
        const q = Math.round(Site.clamp(sh[i], 0, 255)); sh[i] = q; hb[q]++;
        if (q >= 255) hiC++; else if (q <= 0) loC++;
        out.data[i * 4] = out.data[i * 4 + 1] = out.data[i * 4 + 2] = q; out.data[i * 4 + 3] = 255;
      }
      vctx.putImageData(out, 0, 0);
      // decision margin on these pixels (the formula from chapter 02, one flat threshold)
      const samp = (x, y) => { const X = Math.floor(x), Y = Math.floor(y), fx = x - X, fy = y - Y, I = (a, b) => sh[b * W + a]; return (I(X, Y) * (1 - fx) + I(X + 1, Y) * fx) * (1 - fy) + (I(X, Y + 1) * (1 - fx) + I(X + 1, Y + 1) * fx) * fy; };
      let badges = '';
      tags.forEach((t) => {
        const at = (u, w2) => samp(...Site._homog(t.quad, u, w2));
        let blk = 0, nb = 0, wht = 0, nw = 0;
        let bz = 0, wz = 0; // tag samples crushed to pure black / clipped to pure white
        for (let i = 0; i < 8; i++) for (const [u, w2] of [[(i + 0.5) / 8, 0.5 / 8], [(i + 0.5) / 8, 7.5 / 8], [0.5 / 8, (i + 0.5) / 8], [7.5 / 8, (i + 0.5) / 8]]) { const q = at(u, w2); blk += q; nb++; if (q <= 1) bz++; }
        for (let i = 0; i < 8; i++) for (const [u, w2] of [[(i + 0.5) / 8, -0.5 / 8], [(i + 0.5) / 8, 8.5 / 8], [-0.5 / 8, (i + 0.5) / 8], [8.5 / 8, (i + 0.5) / 8]]) { const q = at(u, w2); wht += q; nw++; if (q >= 254) wz++; }
        t.crushed = bz / nb; t.blown = wz / nw;
        const thr = (blk / nb + wht / nw) / 2;
        let ws = 0, wc = 1, bs = 0, bc = 1, wrong = 0;
        for (let yy = 0; yy < 6; yy++) for (let xx = 0; xx < 6; xx++) { const d = at((xx + 1.5) / 8, (yy + 1.5) / 8) - thr; if (d > 0) { ws += d; wc++; } else { bs -= d; bc++; } if ((d > 0 ? 1 : 0) !== t.truth[yy * 6 + xx]) wrong++; }
        // ponytail: one fixed factor. The library formula reads ~43 on this frame at 5 ms; our GPU detector reported 90.
        const m = 2.1 * Math.min(ws / wc, bs / bc), ok = !wrong && m >= 15;
        t.ok = ok;
        badges += `<span class="badge ${ok ? 'ok' : 'bad'}">Tag ${t.id}: ${wrong ? `${wrong} squares misread ✗` : `margin ${Math.round(m)} ${ok ? '✓' : '✗ below 15'}`}${ok && m < 35 ? ' (default 35 would drop it)' : ''}</span>`;
      });
      const hp = (100 * hiC) / N, lp = (100 * loC) / N;
      // Only the tag's own pixels matter here: clipping elsewhere in the picture doesn't affect detection.
      // Clipping on the tag still decodes, but flattens the edge gradient the detector uses to place corners.
      tags.forEach((t) => {
        if (t.crushed > 0.5) badges += `<span class="badge warn" title="The detector still reads the tag, but it places each corner using the gray gradient along the edges. Flattened edges mean slightly less precise corners, so the pose jitters more.">⚠ Tag ${t.id}'s black squares crushed${t.ok ? ': still found, corners less precise' : ''}</span>`;
        if (t.blown > 0.5) badges += `<span class="badge warn" title="The detector still reads the tag, but it places each corner using the gray gradient along the edges. Flattened edges mean slightly less precise corners, so the pose jitters more.">⚠ Tag ${t.id}'s white clipped${t.ok ? ': still found, corners less precise' : ''}</span>`;
      });
      $('#s-badges').innerHTML = badges;
      tags.forEach((t) => { vctx.strokeStyle = t.ok ? '#a3e635' : '#f43f5e'; vctx.lineWidth = 2; vctx.beginPath(); t.quad.forEach(([x, y], i) => (i ? vctx.lineTo(x, y) : vctx.moveTo(x, y))); vctx.closePath(); vctx.stroke(); });
      // histogram
      const { ctx, w, h } = hist, mx = Math.max(...hb.slice(1, 255));
      ctx.clearRect(0, 0, w, h); ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
      for (let i = 0; i < 256; i++) { const bh = Math.min(1, Math.sqrt(hb[i] / mx)) * (h - 14); ctx.fillStyle = (i === 255 && hiC) || (i === 0 && loC) ? '#f59e0b' : '#8b5cf6'; ctx.fillRect((i / 256) * w, h - 12 - bh, w / 256 + 0.6, bh); }
      ctx.fillStyle = '#b8a9d4'; ctx.font = '10px JetBrains Mono, monospace'; ctx.fillText('black', 2, h - 2); ctx.textAlign = 'right'; ctx.fillText('white', w - 2, h - 2); ctx.textAlign = 'center'; ctx.fillText('histogram', w / 2, h - 2); ctx.textAlign = 'left';
      $('#s-uvc').textContent = Math.round(exp * 10);
      $('#s-fps').textContent = Math.min(120, Math.floor(1000 / exp)) + ' fps';
      $('#s-blur').textContent = Math.round((737 * spin * exp) / 1000) + ' px';
      $('#s-clip').textContent = hp.toFixed(1) + '%';
    };
    // a preset stays highlighted only until you move a slider yourself
    let applying = false;
    const pick = $('#s-preset'), customOpt = pick.querySelector('[value="custom"]');
    const clearPreset = () => { if (!applying) { customOpt.hidden = false; pick.value = 'custom'; } };
    const bind = (id, key, fmt) => Site.range($(id), (val) => { S[key] = val; if (key !== 'spin') clearPreset(); later(); }, fmt);
    bind('#s-exp', 'exp', (x) => `${x.toFixed(1)} ms`);
    bind('#s-gain', 'gain', (x) => `${x.toFixed(1)}×`);
    bind('#s-bri', 'bri', (x) => (x > 0 ? '+' : '') + x);
    bind('#s-con', 'con', (x) => `${x.toFixed(2)}×`);
    bind('#s-gam', 'gam', (x) => x.toFixed(2));
    bind('#s-sharp', 'sharp', (x) => x + (x === 5 ? ' (default)' : ''));
    bind('#s-spin', 'spin', (x) => `${x.toFixed(1)} rad/s`);
    const P = {
      ours: { exp: 5, gain: 1, bri: 0, con: 1, gam: 1, sharp: 5 },
      auto: { exp: 20, gain: 1, bri: 0, con: 1, gam: 1, sharp: 5 },
      cal: { exp: 15, gain: 1, bri: 0, con: 1, gam: 1, sharp: 5 },
      dark: { exp: 1.2, gain: 1, bri: 0, con: 1, gam: 1, sharp: 5 },
      wash: { exp: 5, gain: 1, bri: 55, con: 0.6, gam: 1.6, sharp: 5 },
      sharp: { exp: 5, gain: 1, bri: 0, con: 1, gam: 1, sharp: 10 },
    };
    const ids = { exp: '#s-exp', gain: '#s-gain', bri: '#s-bri', con: '#s-con', gam: '#s-gam', sharp: '#s-sharp' };
    const applyPreset = (p) => { if (!P[p]) return; applying = true; Object.entries(P[p]).forEach(([k2, val]) => setRange(ids[k2], val)); applying = false; customOpt.hidden = true; };
    pick.addEventListener('change', () => applyPreset(pick.value));
    applyPreset(pick.value);
    // live sensor noise, a few times a second while visible
    let last = 0;
    Site.loop(view, (t) => { if (Site.reduced || t - last < 0.12) return; last = t; zoff = Math.floor(Math.random() * 4096); render(); });
  })();

  /* ── Exposure timeline ─────────────────────────────────── */
  {
    const st = Site.canvas($('#s-tl')); // height from CSS aspect-ratio
    let raw = 50;
    const draw = () => {
      const { ctx, w, h } = st, exp = raw / 10, per = Math.max(1000 / 120, exp), T = w < 500 ? 36 : 72, X = (t) => 12 + (t / T) * (w - 24);
      ctx.clearRect(0, 0, w, h); ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
      // 120 fps slots
      ctx.strokeStyle = 'rgba(196,181,253,.22)'; ctx.setLineDash([3, 4]); ctx.lineWidth = 1;
      for (let t = 0; t <= T; t += 1000 / 120) { ctx.beginPath(); ctx.moveTo(X(t), 18); ctx.lineTo(X(t), h - 30); ctx.stroke(); }
      ctx.setLineDash([]);
      ctx.fillStyle = '#b8a9d4'; ctx.font = '11px Plus Jakarta Sans, sans-serif'; ctx.fillText('dashed: every 8.3 ms (120 fps)', 12, 13);
      const y = h * 0.3, bh = h * 0.34;
      for (let k = 0, t = 0; t < T; k++, t += per) {
        const x0 = X(t), x1 = X(Math.min(T, t + exp));
        ctx.fillStyle = 'rgba(139,92,246,.85)'; ctx.fillRect(x0 + 1, y, Math.max(2, x1 - x0 - 2), bh);
        ctx.strokeStyle = '#c4b5fd'; ctx.strokeRect(X(t) + 0.5, y - 6, X(Math.min(T, t + per)) - X(t) - 1, bh + 12);
        if (x1 - x0 > 34) { ctx.fillStyle = '#fff'; ctx.font = '600 11px Plus Jakarta Sans, sans-serif'; ctx.fillText('frame ' + (k + 1), x0 + 5, y + bh / 2 + 4); }
      }
      ctx.fillStyle = '#b8a9d4'; ctx.font = '10px JetBrains Mono, monospace';
      for (let t = 0; t <= T - 2; t += 10) ctx.fillText(t + ' ms', X(t) - 10, h - 12);
      $('#s-tlms').textContent = exp.toFixed(1) + ' ms';
      $('#s-tlfps').textContent = Math.min(120, Math.floor(1000 / exp)) + ' fps';
      $('#s-tlper').textContent = per.toFixed(1) + ' ms';
    };
    Site.range($('#s-tlexp'), (x) => { raw = x; draw(); }, (x) => `${x} = ${(x / 10).toFixed(1)} ms`);
    $('#s-tlsnap').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) setRange('#s-tlexp', b.dataset.v); });
    new ResizeObserver(draw).observe(st.cv);
  }

  /* ── Flicker lab ───────────────────────────────────────── */
  {
    const st = Site.canvas($('#s-fl')); // height from CSS aspect-ratio
    let exp = 5, depth = 0.4, tau = 0.2;
    const W2 = 2 * Math.PI * 120, FPS = 122;
    const light = (t) => 1 - depth * (0.5 + 0.5 * Math.cos(W2 * t));
    // average light over a frame's exposure [a, a + T]
    const frameMean = (a, T) => 1 - depth / 2 - (depth / 2) * (Math.sin(W2 * (a + T)) - Math.sin(W2 * a)) / (W2 * T);
    const stats = () => {
      const T = exp / 1000, f = Array.from({ length: 244 }, (_, k) => frameMean(k / FPS, T));
      let d = 0; for (let k = 1; k < f.length; k++) d += Math.abs(f[k] - f[k - 1]);
      const m = f.reduce((a, b) => a + b, 0) / f.length, pct = (100 * d) / (f.length - 1) / m, rng2 = (100 * (Math.max(...f) - Math.min(...f))) / m;
      $('#s-flchg').textContent = pct.toFixed(1) + '%';
      $('#s-flrng').textContent = rng2.toFixed(1) + '%';
      $('#s-flv').innerHTML = rng2 < 2 ? '<span style="color:#a3e635">steady</span>' : rng2 < 6 ? '<span style="color:#f59e0b">slight pulsing</span>' : '<span style="color:#fb7185">flicker: try 8.3 ms</span>';
    };
    Site.range($('#s-flexp'), (x) => { exp = x; stats(); }, (x) => x.toFixed(1) + ' ms');
    Site.range($('#s-fldepth'), (x) => { depth = x / 100; stats(); }, (x) => x + '%');
    $('#s-flsnap').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) setRange('#s-flexp', b.dataset.v); });
    Site.loop(st.cv, (t, dt) => {
      if (!Site.reduced) tau += dt * 0.012; // slow motion: 1 real second = 12 ms
      const { ctx, w, h } = st, span = 0.05, t0 = tau - span, X = (t) => ((t - t0) / span) * w, T = exp / 1000;
      const top = 18, wh = h * 0.42, base = top + wh;
      ctx.clearRect(0, 0, w, h); ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
      // exposure windows of recent frames
      const k0 = Math.floor(t0 * FPS) - 2, k1 = Math.floor(tau * FPS);
      for (let k = k0; k <= k1; k++) { const a = k / FPS; ctx.fillStyle = k % 2 ? 'rgba(139,92,246,.28)' : 'rgba(139,92,246,.42)'; ctx.fillRect(X(a), top, X(a + T) - X(a), wh); }
      // light waveform
      ctx.strokeStyle = '#fde68a'; ctx.lineWidth = 2; ctx.beginPath();
      for (let i = 0; i <= w; i += 2) { const t2 = t0 + (i / w) * span, y = base - light(t2) * (wh - 6); i ? ctx.lineTo(i, y) : ctx.moveTo(i, y); }
      ctx.stroke();
      ctx.fillStyle = '#b8a9d4'; ctx.font = '11px Plus Jakarta Sans, sans-serif';
      ctx.fillText('light (yellow) and exposure windows (purple), last 50 ms', 8, 13);
      // frame brightness bars
      const bt = base + 34, bh2 = h - bt - 8, n = 48;
      ctx.fillText('brightness of each frame', 8, bt - 8);
      for (let j = 0; j < n; j++) {
        const k = k1 - n + 1 + j, m = frameMean(k / FPS, T), rel = (m - (1 - depth)) / Math.max(depth, 1e-6);
        const hh = bh2 * (0.35 + 0.65 * (depth > 0.001 ? rel : 1));
        ctx.fillStyle = j === n - 1 ? '#c4b5fd' : '#8b5cf6'; ctx.fillRect((j / n) * w + 1, bt + bh2 - hh, w / n - 2, hh);
      }
    });
  }
});
