Site.chapter('finale', (root) => {
  const $ = (s) => root.querySelector(s);
  const font = (px, w = 600, mono) => `${w} ${px}px ${mono ? 'JetBrains Mono, monospace' : 'Plus Jakarta Sans, sans-serif'}`;

  /* ── Follow one frame ──────────────────────────────────── */
  {
    const IW = 1280, IH = 800;
    // Our TopLeft camera, Rewind recording 0007 frame 51 (assets/from-jetson/frames/frames.json).
    // Corners from the Jetson's CUDA detector, in AprilTag order: BL, BR, TR, TL.
    const TAGS = [
      { id: 3, dm: 89.8, c: [507.4, 483.8], k: [[448.0, 576.9], [596.0, 533.6], [570.3, 394.6], [415.3, 430.0]] },
    ];
    const JPEG_BYTES = 52801;
    // The first bytes of that frame's real JPEG file (SOI, APP0 "AVI1", then a quantization table).
    const HEX = 'FF D8 FF E0 00 21 41 56 49 31 00 01 01 01 00 78 00 78 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 FF DB 00 43 00 06 04 05 05 05 04'.split(' ');
    const img = new Image();
    img.src = 'assets/from-jetson/frames/tag-close_TopLeft.png';
    let gray = null, thr = null, pix = null;
    img.onload = () => {
      // real pixel values from the lossless gray decode, around the tag's top-left corner
      const full = document.createElement('canvas'); full.width = IW; full.height = IH;
      const f = full.getContext('2d', { willReadFrequently: true }); f.drawImage(img, 0, 0);
      const fd = f.getImageData(398, 420, 28, 25).data;
      pix = [];
      for (let r = 0; r < 5; r++) { const row = []; for (let q = 0; q < 7; q++) row.push(fd[((r * 5) * 28 + q * 4) * 4]); pix.push(row); }
      const W = 640, H = 400;
      const mk = () => { const c = document.createElement('canvas'); c.width = W; c.height = H; return c; };
      gray = mk(); const g = gray.getContext('2d', { willReadFrequently: true });
      g.drawImage(img, 0, 0, W, H);
      const d = g.getImageData(0, 0, W, H).data;
      // illustrative adaptive threshold: compare each pixel with a blurred local mean
      const small = document.createElement('canvas'); small.width = 32; small.height = 20;
      const sm = small.getContext('2d', { willReadFrequently: true }); sm.drawImage(gray, 0, 0, 32, 20);
      const blur = mk(), b = blur.getContext('2d', { willReadFrequently: true }); b.imageSmoothingEnabled = true; b.drawImage(small, 0, 0, W, H);
      const bd = b.getImageData(0, 0, W, H).data;
      thr = mk(); const t = thr.getContext('2d'); const td = t.createImageData(W, H);
      for (let i = 0; i < d.length; i += 4) { const v = d[i] > bd[i] - 10 ? 255 : 0; td.data[i] = td.data[i + 1] = td.data[i + 2] = v; td.data[i + 3] = 255; }
      t.putImageData(td, 0, 0);
    };
    const MF = Math.ceil(JPEG_BYTES / 1280), USB_MS = MF * 0.125;

    const S = [
      { n: 'Light', t: '0 ms', ch: 'camera', cn: '03', d: 'Room light shines on tag 3, propped on a box in our shop. White squares reflect a lot of light, black ones very little. Some of that light heads into TopLeft\'s lens.', data: 'photons → lens → sensor' },
      { n: 'Exposure', t: '0 → 5 ms (likely)', ch: 'settings', cn: '04', d: 'Every pixel of the global-shutter sensor collects light at once, then each pixel\'s charge becomes a number: 0 is black, 255 is white. This recording didn\'t save its exposure; our setting then was 5 ms, so it was likely 5 ms.', data: () => 'real pixel values at the tag\'s top-left corner:\n' + (pix ? pix.map((r) => r.map((v) => String(v).padStart(3)).join(' ')).join('\n') : '…') },
      { n: 'JPEG', t: 'camera delay (?)', ch: 'camera', cn: '03', d: 'The camera compresses the 1,024,000 numbers into a JPEG, 8×8 pixel blocks at a time. This frame\'s JPEG is exactly 52,801 bytes, about 1/19 of the raw pixels. The time this takes inside the camera isn\'t measured yet.', data: 'the real first bytes of this frame:\n' + HEX.slice(0, 24).join(' ') + '\n' + HEX.slice(24).join(' ') + ' …\n(52,801 bytes in all)' },
      { n: 'USB', t: `+${USB_MS.toFixed(1)} ms`, ch: 'speed', cn: '10', chs: 'dataflow', cns: '07', d: 'The JPEG crosses USB 2.0 in slices of up to 1280 bytes, one slice every 125 µs microframe. The Linux driver stamps the frame when the first slice arrives.', data: `52,801 B ÷ 1280 B → ${MF} microframes\n${MF} × 125 µs ≈ ${USB_MS.toFixed(1)} ms\nshared bus: ~6,700 B per microframe for all cameras` },
      { n: 'Decode', t: '+2.6 ms', ch: 'dataflow', cn: '07', d: 'The Jetson\'s NVJPG hardware turns the JPEG back into a gray image in shared (unified) memory, where the GPU can read it without a copy across a bus. The picture here is that gray decode, pixel for pixel.', data: 'a gray image, 1 byte per pixel:\n1280 × 800 = 1,024,000 bytes\nNVJPG: 2.59 ms a frame (our Jetson\'s log)' },
      { n: 'Blobs', t: 'GPU, ~1–2 ms total', ch: 'cuda', cn: '08', d: 'Thousands of GPU threads threshold the image into black and white, then group touching pixels into blobs. The tag\'s black border pops out as a ring.', data: 'threshold → connected components → blob edges\n(1,024 CUDA cores, 32-thread warps)\nthe threshold view is an illustration' },
      { n: 'Corners', t: '(same GPU step)', ch: 'cuda', cn: '08', d: 'Blob edges are fit with four straight lines. Their crossings are the tag\'s corners, found to a fraction of a pixel. Then a few CPU threads read the inside as bits to get the ID. These are the corners our Jetson\'s detector really found.', data: () => TAGS.map((tg) => `tag ${tg.id}, decision margin ${tg.dm}:\n` + tg.k.map((pt) => `  (${pt[0].toFixed(1)}, ${pt[1].toFixed(1)})`).join('\n')).join('\n') },
      { n: 'Pose', t: '≈ <1 ms', ch: 'pose', cn: '12', d: 'With TopLeft\'s calibration (focal length 737.8 px, image center, 8 distortion numbers), PnP turns the four corners into the camera\'s 3D pose relative to the tag. With 2+ tags in view, one multi-tag solve would use every corner.', data: 'tag ≈151 px wide, fx ≈ 738 px\n→ about 0.8 m away, if it\'s a full-size 6.5 in tag\n(axes drawn for illustration)' },
      { n: 'Network', t: '≈ <1 ms', ch: 'networktables', cn: '15', d: 'PhotonVision packs the result, with its mid-exposure capture timestamp already on the robot\'s clock, and publishes it on NetworkTables to the SystemCore.', data: '/photonvision/TopLeft/rawBytes\n{ captureTimestampMicros, targets [ id 3,\n  corners, bestCameraToTarget, ambiguity ] }' },
      { n: 'Robot', t: 'next 20 ms loop', ch: 'latency', cn: '14', d: 'Robot code reads it with PhotonLib and calls addVisionMeasurement(pose, timestamp). The estimator corrects the pose at capture time and replays odometry, so the robot knows where it is.', data: 'estimator.estimateLowestAmbiguityPose(result)\ndrivetrain.addVisionMeasurement(\n    pose, e.timestampSeconds)' },
    ];
    const N = S.length, PER = 2.6;
    const cv = $('#fn-stage'), st = Site.canvas(cv, 0.625);
    const now = $('#fn-now'), scrub = $('#fn-scrub'), btn = $('#fn-play'), jr = $('#fn-journey');
    jr.innerHTML = S.map((s, i) => `<li><button data-i="${i}"><i>${s.chs ? `<span class="full">ch ${s.cn}</span><span class="short">ch ${s.cns}</span>` : `ch ${s.cn}`}</i><b>${i + 1}. ${s.n}</b><small>${s.t}</small><span class="fill"></span></button></li>`).join('');
    const lis = [...jr.children];
    addEventListener('site:mode', () => { shown = -1; });
    let T = 0, playing = false, shown = -1;
    const setT = (v) => { T = Site.clamp(v, 0, N * PER - 0.001); scrub.value = Math.round((T / (N * PER)) * 1000); };
    btn.onclick = () => { if (!playing && T >= N * PER - 0.01) setT(0); playing = !playing; btn.textContent = playing ? '❚❚ Pause' : '▶ Play'; };
    // update the text and chips at once, even if the canvas is scrolled off screen (its loop pauses then)
    const syncUI = () => { const i = Math.min(N - 1, Math.floor(T / PER)); if (i !== shown) { shown = i; info(i); } lis.forEach((li, j) => { li.classList.toggle('on', j === i); li.classList.toggle('done', j < i); }); };
    scrub.oninput = () => { T = (scrub.value / 1000) * N * PER; playing = false; btn.textContent = '▶ Play'; syncUI(); };
    jr.onclick = (e) => { const b = e.target.closest('button'); if (b) { setT(+b.dataset.i * PER + 0.01); playing = false; btn.textContent = '▶ Play'; syncUI(); } };
    const info = (i) => {
      const s0 = S[i], sh = document.body.classList.contains('mode-short') && s0.chs;
      const s = sh ? { ...s0, ch: s0.chs, cn: s0.cns } : s0;
      now.innerHTML = `<h5>Stage ${i + 1} of ${N} · chapter ${s.cn}</h5><h4>${s.n}</h4><span class="t">${s.t}</span><p>${s.d}</p><div class="data">${typeof s.data === 'function' ? s.data() : s.data}</div><p style="margin-bottom:0"><a href="#${s.ch}">Read chapter ${s.cn} →</a></p>`;
    };

    const Q = (tg) => [tg.k[3], tg.k[2], tg.k[1], tg.k[0]]; // TL, TR, BR, BL
    const drawImg = (ctx, w, h, src, alpha = 1) => { if (!src) return; ctx.globalAlpha = alpha; ctx.drawImage(src, 0, 0, w, h); ctx.globalAlpha = 1; };
    const label = (ctx, txt, x, y, col = '#fff', size = 13) => { if (y < 40 && ctx.canvas.clientWidth < 520) { y = ctx.canvas.clientHeight - 10; size = 11.5; } ctx.font = font(size, 700); const tw = ctx.measureText(txt).width; ctx.fillStyle = 'rgba(14,5,24,.78)'; ctx.fillRect(x - 6, y - size - 3, tw + 12, size + 9); ctx.fillStyle = col; ctx.textAlign = 'left'; ctx.fillText(txt, x, y); };
    const R = [
      // 0 light
      (ctx, w, h, p, t, k) => {
        drawImg(ctx, w, h, img.complete ? img : null, 0.35 + 0.25 * p);
        for (const tg of TAGS) {
          for (let i = 0; i < 14; i++) {
            const u = (t * 0.6 + i / 14) % 1, a = (i * 2.4) % (Math.PI * 2);
            const sx = tg.c[0] * k + Math.cos(a) * 18 * k, sy = tg.c[1] * k + Math.sin(a) * 18 * k;
            const ex = w * 0.5, ey = h * 1.08;
            ctx.fillStyle = `rgba(253,230,138,${0.9 * (1 - u)})`; ctx.beginPath(); ctx.arc(Site.lerp(sx, ex, u), Site.lerp(sy, ey, u), 2.4, 0, 7); ctx.fill();
          }
        }
        label(ctx, 'light bouncing off the tag toward the lens ↓', 12, 26, '#fde68a');
      },
      // 1 exposure
      (ctx, w, h, p) => {
        ctx.fillStyle = '#000'; ctx.fillRect(0, 0, w, h);
        drawImg(ctx, w, h, gray, Site.ease(Math.min(1, p * 1.4)));
        // pixel inset
        if (pix) {
          const cw = Math.min(w * (w < 520 ? 0.056 : 0.07), 34), x0 = w - cw * 7 - (w < 520 ? 10 : 22), y0 = w < 520 ? 62 : h - cw * 5 - 14;
          ctx.fillStyle = 'rgba(14,5,24,.85)'; ctx.fillRect(x0 - 8, y0 - 26, cw * 7 + 16, cw * 5 + 34);
          ctx.fillStyle = '#c4b5fd'; ctx.font = font(11, 700); ctx.textAlign = 'left'; ctx.fillText('pixel values', x0, y0 - 10);
          const f = Math.min(1, p * 1.4);
          pix.forEach((row, r) => row.forEach((v, q) => {
            const vv = Math.round(v * f);
            ctx.fillStyle = `rgb(${vv},${vv},${vv})`; ctx.fillRect(x0 + q * cw, y0 + r * cw, cw - 1, cw - 1);
            ctx.fillStyle = vv > 128 ? '#000' : '#fff'; ctx.font = font(Math.max(8, cw * 0.32), 600, true); ctx.textAlign = 'center'; ctx.fillText(vv, x0 + q * cw + cw / 2, y0 + r * cw + cw * 0.62);
          }));
        }
        label(ctx, `collecting light: ${(p * 5).toFixed(1)} of 5.0 ms`, 12, 26, '#c4b5fd');
      },
      // 2 JPEG
      (ctx, w, h, p, t) => {
        drawImg(ctx, w, h, gray);
        const bs = w / 80; // 8x8 blocks of the 640-wide gray, shown at canvas scale
        ctx.strokeStyle = 'rgba(139,92,246,.45)'; ctx.lineWidth = 1;
        const rows = Math.floor((h / bs) * p);
        for (let r = 0; r <= rows; r++) { ctx.beginPath(); ctx.moveTo(0, r * bs); ctx.lineTo(w, r * bs); ctx.stroke(); }
        for (let x = 0; x <= w; x += bs) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, rows * bs); ctx.stroke(); }
        ctx.font = font(Math.max(10, w / 60), 600, true); ctx.textAlign = 'left';
        const n = Math.floor(p * 40) + 6;
        let line = '';
        for (let i = 0; i < Math.min(n, HEX.length); i++) line += HEX[i] + ' ';
        const hy = w < 520 ? h - 64 : h - 40;
        ctx.fillStyle = 'rgba(14,5,24,.82)'; ctx.fillRect(0, hy, w, 36);
        ctx.fillStyle = '#a3e635'; ctx.fillText(line.slice(0, Math.floor(w / (Math.max(10, w / 60) * 0.62))), 10, hy + 23);
        label(ctx, `JPEG: 1,024,000 B of pixels → ${Math.round(Site.lerp(1024000, JPEG_BYTES, p)).toLocaleString('en-US')} B`, 12, 26, '#a3e635');
      },
      // 3 USB
      (ctx, w, h, p, t) => {
        ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
        const bw = w * 0.2, bx = w - bw - 14;
        ctx.fillStyle = '#251038'; ctx.strokeStyle = '#8b5cf6'; ctx.lineWidth = 2; ctx.beginPath(); ctx.roundRect(bx, h * 0.25, bw, h * 0.5, 12); ctx.fill(); ctx.stroke();
        ctx.fillStyle = '#fff'; ctx.font = font(Math.max(12, w / 42), 800); ctx.textAlign = 'center'; ctx.fillText('Jetson', bx + bw / 2, h * 0.5 + 5);
        ctx.strokeStyle = 'rgba(6,182,212,.5)'; ctx.lineWidth = 10; ctx.beginPath(); ctx.moveTo(w * 0.1, h * 0.5); ctx.lineTo(bx, h * 0.5); ctx.stroke();
        const total = Math.ceil(JPEG_BYTES / 1280), sent = Math.floor(p * total);
        for (let i = 0; i < 6; i++) {
          const u = (t * 1.6 + i / 6) % 1, x = Site.lerp(w * 0.1, bx - 10, u);
          ctx.fillStyle = i === 0 && sent < 2 ? '#f59e0b' : '#06b6d4'; ctx.fillRect(x - 9, h * 0.5 - 8, 18, 16);
        }
        // camera
        ctx.fillStyle = '#1f1b23'; ctx.strokeStyle = '#b8a9d4'; ctx.lineWidth = 2; ctx.beginPath(); ctx.roundRect(14, h * 0.38, w * 0.09, h * 0.24, 8); ctx.fill(); ctx.stroke();
        ctx.fillStyle = '#b8a9d4'; ctx.beginPath(); ctx.arc(14 + w * 0.045, h * 0.5, Math.min(w * 0.025, 14), 0, 7); ctx.fill();
        // packet counter bar
        const gx = w * 0.1, gw = bx - gx - 20, gy = h * 0.78;
        for (let i = 0; i < total; i++) { ctx.fillStyle = i < sent ? '#06b6d4' : 'rgba(255,255,255,.08)'; ctx.fillRect(gx + (i * gw) / total, gy, gw / total - 2, 14); }
        ctx.fillStyle = '#b8a9d4'; ctx.font = font(12, 600); ctx.textAlign = 'left'; ctx.fillText(`microframe ${sent} of ${total} · ${(sent * 0.125).toFixed(2)} ms · ${Math.min(JPEG_BYTES, sent * 1280).toLocaleString('en-US')} B`, gx, gy + 32);
        label(ctx, 'USB 2.0: ≤1280 bytes every 125 µs', 12, 26, '#67e8f9');
        if (sent < 3) { ctx.fillStyle = '#fcd34d'; ctx.font = font(12, 700); ctx.textAlign = 'left'; ctx.fillText('first packet → timestamp', gx, h * 0.5 - 20); }
      },
      // 4 decode
      (ctx, w, h, p) => {
        ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
        if (gray) { const hh = h * p; ctx.drawImage(gray, 0, 0, 640, 400 * p, 0, 0, w, hh); ctx.fillStyle = '#a3e635'; ctx.fillRect(0, hh - 2, w, 3); }
        label(ctx, `NVJPG decoding: ${Math.round(p * 100)}%`, 12, 26, '#a3e635');
      },
      // 5 blobs
      (ctx, w, h, p, t, k) => {
        drawImg(ctx, w, h, gray);
        ctx.save(); ctx.beginPath(); ctx.rect(0, 0, w * Math.min(1, p * 1.6), h); ctx.clip(); drawImg(ctx, w, h, thr); ctx.restore();
        if (p > 0.55) {
          const a = Math.min(1, (p - 0.55) * 3);
          const cols = ['#f472b6', '#38bdf8'];
          TAGS.forEach((tg, i) => {
            const q = Q(tg).map(([x, y]) => [x * k, y * k]);
            const cx = tg.c[0] * k, cy = tg.c[1] * k;
            // the black border ring is the blob: stroke along its middle, 1/8 of the tag wide
            ctx.strokeStyle = cols[i]; ctx.globalAlpha = a * 0.85; ctx.lineWidth = Math.hypot(q[1][0] - q[0][0], q[1][1] - q[0][1]) / 8;
            ctx.beginPath(); q.forEach(([x, y], j) => { const X = cx + (x - cx) * 0.875, Y = cy + (y - cy) * 0.875; j ? ctx.lineTo(X, Y) : ctx.moveTo(X, Y); }); ctx.closePath(); ctx.stroke();
            ctx.globalAlpha = 1;
          });
        }
        label(ctx, p < 0.55 ? 'threshold: black or white' : 'blobs: the tag borders (colored)', 12, 26, '#f9a8d4');
      },
      // 6 corners
      (ctx, w, h, p, t, k) => {
        drawImg(ctx, w, h, gray);
        TAGS.forEach((tg) => {
          const q = Q(tg).map(([x, y]) => [x * k, y * k]);
          const n = Math.min(4, Math.floor(p * 6));
          ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2.5; ctx.beginPath();
          for (let j = 0; j < Math.min(4, n + 1); j++) { const [x, y] = q[j]; j ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
          if (n >= 4) ctx.closePath(); ctx.stroke();
          for (let j = 0; j < n; j++) { ctx.fillStyle = '#f43f5e'; ctx.beginPath(); ctx.arc(q[j][0], q[j][1], 4.5, 0, 7); ctx.fill(); }
          if (p > 0.7) label(ctx, `ID ${tg.id}`, tg.c[0] * k - 18, q[0][1] - 10, '#a3e635');
        });
        label(ctx, 'four corners per tag, sub-pixel; bits read → ID', 12, 26, '#a3e635');
      },
      // 7 pose
      (ctx, w, h, p, t, k) => {
        drawImg(ctx, w, h, gray);
        TAGS.forEach((tg) => {
          const q = Q(tg).map(([x, y]) => [x * k, y * k]);
          ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.beginPath(); q.forEach(([x, y], j) => (j ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.closePath(); ctx.stroke();
          const cx = tg.c[0] * k, cy = tg.c[1] * k, L = 95 * k * Site.ease(Math.min(1, p * 1.5));
          const ax = (dx, dy, col) => { ctx.strokeStyle = col; ctx.lineWidth = 3.5; ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + dx, cy + dy); ctx.stroke(); };
          ax(L, 0, '#ef4444'); ax(0, -L, '#22c55e'); ax(-L * 0.55, L * 0.55, '#3b82f6');
        });
        if (p > 0.5) {
          // the camera looks at the tag: a ray from the lens
          ctx.setLineDash([5, 5]); ctx.strokeStyle = 'rgba(196,181,253,.8)'; ctx.lineWidth = 1.5;
          TAGS.forEach((tg) => { ctx.beginPath(); ctx.moveTo(w * 0.5, h * 1.02); ctx.lineTo(tg.c[0] * k, tg.c[1] * k); ctx.stroke(); });
          ctx.setLineDash([]);
        }
        label(ctx, 'PnP: corners + calibration → 3D pose', 12, 26, '#c4b5fd');
      },
      // 8 network
      (ctx, w, h, p) => {
        ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
        const nw = w < 520, y = h * (nw ? 0.66 : 0.52), x0 = w * (nw ? 0.13 : 0.1), x1 = w * (nw ? 0.87 : 0.9), bw = w * (nw ? 0.24 : 0.18);
        ctx.strokeStyle = '#06b6d4'; ctx.lineWidth = 6; ctx.beginPath(); ctx.moveTo(x0, y); ctx.lineTo(x1, y); ctx.stroke();
        const box = (x, txt, col) => { ctx.fillStyle = '#251038'; ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.beginPath(); ctx.roundRect(x - bw / 2, y - h * 0.11, bw, h * 0.22, 10); ctx.fill(); ctx.stroke(); ctx.fillStyle = '#fff'; ctx.font = font(nw ? 10 : Math.max(11, w / 50), 800); ctx.textAlign = 'center'; ctx.fillText(txt, x, y + 5); };
        box(x0, 'Jetson', '#8b5cf6'); box(x1, 'SystemCore', '#f59e0b');
        const pw = Math.min(w * (nw ? 0.62 : 0.36), 230), ph = h * (nw ? 0.3 : 0.34), px = Site.lerp(x0 + pw / 2 - bw / 2, x1 - pw / 2 + bw / 2, Site.ease(p));
        ctx.fillStyle = 'rgba(163,230,53,.14)'; ctx.strokeStyle = '#a3e635'; ctx.lineWidth = 2; ctx.beginPath(); ctx.roundRect(px - pw / 2, y - h * 0.15 - ph, pw, ph, 10); ctx.fill(); ctx.stroke();
        ctx.fillStyle = '#e9ddf7'; ctx.font = font(Math.max(9, Math.min(12, w / 60)), 500, true); ctx.textAlign = 'left';
        const lines = nw ? ['rawBytes · timestamp', 'target: id 3', 'corners, pose'] : ['rawBytes', 'timestamp: capture (robot clock)', 'target: id 3', 'corners, pose, ambiguity'];
        lines.forEach((s, i) => ctx.fillText(s, px - pw / 2 + 10, y - h * 0.15 - ph + 18 + i * (ph - 20) / (lines.length - 1)));
        ctx.fillStyle = '#b8a9d4'; ctx.font = font(12, 600); ctx.textAlign = 'center'; ctx.fillText('10.85.15.15  →  10.85.15.2 : 5810', w / 2, y + h * (nw ? 0.2 : 0.2));
        label(ctx, 'NetworkTables 4 over Ethernet', 12, 26, '#a3e635');
      },
      // 9 robot
      (ctx, w, h, p, t) => {
        ctx.fillStyle = '#1b0d2c'; ctx.fillRect(0, 0, w, h);
        const m = w / 5; // 5 m shown across
        ctx.strokeStyle = 'rgba(196,181,253,.3)'; ctx.lineWidth = 1;
        for (let x = 0; x < w; x += m) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke(); }
        for (let y = 0; y < h; y += m) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); }
        // the shop wall with tag 3
        const sx = w - 10, sy = h / 2;
        ctx.fillStyle = '#6b1199'; ctx.fillRect(sx - 12, 0, 12, h);
        ctx.fillStyle = '#fff'; ctx.fillRect(sx - 18, sy - m * 0.08, 6, m * 0.165);
        const rx = sx - 18 - 0.8 * m - m * 0.4, ry = sy; // ~0.8 m from the tag
        const odo = [rx - m * 0.35, ry + m * 0.25];
        const u = Site.ease(Site.clamp((p - 0.3) / 0.4, 0, 1));
        const ex = Site.lerp(odo[0], rx, u), ey = Site.lerp(odo[1], ry, u);
        // true robot
        ctx.fillStyle = 'rgba(124,58,237,.9)'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.fillRect(rx - m * 0.4, ry - m * 0.4, m * 0.8, m * 0.8); ctx.strokeRect(rx - m * 0.4, ry - m * 0.4, m * 0.8, m * 0.8);
        // estimate
        ctx.strokeStyle = u >= 1 ? '#a3e635' : '#f59e0b'; ctx.setLineDash([5, 4]); ctx.strokeRect(ex - m * 0.4, ey - m * 0.4, m * 0.8, m * 0.8); ctx.setLineDash([]);
        if (p > 0.15 && p < 0.75) { ctx.strokeStyle = 'rgba(163,230,53,.8)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(rx + m * 0.4, ry); ctx.lineTo(sx - 18, sy); ctx.stroke(); }
        ctx.fillStyle = u >= 1 ? '#a3e635' : '#fcd34d'; ctx.font = font(12, 700); ctx.textAlign = 'center';
        ctx.fillText(u >= 1 ? 'estimate corrected' : 'odometry estimate (drifted)', ex, ey - m * 0.55);
        label(ctx, 'robot pose on the field (illustration)', 12, 26, '#a3e635');
      },
    ];
    Site.loop(cv, (t, dt) => {
      if (playing) { T += dt; if (T >= N * PER) { T = N * PER - 0.001; playing = false; btn.textContent = '↺ Replay'; } scrub.value = Math.round((T / (N * PER)) * 1000); }
      const i = Math.min(N - 1, Math.floor(T / PER)), p = (T - i * PER) / PER;
      if (i !== shown || (i === 1 && pix && !now.textContent.includes(String(pix[0][0])))) { shown = i; info(i); }
      lis.forEach((li, j) => { li.classList.toggle('on', j === i); li.classList.toggle('done', j < i); li.querySelector('.fill').style.width = j < i ? '100%' : j === i ? (p * 100).toFixed(0) + '%' : '0'; });
      const { ctx, w, h } = st;
      ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
      R[i](ctx, w, h, Site.clamp(p * 1.15, 0, 1), t, w / IW);
      // running clock (after the camera stage, the camera's own unmeasured delay is added as "+ cam")
      const u0 = 5 + USB_MS, u1 = u0 + 2.6, u2 = u1 + 1.6; // exposure (likely 5), USB, NVJPG 2.6, detect ~1.6 with a tag
      const A = [0, 0, 5, 5, u0, u1, u2, u2, u2 + 0.5, u2 + 1], B = [0, 5, 5, u0, u1, u2, u2, u2 + 0.5, u2 + 1, u2 + 1];
      const cur = Site.lerp(A[i], B[i], Site.clamp(p * 1.15, 0, 1));
      ctx.font = font(w < 520 ? 11 : 13, 700, true); const txt = `≈ ${cur.toFixed(1)} ms${i >= 2 ? ' + cam' : ''}${i === 9 ? ' + loop' : ''}`; const tw = ctx.measureText(txt).width;
      ctx.fillStyle = 'rgba(14,5,24,.8)'; ctx.fillRect(w - tw - 22, 8, tw + 14, 24); ctx.fillStyle = '#fff'; ctx.textAlign = 'right'; ctx.fillText(txt, w - 15, 25);
    });
  }

  /* ── Quiz ──────────────────────────────────────────────── */
  {
    const QS = [
      ['What does the pattern inside an AprilTag tell the robot?', ['Its distance to the tag', 'Which tag it is (an ID number)', 'The robot\'s team number', 'The match time'], 1, 'The squares encode an ID (36 data bits in tag36h11). The field map says where each ID is mounted.', 'apriltags'],
      ['Why use a global-shutter camera on a moving robot?', ['It records color', 'Every pixel captures at the same instant, so motion isn\'t skewed', 'It doesn\'t need USB', 'It focuses itself'], 1, 'A rolling shutter reads rows one after another, so a fast-moving tag comes out slanted.', 'camera'],
      ['PhotonVision\'s exposure was set to 295. How long was each exposure?', ['0.3 ms', '2.95 ms', '29.5 ms', '295 ms'], 2, 'USB cameras count exposure in 100 µs units. 29.5 ms capped the camera near 34 fps; we run 50 (5 ms).', 'settings', 'full'],
      ['Why could only two cameras stream with the stock camera driver?', ['The GPU was full', 'Each reserved ~196 Mbps of one shared USB 2.0 budget', 'The Jetson has only two USB ports', 'The CPU was full'], 1, 'Every USB 2.0 port shares one bus of about 6,700 bytes per microframe. Our driver caps each camera so four fit.', 'speed', 'full'],
      ['What took both cameras to 122 fps?', ['A faster GPU', 'Turning Low Latency Mode on', 'Decoding the JPEG straight to gray: 8.9 → 2.6 ms', 'Lowering the resolution'], 2, 'cscore secretly decoded each frame to full color first. The GPU was never the bottleneck.', 'speed', 'full'],
      ['What is NVJPG?', ['A brand of camera', 'A JPEG decoder built into the Jetson\'s chip', 'A NetworkTables topic', 'A PhotonVision pipeline'], 1, 'Hardware decode, ~2.6 ms a frame, took PhotonVision from 0.85 to 0.52 CPU cores. We check its frames against the CPU decoder.', 'dataflow', 'full'],
      ['What\'s special about the Jetson\'s memory?', ['It has no RAM', 'The CPU and GPU share the same RAM', 'It stores images on the SSD', 'The GPU has its own 8 GB'], 1, 'Unified memory: a decoded image is already where the GPU can read it, with no copy across a slow bus.', 'dataflow'],
      ['On an NVIDIA GPU, a warp is…', ['32 threads that run the same instruction together', 'One CUDA core', 'A distorted image', 'A memory chip'], 0, 'The GPU schedules threads in warps of 32. Code runs fastest when all 32 do the same thing.', 'cuda', 'full'],
      ['What is a patch file, like photonvision-13?', ['A firmware image', 'A list of lines to remove and add in someone else\'s code', 'A calibration file', 'A cable repair'], 1, 'Our build scripts apply our patches to PhotonVision and the detector automatically, so every fix is small and reviewable.', 'photonvision', 'full'],
      ['Which of these are camera intrinsics, found by calibration?', ['Where the camera is mounted on the robot', 'Focal length, image center and lens distortion', 'Exposure and brightness', 'The camera\'s USB port'], 1, 'Our cameras\' focal length came out at about 737 px. The mount position is the extrinsics.', 'calibration'],
      ['Why is a multi-tag pose more trustworthy than one tag?', ['It\'s computed faster', 'One small tag can look nearly the same from two poses; more tags pin down one answer', 'It needs no calibration', 'It uses less USB bandwidth'], 1, 'A single square tag often has an ambiguous "flipped" pose. Corners from several tags at once remove the ambiguity.', 'pose'],
      ['How does the robot\'s gyro help vision?', ['It measures distance to tags', 'Its very accurate heading lets the solver fix the heading and reject wrong poses', 'It cleans the lens', 'It replaces odometry'], 1, 'Heading-constrained solves (like MegaTag2) hold the heading to the gyro and only solve position.', 'gyro', 'full'],
      ['A robot drives 4 m/s and treats a 15 ms old vision pose as "now." How far off is it?', ['0.6 mm', '6 cm', '60 cm', '6 m'], 1, '4 m/s × 0.015 s = 0.06 m. The fix: addVisionMeasurement(pose, timestamp).', 'latency'],
      ['In NetworkTables 4, where does the server run?', ['On the Jetson', 'In the robot program on the SystemCore', 'On the driver station', 'In the cloud'], 1, 'PhotonVision and dashboards are clients that connect on port 5810 and publish or subscribe to topics.', 'networktables'],
      ['What does the Jetson\'s hardware watchdog do?', ['Resets the board if Linux stops "petting" it for 30 s', 'Checks lens focus', 'Watches for other robots', 'Cools the GPU'], 0, 'systemd pets it regularly. If Linux freezes, the petting stops and the hardware resets the Jetson.', 'failsafes'],
    ];
    // spread the right answers across positions: rotate each question's options by a fixed amount
    QS.forEach((q, i) => { const r = (i * 3 + 2) % 4, o = q[1]; q[1] = o.map((_, j) => o[(j + r) % o.length]); q[2] = (q[2] - r + o.length) % o.length; });
    const KEY = 'spectrum-vision-quiz-v2';
    let ans = {};
    try { ans = JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (e) { ans = {}; }
    const save = () => { try { localStorage.setItem(KEY, JSON.stringify(ans)); } catch (e) { /* storage blocked: answers just aren't kept */ } };
    const qz = $('#fn-quiz');
    // a 6th element 'full' marks a question only the full course teaches: hidden (and not scored) in short mode
    qz.innerHTML = QS.map(([q, opts, , , , only], i) => `<div class="q${only === 'full' ? ' full' : ''}" data-i="${i}"><h4><span>${i + 1}</span>${q}</h4><div class="opts">${opts.map((o, j) => `<button data-j="${j}">${o}</button>`).join('')}</div><div class="fb"></div></div>`).join('');
    const sc = $('#fn-sc'), bar = $('#fn-bar'), msg = $('#fn-msg');
    const show = (i) => {
      const card = qz.children[i], a = ans[i], [, , right, why, ch] = QS[i];
      const btns = card.querySelectorAll('.opts button');
      btns.forEach((b, j) => { b.disabled = a !== undefined; b.classList.toggle('right', a !== undefined && j === right); b.classList.toggle('wrong', a !== undefined && j === a && a !== right); });
      const fb = card.querySelector('.fb');
      fb.classList.toggle('show', a !== undefined);
      if (a !== undefined) fb.innerHTML = `<b class="${a === right ? 'ok' : 'no'}">${a === right ? 'Right.' : 'Not quite.'}</b> ${why} <a href="#${ch}">Review →</a>`;
    };
    const visible = () => QS.map((_, i) => i).filter((i) => !(document.body.classList.contains('mode-short') && QS[i][5] === 'full'));
    const score = () => {
      const vis = visible(), n = vis.length;
      // number the visible questions 1..n
      vis.forEach((i, k) => (qz.children[i].querySelector('h4 span').textContent = k + 1));
      const done = vis.filter((i) => ans[i] !== undefined).length, ok = vis.filter((i) => ans[i] === QS[i][2]).length;
      sc.textContent = `${ok} / ${n}`; bar.style.width = (100 * ok / n) + '%';
      msg.textContent = done === 0 ? 'Pick an answer to start.' : done < n ? `${n - done} to go.` : ok === n ? 'Perfect score. You know how our robot sees.' : ok >= Math.round(n * 0.8) ? 'Great job. Review the ones you missed.' : 'Done. Follow the review links and try again.';
    };
    qz.onclick = (e) => {
      const b = e.target.closest('.opts button'); if (!b || b.disabled) return;
      const i = +b.closest('.q').dataset.i; ans[i] = +b.dataset.j; save(); show(i); score();
    };
    $('#fn-reset').onclick = () => { ans = {}; save(); QS.forEach((_, i) => show(i)); score(); };
    QS.forEach((_, i) => show(i)); score();
    addEventListener('site:mode', score);
  }

  /* ── Glossary ──────────────────────────────────────────── */
  {
    const dl = $('#fn-gloss'), input = $('#fn-gsearch'), count = $('#fn-gcount');
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
    const build = () => {
      const keys = Object.keys(Site.glossary).sort((a, b) => a.localeCompare(b, 'en', { sensitivity: 'base' }));
      let html = '', letter = '';
      for (const k of keys) {
        const L = /[a-z]/i.test(k[0]) ? k[0].toUpperCase() : '#';
        if (L !== letter) { letter = L; html += `<div class="letter" data-l="${L}">${L}</div>`; }
        html += `<div class="g" data-l="${L}" data-s="${esc((k + ' ' + Site.glossary[k]).toLowerCase())}"><dt>${esc(k)}</dt><dd>${esc(Site.glossary[k])}</dd></div>`;
      }
      dl.innerHTML = html;
      filter();
    };
    const filter = () => {
      const q = input.value.trim().toLowerCase();
      let n = 0; const seen = new Set();
      dl.querySelectorAll('.g').forEach((g) => { const on = !q || g.dataset.s.includes(q); g.hidden = !on; if (on) { n++; seen.add(g.dataset.l); } });
      dl.querySelectorAll('.letter').forEach((l) => (l.hidden = !seen.has(l.dataset.l)));
      count.textContent = `${n} term${n === 1 ? '' : 's'}`;
    };
    input.addEventListener('input', filter);
    build();
    // chapters that load later may add terms; rebuild once the page has settled
    setTimeout(build, 3000);
  }
});
