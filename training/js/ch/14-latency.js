Object.assign(Site.glossary, {
  'pose estimator': 'WPILib code (e.g. SwerveDrivePoseEstimator) that fuses odometry with vision measurements into one best guess of the robot\'s field pose.',
  'monotonic clock': 'A clock that only counts up, steadily, from boot. Nobody can set it, so it never jumps. Used for timing.',
  'round trip': 'The time for a message to go to another computer and for its reply to come back.',
});

Site.chapter('latency', (root) => {
  const $ = (s) => root.querySelector(s);
  const LAB_BG = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', LINE = 'rgba(196,181,253,.18)';
  const font = (px, w = 500, fam = 'var(--font)') => `${w} ${px}px ${fam === 'mono' ? 'JetBrains Mono, monospace' : 'Plus Jakarta Sans, sans-serif'}`;
  const hatch = (ctx, x, y, w, h, col) => {
    ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
    ctx.strokeStyle = col; ctx.lineWidth = 1.5;
    for (let i = -h; i < w; i += 6) { ctx.beginPath(); ctx.moveTo(x + i, y + h); ctx.lineTo(x + i + h, y); ctx.stroke(); }
    ctx.restore(); ctx.strokeStyle = col; ctx.lineWidth = 1; ctx.strokeRect(x + .5, y + .5, w - 1, h - 1);
  };
  const arrow = (ctx, x1, y1, x2, y2, col, w = 2, head = 7) => {
    ctx.strokeStyle = col; ctx.fillStyle = col; ctx.lineWidth = w;
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    const a = Math.atan2(y2 - y1, x2 - x1);
    ctx.beginPath(); ctx.moveTo(x2, y2); ctx.lineTo(x2 - head * Math.cos(a - .45), y2 - head * Math.sin(a - .45)); ctx.lineTo(x2 - head * Math.cos(a + .45), y2 - head * Math.sin(a + .45)); ctx.fill();
  };

  /* ── Thunder ───────────────────────────────────────────── */
  {
    const cv = $('#l-thunder'), st = Site.canvas(cv, 0.52);
    const DIST = 1.7; // km
    const period = 8;
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st;
      const tt = t % period, flashT = 0.6, since = tt - flashT;
      const gy = h * 0.8, cx = w * 0.14, px = w * 0.86;
      const sky = ctx.createLinearGradient(0, 0, 0, gy);
      const lit = since > 0 && since < 0.18 ? 1 - since / 0.18 : 0;
      sky.addColorStop(0, `rgb(${30 + 120 * lit},${14 + 110 * lit},${60 + 130 * lit})`); sky.addColorStop(1, '#3c0060');
      ctx.fillStyle = sky; ctx.fillRect(0, 0, w, h);
      ctx.fillStyle = '#1a0a2b'; ctx.fillRect(0, gy, w, h - gy);
      // cloud
      ctx.fillStyle = '#6b5a85';
      for (const [dx, dy, r] of [[-22, 6, 18], [0, 0, 24], [24, 6, 18], [8, 12, 18]]) { ctx.beginPath(); ctx.arc(cx + dx, h * 0.2 + dy, r * w / 520, 0, 7); ctx.fill(); }
      if (lit > 0) {
        ctx.strokeStyle = `rgba(255,255,200,${lit})`; ctx.lineWidth = 3;
        ctx.beginPath(); let x = cx, y = h * 0.26; ctx.moveTo(x, y);
        for (let i = 0; i < 6; i++) { x += (i % 2 ? 10 : -8) * w / 520; y += (gy - h * 0.26) / 6; ctx.lineTo(x, y); }
        ctx.stroke();
      }
      // sound wave
      const mPerPx = (DIST * 1000) / (px - cx);
      const rad = since > 0 ? (since * 343) / mPerPx : 0;
      const arrived = rad >= px - cx;
      if (since > 0 && !arrived) {
        for (let k = 0; k < 3; k++) {
          const r = rad - k * 10; if (r <= 0) continue;
          ctx.strokeStyle = `rgba(252,211,77,${0.7 - k * 0.2})`; ctx.lineWidth = 2;
          ctx.beginPath(); ctx.arc(cx, gy - 30, r, -0.7, 0.35); ctx.stroke();
        }
      }
      // listener
      const shake = arrived && since < (DIST * 1000) / 343 + 0.6 ? Math.sin(t * 60) * 2 : 0;
      ctx.fillStyle = '#f4efff';
      ctx.beginPath(); ctx.arc(px + shake, gy - 44, 8, 0, 7); ctx.fill();
      ctx.fillRect(px - 5 + shake, gy - 34, 10, 26);
      ctx.fillRect(px - 5 + shake, gy - 8, 4, 8); ctx.fillRect(px + 1 + shake, gy - 8, 4, 8);
      if (arrived && since < (DIST * 1000) / 343 + 1.2) { ctx.fillStyle = '#fcd34d'; ctx.font = font(Math.max(13, w / 28), 800); ctx.textAlign = 'right'; ctx.fillText('BOOM', px - 16, gy - 56); }
      // distance ruler
      ctx.strokeStyle = MUTED; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
      ctx.beginPath(); ctx.moveTo(cx, gy + 14); ctx.lineTo(px, gy + 14); ctx.stroke(); ctx.setLineDash([]);
      ctx.fillStyle = MUTED; ctx.font = font(11); ctx.textAlign = 'center'; ctx.fillText(`${DIST} km`, (cx + px) / 2, gy + 30);
      // timers
      const s = Math.max(0, since);
      ctx.textAlign = 'left'; ctx.font = font(Math.max(11, w / 44), 600);
      ctx.fillStyle = '#fff'; ctx.fillText(`Light arrives after ${since > 0 ? '0.000006' : '—'} s`, w * 0.3, h * 0.16);
      ctx.fillStyle = '#fcd34d'; ctx.fillText(`Sound: ${since > 0 ? Math.min(s, (DIST * 1000) / 343).toFixed(1) + ' s' : '—'}${arrived ? ' (arrived)' : ''}`, w * 0.3, h * 0.16 + Math.max(16, w / 30));
    });
  }

  /* ── Frame timeline ────────────────────────────────────── */
  {
    const S = [
      { n: 'Exposure', ms: 5, k: 'm', d: 'The sensor collects light for 5 ms (our setting: exposure 50, in 100 µs units). Every pixel starts and stops together (global shutter). The frame\'s timestamp points at the middle of this bar.' },
      { n: 'Before sending', ms: 1.2, k: 'u', d: 'Any time between the end of the exposure and the camera\'s first USB packet. This delay is inside the camera and not measured yet (SPECTRUM_CAMERA_DELAY_US). Bar width is a placeholder.' },
      { n: 'Camera sends', ms: 8.1, k: 'm', d: 'The slowest step, and it\'s the camera: it streams each JPEG (34–36 KB here) out over about one frame period while its sensor reads out. Timed with the camera driver\'s own log: 8.1 ms from the first USB packet to the last, on every camera. At our USB cap the frame could cross in 3.4 ms, so the cap costs no latency. The frame\'s timestamp comes from the camera\'s own clock, at about the start of this bar.' },
      { n: 'To the decoder', ms: 0.15, k: 'm', d: 'From the last packet to the start of decoding: 0.15 ms (measured). Since then, our driver also looks for finished packets every 2 ms instead of every 4 (urb_packets=16), which took another 1.2 ms off: 12.98 → 11.76 ms from capture to result with 5 cameras.' },
      { n: 'Decode', ms: 2.8, k: 'm', d: 'The JPEG is turned back into a 1280×800 gray image: about 2.8 ms on the Jetson\'s NVJPG hardware decoders, with 4–5 cameras sharing the two of them. It was 8.9 ms before our fix.' },
      { n: 'GPU detect', ms: 1.2, k: 'm', d: 'The CUDA detector finds every tag and its four corners on the GPU: about 1.2 ms per frame with 4 cameras, 2.1 ms with 5 cameras facing bright ceiling lights (more candidate blobs to check).' },
      { n: 'Pose solve', ms: 0.5, k: 'e', d: 'PhotonVision solves the camera\'s pose from the corners (single-tag and multi-tag PnP) and packs the result. A fraction of a millisecond; our estimate, not separately measured.' },
      { n: 'NetworkTables', ms: 0.5, k: 'e', d: 'The result goes over Ethernet to the SystemCore. On a wired network that\'s well under a millisecond (estimate). PhotonVision\'s latency readout stops at publish.' },
      { n: 'Robot loop', ms: 20, k: 'r', d: 'Robot code runs every 20 ms and reads new results when it next runs: anywhere from 0 to 20 ms later. With the timestamp, this wait doesn\'t add error: the estimator knows exactly how old the measurement is.' },
    ];
    let t0 = 0; S.forEach((s) => { s.a = t0; t0 += s.ms; s.b = t0; });
    const RL = S.length - 1; // the robot loop row
    S[RL].a = S[RL - 1].b; S[RL].b = S[RL - 1].b + 20;
    const TOT = S[RL].b + 1;
    const cv = $('#l-tl'); cv.style.height = (root.clientWidth < 560 ? 380 : 300) + 'px';
    const st = Site.canvas(cv);
    const card = $('#l-tl-card'), btn = $('#l-tl-play');
    let T = 0, playing = false, slow = 300, sel = -1;
    Site.seg($('#l-tl-speed'), (v) => (slow = +v));
    const show = (i) => {
      const s = S[i];
      const tag = s.k === 'm' ? `${s.ms} ms, measured` : s.k === 'u' ? 'not measured yet' : s.k === 'r' ? '0–20 ms' : `≈ ${s.ms} ms, estimate`;
      card.innerHTML = `<h5>${s.n}<span>${tag}</span></h5><p>${s.d}</p>`;
    };
    btn.onclick = () => { if (!playing && T >= TOT - 0.01) T = 0; playing = !playing; btn.textContent = playing ? '❚❚ Pause' : '▶ Play'; };
    let geo = null, hover = -1;
    const rowAt = (e) => { if (!geo) return -1; const r = cv.getBoundingClientRect(), i = Math.floor((e.clientY - r.top - geo.top) / geo.rh); return i >= 0 && i < S.length ? i : -1; };
    cv.addEventListener('mousemove', (e) => (hover = rowAt(e)));
    cv.addEventListener('mouseleave', () => (hover = -1));
    cv.addEventListener('click', (e) => {
      if (!geo) return;
      const r = cv.getBoundingClientRect(), y = e.clientY - r.top;
      const i = Math.floor((y - geo.top) / geo.rh);
      if (i >= 0 && i < S.length) { sel = i; T = S[i].a + S[i].ms * 0.999; if (i === RL) T = S[RL].a + 10; playing = false; btn.textContent = '▶ Play'; show(i); }
    });
    let lastShown = -1;
    Site.loop(cv, (_, dt) => {
      if (playing) { T += (dt * 1000) / slow; if (T >= TOT) { T = TOT; playing = false; btn.textContent = '↺ Replay'; } }
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB_BG; ctx.fillRect(0, 0, w, h);
      const narrow = w < 560;
      const lab = narrow ? 84 : 150, x0 = lab + 8, x1 = w - 14, top = 34, rh = (h - top - 44) / S.length;
      geo = { top, rh };
      const X = (ms) => x0 + ((x1 - x0) * ms) / TOT;
      // grid
      ctx.font = font(10, 500, 'mono'); ctx.textAlign = 'center';
      for (let m = 0; m <= TOT; m += narrow ? 10 : 5) { ctx.strokeStyle = LINE; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(X(m), top - 6); ctx.lineTo(X(m), h - 38); ctx.stroke(); ctx.fillStyle = MUTED; ctx.fillText(m + ' ms', X(m), h - 24); }
      // bracket: mid-exposure to the detector's result
      const mid = 2.5, pub = S[5].b;
      ctx.strokeStyle = '#c4b5fd'; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(X(mid), 16); ctx.lineTo(X(mid), 22); ctx.lineTo(X(pub), 22); ctx.lineTo(X(pub), 16); ctx.stroke();
      ctx.fillStyle = '#c4b5fd'; ctx.font = font(narrow ? 10 : 11, 600); ctx.textAlign = 'center';
      ctx.fillText(narrow ? '≈14.5 ms + camera delay' : '≈ 14.5 ms + camera delay: mid-exposure → result', X((mid + pub) / 2), 12);
      let active = -1;
      S.forEach((s, i) => {
        const y = top + i * rh, bh = Math.min(20, rh - 6), by = y + (rh - bh) / 2;
        ctx.textAlign = 'right'; ctx.font = font(narrow ? 10.5 : 12.5, 600);
        const on = T >= s.a && T < s.b;
        if (i === sel || i === hover) { ctx.fillStyle = i === sel ? 'rgba(139,92,246,.22)' : 'rgba(255,255,255,.06)'; ctx.fillRect(4, y + 1, w - 8, rh - 2); }
        if (on) active = i;
        ctx.fillStyle = on || sel === i ? '#fff' : MUTED; ctx.fillText(s.n, lab, by + bh / 2 + 4);
        const xa = X(s.a), xb = X(s.b), fill = Site.clamp((T - s.a) / (s.b - s.a), 0, 1);
        if (s.k === 'u') hatch(ctx, xa, by, xb - xa, bh, fill > 0 ? '#e9ddf7' : '#6b5a85');
        else if (s.k === 'r') {
          const g = ctx.createLinearGradient(xa, 0, xb, 0); g.addColorStop(0, 'rgba(245,158,11,.55)'); g.addColorStop(1, 'rgba(245,158,11,.05)');
          ctx.fillStyle = g; ctx.fillRect(xa, by, xb - xa, bh);
          ctx.strokeStyle = 'rgba(245,158,11,.6)'; ctx.setLineDash([4, 3]); ctx.strokeRect(xa + .5, by + .5, xb - xa - 1, bh - 1); ctx.setLineDash([]);
          if (fill > 0) { ctx.fillStyle = '#f59e0b'; ctx.fillRect(xa, by + bh - 3, (xb - xa) * fill, 3); }
          ctx.fillStyle = '#fcd34d'; ctx.font = font(10.5, 600); ctx.textAlign = 'left';
          ctx.fillText(narrow ? '0–20 ms' : 'reads it 0–20 ms later', xa + 6, by + bh / 2 + 4);
        } else {
          ctx.fillStyle = s.k === 'e' ? 'rgba(139,92,246,.35)' : 'rgba(139,92,246,.3)'; ctx.fillRect(xa, by, xb - xa, bh);
          ctx.fillStyle = s.k === 'e' ? 'rgba(167,139,250,.75)' : '#8b5cf6'; ctx.fillRect(xa, by, (xb - xa) * fill, bh);
          if (!narrow || xb - xa > 34) { ctx.fillStyle = '#fff'; ctx.font = font(10, 500, 'mono'); ctx.textAlign = 'left'; const lbl = (s.k === 'e' ? '≈' : '') + s.ms; if (xb - xa > 22) ctx.fillText(lbl, xa + 4, by + bh / 2 + 4); }
        }
      });
      // timestamp marker (mid-exposure) and driver stamp (first packet)
      const yb = h - 38;
      ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.setLineDash([3, 3]);
      ctx.beginPath(); ctx.moveTo(X(2.5), top - 4); ctx.lineTo(X(2.5), yb); ctx.stroke(); ctx.setLineDash([]);
      ctx.fillStyle = '#a3e635'; ctx.font = font(10, 700); ctx.textAlign = 'left'; ctx.fillText('timestamp', X(2.5) + 4, h - 8);
      ctx.strokeStyle = 'rgba(245,158,11,.8)'; ctx.setLineDash([2, 3]); ctx.beginPath(); ctx.moveTo(X(S[2].a), top + 2 * rh); ctx.lineTo(X(S[2].a), yb); ctx.stroke(); ctx.setLineDash([]);
      if (!narrow) { ctx.fillStyle = '#f59e0b'; ctx.fillText('camera-clock stamp (starts sending)', X(S[2].a) + 4, h - 8); }
      // playhead
      if (T > 0) { ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(X(T), top - 6); ctx.lineTo(X(T), yb); ctx.stroke(); ctx.fillStyle = '#fff'; ctx.font = font(11, 700, 'mono'); ctx.textAlign = X(T) > w - 70 ? 'right' : 'left'; ctx.fillText(T.toFixed(1) + ' ms', X(T) + (ctx.textAlign === 'right' ? -5 : 5), top + (T < S[RL].a ? RL : RL - 1) * rh + rh / 2 + 4); }
      if (playing && active !== lastShown && active >= 0) { lastShown = active; sel = -1; show(active); }
    });
  }

  /* ── Stale answers lab ─────────────────────────────────── */
  {
    const cv = $('#l-bot');
    const narrow = (cv.clientWidth || cv.parentElement.clientWidth || root.clientWidth) < 520;
    const st = Site.canvas(cv, narrow ? 1.12 : 0.43);
    let mode = 'ts', L = 15, V = 4, W = 3;
    const e1 = $('#l-e1'), e2 = $('#l-e2'), e3 = $('#l-e3'), e4 = $('#l-e4');
    const upd = () => {
      e1.textContent = (V * L / 10).toFixed(1) + ' cm';
      e2.textContent = (W * L / 1000 * 180 / Math.PI).toFixed(1) + '°';
      e3.textContent = (4 * W * L / 10).toFixed(0) + ' cm';
      e4.textContent = mode === 'ts' ? '≈ 0' : 'off';
      root.querySelectorAll('#l-e1, #l-e2, #l-e3').forEach((b) => (b.style.color = mode === 'now' ? '#fda4af' : '#fff'));
    };
    Site.seg($('#l-mode'), (v) => { mode = v; upd(); });
    Site.range($('#l-lat'), (v) => { L = v; upd(); }, (v) => v + ' ms');
    Site.range($('#l-v'), (v) => { V = v; upd(); }, (v) => v.toFixed(1) + ' m/s');
    Site.range($('#l-w'), (v) => { W = v; upd(); }, (v) => v.toFixed(1) + ' rad/s');
    const FW = 16.5, FH = 8.1, AX = 5.2, AY = 2.3;
    let s = 0, head = 0, t = 0;
    const hist = [];
    const posAt = (s) => [FW / 2 + AX * Math.cos(s), FH / 2 + AY * Math.sin(2 * s) * 0.9];
    const sample = (tq) => {
      if (!hist.length) return null;
      if (tq <= hist[0].t) return hist[0];
      for (let i = hist.length - 1; i > 0; i--) if (hist[i - 1].t <= tq) { const a = hist[i - 1], b = hist[i], u = (tq - a.t) / (b.t - a.t || 1); return { x: Site.lerp(a.x, b.x, u), y: Site.lerp(a.y, b.y, u), h: Site.lerp(a.h, b.h, u) }; }
      return hist[hist.length - 1];
    };
    const trail = [];
    const tags = [[0.2, 1.5], [0.2, 6.6], [16.3, 1.5], [16.3, 6.6], [4.6, 4.05], [11.9, 4.05], [8.25, 0.1], [8.25, 8]];
    Site.loop(cv, (_, dt) => {
      if (!dt) return;
      t += dt;
      const [px0, py0] = posAt(s), [px1, py1] = posAt(s + 0.001);
      const dl = Math.hypot(px1 - px0, py1 - py0) / 0.001;
      s += (V * dt) / dl; head += W * dt;
      const [x, y] = posAt(s);
      hist.push({ t, x, y, h: head }); while (hist.length && hist[0].t < t - 0.4) hist.shift();
      trail.push([x, y]); if (trail.length > 140) trail.shift();
      const g = sample(t - L / 1000) || { x, y, h: head };
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB_BG; ctx.fillRect(0, 0, w, h);
      // field area
      const fw = narrow ? w : w * 0.6 - 8, fh = fw * FH / FW, fy = narrow ? 0 : (h - fh) / 2;
      const k = fw / FW, FX = (x) => x * k, FY = (y) => fy + fh - y * k;
      ctx.fillStyle = '#1b0d2c'; ctx.fillRect(0, fy, fw, fh);
      ctx.strokeStyle = 'rgba(196,181,253,.35)'; ctx.lineWidth = 1.5; ctx.strokeRect(1, fy + 1, fw - 2, fh - 2);
      ctx.beginPath(); ctx.moveTo(fw / 2, fy); ctx.lineTo(fw / 2, fy + fh); ctx.strokeStyle = 'rgba(196,181,253,.15)'; ctx.stroke();
      for (const tg of tags) { ctx.fillStyle = '#fff'; ctx.fillRect(FX(tg[0]) - 3, FY(tg[1]) - 3, 6, 6); }
      ctx.strokeStyle = 'rgba(255,255,255,.35)'; ctx.lineWidth = 1.5; ctx.beginPath(); trail.forEach((p, i) => (i ? ctx.lineTo(FX(p[0]), FY(p[1])) : ctx.moveTo(FX(p[0]), FY(p[1])))); ctx.stroke();
      const rs = 0.8 * k;
      ctx.save(); ctx.translate(FX(x), FY(y)); ctx.rotate(-head); ctx.fillStyle = 'rgba(124,58,237,.9)'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.fillRect(-rs / 2, -rs / 2, rs, rs); ctx.strokeRect(-rs / 2, -rs / 2, rs, rs); ctx.restore();
      // magnifier box on field
      const VIEW = 1.1; // meters shown in the zoom
      const zx = narrow ? 8 : w * 0.6 + 8, zy = narrow ? fh + 12 : 8, zs = narrow ? Math.min(w - 16, h - fh - 20) : Math.min(w * 0.4 - 16, h - 16);
      ctx.strokeStyle = '#fcd34d'; ctx.lineWidth = 1; ctx.strokeRect(FX(x) - (VIEW * k) / 2, FY(y) - (VIEW * k) / 2, VIEW * k, VIEW * k);
      ctx.beginPath(); ctx.moveTo(FX(x) + (VIEW * k) / 2, FY(y)); ctx.lineTo(narrow ? zx + zs / 2 : zx, narrow ? zy : zy + zs / 2); ctx.strokeStyle = 'rgba(252,211,77,.35)'; ctx.stroke();
      // zoom view
      const zk = zs / VIEW, ZX = (xx) => zx + zs / 2 + (xx - x) * zk, ZY = (yy) => zy + zs / 2 - (yy - y) * zk;
      ctx.save(); ctx.beginPath(); ctx.rect(zx, zy, zs, zs); ctx.clip();
      ctx.fillStyle = '#140822'; ctx.fillRect(zx, zy, zs, zs);
      ctx.strokeStyle = 'rgba(196,181,253,.08)'; ctx.lineWidth = 1;
      const g10 = 0.1 * zk, ox = ((x * zk) % g10), oy = ((y * zk) % g10);
      for (let gx = zx - ox; gx < zx + zs; gx += g10) { ctx.beginPath(); ctx.moveTo(gx, zy); ctx.lineTo(gx, zy + zs); ctx.stroke(); }
      for (let gy = zy + oy; gy < zy + zs; gy += g10) { ctx.beginPath(); ctx.moveTo(zx, gy); ctx.lineTo(zx + zs, gy); ctx.stroke(); }
      const bot = (p, stroke, fill, dash) => {
        ctx.save(); ctx.translate(ZX(p.x), ZY(p.y)); ctx.rotate(-p.h); const r = 0.8 * zk;
        ctx.setLineDash(dash || []); ctx.fillStyle = fill; ctx.strokeStyle = stroke; ctx.lineWidth = 2;
        ctx.fillRect(-r / 2, -r / 2, r, r); ctx.strokeRect(-r / 2, -r / 2, r, r); ctx.setLineDash([]);
        ctx.beginPath(); ctx.moveTo(r / 2 - 2, 0); ctx.lineTo(r / 2 - 14, -8); ctx.lineTo(r / 2 - 14, 8); ctx.fillStyle = stroke; ctx.fill();
        ctx.restore();
      };
      bot(g, '#b8a9d4', 'rgba(184,169,212,.08)', [5, 4]);
      bot({ x, y, h: head }, '#fff', 'rgba(124,58,237,.35)');
      const cam = (p) => [p.x + 0.4 * Math.cos(p.h), p.y + 0.4 * Math.sin(p.h)];
      if (mode === 'now') {
        const [gx, gy] = [g.x, g.y];
        if (Math.hypot(gx - x, gy - y) * zk > 6) arrow(ctx, ZX(x), ZY(y), ZX(gx), ZY(gy), '#f43f5e', 2.5, 8);
        ctx.fillStyle = '#f43f5e'; ctx.beginPath(); ctx.arc(ZX(gx), ZY(gy), 5, 0, 7); ctx.fill();
        // heading error: the "now" pose's front point versus the stale one
        const a = cam({ x, y, h: head }), b = cam({ x, y, h: g.h });
        ctx.strokeStyle = '#f43f5e'; ctx.setLineDash([3, 3]); ctx.lineWidth = 1.5;
        ctx.beginPath(); ctx.arc(ZX(x), ZY(y), 0.4 * zk, -head, -g.h, W > 0 ? false : true); ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = '#fda4af'; ctx.font = font(12, 700); ctx.textAlign = 'left';
        ctx.font = font(narrow ? 11 : 12, 700); ctx.fillText('stale pose, treated as now:', zx + 10, zy + zs - 28); ctx.fillText(`${(Math.hypot(gx - x, gy - y) * 100).toFixed(1)} cm and ${((head - g.h) * 180 / Math.PI).toFixed(1)}° behind`, zx + 10, zy + zs - 12);
        void a; void b;
      } else {
        ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.setLineDash([4, 4]);
        ctx.beginPath(); for (let i = 0; i <= 12; i++) { const p = sample(t - (L / 1000) * (1 - i / 12)) || g; i ? ctx.lineTo(ZX(p.x), ZY(p.y)) : ctx.moveTo(ZX(p.x), ZY(p.y)); } ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = '#a3e635'; ctx.beginPath(); ctx.arc(ZX(g.x), ZY(g.y), 4, 0, 7); ctx.fill();
        ctx.beginPath(); ctx.arc(ZX(x), ZY(y), 6, 0, 7); ctx.fill();
        ctx.font = font(12, 700); ctx.textAlign = 'left';
        ctx.font = font(narrow ? 11 : 12, 700); ctx.fillText('fix applied at capture time,', zx + 10, zy + zs - 28); ctx.fillText('odometry replayed → on target', zx + 10, zy + zs - 12);
      }
      // scale bar
      ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(zx + 10, zy + 16); ctx.lineTo(zx + 10 + 0.1 * zk, zy + 16); ctx.stroke();
      ctx.fillStyle = '#fff'; ctx.font = font(11, 600); ctx.textAlign = 'left'; ctx.fillText('10 cm', zx + 14 + 0.1 * zk, zy + 20);
      ctx.fillStyle = '#fcd34d'; ctx.textAlign = 'right'; ctx.fillText(`magnifier ×${(zk / k).toFixed(0)}`, zx + zs - 10, zy + 20);
      ctx.restore();
      ctx.strokeStyle = 'rgba(252,211,77,.6)'; ctx.lineWidth = 1.5; ctx.strokeRect(zx + .5, zy + .5, zs - 1, zs - 1);
    });
  }

  /* ── Rewind animation ──────────────────────────────────── */
  {
    const cv = $('#l-rewind'), st = Site.canvas(cv, 0.66), cap = $('#l-rw-cap');
    const N = 14, K = 6, CYC = 10;
    const caps = ['Odometry adds a pose every loop. It slowly drifts from the truth (white).', 'A vision result arrives now, stamped with its capture time. The estimator finds the odometry pose from that moment.', 'It blends the vision pose in at that moment in the past.', 'Then it replays every wheel movement since, on top of the corrected pose.', 'The current estimate is corrected, as if the measurement had arrived instantly.'];
    let lastPh = -1;
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st;
      const tt = (Site.reduced ? 8.5 : t % CYC);
      const ph = tt < 2.4 ? 0 : tt < 4 ? 1 : tt < 5.5 ? 2 : tt < 7.5 ? 3 : 4;
      if (ph !== lastPh) { lastPh = ph; cap.textContent = caps[ph] + ' (Simplified illustration.)'; }
      ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, h);
      const P = (i) => { const u = i / (N - 1); return [w * (0.08 + 0.84 * u), h * (0.74 - 0.44 * Math.sin(u * 2.6))]; };
      const drift = (i) => [-i * i * 0.00015 * w, i * i * 0.0009 * h];
      // truth
      ctx.strokeStyle = '#d4c0ee'; ctx.lineWidth = 3; ctx.beginPath(); for (let i = 0; i < N; i++) { const [x, y] = P(i); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); } ctx.stroke();
      const shown = ph === 0 ? Math.min(N, Math.floor((tt / 2.4) * N) + 1) : N;
      const [kx, ky] = P(K), [dkx, dky] = drift(K);
      const corr = ph < 2 ? 0 : ph === 2 ? Site.ease((tt - 4) / 1.5) : 1;
      const rep = ph < 3 ? 0 : ph === 3 ? Site.ease((tt - 5.5) / 2) : 1;
      const cx = -dkx * 0.85 * corr, cy = -dky * 0.85 * corr;
      const pts = [];
      for (let i = 0; i < shown; i++) {
        const [x, y] = P(i), [dx, dy] = drift(i);
        let ox = x + dx, oy = y + dy;
        if (i === K) { ox += cx; oy += cy; }
        if (i > K) { ox += -dkx * 0.85 * rep; oy += -dky * 0.85 * rep; }
        pts.push([ox, oy]);
      }
      ctx.strokeStyle = 'rgba(245,158,11,.5)'; ctx.lineWidth = 2; ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.stroke();
      pts.forEach(([x, y], i) => { ctx.fillStyle = i === K && ph >= 1 ? '#a3e635' : i > K && ph === 3 ? '#fb923c' : '#f59e0b'; ctx.beginPath(); ctx.arc(x, y, i === K && ph >= 1 ? 7 : 5, 0, 7); ctx.fill(); });
      if (ph >= 1) {
        // vision measurement: true pose at K
        ctx.strokeStyle = '#16a34a'; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(kx, ky, 11, 0, 7); ctx.stroke();
        ctx.fillStyle = '#15803d'; ctx.font = font(12, 700); ctx.textAlign = 'center'; ctx.fillText('vision pose', kx, ky - 18);
        const [nx, ny] = pts[N - 1];
        if (ph === 1) {
          ctx.strokeStyle = '#6b1199'; ctx.setLineDash([5, 4]); ctx.lineWidth = 1.5;
          ctx.beginPath(); ctx.moveTo(nx, h * 0.93); ctx.lineTo(kx, h * 0.93); ctx.stroke(); ctx.setLineDash([]);
          arrow(ctx, nx, h * 0.93, kx + 4, h * 0.93, '#6b1199', 1.5);
          ctx.fillStyle = '#6b1199'; ctx.font = font(11, 700); ctx.fillText('timestamp → look up this moment', (nx + kx) / 2, h * 0.9);
        }
        ctx.fillStyle = '#3c0060'; ctx.font = font(11, 700); ctx.fillText('now', nx, ny + 22);
      }
      // time axis
      ctx.strokeStyle = '#d4c0ee'; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(w * 0.06, h * 0.97); ctx.lineTo(w * 0.94, h * 0.97); ctx.stroke();
      ctx.fillStyle = '#635a72'; ctx.font = font(11, 600); ctx.textAlign = 'left'; ctx.fillText('older', w * 0.06, h * 0.97 - 4); ctx.textAlign = 'right'; ctx.fillText('newer', w * 0.94, h * 0.97 - 4);
      // legend
      ctx.textAlign = 'left'; ctx.font = font(11, 600);
      ctx.fillStyle = '#b39ddb'; ctx.fillText('— true path', 10, 18); ctx.fillStyle = '#d97706'; ctx.fillText('● odometry history', 90, 18);
    });
  }

  /* ── Mid-exposure diagram ──────────────────────────────── */
  {
    const cv = $('#l-mid'), nw = (cv.clientWidth || cv.parentElement.clientWidth || root.clientWidth) < 480, st = Site.canvas(cv, nw ? 1.15 : 0.57);
    let E = 5;
    const late = $('#l-late'), sub = $('#l-sub');
    Site.range($('#l-exp'), (v) => { E = v; late.textContent = (v / 2).toFixed(1) + ' ms + ?'; sub.textContent = (v / 2).toFixed(2) + ' ms'; }, (v) => v.toFixed(1) + ' ms');
    const D = 1.0, USB = 8.1;
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB_BG; ctx.fillRect(0, 0, w, h);
      const TOT = 10 + D + USB + 1;
      const cyc = TOT * 0.45 + 2.5, tt = Site.reduced ? cyc : t % cyc, T = Math.min(TOT, tt / 0.45);
      const x0 = 18, x1 = w - 18, X = (ms) => x0 + ((x1 - x0) * ms) / TOT;
      // top: moving tag and blur
      const ty = 26, ts = nw ? 44 : Math.min(h * 0.2, 60), speed = (w * 0.5) / 10; // px per ms of motion
      const tx0 = w * 0.18;
      const expT = Math.min(T, E);
      ctx.fillStyle = MUTED; ctx.font = font(11, 600); ctx.textAlign = 'left';
      ctx.fillText(nw ? 'A tag sliding right during the exposure' : 'What the sensor sees: a tag sliding right during the exposure', x0, 16);
      // running average of shifted copies = what a sensor integrates over the exposure
      const steps = Math.max(1, Math.round(30 * expT / E));
      if (expT > 0) for (let i = 0; i <= steps; i++) {
        ctx.globalAlpha = 1 / (i + 1);
        Site.drawTag(ctx, 7, tx0 + (i / steps) * expT * speed, ty + 14, ts, { quiet: true });
      }
      ctx.globalAlpha = 1;
      if (T >= E) {
        const mx = tx0 + (E / 2) * speed + ts / 2;
        ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(mx, ty + 8); ctx.lineTo(mx, ty + ts + 22); ctx.stroke();
        ctx.fillStyle = '#a3e635'; ctx.font = font(11, 700); ctx.textAlign = 'center'; ctx.fillText('middle of the blur', mx, ty + ts + 36);
      }
      // bottom: timeline
      const yb = h * (nw ? 0.58 : 0.6), bh = 24;
      ctx.font = font(10, 500, 'mono'); ctx.textAlign = 'center';
      for (let m = 0; m <= TOT; m += nw ? 4 : 2) { ctx.strokeStyle = LINE; ctx.beginPath(); ctx.moveTo(X(m), yb - 40); ctx.lineTo(X(m), yb + bh + 6); ctx.stroke(); ctx.fillStyle = MUTED; ctx.fillText(m + '', X(m), yb + bh + 20); }
      ctx.fillText('ms', X(TOT) - 4, yb + bh + 34);
      // exposure
      ctx.fillStyle = 'rgba(139,92,246,.25)'; ctx.fillRect(X(0), yb, X(E) - X(0), bh);
      ctx.fillStyle = '#8b5cf6'; ctx.fillRect(X(0), yb, X(expT) - X(0), bh);
      ctx.fillStyle = '#fff'; ctx.font = font(11, 700); ctx.textAlign = 'center'; if (X(E) - X(0) > 60) ctx.fillText('exposure', (X(0) + X(E)) / 2, yb + 16);
      // camera delay
      hatch(ctx, X(E), yb, X(E + D) - X(E), bh, T > E ? '#e9ddf7' : '#6b5a85');
      ctx.fillStyle = '#e9ddf7'; ctx.font = font(12, 700); ctx.fillText('?', X(E + D / 2), yb - 6);
      // usb packets
      const n = 20;
      for (let i = 0; i < n; i++) {
        const pa = E + D + (USB * i) / n; if (pa > T) break;
        ctx.fillStyle = i === 0 ? '#f59e0b' : 'rgba(6,182,212,.8)'; ctx.fillRect(X(pa) + 1, yb + 4, Math.max(2, X(USB / n) - X(0) - 2), bh - 8);
      }
      if (X(USB) - X(0) > 70 && T < E + D) { ctx.fillStyle = '#67e8f9'; ctx.font = font(11, 600); ctx.fillText('USB packets', X(E + D + USB / 2), yb - 8); }
      // stamps
      const fp = E + D;
      if (T >= fp) {
        ctx.strokeStyle = '#f59e0b'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(X(fp), yb - 44); ctx.lineTo(X(fp), yb + bh); ctx.stroke();
        ctx.fillStyle = '#fcd34d'; ctx.font = font(11, 700); ctx.textAlign = 'left'; ctx.fillText('the frame is stamped', X(fp) + 5, yb - 44);
        ctx.fillStyle = MUTED; ctx.font = font(10.5, 500); ctx.fillText('(camera\'s clock: it starts sending)', X(fp) + 5, yb - 30);
      }
      if (T >= fp + 1.2) {
        const a = Site.ease(Site.clamp((T - fp - 1.2) / 2, 0, 1));
        const xs = X(fp), xe = X(Site.lerp(fp, E / 2, a));
        ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.setLineDash([4, 3]);
        ctx.beginPath(); ctx.moveTo(xs, yb - 16); ctx.quadraticCurveTo((xs + xe) / 2, yb - 34, xe, yb - 16); ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = '#a3e635'; ctx.beginPath(); ctx.arc(xe, yb + bh / 2, 6, 0, 7); ctx.fill();
        ctx.strokeStyle = '#a3e635'; ctx.beginPath(); ctx.moveTo(xe, yb - 14); ctx.lineTo(xe, yb + bh + 6); ctx.stroke();
        if (a >= 1) {
          ctx.textAlign = 'center'; ctx.font = font(11.5, 700);
          const lx = Site.clamp(X(E / 2), 70, w - 70);
          ctx.fillText('published timestamp', lx, yb + bh + 52);
          ctx.fillStyle = MUTED; ctx.font = font(10.5, 500); ctx.fillText(`= stamp − ${(E / 2).toFixed(1)} ms (half the exposure)`, lx, yb + bh + 67);
        }
      }
    });
  }

  /* ── Time sync ping-pong ───────────────────────────────── */
  {
    const cv = $('#l-sync'), st = Site.canvas(cv, (cv.clientWidth || cv.parentElement.clientWidth || root.clientWidth) < 600 ? 0.62 : 0.36);
    const OFFSET = 718266.4312; // robot = jetson + OFFSET (ms), made up
    const base = performance.now() - 812004.513;
    const jet = () => performance.now() - base;
    const cj = $('#l-cj'), cr = $('#l-cr'), math = $('#l-math');
    let asym = 0.3, ping = null;
    let asymTouched = false;
    Site.range($('#l-asym'), (v) => { asym = v; if (asymTouched && ping && ping.reported) math.innerHTML = `<span class="dim">Unevenness set to ${v.toFixed(2)} ms. Press "Send a ping" to see how it changes the error.</span>`; asymTouched = true; }, (v) => v.toFixed(2) + ' ms');
    const fmt = (ms) => (ms / 1000).toFixed(6) + ' s';
    const send = () => {
      const base = 0.15;
      const a = base + Math.random() * asym, b = base + Math.random() * asym, srv = 0.02;
      const t0 = jet();
      ping = { t0, a, b, srv, t1: t0 + a + OFFSET, t2: t0 + a + srv + b, start: performance.now() };
      math.innerHTML = '<span class="dim">Ping in flight…</span>';
    };
    $('#l-ping').onclick = send;
    const done = (p) => {
      const rtt = p.t2 - p.t0 - p.srv; // server turnaround is tiny; shown combined
      const rttAll = p.t2 - p.t0;
      const est = p.t1 + rttAll / 2 - p.t2;
      const err = (est - OFFSET) * 1000;
      void rtt;
      math.innerHTML = `t0 = ${fmt(p.t0)} <span class="dim">(Jetson sends)</span><br>t1 = ${fmt(p.t1)} <span class="dim">(robot's clock when it answers)</span><br>t2 = ${fmt(p.t2)} <span class="dim">(Jetson receives)</span><br>round trip = t2 − t0 = <b>${rttAll.toFixed(3)} ms</b><br>offset = t1 + RTT/2 − t2 = <b>${(est / 1000).toFixed(6)} s</b> <span class="dim">(true: ${(OFFSET / 1000).toFixed(6)} s, error ${err >= 0 ? '+' : ''}${err.toFixed(0)} µs)</span>`;
    };
    Site.loop(cv, () => {
      const { ctx, w, h } = st;
      const nowJ = jet();
      cj.textContent = fmt(nowJ); cr.textContent = fmt(nowJ + OFFSET);
      ctx.fillStyle = LAB_BG; ctx.fillRect(0, 0, w, h);
      const yJ = h * 0.3, yR = h * 0.72, xa = w * 0.2, xb = w * 0.88;
      ctx.lineWidth = 2;
      ctx.strokeStyle = '#c4b5fd'; ctx.beginPath(); ctx.moveTo(xa - 20, yJ); ctx.lineTo(xb + 20, yJ); ctx.stroke();
      ctx.strokeStyle = '#fcd34d'; ctx.beginPath(); ctx.moveTo(xa - 20, yR); ctx.lineTo(xb + 20, yR); ctx.stroke();
      ctx.font = font(11.5, 700); ctx.textAlign = 'left';
      ctx.fillStyle = '#c4b5fd'; ctx.fillText('Jetson', 8, yJ - 10);
      ctx.fillStyle = '#fcd34d'; ctx.fillText('SystemCore', 8, yR + 20);
      ctx.fillStyle = MUTED; ctx.font = font(10.5, 500); ctx.textAlign = 'right'; ctx.fillText('time →', w - 8, h - 8);
      if (!ping) return;
      const tot = ping.a + ping.srv + ping.b, X = (ms) => xa + ((xb - xa) * ms) / tot;
      const el = (performance.now() - ping.start) / 1000, dur = 2.2;
      const u = Math.min(1, el / dur), m = u * tot;
      const x0 = X(0), x1 = X(ping.a), x1b = X(ping.a + ping.srv), x2 = X(tot);
      ctx.strokeStyle = '#8b5cf6'; ctx.lineWidth = 2.5;
      ctx.beginPath(); ctx.moveTo(x0, yJ);
      if (m < ping.a) { const f = m / ping.a; ctx.lineTo(Site.lerp(x0, x1, f), Site.lerp(yJ, yR, f)); ctx.stroke(); }
      else {
        ctx.lineTo(x1, yR); ctx.lineTo(x1b, yR);
        const f = Site.clamp((m - ping.a - ping.srv) / ping.b, 0, 1);
        ctx.lineTo(Site.lerp(x1b, x2, f), Site.lerp(yR, yJ, f)); ctx.stroke();
      }
      const dot = (x, y, lbl, col, up) => { ctx.fillStyle = col; ctx.beginPath(); ctx.arc(x, y, 5, 0, 7); ctx.fill(); ctx.font = font(12, 700, 'mono'); ctx.textAlign = 'center'; ctx.fillText(lbl, x, up ? y - 12 : y + 22); };
      dot(x0, yJ, 't0', '#c4b5fd', true);
      ctx.fillStyle = '#fff'; ctx.font = font(11, 600); ctx.textAlign = 'center';
      if (m >= ping.a) dot(x1, yR, 't1', '#fcd34d', false);
      if (u >= 1) {
        dot(x2, yJ, 't2', '#c4b5fd', true);
        ctx.fillStyle = MUTED; ctx.font = font(10.5, 600);
        ctx.textAlign = 'right'; ctx.fillText(`there: ${ping.a.toFixed(2)} ms`, (x0 + x1) / 2 - 6, (yJ + yR) / 2 + 4);
        ctx.textAlign = 'left'; ctx.fillText(`back: ${ping.b.toFixed(2)} ms`, (x1b + x2) / 2 + 6, (yJ + yR) / 2 + 4);
        if (!ping.reported) { ping.reported = true; done(ping); }
      } else {
        const lbl = m < ping.a ? 'ping (carries t0)' : 'pong (carries t0 and t1)';
        ctx.fillStyle = '#fff'; ctx.fillText(lbl, w / 2, (yJ + yR) / 2 + 4);
      }
    });
    setTimeout(() => { if (!ping) send(); }, 400);
  }

  /* ── fps sawtooth ──────────────────────────────────────── */
  {
    const cv = $('#l-fps'), st = Site.canvas(cv, 0.6);
    let F = 120; const L = 15;
    const f1 = $('#l-f1'), f2 = $('#l-f2'), f3 = $('#l-f3');
    Site.seg($('#l-fps-seg'), (v) => { F = +v; const T = 1000 / F; f1.textContent = T.toFixed(1) + ' ms'; f2.textContent = (L + T / 2).toFixed(0) + ' ms'; f3.textContent = (20 / T).toFixed(1); });
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st;
      ctx.fillStyle = LAB_BG; ctx.fillRect(0, 0, w, h);
      const T = 1000 / F, WIN = 120, YMAX = 60;
      const x0 = 36, x1 = w - 10, y0 = 10, y1 = h - 28;
      const X = (ms) => x0 + ((x1 - x0) * ms) / WIN, Y = (a) => y1 - ((y1 - y0) * a) / YMAX;
      ctx.font = font(10, 500, 'mono'); ctx.fillStyle = MUTED; ctx.textAlign = 'right';
      for (let a = 0; a <= YMAX; a += 20) { ctx.strokeStyle = LINE; ctx.beginPath(); ctx.moveTo(x0, Y(a)); ctx.lineTo(x1, Y(a)); ctx.stroke(); ctx.fillText(a + '', x0 - 5, Y(a) + 3); }
      ctx.save(); ctx.translate(11, (y0 + y1) / 2); ctx.rotate(-Math.PI / 2); ctx.textAlign = 'center'; ctx.font = font(10, 600); ctx.fillText('age of newest answer (ms)', 0, 0); ctx.restore();
      const off = Site.reduced ? 0 : (t * 1000 * 0.15) % 20;
      // robot loop ticks
      for (let m = -off; m < WIN; m += 20) { if (m < 0) continue; ctx.fillStyle = 'rgba(245,158,11,.8)'; ctx.fillRect(X(m) - 1, y1 + 4, 2, 8); }
      ctx.fillStyle = '#f59e0b'; ctx.font = font(10, 600); ctx.textAlign = 'left'; ctx.fillText('robot loops (every 20 ms)', x0, h - 4);
      // sawtooth
      ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.beginPath();
      const phase = Site.reduced ? 0 : (t * 1000 * 0.15) % T;
      for (let px = 0; px <= 400; px++) {
        const m = (px / 400) * WIN, tm = m + phase;
        const age = L + (((tm % T) + T) % T);
        const x = X(m), y = Y(age);
        px ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }
      ctx.stroke();
      ctx.strokeStyle = 'rgba(255,255,255,.6)'; ctx.setLineDash([5, 4]); ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(x0, Y(L + T / 2)); ctx.lineTo(x1, Y(L + T / 2)); ctx.stroke(); ctx.setLineDash([]);
      ctx.strokeStyle = 'rgba(139,92,246,.8)'; ctx.beginPath(); ctx.moveTo(x0, Y(L)); ctx.lineTo(x1, Y(L)); ctx.stroke();
      ctx.fillStyle = '#c4b5fd'; ctx.textAlign = 'right'; ctx.font = font(10, 600); ctx.fillText('latency alone', x1 - 2, Y(L) + 13);
      ctx.fillStyle = '#fff'; ctx.fillText('average', x1 - 2, Y(L + T / 2) - 5);
    });
  }

  /* ── Gyro heading lookup at the capture time (moved from chapter 13) ── */
  {
    const later = (fn) => () => requestAnimationFrame(fn);
    const LAB = '#0e0518', MUTED = '#b8a9d4', RED = '#f43f5e', GREEN = '#a3e635', AMBER = '#f59e0b', LAV = '#c4b5fd';
    const line = (ctx, a, b) => { ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke(); };
    const dot = (ctx, p, r, c) => { ctx.fillStyle = c; ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 7); ctx.fill(); };
    const D2R = Math.PI / 180;
  {
    const cv = $('#l-gy-time'); let st = null; const P = { w: 3, l: 30, d: 4 };
    const draw = () => {
      if (!st || !st.w) return;
      const { ctx, w, h } = st;
      const t0 = -110, t1 = 12, L = 44, Rr = w - 14, top = 26, bot = h - 34;
      const X = (t) => L + ((t - t0) / (t1 - t0)) * (Rr - L);
      const acc = 8; // rad/s², a gentle change in spin so interpolation isn't trivially exact
      const th = (t) => { const s = t / 1000; return P.w * s + 0.5 * acc * s * s; };
      const lo = Math.min(th(t0), th(t1)), hi = Math.max(th(t0), th(t1)), span = Math.max(0.02, hi - lo), mid = (hi + lo) / 2;
      const Y = (a) => (top + bot) / 2 - ((a - mid) / span) * (bot - top - 30);
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.25)'; line(ctx, [L, bot], [Rr, bot]);
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED;
      const stepT = w < 500 ? 50 : 20; for (let t = -100; t <= 0; t += stepT) { line(ctx, [X(t), bot], [X(t), bot + 4]); ctx.fillText(t + ' ms', X(t) - 16, bot + 16); }
      ctx.fillText('heading', 4, top - 8);
      ctx.strokeStyle = 'rgba(163,230,53,.35)'; ctx.beginPath(); for (let t = t0; t <= t1; t += 1) { const p = [X(t), Y(th(t))]; t === t0 ? ctx.moveTo(...p) : ctx.lineTo(...p); } ctx.stroke();
      for (let t = -108; t <= 0; t += 4) dot(ctx, [X(t), Y(th(t))], 2.2, GREEN);
      const tc = -P.l;
      // capture and now
      ctx.setLineDash([4, 4]); ctx.strokeStyle = LAV; line(ctx, [X(tc), top], [X(tc), bot]); ctx.strokeStyle = '#fff'; line(ctx, [X(0), top], [X(0), bot]); ctx.setLineDash([]);
      ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = '#fff'; ctx.textAlign = 'right'; ctx.fillText('result arrives', X(0) + 4, top - 8); ctx.fillStyle = LAV; ctx.fillText('frame captured', X(tc) - 4, top + 8); ctx.textAlign = 'left';
      // the frame's journey
      ctx.strokeStyle = 'rgba(196,181,253,.6)'; ctx.lineWidth = 2; line(ctx, [X(tc), bot - 12], [X(0) - 4, bot - 12]); ctx.lineWidth = 1;
      ctx.fillStyle = LAV; ctx.beginPath(); ctx.moveTo(X(0) - 2, bot - 12); ctx.lineTo(X(0) - 9, bot - 16); ctx.lineTo(X(0) - 9, bot - 8); ctx.fill();
      // the two headings
      const a0 = Math.floor(tc / 4) * 4, a1 = a0 + 4, f = (tc - a0) / 4, interp = th(a0) + (th(a1) - th(a0)) * f;
      dot(ctx, [X(0), Y(th(0))], 6, AMBER); dot(ctx, [X(tc), Y(interp)], 6, GREEN);
      ctx.strokeStyle = AMBER; ctx.setLineDash([2, 3]); line(ctx, [X(tc), Y(th(0))], [X(0), Y(th(0))]); ctx.setLineDash([]);
      ctx.strokeStyle = RED; ctx.lineWidth = 2; line(ctx, [X(tc) - 10, Y(interp)], [X(tc) - 10, Y(th(0))]); ctx.lineWidth = 1;
      ctx.fillStyle = AMBER; ctx.fillText('heading "now"', Math.min(X(0) - 90, w - 100), Y(th(0)) - 10);
      ctx.fillStyle = GREEN; ctx.fillText('heading at capture', Math.max(4, X(tc) - 60), Y(interp) + 20);
      if (X(tc) - 16 > 60) { ctx.fillStyle = RED; ctx.textAlign = 'right'; ctx.fillText('error', X(tc) - 16, (Y(interp) + Y(th(0))) / 2 + 4); ctx.textAlign = 'left'; }
      const err = th(0) - th(tc), look = interp - th(tc);
      $('#l-gy-t-err').textContent = (err / D2R).toFixed(2) + '°';
      $('#l-gy-t-miss').textContent = (P.d * Math.tan(Math.abs(err)) * 100).toFixed(1) + ' cm';
      $('#l-gy-t-ok').textContent = Math.abs(look / D2R) < 0.01 ? '< 0.01°' : (Math.abs(look) / D2R).toFixed(2) + '°';
    };
    st = Site.canvas(cv, 0.62, later(draw));
    Site.range($('#l-gy-t-w'), (v) => { P.w = v; draw(); }, (v) => v.toFixed(1) + ' rad/s');
    Site.range($('#l-gy-t-l'), (v) => { P.l = v; draw(); }, (v) => v + ' ms');
    Site.range($('#l-gy-t-d'), (v) => { P.d = v; draw(); }, (v) => v.toFixed(1) + ' m');
  }
  }

});
