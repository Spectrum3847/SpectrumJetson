Object.assign(Site.glossary, {
  'Huffman coding': 'A way of packing data so common values take fewer bits. The first step of decoding a JPEG unpacks it, one bit at a time.',
});

Site.chapter('speed', (root) => {
  // ponytail: on phones the sticky visual is see-through (background: inherit from a transparent parent), so the
  // progress rail sat over the step text; give it the section's real background.
  { let e = root, bg = ''; while (e && (!(bg = getComputedStyle(e).backgroundColor) || bg === 'rgba(0, 0, 0, 0)')) e = e.parentElement;
    root.querySelectorAll('.scrolly .vis').forEach((v) => (v.style.backgroundColor = bg || '#fff')); }
  const $ = (s) => root.querySelector(s);
  const BG = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', ACC = '#8b5cf6', SOFT = '#c4b5fd', LIME = '#a3e635', RED = '#f43f5e', AMBER = '#f59e0b', CYAN = '#22d3ee';
  const F = (px, w = 600) => `${w} ${px}px "Plus Jakarta Sans", sans-serif`;
  const H = (px) => `800 ${px}px Outfit, sans-serif`;

  /* ── 1. Detective story chart ─────────────────────────── */
  {
    const cv = $('#sp-chart'), st = Site.canvas(cv, 0.74), cpu = $('#sp-cpu');
    const S = [
      ['Start', [33], 44, '1 camera, exposure 29.5 ms'],
      ['Exposure', [61], 20, 'Exposure <b>29.5 → 8.3 ms</b>: the camera can now do 120 fps'],
      ['Gray', [62], 18, 'Java CPU <b>155% → 111%</b> of a core'],
      ['No wait', [100], 18, 'Java CPU <b>113% → 191%</b>: using every frame is more work'],
      ['2 cams', [92, 104], 23, 'PhotonVision: <b>3.3 of 6 cores</b> for 2 cameras'],
      ['Gray decode', [122, 122], 13, 'CPU <b>3.3 → about 1.95 cores</b> (2 cameras)'],
      ['Sleep', [122, 122], 13, 'CPU <b>1.95 → 1.29 cores</b>'],
      ['NVJPG', [122, 122], null, 'CPU <b>0.85 → 0.52 cores</b> (same scene, back to back)'],
      ['Stream', [122, 122], null, 'CPU <b>0.49 → 0.43 cores</b> with no browser open'],
    ];
    let cur = 0, since = 0, now = 0;
    Site.scrolly($('#sp-story'), (i) => { cur = i; since = now; cpu.innerHTML = S[i][3]; });
    cpu.innerHTML = S[0][3];
    Site.loop(cv, (t) => {
      now = t;
      const { ctx, w, h } = st, L = 34, R = w - 34, T = 30, B = h - 44, n = S.length, slot = (R - L) / n;
      const Y = (v) => B - (B - T) * v / 130, YL = (v) => B - (B - T) * v / 50, e = Site.ease(Math.min(1, (t - since) / .7));
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      ctx.font = F(10); ctx.fillStyle = MUTED;
      for (let v = 0; v <= 120; v += 30) { ctx.strokeStyle = 'rgba(196,181,253,.1)'; ctx.beginPath(); ctx.moveTo(L, Y(v)); ctx.lineTo(R, Y(v)); ctx.stroke(); ctx.fillText(v, 6, Y(v) + 3); }
      ctx.fillText('fps', 6, T - 12); ctx.textAlign = 'right'; ctx.fillStyle = AMBER; ctx.fillText('latency', w - 4, T - 12);
      for (let v = 0; v <= 50; v += 10) ctx.fillText(`${v}`, w - 6, YL(v) + 3);
      ctx.textAlign = 'left';
      ctx.setLineDash([5, 4]); ctx.strokeStyle = 'rgba(163,230,53,.6)'; ctx.beginPath(); ctx.moveTo(L, Y(120)); ctx.lineTo(R, Y(120)); ctx.stroke(); ctx.setLineDash([]);
      ctx.fillStyle = LIME; ctx.fillText('camera maximum, 120', L + 4, Y(120) - 5);
      if (cur === 1 || cur === 0) { ctx.setLineDash([3, 3]); ctx.strokeStyle = 'rgba(244,63,94,.7)'; ctx.beginPath(); ctx.moveTo(L, Y(34)); ctx.lineTo(R, Y(34)); ctx.stroke(); ctx.setLineDash([]); ctx.fillStyle = RED; ctx.textAlign = 'right'; ctx.fillText('exposure 29.5 ms caps it at 34', R - 4, Y(34) - 5); ctx.textAlign = 'left'; }
      S.forEach(([lab, fps], i) => {
        const x = L + i * slot, vis = i <= cur, bw = (slot * .62) / fps.length;
        fps.forEach((v, j) => {
          const bx = x + slot * .19 + j * bw, hh = (B - Y(v)) * (i === cur ? e : 1);
          ctx.fillStyle = vis ? (i === cur ? ACC : 'rgba(139,92,246,.55)') : 'rgba(255,255,255,.05)';
          ctx.fillRect(bx + 1, B - (vis ? hh : B - Y(v)), bw - 2, vis ? hh : B - Y(v));
          if (vis && i === cur) { ctx.fillStyle = '#fff'; ctx.font = H(Math.min(15, slot * .3)); ctx.textAlign = 'center'; ctx.fillText(v, bx + bw / 2, B - hh - 6); ctx.textAlign = 'left'; }
        });
        ctx.save(); ctx.translate(x + slot / 2, B + 10); ctx.rotate(-0.5); ctx.textAlign = 'right'; ctx.fillStyle = i === cur ? '#fff' : MUTED; ctx.font = F(Math.min(11, slot * .24)); ctx.fillText(lab, 0, 4); ctx.restore();
      });
      // latency line
      ctx.strokeStyle = AMBER; ctx.lineWidth = 2; ctx.beginPath(); let started = false;
      S.forEach(([, , lat], i) => { if (i > cur || lat == null) return; const x = L + i * slot + slot / 2; started ? ctx.lineTo(x, YL(lat)) : ctx.moveTo(x, YL(lat)); started = true; });
      ctx.stroke(); ctx.lineWidth = 1;
      S.forEach(([, , lat], i) => { if (i > cur || lat == null) return; const x = L + i * slot + slot / 2; ctx.fillStyle = AMBER; ctx.beginPath(); ctx.arc(x, YL(lat), i === cur ? 5 : 3.5, 0, 7); ctx.fill(); if (i === cur) { ctx.fillStyle = AMBER; ctx.font = H(12); ctx.fillText(`${lat} ms`, x + 8, YL(lat) - 6); } });
    });
  }

  /* ── 2. USB bus diagram ───────────────────────────────── */
  {
    const b = (x, y, w, h, t, s, fill = '#fff', stroke = '#d4c0ee', tc = '#4c0070') => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/><text x="${x + 10}" y="${y + 20}" font-size="13" font-weight="700" fill="${tc}">${t}</text>${s ? `<text x="${x + 10}" y="${y + 37}" font-size="11" fill="#635a72">${s}</text>` : ''}`;
    let s = b(10, 120, 120, 56, 'USB controller', 'one in the Jetson');
    s += `<rect x="160" y="20" width="350" height="186" rx="14" fill="#faf5ff" stroke="#8b5cf6" stroke-width="2"/><text x="174" y="42" font-size="13" font-weight="700" fill="#6b1199">Bus 1 · USB 2.0 · one budget</text><text x="174" y="58" font-size="11" fill="#635a72">≈ 6,700 bytes per 125 µs, shared by all of these:</text>`;
    s += b(174, 70, 150, 56, 'USB-A hub', '4 ports (1-2.x)') + b(340, 70, 156, 56, 'USB-C port', '1-1 (a hub there)') + b(174, 138, 322, 56, 'M.2 Key E slot', 'the Wi-Fi card\'s Bluetooth (1-3)');
    s += b(160, 224, 350, 56, 'Bus 2 · USB 3 · its own budget', 'a USB 3 camera would stream here', '#ecfeff', '#06b6d4', '#0e7490');
    s += `<path d="M130 148 H 160" stroke="#8b5cf6" stroke-width="2"/><path d="M110 176 V 252 H 160" fill="none" stroke="#06b6d4" stroke-width="2"/>`;
    $('#sp-bus').innerHTML = s;
  }

  /* ── 3. USB bandwidth lab ─────────────────────────────── */
  {
    const TYPES = {
      thrifty: { n: 'Thriftiest Cam', fps: 121, avg: 50000, big: 62000, allocs: [3060, 1984, 1280, 944, 640, 512] },
      gs: { n: 'Global Shutter', fps: 60, avg: 48000, big: 57000, allocs: [3060, 1984, 1280, 944, 640, 512] },
      color: { n: 'Color camera', fps: 30, avg: 36600, big: 36600, allocs: [3072, 2400, 1600, 800, 256, 128] },
    };
    const PORTS = [['USB-A', '1-2.1', 'TopLeft'], ['USB-A', '1-2.3', 'TopRight'], ['USB-A', '1-2.2', 'BottomLeft'], ['USB-A', '1-2.4', 'BottomRight'], ['USB-C hub', '1-1', 'C']];
    const COLS = ['#a78bfa', '#22d3ee', '#f59e0b', '#f472b6', '#a3e635'];
    const FIT = 6720, REFUSE = 7400;
    let state = PORTS.map(() => ({ type: '', alloc: 0, order: 0 })), seq = 0;
    const box = $('#sp-ports');
    box.innerHTML = PORTS.map(([k, p, n], i) => `<div class="port" data-i="${i}" style="--c:${COLS[i]}"><div class="pn"><b>${k}</b>${p}</div>
      <select class="ty" aria-label="Camera on ${k} ${p}"><option value="">(empty)</option>${Object.entries(TYPES).map(([v, t]) => `<option value="${v}">${t.n}</option>`).join('')}</select>
      <select class="al" aria-label="Allocation for ${k} ${p}"></select></div>`).join('');
    const ports = [...box.querySelectorAll('.port')];
    const fillAllocs = (i) => {
      const st = state[i], sel = ports[i].querySelector('.al');
      if (!st.type) { sel.innerHTML = '<option>–</option>'; sel.disabled = true; return; }
      const T = TYPES[st.type];
      sel.disabled = false;
      sel.innerHTML = T.allocs.map((a, j) => `<option value="${a}"${a === st.alloc ? ' selected' : ''}>${a} B${j === 0 ? ' (stock)' : ''}</option>`).join('');
    };
    const evaluate = () => {
      const on = state.map((s, i) => ({ ...s, i })).filter((s) => s.type).sort((a, b) => a.order - b.order);
      let total = 0;
      for (const c of on) {
        if (total + c.alloc <= FIT) { c.status = 'ok'; total += c.alloc; }
        else if (total + c.alloc < REFUSE) { c.status = 'untested'; total += c.alloc; }
        else c.status = 'refused';
        const T = TYPES[c.type], cap = c.alloc * 8000; // bytes per second
        const want = T.avg * T.fps;
        c.squeezed = want > 0.9 * cap;
        c.frame = c.squeezed ? Math.min(T.avg, 0.97 * cap / T.fps) : T.avg;
        c.use = c.frame * T.fps / cap;
        c.cap = cap; c.T = T;
        c.fits = cap / T.fps / (c.squeezed ? c.frame : T.big);
        c.usbms = 1000 * c.frame / cap;
      }
      return { on, total };
    };
    let model = evaluate();
    const table = $('#sp-usbtable'), kern = $('#sp-kernel');
    const render = () => {
      model = evaluate();
      const rows = model.on.slice().sort((a, b) => a.i - b.i);
      table.innerHTML = '<tr><th>Port</th><th>Camera</th><th>Allocation</th><th>Using</th><th>Largest frame</th><th>Frame on USB</th><th>Status</th></tr>' + (rows.length ? rows.map((c) => {
        const p = PORTS[c.i];
        if (c.status === 'refused') return `<tr><td>${p[1]}</td><td>${c.T.n}</td><td>${c.alloc} B</td><td colspan="3"><small>didn't get to start</small></td><td class="no">refused</td></tr>`;
        return `<tr><td>${p[1]}</td><td>${c.T.n}<small>${c.T.fps} fps</small></td><td>${c.alloc} B<small>${(c.cap / 1e6).toFixed(1)} MB/s</small></td>
          <td>${(c.frame * c.T.fps / 1e6).toFixed(1)} MB/s<small>${Math.round(c.use * 100)}% of it</small></td>
          <td>fits ${c.fits.toFixed(1)}×<small>${c.squeezed ? `frames shrink to ${(c.frame / 1000).toFixed(0)} KB` : `${(c.T.big / 1000).toFixed(0)} KB${c.type === 'color' ? ' (avg)' : ''}`}</small></td>
          <td>${c.usbms.toFixed(1)} ms<small>avg frame</small></td>
          <td class="${c.squeezed ? 'sq' : c.status === 'untested' ? 'sq' : 'ok'}">${c.squeezed ? 'squeezed' : c.status === 'untested' ? 'untested' : 'ok'}${c.status === 'untested' ? '<small>6,720–7,400: not tested</small>' : ''}</td></tr>`;
      }).join('') : '<tr><td colspan="7"><small>Pick a camera for a port.</small></td></tr>');
      const bad = model.on.filter((c) => c.status === 'refused');
      kern.innerHTML = bad.length ? bad.map((c) => `kernel: ${PORTS[c.i][1]}: Not enough bandwidth for new device state → ${TYPES[c.type].n} fails to start (No space left on device)`).join('<br>') : '';
    };
    const set = (i, type, alloc) => {
      const s = state[i];
      s.type = type; s.alloc = type ? alloc ?? TYPES[type].allocs[0] : 0; s.order = ++seq;
      ports[i].querySelector('.ty').value = type; fillAllocs(i);
    };
    ports.forEach((p, i) => {
      p.querySelector('.ty').addEventListener('change', (e) => { set(i, e.target.value); render(); });
      p.querySelector('.al').addEventListener('change', (e) => { state[i].alloc = +e.target.value; state[i].order = ++seq; render(); });
    });
    const PRE = {
      stock2: [[0, 'thrifty', 3060], [1, 'thrifty', 3060]],
      stock3: [[0, 'thrifty', 3060], [1, 'thrifty', 3060], [2, 'thrifty', 3060]],
      usbc: [[4, 'color', 3072], [0, 'thrifty', 3060], [1, 'thrifty', 3060]],
      ours: [[0, 'thrifty', 1280], [1, 'thrifty', 1280], [2, 'thrifty', 1280], [3, 'thrifty', 1280], [4, 'thrifty', 1280]],
      greedy: [[0, 'thrifty', 1280], [1, 'thrifty', 1280], [2, 'thrifty', 1280], [3, 'thrifty', 1280], [4, 'color', 2400]],
    };
    const preset = (k) => { state.forEach((_, i) => set(i, '')); PRE[k].forEach(([i, ty, a]) => set(i, ty, a)); render(); };
    $('#sp-presets').addEventListener('click', (e) => { const b = e.target.closest('button'); if (!b) return; $('#sp-presets').querySelectorAll('button').forEach((x) => x.classList.toggle('primary', x === b)); preset(b.dataset.p); });
    preset('ours');

    const cv = $('#sp-usb'), st = Site.canvas(cv, 0.62);
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st, sc = (w - 8) / 8000;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      // budget bar
      const by = 30, bh = 34;
      ctx.font = F(11); ctx.fillStyle = MUTED; ctx.fillText(`reserved: ${model.total.toLocaleString()} bytes per microframe`, 4, 16);
      ctx.fillStyle = 'rgba(255,255,255,.06)'; ctx.fillRect(4, by, w - 8, bh);
      ctx.fillStyle = 'rgba(245,158,11,.14)'; ctx.fillRect(4 + FIT * sc, by, (REFUSE - FIT) * sc, bh);
      ctx.fillStyle = 'rgba(244,63,94,.14)'; ctx.fillRect(4 + REFUSE * sc, by, (8000 - REFUSE) * sc, bh);
      let x = 4;
      for (const c of model.on) {
        if (c.status === 'refused') continue;
        const ww = c.alloc * sc, col = COLS[c.i];
        ctx.strokeStyle = col; ctx.lineWidth = 1.5; ctx.strokeRect(x + 1, by + 1, ww - 2, bh - 2);
        ctx.fillStyle = col; ctx.globalAlpha = .9; ctx.fillRect(x + 1, by + 1, (ww - 2) * Math.min(1, c.use), bh - 2); ctx.globalAlpha = 1;
        x += ww;
      }
      ctx.lineWidth = 1;
      ctx.fillStyle = '#fff'; ctx.fillRect(4 + FIT * sc, by - 4, 2, bh + 8);
      ctx.fillStyle = RED; ctx.fillRect(4 + REFUSE * sc, by - 4, 2, bh + 8);
      ctx.font = F(10); ctx.fillStyle = '#fff'; ctx.textAlign = 'right'; ctx.fillText('6,720 fit', 4 + FIT * sc - 3, by + bh + 14);
      ctx.fillStyle = RED; ctx.fillText('7,400 refused', Math.min(w - 4, 4 + REFUSE * sc + 30), by + bh + 26); ctx.textAlign = 'left';
      ctx.fillStyle = MUTED; ctx.fillText('outline = reserved, fill = really sent', 4, by + bh + 14);
      // microframes scrolling
      const my = by + bh + 44, mh = h - my - 30, cw = Math.max(26, w / 11), speed = cw * 1.2;
      const off = (t * speed) % cw;
      ctx.save(); ctx.beginPath(); ctx.rect(4, my, w - 8, mh); ctx.clip();
      for (let k = -1; k < w / cw + 1; k++) {
        const cx = 4 + k * cw - off, idx = Math.floor((t * speed) / cw) + k;
        ctx.fillStyle = 'rgba(255,255,255,.04)'; ctx.fillRect(cx + 2, my, cw - 4, mh);
        let yy = my + mh;
        for (const c of model.on) {
          if (c.status === 'refused') continue;
          const hh = mh * c.alloc / 8000, col = COLS[c.i];
          const busy = ((idx * 37 + c.i * 11) % 100) / 100 < c.use; // this microframe carries data?
          ctx.strokeStyle = col; ctx.strokeRect(cx + 3, yy - hh + 1, cw - 6, hh - 2);
          if (busy) { ctx.fillStyle = col; ctx.globalAlpha = .8; ctx.fillRect(cx + 3, yy - hh + 1, cw - 6, hh - 2); ctx.globalAlpha = 1; }
          yy -= hh;
        }
        ctx.strokeStyle = 'rgba(255,255,255,.35)'; ctx.setLineDash([2, 3]); ctx.beginPath(); ctx.moveTo(cx + 2, my + mh * (1 - FIT / 8000)); ctx.lineTo(cx + cw - 2, my + mh * (1 - FIT / 8000)); ctx.stroke(); ctx.setLineDash([]);
      }
      ctx.restore();
      ctx.fillStyle = MUTED; ctx.font = F(10.5);
      const th = model.on.find((c) => c.status !== 'refused' && c.type === 'thrifty');
      ctx.fillText(th ? `each column: one 125 µs microframe. A ${(th.frame / 1000).toFixed(0)} KB frame at ${th.alloc} B needs ${Math.ceil(th.frame / th.alloc)} of them: ${th.usbms.toFixed(1)} ms` : 'each column: one 125 µs microframe, 8,000 a second (slowed down)', 4, h - 10);
    });
  }

  /* ── 4. JPEG decode steps ─────────────────────────────── */
  {
    const icon = {
      huff: '<text x="4" y="18" font-size="11" font-family="JetBrains Mono, monospace" fill="#8b5cf6">0110100111…</text><text x="4" y="38" font-size="11" font-family="JetBrains Mono, monospace" fill="#4c0070">→ 12 −3 0 1…</text>',
      deq: '<text x="4" y="18" font-size="11" font-family="JetBrains Mono, monospace" fill="#4c0070">12 −3 0 1</text><text x="4" y="38" font-size="11" font-family="JetBrains Mono, monospace" fill="#8b5cf6">× 16 11 10 16</text>',
      idct: () => { let s = ''; for (let i = 0; i < 64; i++) { const x = i % 8, y = i >> 3, v = x + y < 7 ? 30 : 225; s += `<rect x="${60 + x * 5}" y="${4 + y * 5}" width="5" height="5" fill="rgb(${v},${v},${v})"/>`; } return `<text x="4" y="26" font-size="16" fill="#8b5cf6">∿∿ →</text>${s}`; },
      up: '<g fill="#fbbf24"><rect x="4" y="8" width="14" height="14"/><rect x="20" y="8" width="14" height="14" fill="#60a5fa"/></g><text x="40" y="22" font-size="14" fill="#8b5cf6">→</text><g><rect x="58" y="4" width="8" height="8" fill="#fbbf24"/><rect x="67" y="4" width="8" height="8" fill="#fbbf24"/><rect x="58" y="13" width="8" height="8" fill="#fbbf24"/><rect x="67" y="13" width="8" height="8" fill="#fbbf24"/><rect x="78" y="4" width="8" height="8" fill="#60a5fa"/><rect x="87" y="4" width="8" height="8" fill="#60a5fa"/><rect x="78" y="13" width="8" height="8" fill="#60a5fa"/><rect x="87" y="13" width="8" height="8" fill="#60a5fa"/></g>',
      bgr: '<text x="4" y="20" font-size="12" font-family="JetBrains Mono, monospace" fill="#4c0070">Y Cb Cr</text><text x="4" y="40" font-size="12" font-family="JetBrains Mono, monospace" fill="#8b5cf6">→ B G R</text>',
      gray: '<rect x="4" y="6" width="12" height="30" fill="#3b82f6"/><rect x="18" y="6" width="12" height="30" fill="#22c55e"/><rect x="32" y="6" width="12" height="30" fill="#ef4444"/><text x="50" y="26" font-size="14" fill="#8b5cf6">→</text><rect x="68" y="6" width="26" height="30" fill="#888"/>',
    };
    const steps = [
      ['1 · Unpack bits', 'Huffman decoding turns the packed bits back into numbers, one bit at a time. Hard to split up.', icon.huff, 'both', 'both paths'],
      ['2 · Dequantize', 'Multiply each number back up by the quality table it was divided by.', icon.deq, 'both', 'both paths'],
      ['3 · IDCT', 'Turn each 8×8 block of frequencies back into pixels (the lab below).', icon.idct(), 'both', 'brightness: both'],
      ['4 · Upsample color', 'Color is stored at lower resolution; stretch it back to full size.', icon.up, 'skip', 'skipped by gray'],
      ['5 · To BGR', 'Math per pixel to turn brightness + color into blue, green, red.', icon.bgr, 'skip', 'skipped by gray'],
      ['6 · Back to gray', 'Average the three channels into one again. Pure waste for a gray camera.', icon.gray, 'skip', 'cscore only'],
    ];
    $('#sp-jflow').innerHTML = steps.map(([t, d, ic, c, tag]) => `<div class="st reveal"><svg viewBox="0 0 110 46">${ic}</svg><b>${t}</b>${d}<br><span class="tag ${c}">${tag}</span></div>`).join('');
    Site.watchReveals($('#sp-jflow'));
  }

  /* ── 5. IDCT lab ──────────────────────────────────────── */
  {
    const cv = $('#sp-idct'), st = Site.canvas(cv, 0.46);
    // 8x8 block from a tag corner: black corner with a slanted edge, as a camera would see it
    const blk = [];
    for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) { const d = (x - 2.5) * 0.9 + (y - 3.2) * 0.45; blk.push(Site.clamp(128 + 110 * Math.tanh(d * 1.6) * (y > 5.2 ? -1 : 1) * (y > 5.2 ? -1 : 1), 20, 235)); }
    const C = (u) => (u === 0 ? Math.SQRT1_2 : 1);
    const coef = [];
    for (let v = 0; v < 8; v++) for (let u = 0; u < 8; u++) { let s = 0; for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) s += (blk[y * 8 + x] - 128) * Math.cos((2 * x + 1) * u * Math.PI / 16) * Math.cos((2 * y + 1) * v * Math.PI / 16); coef.push(s * C(u) * C(v) / 4); }
    const zig = []; for (let s = 0; s < 15; s++) for (let i = 0; i < 8; i++) { const j = s - i; if (j < 0 || j > 7) continue; zig.push(s % 2 ? [i, j] : [j, i]); } // [row(v), col(u)]
    let n = 6;
    const draw = () => {
      const keep = new Set(zig.slice(0, n).map(([v, u]) => v * 8 + u)), rec = [];
      for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) { let s = 0; for (const k of keep) { const v = k >> 3, u = k & 7; s += C(u) * C(v) * coef[k] * Math.cos((2 * x + 1) * u * Math.PI / 16) * Math.cos((2 * y + 1) * v * Math.PI / 16); } rec.push(Site.clamp(s / 4 + 128, 0, 255)); }
      const { ctx, w, h } = st, cs = Math.min((w - 40) / 3, h - 30), c = cs / 8;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const grid = (ox, arr, lab) => { for (let i = 0; i < 64; i++) { const v = Math.round(arr[i]); ctx.fillStyle = `rgb(${v},${v},${v})`; ctx.fillRect(ox + (i % 8) * c, 22 + (i >> 3) * c, c + .5, c + .5); } ctx.fillStyle = MUTED; ctx.font = F(11); ctx.fillText(lab, ox, 14); };
      grid(8, blk, 'original block');
      grid(8 + cs + 12, rec, `rebuilt from ${n}`);
      const ox = 8 + 2 * (cs + 12);
      ctx.fillStyle = MUTED; ctx.fillText('frequencies used', ox, 14);
      const mx = Math.max(...coef.map(Math.abs));
      for (let k = 0; k < 64; k++) { const v = k >> 3, u = k & 7, a = Math.abs(coef[k]) / mx; ctx.fillStyle = keep.has(k) ? `rgba(139,92,246,${.25 + .75 * Math.sqrt(a)})` : `rgba(255,255,255,${.04 + .1 * Math.sqrt(a)})`; ctx.fillRect(ox + u * c + 1, 22 + v * c + 1, c - 2, c - 2); }
    };
    Site.range($('#sp-idct-n'), (v) => { n = v; draw(); });
    new ResizeObserver(draw).observe(cv.parentElement);
  }

  /* ── 6. Decode race ───────────────────────────────────── */
  {
    const cv = $('#sp-race'), st = Site.canvas(cv, root.clientWidth < 640 ? 0.8 : 0.3);
    const lanes = [
      ['cscore: JPEG → color → gray', [['unpack bits', 2.0, '#8b5cf6'], ['IDCT', 3.2, '#a78bfa'], ['color → BGR', 2.3, '#f472b6'], ['BGR → gray', 1.4, '#f43f5e']], 8.9, null],
      ['ours: libjpeg-turbo, gray only', [['unpack bits', 1.4, '#8b5cf6'], ['IDCT', 1.2, '#a78bfa']], 2.6, null],
      ['ours: NVJPG hardware engine', [['hardware decode', 2.3, '#22d3ee'], ['copy', 0.3, '#06b6d4']], 2.6, [[0, 0.35], [2.3, 2.9]]],
    ];
    const meters = [['cscore color', 8.9, '#f43f5e'], ['libjpeg-turbo gray', 2.6, '#a78bfa'], ['NVJPG (CPU part)', 0.95, '#22d3ee']];
    $('#sp-meters').innerHTML = meters.map(([n, ms, c]) => { const cores = ms * 122 / 1000; return `<div class="meter"><small>${n}</small><b>${cores.toFixed(2)} cores</b><i style="--v:${Math.min(100, cores * 100)}%;--c:${c}"></i></div>`; }).join('');
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st, L = w < 500 ? 8 : 210, R = w - 60, sc = (R - L) / 9.5, cyc = 5.5, tm = Math.min(9.5, ((t % cyc) / 3.6) * 9.5);
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const lh = (h - 40) / 3;
      lanes.forEach(([name, segs, tot, cpu], i) => {
        const y = 12 + i * lh, narrow = w < 500, by = narrow ? y + 18 : y + 8, bh = narrow ? lh - 34 : lh - 26;
        ctx.fillStyle = INK; ctx.font = F(12, 700); ctx.fillText(name, narrow ? L : 8, narrow ? y + 10 : y + bh / 2 + 12);
        ctx.fillStyle = 'rgba(255,255,255,.05)'; ctx.fillRect(L, by, R - L, bh);
        let x = 0;
        for (const [lab, d, col] of segs) {
          const vis = Math.max(0, Math.min(d, tm - x));
          ctx.fillStyle = col; ctx.fillRect(L + x * sc, by + (cpu ? bh * .35 : 0), vis * sc - (vis === d ? 1.5 : 0), cpu ? bh * .65 : bh);
          if (vis === d && d * sc > 60) { ctx.fillStyle = '#0e0518'; ctx.font = F(10.5, 700); ctx.fillText(lab, L + x * sc + 5, by + (cpu ? bh * .35 : 0) + (cpu ? bh * .65 : bh) / 2 + 4); }
          x += d;
        }
        if (cpu) for (const [a, b] of cpu) { const vis = Math.max(0, Math.min(b, tm) - a); ctx.fillStyle = AMBER; ctx.fillRect(L + a * sc, by, vis * sc, bh * .28); }
        if (cpu && tm > 3) { ctx.fillStyle = AMBER; ctx.font = F(10); ctx.fillText('CPU', L + 3.0 * sc + 4, by + bh * .25); }
        if (tm >= tot) { ctx.fillStyle = '#fff'; ctx.font = H(15); ctx.fillText(`${tot} ms`, L + tot * sc + 8, by + bh / 2 + 5); }
      });
      ctx.fillStyle = MUTED; ctx.font = F(10);
      for (let v = 0; v <= 9; v += 1) { ctx.fillText(`${v}`, L + v * sc - 3, h - 8); }
      ctx.fillText('ms', R + 8, h - 8);
      ctx.fillStyle = '#fff'; ctx.fillRect(L + tm * sc, 8, 1.5, h - 30);
    });
  }

  /* ── 7. Frozen frames ─────────────────────────────────── */
  {
    const cv = $('#sp-frozen'), st = Site.canvas(cv, root.clientWidth < 640 ? 0.62 : 0.5);
    let cmpAt = -1, now = 0;
    $('#sp-compare').onclick = () => { cmpAt = now; $('#sp-compare').textContent = '↺ Compare again'; };
    const frame = (ctx, x, y, s, k) => {
      ctx.fillStyle = '#777'; ctx.fillRect(x, y, s, s * .7);
      const ts = s * .32, tx = x + s * .1 + k * s * .09, ty = y + s * .18 + Math.sin(k) * s * .04;
      ctx.imageSmoothingEnabled = false; ctx.drawImage(Site.tagCanvas(3, 100), tx, ty, ts, ts);
    };
    Site.loop(cv, (t) => {
      now = t;
      const { ctx, w, h } = st, n = 5, gap = 6, s = (w - gap * (n - 1)) / n, rowH = s * .7;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const y1 = 18, y2 = y1 + rowH + 34;
      ctx.font = F(11); ctx.fillStyle = LIME; ctx.fillText('CPU decoder: frames 0–4', 0, 12);
      ctx.fillStyle = AMBER; ctx.fillText('hardware, the usual call: frames 0–4', 0, y2 - 6);
      const e = cmpAt < 0 ? -1 : t - cmpAt;
      for (let i = 0; i < n; i++) {
        const x = i * (s + gap);
        frame(ctx, x, y1, s, i); frame(ctx, x, y2, s, 0);
        ctx.fillStyle = LIME; ctx.font = F(10, 700); ctx.fillText('✓ success', x + 3, y2 + rowH + 13);
        if (e > i * 0.35) {
          const same = i === 0;
          ctx.strokeStyle = same ? LIME : RED; ctx.lineWidth = 3; ctx.strokeRect(x + 1.5, y2 + 1.5, s - 3, rowH - 3); ctx.lineWidth = 1;
          ctx.fillStyle = same ? LIME : RED; ctx.font = F(11, 700); ctx.fillText(same ? '= same' : '✗ differs', x + 3, y2 + rowH + 28);
        }
      }
      if (e < 0) { ctx.fillStyle = MUTED; ctx.font = F(11); ctx.fillText('both report success on every frame…', 0, h - 4); }
      else if (e > 2) { ctx.fillStyle = '#fff'; ctx.font = F(11, 700); ctx.fillText('the hardware kept returning frame 0', 0, h - 4); }
    });
  }

  /* ── 8. Leak chart ────────────────────────────────────── */
  {
    const cv = $('#sp-leak'), st = Site.canvas(cv, 0.62);
    let mode = 'before', since = 0, now = 0;
    Site.seg($('#sp-leak-seg'), (v) => { mode = v; since = now; });
    // before: 1.1 GB + 61 MB/s until 5.6 GB, killed, restart ~8 s later; twice
    const before = []; let tt = 0, m = 1.1, kills = [];
    while (tt < 200) { before.push([tt, m]); tt += 1; m += 0.061; if (m >= 5.6) { before.push([tt, 5.6]); kills.push(tt); tt += 8; m = 1.1; if (kills.length === 2) break; } }
    Site.loop(cv, (t) => {
      now = t;
      const { ctx, w, h } = st, L = 36, R = w - 10, T = 14, B = h - 26, X = (s) => L + (R - L) * s / 480, Y = (g) => B - (B - T) * g / 6.2;
      const e = Math.min(1, (t - since) / 2.5);
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      ctx.font = F(10); ctx.fillStyle = MUTED;
      for (let g = 0; g <= 6; g += 2) { ctx.strokeStyle = 'rgba(196,181,253,.1)'; ctx.beginPath(); ctx.moveTo(L, Y(g)); ctx.lineTo(R, Y(g)); ctx.stroke(); ctx.fillText(`${g} GB`, 2, Y(g) + 3); }
      for (let mnt = 0; mnt <= 8; mnt += 2) { ctx.textAlign = mnt === 8 ? 'right' : mnt ? 'center' : 'left'; ctx.fillText(`${mnt} min`, X(mnt * 60), h - 8); } ctx.textAlign = 'left';
      ctx.strokeStyle = 'rgba(244,63,94,.5)'; ctx.setLineDash([4, 4]); ctx.beginPath(); ctx.moveTo(L, Y(5.6)); ctx.lineTo(R, Y(5.6)); ctx.stroke(); ctx.setLineDash([]);
      ctx.fillStyle = RED; ctx.fillText('5.6 GB: Linux kills it', R - 110, Y(5.6) - 5);
      if (mode === 'before') {
        const upto = before[before.length - 1][0] * e;
        ctx.strokeStyle = RED; ctx.lineWidth = 2.5; ctx.beginPath();
        let prev = null;
        for (const [s, g] of before) { if (s > upto) break; if (prev && s - prev > 2) ctx.moveTo(X(s), Y(g)); else prev ? ctx.lineTo(X(s), Y(g)) : ctx.moveTo(X(s), Y(g)); prev = s; }
        ctx.stroke(); ctx.lineWidth = 1;
        for (const k of kills) if (k <= upto) { ctx.fillStyle = RED; ctx.font = H(16); ctx.fillText('✗', X(k) - 5, Y(5.6) - 10); }
      } else {
        ctx.strokeStyle = LIME; ctx.lineWidth = 2.5; ctx.beginPath(); ctx.moveTo(X(0), Y(1.078)); ctx.lineTo(X(480 * e), Y(1.078 + 0.014 * e)); ctx.stroke(); ctx.lineWidth = 1;
        ctx.fillStyle = LIME; ctx.font = F(11, 700); ctx.fillText('1.08 → 1.09 GB over 8 minutes, ~116,000 frames', L + 8, Y(1.078) - 10);
      }
    });
  }

  /* ── 9. Scheduler: spin vs sleep ──────────────────────── */
  {
    const cv = $('#sp-sched'), st = Site.canvas(cv, root.clientWidth < 640 ? 0.75 : 0.34);
    const THR = [['camera 1 pipeline', ACC], ['camera 2 pipeline', CYAN], ['OpenCV helper', AMBER], ['other threads', '#8f80ad']];
    let spin = true, segs = [], genT = 0, T = 240, coreFree = [0, 0, 0, 0, 0, 0], lastUi = -9;
    let seed = 3; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    const reset = () => { segs = []; genT = 0; T = 240; coreFree = [0, 0, 0, 0, 0, 0]; lastUi = -9; };
    Site.seg($('#sp-spin'), (v) => { spin = v === 'spin'; reset(); });
    const place = (start, dur, thr, kind) => { // earliest-free core
      let best = 0; for (let c = 1; c < 6; c++) if (Math.max(coreFree[c], start) < Math.max(coreFree[best], start)) best = c;
      const s = Math.max(coreFree[best], start); coreFree[best] = s + dur; segs.push({ c: best, s, e: s + dur, thr, kind });
    };
    const gen = (upto) => {
      while (genT < upto) {
        for (const cam of [0, 1]) {
          const t0 = genT + cam * 4.1;
          place(t0, 3.6 + rnd() * 0.8, cam, 'work');            // pipeline thread: grab, decode, detect
          for (let k = 0; k < 5; k++) {                          // helper pool: a short job, then spin or sleep
            const s = t0 + 1.2 + rnd() * .2;
            place(s, 0.25, 2, 'work');
            if (spin) place(s + 0.25, 0.65, 2, 'spin');
          }
        }
        if (rnd() < .7) place(genT + rnd() * 8, 0.3, 3, 'work');
        genT += 8.2;
      }
    };
    const out = { busy: $('#sp-s-busy'), work: $('#sp-s-work'), waste: $('#sp-s-waste') };
    Site.loop(cv, (t, dt) => {
      T += dt * 9; gen(T + 20);
      segs = segs.filter((g) => g.e > T - 400);
      const { ctx, w, h } = st, L = 56, R = w - 8, WIN = 34, x = (s) => L + (s - (T - WIN)) * (R - L) / WIN, lh = (h - 30) / 6;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      ctx.font = F(10.5);
      for (let c = 0; c < 6; c++) { ctx.fillStyle = MUTED; ctx.fillText(`core ${c}`, 4, 8 + c * lh + lh / 2 + 4); ctx.fillStyle = 'rgba(255,255,255,.035)'; ctx.fillRect(L, 8 + c * lh + 2, R - L, lh - 4); }
      ctx.save(); ctx.beginPath(); ctx.rect(L, 0, R - L, h); ctx.clip();
      for (const g of segs) {
        if (g.s > T || g.e < T - WIN) continue;
        const y = 8 + g.c * lh + 3, a = x(g.s), b = x(Math.min(g.e, T));
        if (g.kind === 'work') { ctx.fillStyle = THR[g.thr][1]; ctx.fillRect(a, y, Math.max(1, b - a - .5), lh - 6); }
        else {
          ctx.fillStyle = 'rgba(244,63,94,.25)'; ctx.fillRect(a, y, b - a, lh - 6);
          ctx.strokeStyle = 'rgba(244,63,94,.8)'; ctx.beginPath(); for (let k = a - lh; k < b; k += 5) { ctx.moveTo(Math.max(a, k), y + lh - 6 - Math.max(0, a - k)); ctx.lineTo(Math.min(b, k + lh - 6), y + Math.max(0, k + lh - 6 - b)); } ctx.stroke();
        }
      }
      ctx.restore();
      let lx = L;
      ctx.font = F(10.5);
      for (const [n, c] of THR) { ctx.fillStyle = c; ctx.fillRect(lx, h - 14, 10, 10); ctx.fillStyle = MUTED; ctx.fillText(n, lx + 14, h - 5); lx += ctx.measureText(n).width + 30; }
      if (spin) { ctx.fillStyle = 'rgba(244,63,94,.8)'; ctx.fillRect(lx, h - 14, 10, 10); ctx.fillStyle = MUTED; ctx.fillText('spinning', lx + 14, h - 5); }
      if (t - lastUi > .5 && T > 200) {
        lastUi = t;
        const a = T - 200; let work = 0, waste = 0;
        for (const g of segs) { const d = Math.max(0, Math.min(g.e, T) - Math.max(g.s, a)); if (g.kind === 'work') work += d; else waste += d; }
        out.busy.textContent = `${((work + waste) / 200).toFixed(2)} cores`;
        out.work.textContent = `${(work / 200).toFixed(2)} cores`;
        out.waste.textContent = `${(waste / 200).toFixed(2)} cores`;
      }
    });
  }

  /* ── 10. Low Latency Mode ─────────────────────────────── */
  {
    const cv = $('#sp-llm'), st = Site.canvas(cv, root.clientWidth < 640 ? 0.7 : 0.3);
    const TF = 1000 / 120;
    let p = 10;
    const simulate = (mode, dur) => { // returns [{frame, start, end}]
      const out = []; let t = 0, last = -1;
      while (t < dur) {
        let k;
        if (mode === 'on') { k = Math.floor(t / TF + 1e-9) + (out.length ? 1 : 0); if (!out.length) k = 0; }
        else { k = Math.floor(t / TF + 1e-9); if (k <= last) k = last + 1; }
        const start = Math.max(t, k * TF);
        out.push({ k, start, end: start + p }); last = k; t = start + p;
      }
      return out;
    };
    const fpsOf = (mode) => { const r = simulate(mode, 2000); return r.length / 2; };
    const draw = () => {
      const { ctx, w, h } = st, L = w < 500 ? 8 : 150, R = w - 8, DUR = 75, X = (ms) => L + (R - L) * ms / DUR;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      ctx.font = F(10.5);
      const ay = 18;
      for (let k = 0; k * TF < DUR; k++) { ctx.fillStyle = SOFT; ctx.fillRect(X(k * TF) - 1, ay, 2, 12); ctx.fillStyle = MUTED; if (w > 500 || k % 2 === 0) ctx.fillText(k, X(k * TF) - 3, ay - 4); }
      ctx.fillStyle = INK; ctx.font = F(11, 700); ctx.fillText(w < 500 ? '' : 'camera: a frame every 8.3 ms', 8, ay + 10);
      const rows = [['on', 'Low Latency Mode on', 'waits for a new frame'], ['off', 'Off', 'takes the newest frame']];
      rows.forEach(([m, n, sub], i) => {
        const y = 48 + i * ((h - 58) / 2), bh = (h - 58) / 2 - (w < 500 ? 26 : 12), by = w < 500 ? y + 16 : y;
        ctx.fillStyle = m === 'on' ? AMBER : LIME; ctx.font = F(12, 700); ctx.fillText(n, 8, w < 500 ? y + 8 : y + 16); ctx.fillStyle = MUTED; ctx.font = F(10.5); if (w >= 500) ctx.fillText(sub, 8, y + 32);
        const r = simulate(m, DUR), used = new Set(r.map((q) => q.k));
        for (const q of r) { const a = X(q.start), b = X(Math.min(q.end, DUR)); if (a > R) break; ctx.fillStyle = m === 'on' ? 'rgba(245,158,11,.75)' : 'rgba(163,230,53,.75)'; ctx.fillRect(a + 1, by, b - a - 2, bh); ctx.fillStyle = BG; ctx.font = F(10.5, 700); if (b - a > 26) ctx.fillText(`#${q.k}`, a + 5, by + bh / 2 + 4); }
        for (let k = 0; k * TF < DUR - p; k++) if (!used.has(k) && k < Math.max(...used)) { ctx.fillStyle = RED; ctx.font = F(12, 700); ctx.fillText('✗', X(k * TF) - 4, by - 2); }
      });
      $('#sp-llm-on').textContent = `${Math.round(fpsOf('on'))} fps`;
      $('#sp-llm-off').textContent = `${Math.round(fpsOf('off'))} fps`;
    };
    Site.range($('#sp-llm-p'), (v) => { p = v; draw(); }, (v) => `${v} ms`);
    new ResizeObserver(draw).observe(cv.parentElement);
  }
});
