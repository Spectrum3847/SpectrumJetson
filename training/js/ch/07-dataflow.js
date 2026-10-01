// Chapter 07: a frame's journey through the Jetson, and why a GPU beats a Pi's CPU.
Site.chapter('dataflow', (root) => {
  ladder(root);
  journey(root);
  latency(root);
  threads(root);
});

/* ── Memory ladder (log-scale sizes) ────────────────── */
function ladder(root) {
  const R = [
    ['CPU L2 cache', '1.5 MB total, next to the cores', 1.5e6, '#a78bfa', '1.5 MB'],
    ['CPU L3 cache', 'shared by all 6 cores', 4e6, '#a78bfa', '4 MB'],
    ['RAM (LPDDR5)', '102 GB/s, shared by CPU and GPU', 8e9, '#a3e635', '8 GB · 1 MB frame in ~10 µs'],
    ['SSD (NVMe)', 'permanent: Linux, recordings', 256e9, '#67e8f9', '256 GB'],
    ['One camera\'s USB share', '10.2 MB/s: raw frame 100 ms, JPEG ~5 ms', 10.24e6, '#fbbf24', '10.2 MB each second'],
  ];
  const lo = Math.log10(1e5), hi = Math.log10(256e9);
  root.querySelector('#d-ladder').innerHTML = R.map(([t, s, v, c, l]) =>
    `<div class="rung"><div><b>${t}</b><small>${s}</small></div><div><div class="bar" style="width:${Math.max(12, (100 * (Math.log10(v) - lo)) / (hi - lo))}%;background:${c}">${l}</div></div></div>`).join('');
}

