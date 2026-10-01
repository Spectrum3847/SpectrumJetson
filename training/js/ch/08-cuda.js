Object.assign(Site.glossary, {
  'SIMT': 'Single instruction, multiple threads: the GPU issues one instruction to a group of 32 threads (a warp), and each runs it on its own data.',
});

Site.chapter('cuda', (root) => {
  // ponytail: on phones the sticky visual is see-through (background: inherit from a transparent parent), so the
  // progress rail sat over the step text; give it the section's real background.
  { let e = root, bg = ''; while (e && (!(bg = getComputedStyle(e).backgroundColor) || bg === 'rgba(0, 0, 0, 0)')) e = e.parentElement;
    root.querySelectorAll('.scrolly .vis').forEach((v) => (v.style.backgroundColor = bg || '#fff')); }
  // Click-to-play video: no YouTube iframe loads until the student asks for it.
  root.addEventListener('click', (e) => {
    const b = e.target.closest('.yt-play');
    if (b) b.outerHTML = `<iframe class="video-embed" src="https://www.youtube-nocookie.com/embed/${b.dataset.yt}?autoplay=1" title="${b.getAttribute('aria-label')}" allow="autoplay; encrypted-media" allowfullscreen></iframe>`;
  });
  const $ = (s) => root.querySelector(s);
  const BG = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', ACC = '#8b5cf6', SOFT = '#c4b5fd', LIME = '#a3e635', RED = '#f43f5e', AMBER = '#f59e0b';
  const svgEl = (svg, html) => { svg.innerHTML = html; };

  /* ── 1. The painting race ─────────────────────────────── */
  {
    const cv = $('#c-race'), st = Site.canvas(cv, 0.42);
    const TX = 16, TY = 12, N = TX * TY, CORES = 6, SLOW = 5;
    const tg = Site.tagGrid(3);
    const color = (x, y) => {
      const gx = x - 3, gy = y - 1;
      if (gx >= 0 && gx < 10 && gy >= 0 && gy < 10) return tg[gy][gx] ? '#f4efff' : '#1f1b23';
      const t = (x + y) / (TX + TY);
      return `hsl(${270 - t * 40} ${55 + t * 20}% ${38 + t * 22}%)`;
    };
    let mode = 'par', t0 = 0, now = 0;
    const unit = () => (mode === 'par' ? 3 / Math.ceil(N / CORES) : 3 / N);
    const cpuDone = (k) => (mode === 'par' ? Math.floor(k / CORES) + 1 : k + 1);
    const gpuDone = (k) => (mode === 'par' ? SLOW : (k + 1) * SLOW);
    const cpuTot = cpuDone(N - 1), elC = $('#c-race-cpu'), elG = $('#c-race-gpu');
    const restart = () => { t0 = now; };
    Site.seg($('#c-race-job'), (v) => { mode = v; restart(); });
    $('#c-race-go').onclick = restart;
    Site.loop(cv, (t) => {
      now = t; if (!t0) t0 = t;
      const u = (t - t0) / unit(); // elapsed time units
      const { ctx, w, h } = st;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const gap = 14, pw = (w - gap * 3) / 2, ts = Math.min(pw / TX, (h - 40) / TY);
      const panel = (ox, label, sub, done, dur, total) => {
        const oy = 32;
        ctx.fillStyle = INK; ctx.font = `700 ${Math.max(11, ts * .9)}px Outfit, sans-serif`; ctx.fillText(label, ox, 18);
        ctx.fillStyle = MUTED; ctx.font = `500 ${Math.max(9, ts * .65)}px "Plus Jakarta Sans", sans-serif`; ctx.fillText(sub, ox + ctx.measureText(label).width * 1.35 + 6, 18);
        let finished = 0;
        for (let k = 0; k < N; k++) {
          const x = k % TX, y = Math.floor(k / TX), px = ox + x * ts, py = oy + y * ts;
          const end = done(k), p = Site.clamp((u - (end - dur)) / dur, 0, 1);
          ctx.fillStyle = 'rgba(196,181,253,.07)'; ctx.fillRect(px + .5, py + .5, ts - 1, ts - 1);
          if (p > 0) { ctx.fillStyle = color(x, y); ctx.fillRect(px + .5, py + .5 + (ts - 1) * (1 - p), ts - 1, (ts - 1) * p); }
          if (p > 0 && p < 1) { ctx.fillStyle = AMBER; ctx.beginPath(); ctx.arc(px + ts / 2, py + (ts - 1) * (1 - p), Math.max(1.5, ts * .16), 0, 7); ctx.fill(); }
          if (p >= 1) finished++;
        }
        return finished === N ? total : null;
      };
      const c = panel(gap, 'CPU', '6 painters', cpuDone, 1, cpuTot);
      const g = panel(gap * 2 + pw, 'GPU', 'one painter per tile', gpuDone, SLOW, gpuDone(N - 1));
      elC.textContent = c ? `${c} ticks` : `${Math.floor(Math.min(u, cpuTot))} ticks…`;
      elG.textContent = g ? `${g} ticks` : `${Math.floor(u)} ticks…`;
    });
  }

  /* ── 2. CPU vs GPU chip picture ───────────────────────── */
  {
    let s = '<rect x="6" y="20" width="238" height="290" rx="16" fill="#faf5ff" stroke="#c4b5fd" stroke-width="2"/><text x="20" y="46" font-size="15" font-weight="700" fill="#4c0070">CPU · 6 cores</text>';
    for (let i = 0; i < 6; i++) {
      const x = 22 + (i % 2) * 108, y = 60 + Math.floor(i / 2) * 80;
      s += `<rect x="${x}" y="${y}" width="98" height="70" rx="10" fill="#fff" stroke="#8b5cf6" stroke-width="1.5"/>
        <rect x="${x + 8}" y="${y + 8}" width="36" height="24" rx="4" fill="#ede9fe"/><rect x="${x + 50}" y="${y + 8}" width="40" height="54" rx="4" fill="#f3e8ff"/>
        <rect x="${x + 8}" y="${y + 38}" width="36" height="24" rx="4" fill="#8b5cf6"/>
        <text x="${x + 12}" y="${y + 24}" font-size="8" fill="#6b1199">control</text><text x="${x + 55}" y="${y + 38}" font-size="8" fill="#6b1199">cache</text><text x="${x + 13}" y="${y + 54}" font-size="8" fill="#fff">math</text>`;
    }
    s += '<text x="20" y="300" font-size="11" fill="#635a72">big, clever, fast one-at-a-time</text>';
    s += '<rect x="262" y="20" width="292" height="290" rx="16" fill="#faf5ff" stroke="#c4b5fd" stroke-width="2"/><text x="276" y="46" font-size="15" font-weight="700" fill="#4c0070">GPU · 8 SMs × 128 cores</text>';
    for (let i = 0; i < 8; i++) {
      const x = 276 + (i % 4) * 68, y = 60 + Math.floor(i / 4) * 118;
      s += `<rect x="${x}" y="${y}" width="62" height="110" rx="8" fill="#fff" stroke="#8b5cf6" stroke-width="1.2"/><text x="${x + 5}" y="${y + 12}" font-size="8" font-weight="700" fill="#6b1199">SM ${i}</text>`;
      for (let r = 0; r < 16; r++) for (let q = 0; q < 8; q++) s += `<rect x="${x + 5 + q * 6.6}" y="${y + 18 + r * 5.6}" width="5" height="4.2" rx="1" fill="#8b5cf6" opacity="${.55 + .45 * ((r * 8 + q) % 32 < 32 ? 1 : 0) * (r % 4 === 0 ? 1 : .8)}"/>`;
    }
    s += '<text x="276" y="300" font-size="11" fill="#635a72">many simple cores, same instruction, different data</text>';
    svgEl($('#c-chips'), s);
  }

  /* ── 3. Grid / block / thread lab ─────────────────────── */
  {
    const cv = $('#c-grid'), st = Site.canvas(cv, root.clientWidth < 620 ? 0.95 : 0.66);
    const IW = 45, IH = 28, MAXW = 64, MAXH = 32;
    const tg = Site.tagGrid(3);
    // tiny synthetic frame: lighting gradient + a tag + noise
    let seed = 7; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    const img = [];
    for (let y = 0; y < IH; y++) for (let x = 0; x < IW; x++) {
      const light = 0.62 + 0.38 * (x / IW) - 0.12 * (y / IH);
      let v = 175 * light + 25;
      const gx = Math.floor((x - 13) / 2), gy = Math.floor((y - 4) / 2);
      if (gx >= 0 && gx < 10 && gy >= 0 && gy < 10) v = tg[gy][gx] ? 235 * (0.6 + 0.4 * light) : 28;
      img.push(Site.clamp(v + (rnd() - .5) * 26, 0, 255));
    }
    const CUT = 128;
    let bw = 16, bh = 8, tLaunch = 0, now = 0, hover = null;
    const out = { grid: $('#c-g-grid'), tpb: $('#c-g-tpb'), wpb: $('#c-g-wpb'), idle: $('#c-g-idle'), who: $('#c-g-who'), real: $('#c-g-real') };
    const hue = (i) => (i * 67) % 360;
    const update = () => {
      const gx = Math.ceil(IW / bw), gy = Math.ceil(IH / bh), tpb = bw * bh, total = gx * gy * tpb;
      out.grid.textContent = `${gx} × ${gy} blocks`;
      out.tpb.textContent = `${bw}×${bh} = ${tpb}`;
      out.wpb.textContent = `${Math.ceil(tpb / 32)}${tpb % 32 ? ' (last one part-empty)' : ''}`;
      const idle = total - IW * IH;
      out.idle.textContent = `${idle} of ${total} (${Math.round(100 * idle / total)}%)`;
      const RG = [Math.ceil(1280 / bw), Math.ceil(800 / bh)], blocks = RG[0] * RG[1];
      const wpb = Math.ceil(tpb / 32), resident = Math.min(16, Math.floor(48 / wpb));
      out.real.innerHTML = `At ${bw}×${bh}, a 1280×800 frame needs a grid of <b>${RG[0]} × ${RG[1]} = ${blocks.toLocaleString()} blocks</b> (${(blocks * tpb).toLocaleString()} threads). An SM on this GPU holds at most 48 warps (1,536 threads) and 16 blocks at once, so up to ${resident} of these blocks fit per SM, ${resident * 8} across all 8 SMs: about <b>${Math.ceil(blocks / (resident * 8))} waves</b> of blocks. (Registers and shared memory can lower that further.) ${tpb < 64 ? 'Tiny blocks waste the SMs: they run out of block slots before they run out of threads.' : ''}`;
      tLaunch = now;
    };
    Site.range($('#c-bw'), (v) => { bw = 2 ** v; update(); }, (v) => 2 ** v);
    Site.range($('#c-bh'), (v) => { bh = 2 ** v; update(); }, (v) => 2 ** v);
    $('#c-launch').onclick = () => (tLaunch = now);
    const geom = () => {
      const { w, h } = st, smH = Math.max(54, h * 0.2);
      const cw = Math.ceil(IW / bw) * bw, chh = Math.ceil(IH / bh) * bh;
      const cell = Math.min((w - 12) / cw, (h - smH - 14) / Math.max(chh, IH * 1.1), (w - 12) / 50);
      return { cell, ox: 6, oy: 6, smY: h - smH, smH };
    };
    const pick = (e) => {
      const r = cv.getBoundingClientRect(), g = geom();
      const cx = Math.floor((e.clientX - r.left - g.ox) / g.cell), cy = Math.floor((e.clientY - r.top - g.oy) / g.cell);
      const gx = Math.ceil(IW / bw), gy = Math.ceil(IH / bh);
      hover = cx >= 0 && cy >= 0 && cx < gx * bw && cy < gy * bh ? [cx, cy] : null;
      if (!hover) return;
      const bx = Math.floor(cx / bw), by = Math.floor(cy / bh), tx = cx % bw, ty = cy % bh, lin = ty * bw + tx;
      const inside = cx < IW && cy < IH;
      out.who.innerHTML = `blockIdx = (${bx}, ${by}), threadIdx = (${tx}, ${ty})<br>x = ${bx}·${bw}+${tx} = <b class="ok">${cx}</b>, y = ${by}·${bh}+${ty} = <b class="ok">${cy}</b>, warp ${Math.floor(lin / 32)}<br>` +
        (inside ? `pixel ${Math.round(img[cy * IW + cx])} → ${img[cy * IW + cx] > CUT ? '255 (white)' : '0 (black)'}` : '<b class="err">past the image edge: returns without doing anything</b>');
    };
    cv.addEventListener('pointermove', pick); cv.addEventListener('pointerdown', pick);
    cv.addEventListener('pointerleave', () => (hover = null));
    update();
    Site.loop(cv, (t) => {
      now = t; if (!tLaunch) tLaunch = t;
      const { ctx, w, h } = st, g = geom(), c = g.cell;
      const gx = Math.ceil(IW / bw), gy = Math.ceil(IH / bh), nb = gx * gy, tpb = bw * bh, nw = Math.ceil(tpb / 32);
      const stagger = Math.min(0.06, 1.6 / nb), dur = 0.45, el = t - tLaunch;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      // idle area
      ctx.fillStyle = 'rgba(245,158,11,.10)'; ctx.fillRect(g.ox, g.oy, gx * bw * c, gy * bh * c);
      ctx.fillStyle = BG; ctx.fillRect(g.ox, g.oy, IW * c, IH * c);
      const prog = (b) => Site.clamp((el - b * stagger) / dur, 0, 1);
      for (let y = 0; y < IH; y++) for (let x = 0; x < IW; x++) {
        const b = Math.floor(y / bh) * gx + Math.floor(x / bw), lin = (y % bh) * bw + (x % bw);
        const lit = prog(b) * nw >= Math.floor(lin / 32) + 1;
        const v = img[y * IW + x];
        const o = lit ? (v > CUT ? 255 : 0) : Math.round(v * 0.75);
        ctx.fillStyle = `rgb(${o},${o},${o})`;
        ctx.fillRect(g.ox + x * c, g.oy + y * c, c + .3, c + .3);
        if (lit && prog(b) < 1) { ctx.fillStyle = `hsla(${hue(b)},90%,65%,.55)`; ctx.fillRect(g.ox + x * c, g.oy + y * c, c + .3, c + .3); }
      }
      // hatch idle threads
      ctx.save(); ctx.beginPath(); ctx.rect(g.ox, g.oy, gx * bw * c, gy * bh * c); ctx.rect(g.ox, g.oy, IW * c, IH * c); ctx.clip('evenodd');
      ctx.strokeStyle = 'rgba(245,158,11,.35)'; ctx.lineWidth = 1;
      for (let d = -MAXH * c; d < MAXW * c; d += 6) { ctx.beginPath(); ctx.moveTo(g.ox + d, g.oy + MAXH * c); ctx.lineTo(g.ox + d + MAXH * c, g.oy); ctx.stroke(); }
      ctx.restore();
      // block outlines
      ctx.lineWidth = 1.5;
      for (let by = 0; by < gy; by++) for (let bx = 0; bx < gx; bx++) {
        const b = by * gx + bx;
        ctx.strokeStyle = `hsla(${hue(b)},85%,70%,${prog(b) > 0 ? .95 : .35})`;
        ctx.strokeRect(g.ox + bx * bw * c + .75, g.oy + by * bh * c + .75, bw * c - 1.5, bh * c - 1.5);
      }
      ctx.strokeStyle = 'rgba(163,230,53,.9)'; ctx.setLineDash([4, 3]); ctx.strokeRect(g.ox, g.oy, IW * c, IH * c); ctx.setLineDash([]);
      if (hover) {
        const [hx, hy] = hover, bx = Math.floor(hx / bw), by = Math.floor(hy / bh), lin = (hy % bh) * bw + (hx % bw), wp = Math.floor(lin / 32);
        ctx.fillStyle = 'rgba(139,92,246,.35)';
        for (let i = wp * 32; i < Math.min(tpb, wp * 32 + 32); i++) ctx.fillRect(g.ox + (bx * bw + (i % bw)) * c, g.oy + (by * bh + Math.floor(i / bw)) * c, c, c);
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 2.5; ctx.strokeRect(g.ox + bx * bw * c, g.oy + by * bh * c, bw * c, bh * c);
        ctx.strokeStyle = RED; ctx.lineWidth = 2; ctx.strokeRect(g.ox + hx * c, g.oy + hy * c, c, c);
      }
      // SMs
      const sw = (w - 12 - 7 * 6) / 8;
      ctx.font = `600 ${Math.max(9, Math.min(11, sw / 7))}px "Plus Jakarta Sans", sans-serif`;
      for (let s = 0; s < 8; s++) {
        const x = 6 + s * (sw + 6), y = g.smY;
        ctx.fillStyle = 'rgba(255,255,255,.05)'; ctx.fillRect(x, y, sw, g.smH - 6);
        ctx.strokeStyle = 'rgba(196,181,253,.3)'; ctx.lineWidth = 1; ctx.strokeRect(x + .5, y + .5, sw - 1, g.smH - 7);
        ctx.fillStyle = MUTED; ctx.fillText(`SM ${s}`, x + 5, y + 13);
        let k = 0;
        for (let b = s; b < nb; b += 8) {
          const p = prog(b); if (p <= 0) continue;
          const bs = Math.min(10, (sw - 10) / 4), bx2 = x + 5 + (k % 4) * (bs + 2), by2 = y + 20 + Math.floor(k / 4) * (bs + 2);
          if (by2 + bs < y + g.smH - 6) { ctx.fillStyle = `hsla(${hue(b)},85%,65%,${p < 1 ? 1 : .45})`; ctx.fillRect(bx2, by2, bs, bs); }
          k++;
        }
      }
    });
  }

  /* warps inside the hierarchy figure */
  {
    let s = '';
    for (let r = 0; r < 8; r++) for (let i = 0; i < 32; i++) s += `<circle cx="${196 + i * 3.9}" cy="${186 + r * 8.6}" r="1.5" fill="${r === 2 ? '#8b5cf6' : '#c4b5fd'}"/>`;
    s += '<rect x="192" y="199.5" width="128" height="8" rx="4" fill="none" stroke="#8b5cf6"/><text x="324" y="206" font-size="9" fill="#6b1199">warp</text>';
    $('#c-warps').innerHTML = s;
  }

  /* ── 4. Warp divergence ───────────────────────────────── */
  {
    const cv = $('#c-div'), st = Site.canvas(cv, 0.46);
    const lines = [...root.querySelectorAll('#c-div-code .line')];
    let vals = [], plan = [], t0 = 0, now = 0;
    const CUT = 128;
    const build = (pat) => {
      let s = 3;
      const r = () => ((s = (s * 16807) % 2147483647) / 2147483647);
      vals = Array.from({ length: 32 }, (_, i) => pat === 'bright' ? 170 + r() * 70 : pat === 'half' ? (i < 16 ? 190 + r() * 40 : 30 + r() * 50) : pat === 'edge' ? (i < 23 ? 200 + r() * 30 : 25 + r() * 30) : r() * 255);
      const bright = vals.map((v) => v > CUT), all = bright.map(() => true);
      plan = [{ line: 0, mask: all, n: 1 }, { line: 1, mask: all, n: 1 }];
      if (bright.some(Boolean)) plan.push({ line: 2, mask: bright, n: 3 }, { line: 3, mask: bright, n: 1 });
      const dark = bright.map((b) => !b);
      if (dark.some(Boolean)) plan.push({ line: 5, mask: dark, n: 3 }, { line: 6, mask: dark, n: 1 });
      const steps = plan.reduce((a, p) => a + p.n, 0), useful = plan.reduce((a, p) => a + p.n * p.mask.filter(Boolean).length, 0);
      $('#c-div-steps').textContent = `${steps}`;
      $('#c-div-eff').textContent = `${Math.round(100 * useful / (32 * steps))}%`;
      lines.forEach((l, i) => l.classList.toggle('skip', (i === 2 || i === 3) ? !bright.some(Boolean) : (i === 5 || i === 6) ? !dark.some(Boolean) : false));
      t0 = now;
    };
    Site.seg($('#c-div-pat'), (v) => build(v));
    const STEP = 0.42;
    Site.loop(cv, (t) => {
      now = t; if (!t0) t0 = t;
      const total = plan.reduce((a, p) => a + p.n, 0);
      let e = ((t - t0) / STEP) % (total + 3), acc = 0, cur = null, doneSteps = 0;
      for (const p of plan) { if (e < acc + p.n) { cur = p; doneSteps = e - acc; break; } acc += p.n; }
      lines.forEach((l, i) => l.classList.toggle('on', !!cur && cur.line === i));
      const { ctx, w, h } = st;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const lw = (w - 16) / 32, top = 26, barH = h - top - 58;
      ctx.font = `600 11px "Plus Jakarta Sans", sans-serif`; ctx.fillStyle = MUTED;
      ctx.fillText(cur ? `running line ${cur.line + 1} · ${cur.mask.filter(Boolean).length} of 32 lanes on` : 'warp finished · starting again', 8, 16);
      for (let i = 0; i < 32; i++) {
        const x = 8 + i * lw, on = cur ? cur.mask[i] : false, v = vals[i];
        ctx.fillStyle = `rgb(${v},${v},${v})`; ctx.fillRect(x + 1, top, lw - 2, 12);
        ctx.fillStyle = on ? 'rgba(139,92,246,.95)' : 'rgba(255,255,255,.06)';
        ctx.fillRect(x + 1, top + 16, lw - 2, barH - 16);
        if (on) { const k = (t * 3 + i * .2) % 1; ctx.fillStyle = 'rgba(255,255,255,.5)'; ctx.fillRect(x + 1, top + 16 + (barH - 20) * k, lw - 2, 3); }
        else if (cur) { ctx.fillStyle = 'rgba(184,169,212,.5)'; ctx.font = `${Math.max(7, lw * .5)}px sans-serif`; ctx.fillText('z', x + lw * .3, top + barH / 2 + 4); }
      }
      // step timeline
      const ty = h - 30, tw = w - 16;
      let x = 8;
      ctx.font = '600 10px "Plus Jakarta Sans", sans-serif';
      for (const p of plan) {
        const pw = tw * p.n / total, frac = p.mask.filter(Boolean).length / 32;
        ctx.fillStyle = p.line === 0 || p.line === 1 ? '#6d28d9' : p.line < 5 ? LIME : AMBER;
        ctx.globalAlpha = .25; ctx.fillRect(x, ty, pw - 2, 18); ctx.globalAlpha = 1;
        ctx.fillRect(x, ty + 18 * (1 - frac), pw - 2, 18 * frac);
        x += pw;
      }
      const px = 8 + tw * Math.min(e, total) / total;
      ctx.fillStyle = '#fff'; ctx.fillRect(px - 1, ty - 4, 2, 26);
      ctx.fillStyle = MUTED; ctx.fillText('time →   (bar height = lanes doing work)', 8, ty - 7);
    });
  }

  /* ── 5. Host / device timeline ────────────────────────── */
  {
    const W = 560;
    let s = `<text x="6" y="44" font-size="13" font-weight="700" fill="#4c0070">CPU</text><text x="6" y="130" font-size="13" font-weight="700" fill="#4c0070">GPU</text>
      <line x1="52" y1="40" x2="${W - 10}" y2="40" stroke="#e9ddf7" stroke-width="24" stroke-linecap="round"/><line x1="52" y1="126" x2="${W - 10}" y2="126" stroke="#e9ddf7" stroke-width="24" stroke-linecap="round"/>`;
    const tick = (x) => `<line x1="${x}" y1="29" x2="${x}" y2="51" stroke="#8b5cf6" stroke-width="3"/><path d="M${x} 54 L${x + 8} 112" stroke="#c4b5fd" stroke-dasharray="3 3"/>`;
    [54, 61, 68, 75].forEach((x) => (s += tick(x)));
    s += `<rect x="84" y="29" width="150" height="22" rx="5" fill="#fed7aa"/><text x="90" y="44" font-size="11.5" fill="#9a3412">wait: how many blobs?</text>`;
    [240, 247, 254].forEach((x) => (s += tick(x)));
    s += `<rect x="262" y="29" width="130" height="22" rx="5" fill="#fed7aa"/><text x="268" y="44" font-size="11.5" fill="#9a3412">wait: quads ready?</text>`;
    s += `<rect x="398" y="29" width="148" height="22" rx="5" fill="#f59e0b"/><text x="405" y="44" font-size="11.5" fill="#fff" font-weight="700">decode tags (CPU)</text>`;
    for (const [n, x, wd] of [['copy', 60, 34], ['threshold', 96, 62], ['label', 160, 44], ['diff', 206, 28], ['sort', 250, 36], ['lines', 288, 42], ['quads', 332, 48]])
      s += `<rect x="${x}" y="114" width="${wd - 2}" height="24" rx="5" fill="#8b5cf6"/><text x="${x + 4}" y="130" font-size="10.5" fill="#fff">${n}</text>`;
    s += `<text x="52" y="168" font-size="12" fill="#635a72">Purple ticks: the CPU queues a command and moves on.</text>
      <text x="52" y="186" font-size="12" fill="#635a72">Orange: the CPU has to wait for a GPU answer.</text>`;
    svgEl($('#c-host'), s);
  }

  /* ── 6. The 971 pipeline, computed on a real field frame ─ */
  {
    const cv = $('#c-stage'), st = Site.canvas(cv, 0.625);
    // Real detections for this frame, from assets/field-images/detections.json (AprilTag C library).
    // Corner order there: bottom-left, bottom-right, top-right, top-left.
    const TAGS = [
      { id: 29, m: 81.0, c: [[578.3, 229.5], [622.2, 223.7], [619.2, 178.5], [574.7, 183.7]] },
      { id: 30, m: 78.9, c: [[690.7, 215.7], [730.5, 210.4], [729.2, 167.2], [688.9, 171.9]] },
      { id: 31, m: 88.9, c: [[1198.4, 147.2], [1221.5, 143.9], [1226.0, 110.3], [1202.5, 113.2]] },
      { id: 32, m: 91.9, c: [[1258.8, 139.5], [1280.3, 136.6], [1285.8, 104.3], [1263.9, 106.7]] },
    ];
    const quadOf = (t) => [t.c[3], t.c[2], t.c[1], t.c[0]]; // → TL, TR, BR, BL for Site._homog
    const IW = 1600, IH = 747, X0 = 520, Y0 = 130, FW = 240, FH = 150, DW = FW / 2, DH = FH / 2;
    const img = new Image();
    img.src = 'assets/field-images/2026-blue-outpost-fuel.jpg';
    let ready = false, P = {};
    const names = ['A frame arrives', 'Threshold at half size', 'Union-find: name the blobs', 'Blob boundaries', 'Filter and sort by angle', 'Fit lines, find corners', 'Fit quads', 'Refine and decode', 'Hand back to PhotonVision'];
    const where = ['GPU · 1 copy', 'GPU · thread per pixel', 'GPU · thread per 2×2', 'GPU · thread per pixel + CUB', 'GPU · CUB', 'GPU · 128-thread blocks', 'GPU → CPU', 'CPU · 6 worker threads', 'PhotonVision'];
    let caps = [];
    const bar = [...root.querySelectorAll('#c-st-bar i')];
    let stage = 0, since = 0, now = 0;
    const setStage = (i) => {
      stage = i; since = now;
      $('#c-st-n').textContent = `Stage ${i + 1} of 9`;
      $('#c-st-name').textContent = names[i];
      $('#c-st-where').textContent = where[i];
      if (ready) $('#c-st-cap').textContent = caps[i];
      bar.forEach((b, j) => b.classList.toggle('on', j <= i));
    };
    Site.scrolly($('#c-971'), setStage);

    img.onload = () => {
      const toCanvas = (w, h, fn) => { const c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d'), d = x.createImageData(w, h); for (let i = 0; i < w * h; i++) { const [r, g, b] = fn(i); d.data[i * 4] = r; d.data[i * 4 + 1] = g; d.data[i * 4 + 2] = b; d.data[i * 4 + 3] = 255; } x.putImageData(d, 0, 0); return c; };
      // gray crop at full resolution
      const cc = document.createElement('canvas'); cc.width = FW; cc.height = FH;
      const cx = cc.getContext('2d', { willReadFrequently: true });
      cx.drawImage(img, X0, Y0, FW, FH, 0, 0, FW, FH);
      const src = cx.getImageData(0, 0, FW, FH).data, gray = new Float32Array(FW * FH);
      for (let i = 0; i < FW * FH; i++) gray[i] = 0.299 * src[i * 4] + 0.587 * src[i * 4 + 1] + 0.114 * src[i * 4 + 2];
      const cFull = toCanvas(FW, FH, (i) => [gray[i], gray[i], gray[i]]);
      // decimate 2x
      const dec = new Float32Array(DW * DH);
      for (let y = 0; y < DH; y++) for (let x = 0; x < DW; x++) dec[y * DW + x] = (gray[2 * y * FW + 2 * x] + gray[2 * y * FW + 2 * x + 1] + gray[(2 * y + 1) * FW + 2 * x] + gray[(2 * y + 1) * FW + 2 * x + 1]) / 4;
      // 4x4 tile min/max, 3x3 tile filter, threshold (like InternalThreshold, min_white_black_diff 20)
      const TWn = Math.ceil(DW / 4), THn = Math.ceil(DH / 4), tmin = [], tmax = [];
      for (let ty = 0; ty < THn; ty++) for (let tx = 0; tx < TWn; tx++) {
        let a = 255, b = 0;
        for (let y = ty * 4; y < Math.min(DH, ty * 4 + 4); y++) for (let x = tx * 4; x < Math.min(DW, tx * 4 + 4); x++) { const v = dec[y * DW + x]; a = Math.min(a, v); b = Math.max(b, v); }
        tmin.push(a); tmax.push(b);
      }
      const th = new Uint8Array(DW * DH);
      for (let y = 0; y < DH; y++) for (let x = 0; x < DW; x++) {
        const tx = x >> 2, ty = y >> 2; let lo = 255, hi = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const X = tx + dx, Y = ty + dy; if (X < 0 || Y < 0 || X >= TWn || Y >= THn) continue; lo = Math.min(lo, tmin[Y * TWn + X]); hi = Math.max(hi, tmax[Y * TWn + X]); }
        th[y * DW + x] = hi - lo < 20 ? 127 : dec[y * DW + x] > lo + (hi - lo) / 2 ? 255 : 0;
      }
      const cTh = toCanvas(DW, DH, (i) => (th[i] === 127 ? [70, 58, 92] : [th[i], th[i], th[i]]));
      // connected components (8-connected, same value), the result the union-find reaches
      const lab = new Int32Array(DW * DH).fill(-1), sizes = [];
      for (let i = 0; i < DW * DH; i++) {
        if (lab[i] >= 0 || th[i] === 127) continue;
        const id = sizes.length, v = th[i], stack = [i]; lab[i] = id; let n = 0;
        while (stack.length) {
          const p = stack.pop(); n++;
          const px = p % DW, py = (p / DW) | 0;
          for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
            const X = px + dx, Y = py + dy; if (X < 0 || Y < 0 || X >= DW || Y >= DH) continue;
            const q = Y * DW + X; if (lab[q] < 0 && th[q] === v) { lab[q] = id; stack.push(q); }
          }
        }
        sizes.push(n);
      }
      const MIN = 6; // ponytail: the detector's 24-pixel minimum is for full frames; our zoomed crop's tag cells are smaller
      const hsl = (hh, s, l) => { s /= 100; l /= 100; const k = (n) => (n + hh / 30) % 12, a = s * Math.min(l, 1 - l), f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1)); return [255 * f(0), 255 * f(8), 255 * f(4)]; };
      const cLab = toCanvas(DW, DH, (i) => { const id = lab[i]; if (id < 0) return [40, 32, 56]; if (sizes[id] < MIN) return [60, 60, 60]; return hsl((id * 137.5) % 360, 70, th[i] ? 68 : 38); });
      // boundary points between black and white blobs, grouped by blob pair
      const pairs = new Map();
      for (let y = 0; y < DH; y++) for (let x = 0; x < DW; x++) {
        const p = y * DW + x; if (lab[p] < 0 || sizes[lab[p]] < MIN) continue;
        for (const [dx, dy] of [[1, 0], [0, 1], [1, 1], [-1, 1]]) {
          const X = x + dx, Y = y + dy; if (X < 0 || Y < 0 || X >= DW || Y >= DH) continue;
          const q = Y * DW + X; if (lab[q] < 0 || sizes[lab[q]] < MIN || th[q] === th[p]) continue;
          const blk = th[p] === 0 ? lab[p] : lab[q], wht = th[p] === 0 ? lab[q] : lab[p], key = blk * 100000 + wht;
          if (!pairs.has(key)) pairs.set(key, []);
          pairs.get(key).push([x + dx / 2 + .5, y + dy / 2 + .5]);
        }
      }
      const kept = new Set([...pairs.entries()].filter(([, pts]) => {
        if (pts.length < 24) return false;
        const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
        return Math.max(...xs) - Math.min(...xs) > 6 && Math.max(...ys) - Math.min(...ys) > 6;
      }).map(([k]) => k));
      // tag 29's outer outline: its black border against the white margin (found from the real corners)
      const Dq = (t) => quadOf(t).map(([x, y]) => [(x - X0) / 2, (y - Y0) / 2]);
      const q29 = Dq(TAGS[0]);
      const labAt = (u, v) => { const [x, y] = Site._homog(q29, u, v); return lab[Math.floor(y) * DW + Math.floor(x)]; };
      const tagKey = labAt(0.06, 0.5) * 100000 + labAt(-0.07, 0.5);
      let tagPts = (pairs.get(tagKey) || []).slice();
      const mx = tagPts.reduce((a, p) => a + p[0], 0) / tagPts.length, my = tagPts.reduce((a, p) => a + p[1], 0) / tagPts.length;
      tagPts.sort((a, b) => Math.atan2(a[1] - my, a[0] - mx) - Math.atan2(b[1] - my, b[0] - mx));
      tagPts = tagPts.filter((p, i, arr) => i === 0 || Math.hypot(p[0] - arr[i - 1][0], p[1] - arr[i - 1][1]) > 0.3);
      const NP = tagPts.length, K = 3;
      const fitErr = (pts) => {
        const n = pts.length, ax = pts.reduce((a, p) => a + p[0], 0) / n, ay = pts.reduce((a, p) => a + p[1], 0) / n;
        let xx = 0, yy = 0, xy = 0; for (const [x, y] of pts) { xx += (x - ax) ** 2; yy += (y - ay) ** 2; xy += (x - ax) * (y - ay); }
        const tr = xx + yy, det = xx * yy - xy * xy; return tr / 2 - Math.sqrt(Math.max(0, tr * tr / 4 - det));
      };
      const errs = tagPts.map((_, i) => fitErr(Array.from({ length: 2 * K + 1 }, (_, j) => tagPts[(i - K + j + NP) % NP])));
      const peaks = [], order = errs.map((e, i) => i).sort((a, b) => errs[b] - errs[a]);
      for (const i of order) { if (peaks.every((p) => Math.min(Math.abs(p - i), NP - Math.abs(p - i)) > NP / 10)) peaks.push(i); if (peaks.length === 4) break; }
      // decode tag 29 from the full-resolution crop, sampling at the real corners
      const Q = quadOf(TAGS[0]).map(([x, y]) => [x - X0, y - Y0]);
      const samples = [];
      for (let r = 0; r < 8; r++) for (let q = 0; q < 8; q++) { const [x, y] = Site._homog(Q, (q + .5) / 8, (r + .5) / 8); samples.push([x, y, gray[Math.round(y) * FW + Math.round(x)], r, q]); }
      const border = samples.filter((s) => s[3] === 0 || s[4] === 0 || s[3] === 7 || s[4] === 7).map((s) => s[2]);
      const inner = samples.filter((s) => !(s[3] === 0 || s[4] === 0 || s[3] === 7 || s[4] === 7)).map((s) => s[2]).sort((a, b) => b - a);
      const cutoff = (border.reduce((a, v) => a + v, 0) / border.length + inner[Math.floor(inner.length * .15)]) / 2;
      const tg = Site.tagGrid(29), bits = [];
      let ham = 0;
      for (const s of samples) { const b = s[2] > cutoff ? 1 : 0; s.push(b); if (s[3] > 0 && s[3] < 7 && s[4] > 0 && s[4] < 7) { bits.push(b); if (b !== tg[s[3] + 1][s[4] + 1]) ham++; } }
      P = { cFull, cTh, cLab, pairs, kept, tagKey, tagPts, NP, mx, my, errs, peaks, Q, samples, bits, ham };
      caps = [
        'Real 1600×747 frame, 2026 blue outpost. The box is the 240×150 area we zoom into.',
        `Every pixel in parallel. Zoomed area at half size: ${DW}×${DH}. Purple-gray = "unknown".`,
        `${sizes.filter((n) => n >= MIN).length} blobs in this small area alone, each in its own color.`,
        `${pairs.size} black/white blob pairs touch here; each pair's points in its own color.`,
        `${kept.size} pairs pass the size filter. Tag 29's outline, sorted by angle.`,
        `Line-fit error around tag 29's outline (${NP} points), from the real pixels.`,
        'The four corners the AprilTag library found for tags 29 and 30 in this frame.',
        `Tag 29's bits read at its real corners: ${ham === 0 ? 'ID 29, Hamming distance 0' : ham + ' bits off from ID 29'}.`,
        'All four tags in the frame, with their real decision margins.',
      ];
      ready = true;
      setStage(stage);
    };

    Site.loop(cv, (t) => {
      now = t;
      const { ctx, w, h } = st, e = t - since;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      if (!ready) { ctx.fillStyle = MUTED; ctx.font = '600 13px "Plus Jakarta Sans", sans-serif'; ctx.fillText('Loading the camera frame…', 14, 24); return; }
      if (stage === 0 || stage === 8) { // whole frame
        const sc = Math.min(w / IW, h / IH), ox = (w - IW * sc) / 2, oy = (h - IH * sc) / 2, F = ([x, y]) => [ox + x * sc, oy + y * sc];
        ctx.imageSmoothingEnabled = true; ctx.drawImage(img, ox, oy, IW * sc, IH * sc);
        if (stage === 0) {
          const a = Math.min(1, e / .8);
          ctx.strokeStyle = `rgba(245,158,11,${a})`; ctx.lineWidth = 2.5; ctx.strokeRect(ox + X0 * sc, oy + Y0 * sc, FW * sc, FH * sc);
          ctx.fillStyle = AMBER; ctx.font = '700 12px "Plus Jakarta Sans", sans-serif'; ctx.fillText('zoom', ox + X0 * sc, oy + Y0 * sc - 6);
        } else {
          TAGS.forEach((tg, i) => {
            const a = Math.min(1, Math.max(0, (e - i * .25) / .5)); if (!a) return;
            ctx.globalAlpha = a; ctx.strokeStyle = LIME; ctx.lineWidth = 2.5; ctx.beginPath(); tg.c.forEach((p, j) => { const [x, y] = F(p); j ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }); ctx.closePath(); ctx.stroke();
            const [lx, ly] = F([tg.c[2][0] / 2 + tg.c[3][0] / 2, Math.min(tg.c[2][1], tg.c[3][1])]);
            ctx.font = '700 12px Outfit, sans-serif'; ctx.fillStyle = LIME; ctx.textAlign = 'center'; ctx.fillText(tg.id, lx, ly - 6); ctx.textAlign = 'left';
            ctx.globalAlpha = 1;
          });
          if (e > 1.2) {
            const lines = TAGS.map((tg) => `ID ${tg.id}: margin ${tg.m.toFixed(1)}`), bw = 142, bh = 16 * lines.length + 12, bx = w - bw - 8, by = h - bh - 8;
            ctx.fillStyle = 'rgba(14,5,24,.85)'; ctx.fillRect(bx, by, bw, bh);
            ctx.font = '600 11.5px "Plus Jakarta Sans", sans-serif'; ctx.fillStyle = '#fff';
            lines.forEach((l, i) => ctx.fillText(l, bx + 10, by + 20 + i * 16));
          }

        }
        return;
      }
      const k = w / FW, kd = w / DW, D = ([x, y]) => [x * kd, y * kd];
      ctx.imageSmoothingEnabled = stage === 7;
      const base = [null, P.cTh, P.cLab, P.cTh, P.cTh, P.cTh, P.cFull, P.cFull][stage];
      ctx.globalAlpha = stage === 3 || stage === 4 ? .28 : stage === 5 ? .5 : 1;
      ctx.drawImage(base, 0, 0, w, h); ctx.globalAlpha = 1;
      if (stage === 1) {
        const a = Math.max(0, 1 - e / 1.5) * .6 + .1;
        ctx.strokeStyle = `rgba(196,181,253,${a})`; ctx.lineWidth = 1;
        for (let x = 0; x <= DW; x += 4) { ctx.beginPath(); ctx.moveTo(x * kd, 0); ctx.lineTo(x * kd, h); ctx.stroke(); }
        for (let y = 0; y <= DH; y += 4) { ctx.beginPath(); ctx.moveTo(0, y * kd); ctx.lineTo(w, y * kd); ctx.stroke(); }
      }
      if (stage === 3 || stage === 4) {
        const r = Math.max(1.2, kd * .45);
        for (const [key, pts] of P.pairs) {
          if (stage === 4 && key === P.tagKey) continue;
          ctx.fillStyle = stage === 4 && !P.kept.has(key) ? 'rgba(120,110,140,.35)' : `hsl(${(key * 0.618 * 360) % 360} 85% 62%)`;
          for (const p of pts) { const [x, y] = D(p); ctx.fillRect(x - r / 2, y - r / 2, r, r); }
        }
        if (stage === 4) {
          const u = Math.min(1, e / 2.2), n = Math.floor(P.NP * u), [cx, cy] = D([P.mx, P.my]);
          for (let i = 0; i < n; i++) { const [x, y] = D(P.tagPts[i]); ctx.fillStyle = `hsl(${280 - 180 * i / P.NP} 90% 65%)`; ctx.fillRect(x - r, y - r, r * 2, r * 2); }
          if (u < 1 && n > 0) { const [x, y] = D(P.tagPts[n - 1]); ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(x, y); ctx.stroke(); }
          ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(cx, cy, 3, 0, 7); ctx.fill();
        }
      }
      if (stage === 5) {
        for (let i = 0; i < P.NP; i++) { const [x, y] = D(P.tagPts[i]); ctx.fillStyle = `hsl(${280 - 180 * i / P.NP} 90% 65%)`; ctx.fillRect(x - 2, y - 2, 4, 4); }
        // chart in the right half, beside tag 29
        const L = w * .5, R = w - 8, ch = h * .55, cy0 = h - 12, maxE = Math.max(...P.errs);
        ctx.fillStyle = 'rgba(14,5,24,.9)'; ctx.fillRect(L - 8, h - ch - 34, w - L + 8, ch + 34);
        const u = Math.min(1, e / 1.6), n = Math.floor(P.NP * u);
        ctx.beginPath();
        for (let i = 0; i < n; i++) { const x = L + (R - L) * i / (P.NP - 1), y = cy0 - (ch - 6) * P.errs[i] / maxE; i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
        ctx.strokeStyle = SOFT; ctx.lineWidth = 1.5; ctx.stroke();
        ctx.fillStyle = MUTED; ctx.font = '600 10.5px "Plus Jakarta Sans", sans-serif'; ctx.fillText('line-fit error, around tag 29 →', L, h - ch - 18);
        for (const p of P.peaks) if (p < n) {
          const x = L + (R - L) * p / (P.NP - 1), y = cy0 - (ch - 6) * P.errs[p] / maxE;
          ctx.fillStyle = RED; ctx.beginPath(); ctx.arc(x, y, 4, 0, 7); ctx.fill();
          const [px, py] = D(P.tagPts[p]); ctx.beginPath(); ctx.arc(px, py, 5, 0, 7); ctx.fill();
        }
      }
      if (stage === 6) {
        const u = Math.min(1, e / 1.2);
        for (const tg of TAGS.slice(0, 2)) {
          const q = tg.c.map(([x, y]) => [(x - X0) * k, (y - Y0) * k]);
          ctx.strokeStyle = LIME; ctx.lineWidth = 3; ctx.globalAlpha = u; ctx.beginPath(); q.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.closePath(); ctx.stroke(); ctx.globalAlpha = 1;
          for (const [x, y] of q) { ctx.fillStyle = RED; ctx.beginPath(); ctx.arc(x, y, 5, 0, 7); ctx.fill(); }
        }
      }
      if (stage === 7) {
        ctx.strokeStyle = LIME; ctx.lineWidth = 2; ctx.beginPath(); P.Q.forEach(([x, y], i) => (i ? ctx.lineTo(x * k, y * k) : ctx.moveTo(x * k, y * k))); ctx.closePath(); ctx.stroke();
        const u = Math.min(1, e / 1.8), n = Math.floor(64 * u);
        P.samples.slice(0, n).forEach(([x, y, , r, q, b]) => { ctx.fillStyle = r === 0 || q === 0 || r === 7 || q === 7 ? 'rgba(244,63,94,.9)' : b ? LIME : ACC; ctx.beginPath(); ctx.arc(x * k, y * k, Math.max(2, k * .9), 0, 7); ctx.fill(); });
        const gs = Math.min(w * .22, h * .42), gx = w - gs - 10, gy = 10, c = gs / 6;
        ctx.fillStyle = 'rgba(14,5,24,.9)'; ctx.fillRect(gx - 8, gy - 4, gs + 16, gs + 34);
        let bi = 0;
        for (let r = 0; r < 6; r++) for (let q = 0; q < 6; q++) { const b = P.bits[bi++]; ctx.fillStyle = bi <= Math.max(0, n - 28) ? (b ? '#fff' : '#000') : '#2a1a40'; ctx.fillRect(gx + q * c, gy + r * c, c - 1, c - 1); }
        if (u >= 1) { ctx.fillStyle = P.ham === 0 ? LIME : AMBER; ctx.font = `700 ${Math.max(11, gs * .13)}px Outfit, sans-serif`; ctx.fillText(P.ham === 0 ? 'ID 29 ✓' : `ID 29? ${P.ham} off`, gx, gy + gs + 22); }
      }
    });
  }

  /* ── 7. A/B chart ─────────────────────────────────────── */
  {
    const rows = [['4143 copy · mwbd 5', 2.40, 3.01], ['bos (Austin\'s current) · mwbd 5', 2.39, 3.03], ['bos · mwbd 20 (what we run)', 1.71, 1.79]];
    const nar = root.clientWidth < 620, X0 = 8, W = nar ? 300 : 420, sc = W / 3.5;
    $('#c-ab').setAttribute('viewBox', `0 0 ${nar ? 400 : 520} 250`);
    let s = '';
    rows.forEach(([n, a, b], i) => {
      const y = 18 + i * 74, hl = i === 2;
      s += `<text x="${X0}" y="${y + 10}" font-size="14" font-weight="700" fill="${hl ? '#6b1199' : '#1f1b23'}">${n}</text>`;
      [[a, '3 ms'], [b, '8.3 ms']].forEach(([v, ex], j) => {
        const yy = y + 18 + j * 22;
        s += `<rect x="${X0}" y="${yy}" width="${v * sc}" height="17" rx="4" fill="${hl ? '#8b5cf6' : '#c4b5fd'}" opacity="${j ? .75 : 1}"/><text x="${X0 + v * sc + 6}" y="${yy + 14}" font-size="13" font-weight="700" fill="#4c0070">${v.toFixed(2)} ms</text><text x="${X0 + 6}" y="${yy + 13.5}" font-size="11.5" fill="${hl ? '#fff' : '#4c0070'}">exp ${ex}</text>`;
      });
    });
    s += `<line x1="${X0}" y1="238" x2="${X0 + W}" y2="238" stroke="#d4c0ee"/>`;
    for (let v = 0; v <= 3.5; v += 0.5) s += `<text x="${X0 + v * sc}" y="249" font-size="9.5" text-anchor="middle" fill="#635a72">${v}</text>`;
    svgEl($('#c-ab'), s);
  }

  /* ── 8. Sticky error strip ────────────────────────────── */
  const narrow = root.clientWidth < 620;
  {
    const calls = [['copy frame', 'ok', 'checked'], ['ReduceByKey', 'fail', 'not checked!'], ['next kernel', 'ok', 'checked'], ['DeviceSelect::If', 'bail', 'CUB peeks the flag']];
    const svg = $('#c-sticky');
    const pos = narrow ? calls.map((_, i) => [12 + (i % 2) * 222, 10 + Math.floor(i / 2) * 118]) : calls.map((_, i) => [12 + i * 220, 10]);
    let s = '';
    calls.forEach(([n, r, note], i) => {
      const [x, y] = pos[i];
      const col = r === 'ok' ? '#16a34a' : r === 'fail' ? '#f59e0b' : '#dc2626';
      s += `<rect x="${x}" y="${y}" width="200" height="64" rx="12" fill="#fff" stroke="${col}" stroke-width="2"/>
        <text x="${x + 14}" y="${y + 26}" font-size="15" font-weight="700" fill="#1f1b23" font-family="JetBrains Mono, monospace">${n}</text>
        <text x="${x + 14}" y="${y + 50}" font-size="13" fill="${col}" font-weight="700">${r === 'ok' ? '✓ worked' : r === 'fail' ? '✗ failed, quietly' : '✗ fails: "leftover error"'}</text>
        <text x="${x + 14}" y="${y + 84}" font-size="12.5" fill="#635a72">${i + 1}. ${note}</text>`;
    });
    if (narrow) {
      s += '<text x="12" y="262" font-size="13" font-weight="700" fill="#4c0070">error flag</text><rect x="92" y="250" width="40" height="18" rx="9" fill="#e9ddf7"/><rect x="132" y="250" width="300" height="18" rx="9" fill="#f59e0b"/><text x="142" y="263" font-size="11" font-weight="700" fill="#fff">set by step 2, still set at step 4</text>';
      svg.setAttribute('viewBox', '0 0 446 280');
    } else {
      s += '<text x="10" y="138" font-size="12" font-weight="700" fill="#4c0070">error flag</text><rect x="82" y="124" width="150" height="18" rx="9" fill="#e9ddf7"/><rect x="232" y="124" width="660" height="18" rx="9" fill="#f59e0b"/><text x="246" y="137" font-size="11" font-weight="700" fill="#fff">still set from the unchecked call… until someone reads it</text>';
      calls.slice(0, 3).forEach((_, i) => (s += `<path d="M${214 + i * 220} 42 h16" stroke="#c4b5fd" stroke-width="2"/>`));
    }
    svgEl(svg, s);
  }

  /* ── 9. Zero-block lab ────────────────────────────────── */
  {
    const cv = $('#c-zbc'), st = Site.canvas(cv, 0.34);
    let n = 480, fixed = true;
    const stEl = $('#c-zb-st');
    const upd = () => {
      const k = Math.ceil(n / 240);
      stEl.innerHTML = k > 0 ? `FitLines&lt;&lt;&lt;<b class="ok">${k}</b>, 128&gt;&gt;&gt;  ·  ${k} block${k > 1 ? 's' : ''} × 128 threads` :
        fixed ? '<b class="ok">no blobs → return "no detections" early ✓</b>' : 'FitLines&lt;&lt;&lt;<b class="err">0</b>, 128&gt;&gt;&gt; → invalid launch<br><b class="err">the next CUB call fails, every blank frame</b>';
    };
    Site.range($('#c-zb'), (v) => { n = v; upd(); });
    Site.seg($('#c-zb-fix'), (v) => { fixed = v === 'new'; upd(); });
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st, k = Math.ceil(n / 240);
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      if (k === 0) {
        ctx.strokeStyle = fixed ? 'rgba(163,230,53,.8)' : `rgba(244,63,94,${.5 + .5 * Math.sin(t * 6)})`; ctx.lineWidth = 2; ctx.setLineDash([6, 5]);
        ctx.strokeRect(10, 10, w - 20, h - 20); ctx.setLineDash([]);
        ctx.fillStyle = fixed ? LIME : RED; ctx.font = '700 15px Outfit, sans-serif'; ctx.textAlign = 'center';
        ctx.fillText(fixed ? 'nothing to fit: skip it' : 'grid of 0 blocks', w / 2, h / 2 + 5); ctx.textAlign = 'left';
        return;
      }
      const bs = Math.min((w - 20) / Math.max(k, 4) - 6, h - 20);
      for (let b = 0; b < k; b++) {
        const x = 10 + b * (bs + 6), y = (h - bs) / 2;
        ctx.fillStyle = 'rgba(139,92,246,.25)'; ctx.fillRect(x, y, bs, bs);
        const c = bs / 16;
        for (let i = 0; i < 128; i++) { const on = (t * 2 + b * .3 + i / 128) % 1 < .5; ctx.fillStyle = on ? SOFT : ACC; ctx.fillRect(x + (i % 16) * c + c * .2, y + Math.floor(i / 16) * c * 2 + c * .4, c * .6, c * 1.2); }
      }
    });
  }

  /* ── 10. Detector slots lab ───────────────────────────── */
  {
    const box = $('#c-slots'), stEl = $('#c-slot-st');
    let fixed = false, used = [], cur = -2, created = 0, broke = false;
    const draw = () => {
      box.innerHTML = '<div class="neg">−1</div>' + Array.from({ length: 10 }, (_, i) => `<div>${i}</div>`).join('');
      const cells = box.children;
      if (broke) cells[0].className = 'neg bad';
      used.forEach((i) => cells[i + 1].classList.add('used'));
      if (cur >= 0) cells[cur + 1].classList.add(fixed ? 'free' : 'used');
    };
    const reset = () => { used = []; cur = -2; created = 0; broke = false; stEl.textContent = 'Each pipeline or resolution change creates a detector.'; draw(); $('#c-slot-add').textContent = 'Change pipeline'; };
    Site.seg($('#c-slot-fix'), (v) => { fixed = v === 'new'; reset(); });
    $('#c-slot-add').onclick = () => {
      if (broke) return reset();
      created++;
      if (fixed) { cur = 0; stEl.innerHTML = `Change ${created}: old detector freed, slot 0 reused. <b class="ok">Handle checked ✓</b>`; }
      else if (created <= 10) { if (cur >= 0) used.push(cur); cur = created - 1; stEl.innerHTML = `Change ${created}: new detector in slot ${cur}. The old one is never freed.`; }
      else { if (cur >= 0) used.push(cur); cur = -2; broke = true; stEl.innerHTML = '<b class="err">Change 11: no free slot → handle −1 → reads detectors[−1], memory before the array.</b> Undefined behavior. (Click to reset.)'; }
      draw();
      $('#c-slot-add').textContent = broke ? '↺ Reset' : 'Change pipeline';
    };
    reset();
  }

  /* ── 12. GPU checkout line (simplified queue model) ───── */
  {
    const cv = $('#c-q'), st = Site.canvas(cv, 0.74);
    const CAMS = [{ n: 'TopLeft', p: 1000 / 122, c: '#a78bfa' }, { n: 'TopRight', p: 1000 / 122, c: '#22d3ee' }, { n: 'BotLeft', p: 1000 / 122, c: '#f59e0b' }, { n: 'BotRight', p: 1000 / 122, c: '#f472b6' }, { n: '5th Cam', p: 1000 / 122, c: '#a3e635' }];
    const NC = CAMS.length;
    const PIECES = 8, CPUGAP = 0.12, DECODE = 0.45;
    // One simulation: ncam cameras, g ms of GPU work per frame, a single GPU doing one piece at a time.
    const makeSim = (ncam, g, seed0) => {
      let seed = seed0;
      const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
      const S = { T: 0, next: CAMS.map((c) => rnd() * c.p), queue: [], gpu: null, frames: [], log: [], done: [], busyT: 0 };
      S.step = (dt, keepVisual, tick = 0.01) => {
        const n = Math.ceil(dt / tick), h = dt / n; // fixed tick count: no float creep
        for (let it = 0; it < n; it++) {
          S.T += h;
          for (let i = 0; i < ncam; i++) if (S.T >= S.next[i]) { S.next[i] += CAMS[i].p * (0.98 + rnd() * 0.04); S.frames.push({ cam: i, t0: S.T, piece: 0, readyAt: S.T, inQ: false, end: null }); }
          for (const f of S.frames) if (f.end === null && !f.inQ && f.piece < PIECES && S.T >= f.readyAt && (!S.gpu || S.gpu.f !== f)) { S.queue.push({ f, need: (g / PIECES) * (0.5 + rnd()) }); f.inQ = true; }
          if (!S.gpu && S.queue.length) { S.gpu = S.queue.shift(); S.gpu.start = S.T; }
          if (S.gpu) {
            S.busyT += h; S.gpu.need -= h;
            if (S.gpu.need <= 0) {
              const f = S.gpu.f; if (keepVisual) S.log.push({ cam: f.cam, a: S.gpu.start, b: S.T });
              f.inQ = false; f.piece++;
              f.readyAt = S.T + (f.piece < PIECES ? CPUGAP * (0.7 + rnd() * 0.6) : DECODE * (0.8 + rnd() * 0.4));
              if (f.piece >= PIECES) { f.end = f.readyAt; S.done.push(f.end - f.t0); }
              S.gpu = null;
            }
          }
        }
        const keep = S.T - 60;
        S.frames = S.frames.filter((f) => f.end === null || f.end > keep);
        if (keepVisual) { S.log = S.log.filter((l) => l.b > keep); if (S.done.length > 400) S.done.splice(0, S.done.length - 400); }
      };
      return S;
    };
    let ncam = 4, g = 0.8, sim = makeSim(4, 0.8, 5);
    const els = { busy: $('#c-q-busy'), avg: $('#c-q-avg'), max: $('#c-q-max') };
    const measure = () => {
      const m = makeSim(ncam, g, 9);
      m.step(4000, false, 0.025);
      const d = m.done.slice().sort((a, b) => a - b);
      els.busy.textContent = `${Math.round(100 * m.busyT / m.T)}%`;
      els.avg.textContent = `${(d.reduce((a, v) => a + v, 0) / d.length).toFixed(1)} ms`;
      els.max.textContent = d.length ? `${d[Math.floor(d.length * 0.99)].toFixed(1)} ms` : '–';
    };
    let mt = 0;
    const restart = () => { sim = makeSim(ncam, g, 5); clearTimeout(mt); Object.values(els).forEach((e) => (e.textContent = '…')); mt = setTimeout(measure, 120); };
    Site.seg($('#c-q-n'), (v) => { ncam = +v; restart(); });
    Site.range($('#c-q-g'), (v) => { g = v; restart(); }, (v) => `${v.toFixed(1)} ms`);
    Site.loop(cv, (t, dt) => {
      if (dt) sim.step(dt * 14, true); // 14 ms of Jetson time per real second
      const { ctx, w, h } = st, T = sim.T, WIN = 42, lx = 66, rx = w - 10, sx = (rx - lx) / WIN, x = (tt) => lx + (tt - (T - WIN)) * sx;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const rowH = (h - 64) / (NC + 1);
      ctx.font = '600 11px "Plus Jakarta Sans", sans-serif';
      ctx.save(); ctx.beginPath(); ctx.rect(lx, 0, rx - lx, h); ctx.clip();
      for (let i = 0; i < NC; i++) { ctx.fillStyle = 'rgba(255,255,255,.04)'; ctx.fillRect(lx, 10 + i * rowH + 3, rx - lx, rowH - 6); }
      for (const f of sim.frames) {
        const y = 10 + f.cam * rowH, a = x(f.t0), b = x(f.end ?? T);
        ctx.fillStyle = CAMS[f.cam].c; ctx.globalAlpha = .3; ctx.fillRect(a, y + 5, b - a, rowH - 10); ctx.globalAlpha = 1;
        ctx.fillRect(a, y + 5, 2, rowH - 10);
        if (f.inQ) { ctx.fillStyle = '#fff'; ctx.fillRect(b - 4, y + rowH / 2 - 4, 8, 8); }
      }
      const gy = 10 + NC * rowH + 8;
      ctx.fillStyle = 'rgba(255,255,255,.06)'; ctx.fillRect(lx, gy, rx - lx, rowH);
      for (const l of sim.log) { ctx.fillStyle = CAMS[l.cam].c; ctx.fillRect(x(l.a), gy + 2, Math.max(1, x(l.b) - x(l.a) - .6), rowH - 4); }
      if (sim.gpu) { ctx.fillStyle = CAMS[sim.gpu.f.cam].c; ctx.fillRect(x(sim.gpu.start), gy + 2, x(T) - x(sim.gpu.start), rowH - 4); }
      ctx.restore();
      for (let i = 0; i < NC; i++) { ctx.fillStyle = i < ncam ? CAMS[i].c : 'rgba(184,169,212,.3)'; ctx.fillText(CAMS[i].n, 6, 10 + i * rowH + rowH / 2 + 4); }
      ctx.fillStyle = INK; ctx.fillText('GPU', 6, gy + rowH / 2 + 4);
      ctx.fillStyle = MUTED; ctx.fillText(`waiting in line: ${sim.queue.length}`, lx, h - 30);
      sim.queue.slice(0, 14).forEach((q, i) => { ctx.fillStyle = CAMS[q.f.cam].c; ctx.fillRect(lx + 116 + i * 12, h - 40, 9, 12); });
      ctx.fillStyle = 'rgba(184,169,212,.7)'; ctx.fillText(`last ${WIN} ms, slowed down ~70× · white square = waiting for the GPU`, lx, h - 10);
      ctx.fillStyle = '#fff'; ctx.fillRect(rx - 1, 6, 1.5, gy + rowH - 4);
    });
  }

  /* ── 13. Eleven runs (real data, TECHNICAL.md) ────────── */
  {
    const cv = $('#c-runs'), st = Site.canvas(cv, innerWidth < 700 ? 0.62 : 0.25);
    // Thriftiest Cams, "typical worst" detect time (ms), each 1-minute run after a restart.
    const Q8 = [[6.65, 'baseline', 1], [5.99, 'block', 0], [6.39, '2 threads', 0], [7.29, '3 threads', 0], [5.95, 'baseline again', 0], [6.46, 'baseline, run 2', 0], [6.32, 'block, run 2', 0]];
    const Q32 = [[4.87, '32 queues', 1], [5.37, 'block + 32', 0], [6.59, '32 queues, run 2', 0], [7.54, 'block + 32 again', 0]];
    let mode = 'first', since = 0, now = 0;
    const note = $('#c-runs-note');
    Site.seg($('#c-runs-mode'), (v) => {
      mode = v; since = now;
      note.innerHTML = v === 'first' ? 'First run of each: 32 queues looks <b>1.8 ms better</b>. Case closed?' :
        'All 11 runs: the averages are <b>6.44 ms (8 queues)</b> and <b>6.09 ms (32 queues)</b>. The same setting (block + 32) gave 5.37 ms once and 7.54 ms the next time.';
    });
    Site.loop(cv, (t) => {
      now = t;
      const { ctx, w, h } = st, x0 = Math.min(120, w * .26), x1 = w - 16, lo = 4, hi = 8, X = (v) => x0 + (x1 - x0) * (v - lo) / (hi - lo);
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const rows = [['8 queues', Q8, '#c4b5fd', 6.44], ['32 queues', Q32, '#a3e635', 6.09]], rh = (h - 40) / 2;
      ctx.font = '600 11px "Plus Jakarta Sans", sans-serif';
      for (let v = lo; v <= hi; v++) { ctx.strokeStyle = 'rgba(196,181,253,.14)'; ctx.beginPath(); ctx.moveTo(X(v), 8); ctx.lineTo(X(v), h - 28); ctx.stroke(); ctx.fillStyle = MUTED; ctx.textAlign = 'center'; ctx.fillText(`${v} ms`, X(v), h - 12); }
      ctx.textAlign = 'left';
      const e = Math.min(1, (t - since) / .8);
      rows.forEach(([name, pts, col, mean], r) => {
        const y = 10 + r * rh + rh / 2;
        ctx.fillStyle = col; ctx.font = '700 12px Outfit, sans-serif'; ctx.fillText(name, 8, y + 4);
        pts.forEach(([v, , first], i) => {
          if (mode === 'first' && !first) return;
          const jit = ((i * 37) % 7 - 3) * 3;
          ctx.globalAlpha = mode === 'all' && !first ? e : 1;
          ctx.fillStyle = col; ctx.beginPath(); ctx.arc(X(v), y + jit, first ? 7 : 5.5, 0, 7); ctx.fill();
          if (first) { ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.stroke(); }
          ctx.globalAlpha = 1;
        });
        if (mode === 'all') { ctx.strokeStyle = col; ctx.lineWidth = 2.5; ctx.globalAlpha = e; ctx.beginPath(); ctx.moveTo(X(mean), y - rh * .4); ctx.lineTo(X(mean), y + rh * .4); ctx.stroke(); ctx.globalAlpha = 1; }
      });
      if (mode === 'all') {
        const y = 10 + rh * 1.5; ctx.strokeStyle = 'rgba(255,255,255,.6)'; ctx.setLineDash([3, 3]); ctx.lineWidth = 1.2;
        ctx.beginPath(); ctx.moveTo(X(5.37), y + 16); ctx.lineTo(X(5.37), y + 22); ctx.lineTo(X(7.54), y + 22); ctx.lineTo(X(7.54), y + 16); ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = '#fff'; ctx.font = '600 10px "Plus Jakarta Sans", sans-serif'; ctx.textAlign = 'center'; ctx.fillText('same settings', (X(5.37) + X(7.54)) / 2, y + 33); ctx.textAlign = 'left';
      }
    });
  }

  /* ── 14. TensorRT chart ───────────────────────────────── */
  {
    const nar = root.clientWidth < 620, VW = nar ? 400 : 520, X0 = 10, W = VW - 110, sc = W / 30;
    const rows = [['FUEL capped at 30 fps (default)', 1.62, 3.75, 'GPU 11–30% · same as with no FUEL'], ['FUEL uncapped (76 fps)', 1.96, 28, 'GPU 29–44%']];
    let s = '<text x="10" y="16" font-size="13" font-weight="700" fill="#4c0070">AprilTag camera detect time</text>';
    rows.forEach(([n, a, b, gpu], i) => {
      const y = 36 + i * 84;
      s += `<text x="${X0}" y="${y + 12}" font-size="13" font-weight="700" fill="#1f1b23">${n}</text><text x="${X0}" y="${y + 28}" font-size="11.5" fill="#635a72">${gpu}</text>
        <rect x="${X0}" y="${y + 36}" width="${b * sc}" height="18" rx="5" fill="${i ? '#f59e0b' : '#c4b5fd'}"/><text x="${X0 + b * sc + 6}" y="${y + 50}" font-size="12" font-weight="700" fill="#4c0070">worst ${b} ms</text>
        <rect x="${X0}" y="${y + 58}" width="${a * sc}" height="12" rx="4" fill="#8b5cf6"/><text x="${X0 + a * sc + 6}" y="${y + 68}" font-size="11" fill="#4c0070">average ${a} ms</text>`;
    });
    s += `<line x1="${X0}" y1="206" x2="${X0 + W}" y2="206" stroke="#d4c0ee"/>`;
    for (let v = 0; v <= 30; v += 10) s += `<text x="${X0 + v * sc}" y="220" font-size="10.5" text-anchor="middle" fill="#635a72">${v} ms</text>`;
    const svg = $('#c-trt'); svg.setAttribute('viewBox', `0 0 ${VW} 226`); svgEl(svg, s);
  }
});
