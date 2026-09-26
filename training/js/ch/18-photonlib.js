Object.assign(Site.glossary, {
  'vendordep': 'A vendor dependency: a JSON file in the robot project\'s vendordeps folder that tells the build which extra library, and which version, to download.',
  'P controller': 'Proportional controller: output = gain × error. A bigger error gives a bigger push; the gain (kP) sets how hard it pushes.',
  'Transform3d': 'WPILib\'s type for a 3D move: a translation (x forward, y left, z up, in meters) plus a rotation (roll, pitch, yaw, in radians).',
});

Site.chapter('photonlib', (root) => {
  const $ = (s) => root.querySelector(s);
  const later = (fn) => () => requestAnimationFrame(fn);
  const LAB = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', RED = '#f43f5e', GREEN = '#a3e635', AMBER = '#f59e0b', LAV = '#c4b5fd', YEL = '#fcd34d';
  const line = (ctx, a, b) => { ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke(); };
  const dot = (ctx, p, r, c) => { ctx.fillStyle = c; ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 7); ctx.fill(); };
  const D2R = Math.PI / 180;

  /* ── Java highlighting for the code blocks (plain text in the HTML, so it reads fine without JS) ── */
  {
    const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const KW = 'new|for|if|else|return|var|double|int|boolean|private|public|static|final|void|class|extends|interface|true|false|null|continue|this';
    const re = new RegExp(`(\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)|("(?:[^"\\\\]|\\\\.)*")|\\b(\\d+(?:\\.\\d+)?(?:e\\d+)?)\\b|\\b(${KW})\\b|\\b([A-Z][A-Za-z0-9_]*)\\b|\\b([a-z_][A-Za-z0-9_]*)(?=\\()|@\\w+`, 'g');
    root.querySelectorAll('pre.java').forEach((pre) => {
      const src = pre.textContent;
      let out = '', last = 0, m;
      re.lastIndex = 0;
      while ((m = re.exec(src))) {
        out += esc(src.slice(last, m.index));
        const cls = m[1] ? 'c' : m[2] ? 's' : m[3] ? 'n' : m[4] ? 'k' : m[5] ? (/^[A-Z0-9_]+$/.test(m[5]) && m[5].length > 2 ? 'n' : 't') : m[6] ? 'm' : 'k';
        out += `<span class="${cls}">${esc(m[0])}</span>`;
        last = re.lastIndex;
      }
      pre.innerHTML = out + esc(src.slice(last));
    });
  }

  /* ── The mailbox: results arriving vs 20 ms robot loops ─────────────── */
  {
    const cv = $('#pl-mail'); const st = Site.canvas(cv, 0.6);
    const P = { mode: 'all', fps: 120 };
    const LOOP = 0.02, LOOP0 = 0.003, SLOW = 25, WIN = 0.12;
    // frame k arrives at k/fps plus a little repeatable jitter
    const hash = (k) => { const s = Math.sin(k * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
    const arr = (k) => (k + 0.5 + (hash(k) - 0.5) * 0.35) / P.fps;
    const loopAt = (j) => LOOP0 + j * LOOP;
    const loopOf = (t) => Math.ceil((t - LOOP0) / LOOP - 1e-9); // first loop at or after t
    // Classify each frame: which loop picks it up, and (latest mode) whether it's used, skipped or reused.
    const classify = (k) => {
      const t = arr(k), j = loopOf(t);
      if (P.mode !== 'latest') return { j, s: 'used' };
      const next = arr(k + 1);
      if (next <= loopAt(j)) return { j, s: 'skip' };      // a newer one arrived before the loop ran
      const reused = arr(k + 1) > loopAt(j + 1);            // nothing new by the next loop either
      return { j, s: reused ? 'twice' : 'used' };
    };
    const stats = () => {
      const T = 10, n = Math.floor(T * P.fps);
      let used = 0, skip = 0;
      for (let k = 0; k < n; k++) { const c = classify(k); if (c.s === 'skip') skip++; else used++; }
      const loops = T / LOOP;
      return { per: n / loops, used: used / T, skip: skip / T };
    };
    const show = () => {
      const s = stats();
      $('#pl-m-per').textContent = P.mode === 'latest' ? '1 (newest)' : s.per.toFixed(1);
      $('#pl-m-used').textContent = P.mode === 'twice' ? `${Math.round(s.used)}, then 0` : String(Math.round(s.used));
      const sk = $('#pl-m-skip'); sk.textContent = String(Math.round(s.skip)); sk.style.color = s.skip > 0 ? RED : '';
      $('#pl-m-note').textContent = P.mode === 'latest'
        ? (P.fps > 50 ? 'getLatestResult() keeps only the newest result each loop, so the others are never seen.' : 'Below 50 fps some loops find nothing new, and getLatestResult() hands back the same frame again (orange).')
        : P.mode === 'twice' ? 'The first call (say, the pose code) takes the whole pile. The second call (say, the aim code) gets an empty list every loop. Read once, then share the list.'
        : 'Every result is used exactly once. Slowed down about 25 times; frame times have a little realistic jitter.';
    };
    Site.seg($('#pl-m-mode'), (v) => { P.mode = v; show(); });
    Site.range($('#pl-m-fps'), (v) => { P.fps = v; show(); }, (v) => v + ' fps');
    let simT = 0.2;
    Site.loop(cv, (t, dt) => {
      const { ctx, w, h } = st; if (!w) return;
      simT += (Site.reduced ? 0 : dt) / SLOW;
      const now = simT, t0 = now - WIN * 0.8, X = (tt) => ((tt - t0) / WIN) * w;
      const yF = h * 0.3, yA = h * 0.62, yB = h * 0.8;
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillStyle = MUTED; ctx.textAlign = 'left';
      ctx.fillText('Results arriving from the Jetson', 8, 16);
      ctx.fillText(P.mode === 'twice' ? 'Each loop: first call / second call' : 'What each robot loop gets', 8, yA - 22);
      // robot loops
      const j0 = loopOf(t0) - 1, j1 = loopOf(t0 + WIN) + 1;
      for (let j = j0; j <= j1; j++) {
        const x = X(loopAt(j)), ran = loopAt(j) <= now;
        ctx.strokeStyle = ran ? 'rgba(196,181,253,.55)' : 'rgba(196,181,253,.18)'; ctx.setLineDash([4, 4]); line(ctx, [x, 24], [x, h - 18]); ctx.setLineDash([]);
        if (!ran) continue;
        // the frames this loop received
        let got = [], newest = null;
        for (let k = Math.max(0, Math.floor((loopAt(j) - 0.15) * P.fps)); arr(k) <= loopAt(j) + 1e-9; k++) { if (loopOf(arr(k)) === j) got.push(k); if (arr(k) <= loopAt(j)) newest = k; }
        let label, col;
        if (P.mode === 'latest') { label = got.length ? '1 new' : '1 again'; col = got.length ? GREEN : AMBER; }
        else { label = String(got.length); col = got.length ? GREEN : MUTED; }
        const bw = Math.min(46, (LOOP / WIN) * w - 6);
        ctx.fillStyle = 'rgba(255,255,255,.06)'; ctx.strokeStyle = col; ctx.lineWidth = 1.5;
        ctx.beginPath(); ctx.roundRect ? ctx.roundRect(x - bw / 2, yA - 12, bw, 22, 6) : ctx.rect(x - bw / 2, yA - 12, bw, 22); ctx.fill(); ctx.stroke(); ctx.lineWidth = 1;
        ctx.font = '600 11px JetBrains Mono'; ctx.textAlign = 'center'; ctx.fillStyle = col; ctx.fillText(label, x, yA + 3);
        if (P.mode === 'twice') {
          ctx.fillStyle = 'rgba(255,255,255,.06)'; ctx.strokeStyle = RED; ctx.beginPath(); ctx.roundRect ? ctx.roundRect(x - bw / 2, yB - 12, bw, 22, 6) : ctx.rect(x - bw / 2, yB - 12, bw, 22); ctx.fill(); ctx.stroke();
          ctx.fillStyle = RED; ctx.fillText('0', x, yB + 3);
        }
        // links from the frames to the loop
        const linked = P.mode === 'latest' ? (newest !== null ? [newest] : []) : got;
        ctx.strokeStyle = P.mode === 'latest' && !got.length ? 'rgba(245,158,11,.5)' : 'rgba(163,230,53,.35)';
        linked.forEach((k) => line(ctx, [X(arr(k)), yF + 7], [x, yA - 13]));
        ctx.textAlign = 'left';
      }
      // frames
      const k0 = Math.max(0, Math.floor(t0 * P.fps) - 2), k1 = Math.ceil((t0 + WIN) * P.fps) + 2;
      const r = Math.max(3, Math.min(7, (w / (WIN * P.fps)) * 0.28));
      for (let k = k0; k <= k1; k++) {
        const ta = arr(k), x = X(ta); if (x < -10 || x > w + 10) continue;
        if (ta > now) { ctx.strokeStyle = 'rgba(196,181,253,.35)'; ctx.beginPath(); ctx.arc(x, yF, r, 0, 7); ctx.stroke(); continue; }
        const c = classify(k);
        const col = loopAt(c.j) > now ? LAV : c.s === 'skip' ? RED : c.s === 'twice' && loopAt(c.j + 1) <= now ? AMBER : GREEN;
        dot(ctx, [x, yF], r, col);
      }
      // now line
      const xn = X(now); ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; line(ctx, [xn, 22], [xn, h - 18]); ctx.lineWidth = 1;
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.textAlign = 'center';
      ctx.fillText('now', xn, h - 6); ctx.textAlign = 'left';
      ctx.fillText('dashed = robot loop, every 20 ms', 8, h - 6);
    });
  }

  /* ── Turn to face the tag: a P controller with delay ────────────────── */
  {
    const cv = $('#pl-aim'); let st = null;
    const P = { kp: 0.006, d: 3, cam: 'c' };
    const MAX = 360, TAU = 0.1, LAT = 0.035, HALF_FOV = 40.5, OFF_L = 0.25, LATX = 0.6;
    let S = null, side = 1;
    const norm = (a) => { while (a > 180) a -= 360; while (a < -180) a += 360; return a; };
    const robotPos = () => [LATX, -P.d];
    const faceTag = () => { const R = robotPos(); return Math.atan2(-R[1], -R[0]) / D2R; };
    const camPos = (phi) => { const R = robotPos(), L = P.cam === 'c' ? 0 : OFF_L, a = phi * D2R; return [R[0] - Math.sin(a) * L, R[1] + Math.cos(a) * L]; };
    // PhotonVision yaw: degrees, positive = tag to the right of the camera's centre
    const yawOf = (phi) => { const C = camPos(phi); return -norm(Math.atan2(-C[1], -C[0]) / D2R - phi); };
    const setpoint = (phi) => {
      if (P.cam !== 'f') return 0;
      const C = camPos(phi), r = Math.hypot(C[0], C[1]); // range, as if from pitch
      return Math.asin(Math.min(1, OFF_L / r)) / D2R;
    };
    const restart = () => {
      side = -side;
      S = { t: 0, phi: faceTag() + side * 28, w: 0, cmd: 0, next: 0, hist: [], trace: [], settled: null, inside: 0, os: 0, sp: 0, seen: true, doneAt: null };
      S.sp = setpoint(S.phi);
      S.startSign = Math.sign(yawOf(S.phi) - S.sp);
    };
    const step = (dt) => {
      S.t += dt;
      const yaw = yawOf(S.phi);
      S.hist.push([S.t, yaw]); if (S.hist.length > 400) S.hist.shift();
      if (S.t >= S.next) {
        S.next += 0.02;
        let m = null; for (let i = S.hist.length - 1; i >= 0; i--) if (S.hist[i][0] <= S.t - LAT) { m = S.hist[i][1]; break; }
        if (m === null) m = S.hist[0][1];
        S.seen = Math.abs(m) < HALF_FOV;
        if (S.seen) { S.sp = setpoint(S.phi); S.cmd = Math.max(-MAX, Math.min(MAX, P.kp * (S.sp - m) * MAX)); } else S.cmd = 0;
      }
      S.w += ((S.cmd - S.w) / TAU) * dt; S.phi += S.w * dt;
      const err = yaw - S.sp;
      if (Math.sign(err) === -S.startSign) S.os = Math.max(S.os, Math.abs(err));
      if (Math.abs(err) < 1) { S.inside += dt; if (S.inside > 0.3 && S.settled === null) S.settled = S.t - 0.3; } else S.inside = 0;
    };
    const draw = () => {
      if (!st || !st.w || !S) return;
      const { ctx, w, h } = st, fh = h * 0.66, gh = h - fh;
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      // field view: wall at y = 0 near the top
      const k = Math.min(w / 3.2, (fh - 34) / (P.d + 0.9)), ox = w / 2, oy = 26;
      const T = (x, y) => [ox + x * k, oy - y * k];
      ctx.fillStyle = 'rgba(196,181,253,.3)'; ctx.fillRect(0, oy - 12, w, 8);
      const ts = Math.max(14, 0.165 * k);
      Site.drawTag(ctx, 10, T(0, 0)[0] - ts / 2, oy - 12 - ts / 2 + 4, ts, { quiet: true });
      ctx.strokeStyle = 'rgba(196,181,253,.07)'; for (let m = 1; m <= Math.ceil(P.d + 1); m++) line(ctx, T(-3, -m), T(3, -m));
      const R = robotPos(), C = camPos(S.phi), a = S.phi * D2R, far = (P.d + 1) * 1.6;
      // camera view wedge
      const a1 = a + HALF_FOV * D2R, a2 = a - HALF_FOV * D2R;
      ctx.fillStyle = 'rgba(196,181,253,.10)'; ctx.beginPath(); ctx.moveTo(...T(C[0], C[1]));
      ctx.lineTo(...T(C[0] + Math.cos(a1) * far, C[1] + Math.sin(a1) * far)); ctx.lineTo(...T(C[0] + Math.cos(a2) * far, C[1] + Math.sin(a2) * far)); ctx.closePath(); ctx.fill();
      ctx.strokeStyle = 'rgba(196,181,253,.35)'; line(ctx, T(C[0], C[1]), T(C[0] + Math.cos(a1) * far, C[1] + Math.sin(a1) * far)); line(ctx, T(C[0], C[1]), T(C[0] + Math.cos(a2) * far, C[1] + Math.sin(a2) * far));
      // camera → tag
      if (S.seen) { ctx.strokeStyle = 'rgba(252,211,77,.7)'; ctx.setLineDash([2, 3]); line(ctx, T(C[0], C[1]), T(0, 0)); ctx.setLineDash([]); }
      // where the robot's centre points, out to the wall
      const s = (0 - R[1]) / Math.max(0.05, Math.sin(a)), hit = [R[0] + Math.cos(a) * s, 0];
      ctx.strokeStyle = GREEN; ctx.lineWidth = 2; ctx.setLineDash([6, 4]); line(ctx, T(R[0], R[1]), T(hit[0], hit[1])); ctx.setLineDash([]); ctx.lineWidth = 1;
      // robot
      const rs = 0.8 * k;
      ctx.save(); ctx.translate(...T(R[0], R[1])); ctx.rotate(-a);
      ctx.fillStyle = 'rgba(124,58,237,.85)'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.fillRect(-rs / 2, -rs / 2, rs, rs); ctx.strokeRect(-rs / 2, -rs / 2, rs, rs);
      ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.moveTo(rs / 2 - 2, 0); ctx.lineTo(rs / 2 - 10, -6); ctx.lineTo(rs / 2 - 10, 6); ctx.closePath(); ctx.fill();
      ctx.restore(); ctx.lineWidth = 1;
      dot(ctx, T(C[0], C[1]), 4.5, YEL);
      // miss at the tag: distance from the tag to the centre line
      const miss = Math.abs(Math.cos(a) * (0 - R[1]) - Math.sin(a) * (0 - R[0]));
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.fillText(`${P.d.toFixed(1)} m`, 8, fh - 8);
      if (!S.seen) { ctx.font = '700 13px Outfit'; ctx.fillStyle = RED; ctx.textAlign = 'center'; ctx.fillText('No target: the tag left the view', w / 2, fh - 10); ctx.textAlign = 'left'; }
      // yaw graph (last 4 s)
      const gy0 = fh + 6, gH = gh - 22, mid = gy0 + gH / 2, Y = (v) => mid - (Math.max(-45, Math.min(45, v)) / 45) * (gH / 2), span = 4;
      ctx.fillStyle = 'rgba(255,255,255,.03)'; ctx.fillRect(0, gy0, w, gH);
      ctx.strokeStyle = 'rgba(196,181,253,.25)'; line(ctx, [0, mid], [w, mid]);
      ctx.strokeStyle = 'rgba(244,63,94,.25)'; ctx.setLineDash([2, 4]); line(ctx, [0, Y(HALF_FOV)], [w, Y(HALF_FOV)]); line(ctx, [0, Y(-HALF_FOV)], [w, Y(-HALF_FOV)]); ctx.setLineDash([]);
      if (S.sp) { ctx.strokeStyle = 'rgba(163,230,53,.6)'; ctx.setLineDash([5, 4]); line(ctx, [0, Y(S.sp)], [w, Y(S.sp)]); ctx.setLineDash([]); }
      const tr = S.trace, tEnd = Math.max(span, S.t), X = (tt) => ((tt - (tEnd - span)) / span) * w;
      ctx.strokeStyle = YEL; ctx.lineWidth = 2; ctx.beginPath();
      tr.forEach((p, i) => { const x = X(p[0]), y = Y(p[1]); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }); ctx.stroke(); ctx.lineWidth = 1;
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED;
      ctx.fillText('camera yaw, last 4 s' + (S.sp ? ' · green = setpoint' : ' · setpoint 0°'), 8, h - 4);
      ctx.textAlign = 'right'; ctx.fillText('+45° (right)', w - 6, gy0 + 11); ctx.fillText('−45°', w - 6, gy0 + gH - 3); ctx.textAlign = 'left';
      // readouts
      const yaw = yawOf(S.phi);
      $('#pl-a-yaw').textContent = S.seen ? ((y1) => `${y1 > 0 ? '+' : ''}${y1.toFixed(1)}°`)(Math.round(yaw * 10) / 10 || 0) : 'no target';
      $('#pl-a-set').textContent = S.settled !== null ? `${S.settled.toFixed(2)} s` : S.t > 6 ? 'not yet' : '…';
      const os = $('#pl-a-os'); os.textContent = `${S.os.toFixed(1)}°`; os.style.color = S.os > 5 ? AMBER : '';
      const ms = $('#pl-a-miss'); ms.textContent = `${(miss * 100).toFixed(0)} cm`; ms.style.color = miss > 0.08 ? RED : '';
    };
    st = Site.canvas(cv, 0.9, later(draw));
    Site.loop(cv, (t, dt) => {
      if (!S) restart();
      const d = Site.reduced ? 0.016 : dt;
      for (let i = 0, n = Math.max(1, Math.round(d / 0.001)); i < n; i++) step(d / n);
      S.trace.push([S.t, yawOf(S.phi)]); while (S.trace.length && S.trace[0][0] < S.t - 4.2) S.trace.shift();
      // start over a little after it settles (or gives up)
      if ((S.settled !== null && S.t > S.settled + 2.5) || S.t > 9) restart();
      draw();
    });
    Site.range($('#pl-a-kp'), (v) => { P.kp = v; restart(); }, (v) => v.toFixed(3));
    Site.range($('#pl-a-d'), (v) => { P.d = v; restart(); }, (v) => v.toFixed(1) + ' m');
    Site.seg($('#pl-a-cam'), (v) => { P.cam = v; restart(); });
    $('#pl-a-go').addEventListener('click', restart);
    cv.addEventListener('click', restart);
  }
});