/* ── The journey scrolly ────────────────────────────── */
function journey(root) {
  const svg = root.querySelector('#d-jv'), clock = root.querySelector('#d-clock'), note = root.querySelector('#d-clock-note');
  const B = {
    cam: [20, 14, 140, 66, 'Camera', 'Thriftiest Cam'],
    robot: [320, 14, 140, 66, 'SystemCore', 'robot controller'],
    usb: [30, 140, 128, 62, 'USB', 'controller'],
    cpu: [176, 140, 128, 62, 'CPU', '6 cores'],
    jpg: [322, 140, 128, 62, 'NVJPG', 'JPEG engine'],
    ram: [30, 230, 420, 120, 'RAM', 'LPDDR5, shared by all'],
    gpu: [30, 380, 200, 66, 'GPU', '1,024 CUDA cores'],
    eth: [250, 380, 200, 66, 'Ethernet', 'NetworkTables'],
  };
  const S = { s1: [48, 280, 120, 52, 'JPEG · 50 KB'], s2: [180, 280, 120, 52, 'gray · 1 MB'], s3: [312, 280, 120, 52, 'corners'] };
  const c = (id) => { const [x, y, w, h] = B[id] || S[id]; return { x, y, w, h, cx: x + w / 2, cy: y + h / 2, b: y + h }; };
  // wires: id -> polyline points
  const W = {
    camusb: [[c('cam').cx - 20, c('cam').b], [c('cam').cx - 20, 110], [c('usb').cx, 110], [c('usb').cx, c('usb').y]],
    usbs1: [[c('usb').cx, c('usb').b], [c('usb').cx, c('s1').y]],
    cpus1: [[c('cpu').cx - 30, c('cpu').b], [c('cpu').cx - 30, 258], [c('s1').cx + 30, 258], [c('s1').cx + 30, c('s1').y]],
    s1jpg: [[c('s1').cx + 45, c('s1').y], [c('s1').cx + 45, 266], [c('jpg').cx - 20, 266], [c('jpg').cx - 20, c('jpg').b]],
    jpgs2: [[c('jpg').cx + 20, c('jpg').b], [c('jpg').cx + 20, 272], [c('s2').cx, 272], [c('s2').cx, c('s2').y]],
    s2gpu: [[c('s2').cx, c('s2').b], [c('s2').cx, 366], [c('gpu').cx + 40, 366], [c('gpu').cx + 40, c('gpu').y]],
    gpus3: [[c('gpu').cx + 80, c('gpu').y], [c('gpu').cx + 80, 360], [c('s3').cx, 360], [c('s3').cx, c('s3').b]],
    s3cpu: [[c('s3').cx - 30, c('s3').y], [c('s3').cx - 30, 250], [c('cpu').cx + 30, 250], [c('cpu').cx + 30, c('cpu').b]],
    cpueth: [[c('cpu').x + c('cpu').w, c('cpu').cy + 18], [314, c('cpu').cy + 18], [314, 364], [c('eth').cx, 364], [c('eth').cx, c('eth').y]],
    ethrobot: [[c('eth').x + c('eth').w, c('eth').cy], [468, c('eth').cy], [468, 100], [c('robot').cx, 100], [c('robot').cx, c('robot').b]],
  };
  const pts = (p) => p.map((q) => q.join(',')).join(' ');
  let h = `<rect x="10" y="118" width="460" height="342" rx="16" fill="none" stroke="rgba(196,181,253,.35)" stroke-dasharray="6 6"/><text class="fl" x="24" y="474">Jetson Orin Nano</text>`;
  for (const [id, [x, y, w, hh, t, s]] of Object.entries(B)) {
    h += `<g class="b" data-b="${id}"><rect x="${x}" y="${y}" width="${w}" height="${hh}" rx="10"/><text x="${x + 14}" y="${y + 26}">${t}</text><text class="s" x="${x + 14}" y="${id === 'ram' ? y + hh - 8 : y + 46}">${s}</text></g>`;
  }
  for (const [id, p] of Object.entries(W)) h += `<polyline class="w" data-w="${id}" points="${pts(p)}"/>`;

  for (const [id, [x, y, w, hh, t]] of Object.entries(S)) h += `<g class="slot" data-s="${id}"><rect x="${x}" y="${y}" width="${w}" height="${hh}" rx="8"/><text x="${x + w / 2}" y="${y + 31}" text-anchor="middle">${t}</text></g>`;
  h += `<text x="240" y="506" text-anchor="middle" style="font:500 12px var(--font);fill:#b8a9d4" id="d-cap"></text>`;
  h += `<g id="d-tok" opacity="0"><rect x="-26" y="-11" width="52" height="22" rx="5" fill="#a3e635"/><text id="d-tok-t" y="4" text-anchor="middle" style="font:700 10.5px var(--mono);fill:#1a0a2b"></text></g>`;
  svg.innerHTML = h;
  const tok = svg.querySelector('#d-tok'), tokT = svg.querySelector('#d-tok-t'), cap = svg.querySelector('#d-cap');

  // step: boxes lit, wires (in order) the token rides, slots filled, token label, clock, caption
  const STEPS = [
    { b: ['cam'], w: [], s: [], tok: '', t: '0 ms', note: 'mid-exposure: the timestamp', cap: 'global shutter: all pixels at once' },
    { b: ['cam', 'usb'], w: ['camusb'], s: [], tok: 'JPEG', t: '≈ 10.6 ms + ?', note: '? = camera delay before sending, not measured yet', cap: 'streamed over 8.1 ms in 1280-byte slices' },
    { b: ['usb', 'ram'], w: ['usbs1'], s: ['s1'], tok: 'JPEG', t: '≈ 10.6 ms + ?', note: 'ms: DMA, no CPU', cap: 'USB controller → RAM by DMA' },
    { b: ['cpu', 'ram'], w: ['cpus1'], s: ['s1'], tok: 'ready', t: '≈ 10.8 ms + ?', note: 'ms: uvcvideo marks it done', cap: 'the kernel driver runs on the CPU' },
    { b: ['cpu'], w: ['cpus1'], s: ['s1'], tok: 'grab', t: '≈ 10.8 ms + ?', note: 'ms: PhotonVision has it', cap: 'raw JPEG handed over, not decoded' },
    { b: ['jpg', 'ram'], w: ['s1jpg', 'jpgs2'], s: ['s1', 's2'], tok: 'decode', t: '≈ 13.6 ms + ?', note: 'ms: NVJPG ~2.8 ms', cap: '50 KB JPEG → 1 MB gray image' },
    { b: ['gpu', 'ram'], w: ['s2gpu'], s: ['s2'], tok: 'gray', t: '≈ 13.6 ms + ?', note: 'ms: already in a GPU buffer', cap: 'unified memory: no PCIe trip' },
    { b: ['gpu'], w: ['gpus3'], s: ['s2', 's3'], tok: 'corners', t: '≈ 14.8 ms + ?', note: 'ms: GPU detect ~1.2 ms', cap: '1,024 cores, then 4 corners per tag' },
    { b: ['cpu'], w: ['s3cpu'], s: ['s3'], tok: 'pose', t: '≈ 15 ms + ?', note: 'ms: solvePnP on the CPU', cap: 'corners → camera pose' },
    { b: ['eth', 'robot'], w: ['cpueth', 'ethrobot'], s: [], tok: 'NT', t: '≈ 15 ms + ?', note: 'ms: at the robot', cap: 'NetworkTables over Ethernet' },
    { b: ['cam', 'usb', 'jpg', 'gpu', 'cpu', 'eth'], w: Object.keys(W), s: ['s1', 's2', 's3'], tok: '', t: '8.3 ms', note: 'between frames at 120 fps', cap: 'several frames in flight at once' },
  ];
  let cur = STEPS[0], t0 = 0;
  const apply = (i) => {
    cur = STEPS[i];
    svg.querySelectorAll('.b').forEach((e) => e.classList.toggle('on', cur.b.includes(e.dataset.b)));
    svg.querySelectorAll('.w').forEach((e) => e.classList.toggle('on', cur.w.includes(e.dataset.w)));
    svg.querySelectorAll('.slot').forEach((e) => e.classList.toggle('full', cur.s.includes(e.dataset.s)));
    clock.textContent = cur.t;
    note.textContent = cur.note.replace(/^ms: /, '');
    cap.textContent = cur.cap;
    tokT.textContent = cur.tok;
    t0 = performance.now();
  };
  Site.scrolly(root.querySelector('#d-scrolly'), apply);
  apply(0);
  // token rides the step's wires in order, looping
  Site.loop(svg, () => {
    const path = cur.w.length && cur.tok ? cur.w.flatMap((id) => W[id]) : null;
    if (!path) { tok.setAttribute('opacity', 0); return; }
    let len = 0; const segs = [];
    for (let i = 1; i < path.length; i++) { const l = Math.hypot(path[i][0] - path[i - 1][0], path[i][1] - path[i - 1][1]); segs.push(l); len += l; }
    const u = Site.reduced ? 1 : Math.min(1, ((performance.now() - t0) / 1000) % 2.2 / 1.6);
    let d = Site.ease(u) * len, i = 0;
    while (i < segs.length - 1 && d > segs[i]) { d -= segs[i]; i++; }
    const f = segs[i] ? d / segs[i] : 0, a = path[i], b = path[i + 1] || a;
    tok.setAttribute('transform', `translate(${a[0] + (b[0] - a[0]) * f} ${a[1] + (b[1] - a[1]) * f})`);
    tok.setAttribute('opacity', 1);
  });
}

/* ── Latency bar ────────────────────────────────────── */
function latency(root) {
  const bar = root.querySelector('#d-latbar'), axis = root.querySelector('#d-lataxis'), desc = root.querySelector('#d-latdesc');
  let usb = 'ours', sel = null;
  const SEG = () => [
    ['exp', 'half exposure', 2.5, 'calc', '#c4b5fd', '<b>Half the exposure, 2.5 ms (from our 5 ms setting).</b> The timestamp marks mid-exposure, so the second half of the exposure already counts as delay.'],
    ['cam', 'camera', 1.2, 'unk', '', '<b>Camera delay before its first USB packet: not measured yet.</b> Any time between the end of the exposure and the camera starting to send. We plan to measure it on the robot by spinning in front of a tag (drawn here at an arbitrary width, and left out of the total).'],
    ['usb', 'camera sends', 8.1, usb === 'ours' ? '' : 'est', '#fbbf24', usb === 'ours' ? '<b>The camera sending the frame, 8.1 ms</b> (measured with the driver\'s own log, first packet to last, on every camera). The camera streams the JPEG out over about one frame period while its sensor reads out. At our 1280-byte cap a 34 KB frame could cross in 3.4 ms, so the cap costs no latency.' : '<b>The same ≈ 8.1 ms.</b> We first estimated the stock driver\'s bigger booking (3060 bytes per 125 µs) would save about 2 ms here. Measured with 4 capped cameras, the cap costs nothing: the camera, not USB, sets the pace. And with the stock driver only 2 cameras fit.'],
    ['wait', '', 0.15, '', '#86efac', '<b>Last packet to decode start, 0.15 ms</b> (measured, from the same kernel log).'],
    ['dec', 'decode', 2.8, '', '#a3e635', '<b>JPEG decode on NVJPG, ~2.8 ms</b> (measured, 5 cameras sharing the 2 engines). Almost no CPU. The decoder also leaves the gray frame in a GPU buffer, so the detector needs no upload.'],
    ['det', 'GPU', 1.2, '', '#22d3ee', '<b>GPU AprilTag detection, ~1.2 ms</b> per 1280×800 frame (measured, 4 cameras; 2.1 ms with 5 facing bright lights).'],
    ['pose', 'pose', 0.5, 'est', '#f9a8d4', '<b>Pose solve and publishing, ≈ 0.5 ms (estimated).</b> A fraction of a millisecond, not separately measured. PhotonVision\'s dashboard shows 14.3–15.2 ms from mid-exposure to the result.'],
    ['net', '', 0.5, 'unk', '', '<b>Network to the SystemCore: not measured</b> (probably well under a millisecond on a wired robot network). Left out of the total.'],
  ];
  const draw = () => {
    const segs = SEG(), total = segs.reduce((a, s) => a + s[2], 0);
    bar.innerHTML = segs.map(([id, l, ms, cls, col]) => `<div data-id="${id}" class="${cls}${sel === id ? ' sel' : ''}" style="width:${(100 * ms) / total}%;${col ? `background-color:${col}` : ''}"><span>${l}</span><small>${cls === 'unk' ? '?' : (cls ? '≈' : '') + ms + ' ms'}</small></div>`).join('');
    const known = segs.filter((s) => s[3] !== 'unk').reduce((a, s) => a + s[2], 0);
    let marks = '<span style="left:0;transform:none">0</span>';
    marks += `<span style="left:100%;transform:translateX(-100%)">≈ ${known.toFixed(1)} ms known + ?</span>`;
    axis.innerHTML = marks;
    const s = segs.find((q) => q[0] === sel);
    desc.innerHTML = s ? s[5] : `Total of the known parts: <b>≈ ${known.toFixed(1)} ms</b> from mid-exposure to a result ready to send. The blocks are tappable.`;
  };
  bar.addEventListener('click', (e) => { const d = e.target.closest('[data-id]'); sel = d && d.dataset.id !== sel ? d.dataset.id : null; draw(); });
  Site.seg(root.querySelector('#d-lat-seg'), (v) => { usb = v; draw(); });
}

/* ── CPU vs GPU race ────────────────────────────────── */

function threads(root) {
  const svg = root.querySelector('#d-thr');
  const ST = [['grab', 60], ['decode', 150], ['detect', 250], ['solve', 340], ['send', 420]];
  let h = '';
  const lanes = [['TopLeft', 50, '#c4b5fd'], ['TopRight', 196, '#f9a8d4']];
  // shared GPU in the middle
  h += `<rect x="208" y="98" width="84" height="54" rx="10" fill="rgba(34,211,238,.15)" stroke="#22d3ee" stroke-width="1.5"/><text x="250" y="122" text-anchor="middle" fill="#67e8f9" style="font:700 13px var(--font-heading)">GPU</text><text x="250" y="139" text-anchor="middle" fill="#b8a9d4" style="font:500 10.5px var(--font)">shared</text>`;
  for (const [name, y, col] of lanes) {
    h += `<text x="14" y="${y - 22}" fill="${col}" style="font:700 12px var(--font)">${name} thread</text>`;
    h += `<line x1="30" y1="${y}" x2="440" y2="${y}" stroke="rgba(196,181,253,.2)" stroke-width="2"/>`;
    for (const [s, x] of ST) h += `<rect x="${x - 34}" y="${y - 14}" width="68" height="28" rx="7" fill="#221236" stroke="rgba(196,181,253,.3)"/><text x="${x}" y="${y + 4}" text-anchor="middle" fill="#f4efff" style="font:600 11.5px var(--font)">${s}</text>`;
    h += `<line x1="250" y1="${y + (y < 100 ? 14 : -14)}" x2="250" y2="${y < 100 ? 98 : 152}" stroke="#22d3ee" stroke-dasharray="3 4" stroke-width="1.5"/>`;
    h += `<circle class="tk" data-y="${y}" r="7" fill="${col}"/>`;
  }
  svg.innerHTML = h;
  const tks = [...svg.querySelectorAll('.tk')];
  Site.loop(svg, (t) => {
    tks.forEach((c, i) => {
      const u = ((t * 0.3) + i * 0.43) % 1;
      c.setAttribute('cx', 26 + u * 420);
      c.setAttribute('cy', +c.dataset.y - 22);
    });
  });
}
