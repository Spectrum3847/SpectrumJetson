// Chapter 06: Linux, drivers, and why we patched one.
Object.assign(Site.glossary, {
  'operating system': 'The software that manages a computer\'s hardware and shares it between programs. Linux, Windows, macOS and Android are operating systems.',
  'user space': 'Where normal programs run. They can only touch their own memory and must ask the kernel for anything involving hardware.',
  'kernel module': 'A piece of the Linux kernel, usually a driver, kept in its own file (.ko) and loaded only when needed.',
  'UVC': 'USB Video Class: the standard way USB webcams talk, so one driver works for almost every camera.',
  'V4L2': 'Video4Linux2: Linux\'s standard way for programs to read video from cameras, through files like /dev/video0.',
  'cscore': 'WPILib\'s camera library. PhotonVision uses it to open cameras and read their frames.',
  'GPL': 'GNU General Public License: an open-source license. You may change and share the code, but what you share must stay open source too.',
  'Flashing': 'Writing a complete operating system image onto a device\'s storage, from another computer.',
});

Site.chapter('linux', (root) => {
  layers(root);
  cameraPath(root);
  diffViewer(root);
  serviceDemo(root);
  bootReplay(root);
  header12(root);
});

/* ── The layers lab ─────────────────────────────────── */
function layers(root) {
  const stack = root.querySelector('#l-stack'), pkt = root.querySelector('#l-pkt'), cap = root.querySelector('#l-os-cap');
  const els = [...stack.querySelectorAll('.layer')];
  const INFO = [
    ['You', 'You open PhotonVision\'s dashboard in a web browser on your laptop (<code>http://10.85.15.15:5800</code>). The browser is a program on <em>your</em> computer; it talks to the Jetson over the network.'],
    ['Programs (user space)', 'PhotonVision, written in Java, runs here with cscore, OpenCV and our CUDA detector library inside it. Programs only see their own memory. For anything else they ask the kernel.'],
    ['System services', 'Background programs that keep the system running. <b>systemd</b> starts them all at boot and restarts PhotonVision if it exits. <b>journald</b> keeps the log; NetworkManager sets up Ethernet and Wi-Fi.'],
    ['Linux kernel', 'The boss of the hardware. Its <b>drivers</b> talk to devices (<code>uvcvideo</code> for cameras, <code>nvme</code> for the SSD, the USB controller\'s driver). Its <b>scheduler</b> picks which thread runs on which of the 6 CPU cores, thousands of times a second. It hands out <b>memory</b> and keeps the <b>files</b> on the SSD.'],
    ['Hardware', 'The physical parts from chapter 05: CPU, GPU, RAM, the SSD, the USB controller and the cameras plugged into it.'],
  ];
  const TRIPS = {
    exp: [
      [0, 'You drag the exposure slider to 5 ms. The browser sends the new value over the network.'],
      [1, 'PhotonVision receives it and asks cscore to set the camera\'s exposure.'],
      [3, 'cscore makes a system call on <code>/dev/video0</code>. The kernel\'s <code>uvcvideo</code> driver turns it into a UVC "set exposure" message.'],
      [4, 'The USB controller sends the message down the cable. The camera changes its exposure for the next frame.'],
    ],
    frame: [
      [4, 'The camera sends a JPEG frame as USB packets. The USB controller writes them straight into RAM.'],
      [3, '<code>uvcvideo</code> notices the frame is complete, stamps the time, and marks the buffer ready on <code>/dev/video0</code>.'],
      [1, 'cscore in PhotonVision picks up the frame. PhotonVision decodes it and finds the tags.'],
      [2, 'Meanwhile systemd is watching: if PhotonVision crashed right now, it would start it again 1 s later.'],
      [0, 'The result goes to the robot over NetworkTables, and a small preview to your browser.'],
    ],
  };
  // A trip plays step by step: the dot slides to the layer, a trail shows where the message
  // has been, and the step's bar fills while you read, then it moves on. Pause, step with
  // ◀ ▶, click a bar, or tap a layer to stop and explore it.
  const trail = root.querySelector('#l-trail'), st = root.querySelector('#l-os-st');
  const bars = root.querySelector('#l-os-steps'), nEl = root.querySelector('#l-os-n'), playBtn = root.querySelector('#l-os-play');
  const DWELL = Site.reduced ? 9 : 6; // seconds per step, enough to read it
  let trip = 'exp', i = 0, playing = true, exploring = false, elapsed = 0, fromL = null;
  const mid = (l) => els[l].offsetTop + els[l].offsetHeight / 2;
  const show = (l, text) => {
    els.forEach((e, j) => e.classList.toggle('on', j === l));
    pkt.style.top = mid(l) - 7 + 'px';
    const a = fromL == null ? mid(l) : Math.min(mid(fromL), mid(l)), b2 = fromL == null ? mid(l) : Math.max(mid(fromL), mid(l));
    trail.style.top = a + 'px'; trail.style.height = b2 - a + 'px';
    cap.innerHTML = `<h5>${INFO[l][0]}</h5>${text ? `<p><b>${text}</b></p>` : ''}<p>${INFO[l][1]}</p>`;
  };
  const steps = () => TRIPS[trip];
  const buildBars = () => { bars.innerHTML = steps().map((_, k) => `<button type="button" data-k="${k}" aria-label="Step ${k + 1}"><i></i></button>`).join(''); };
  const paintBars = () => {
    [...bars.children].forEach((b, k) => { b.classList.toggle('done', k < i); b.classList.toggle('cur', k === i && !exploring); b.setAttribute('aria-current', k === i && !exploring ? 'step' : 'false'); b.querySelector('i').style.width = k === i ? Math.min(100, (100 * elapsed) / DWELL) + '%' : ''; });
    nEl.textContent = exploring ? '' : `${i + 1} / ${steps().length}`;
  };
  const status = () => {
    st.textContent = exploring ? 'This layer is not a stop on this trip. Press ▶ Play, or use ◀ ▶, to follow the message.'
      : playing ? `Step ${i + 1} of ${steps().length}: the green bar fills while you read, then the message moves on.` : `Paused on step ${i + 1} of ${steps().length}. Press ▶ Play or use ◀ ▶.`;
    playBtn.textContent = playing && !exploring ? '⏸ Pause' : '▶ Play';
    playBtn.setAttribute('aria-pressed', String(playing && !exploring));
    pkt.classList.toggle('wait', !exploring);
  };
  const go = (k) => {
    const n = steps().length; i = ((k % n) + n) % n; elapsed = 0; exploring = false;
    const [l, text] = steps()[i];
    fromL = i ? steps()[i - 1][0] : null;
    show(l, `${i + 1}/${n}: ${text}`); paintBars(); status();
  };
  Site.seg(root.querySelector('#l-os-seg'), (v) => { trip = v; buildBars(); playing = true; go(0); });
  playBtn.addEventListener('click', () => { if (exploring) { playing = true; go(i); return; } playing = !playing; status(); });
  root.querySelector('#l-os-prev').addEventListener('click', () => { playing = false; go(i - 1); });
  root.querySelector('#l-os-next').addEventListener('click', () => { playing = false; go(i + 1); });
  bars.addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) { playing = false; go(+b.dataset.k); } });
  // Tapping a layer shows its step in this trip (same text as during playback), paused there.
  // A layer the trip doesn't stop at shows its description and says so.
  els.forEach((e, j) => e.addEventListener('click', () => {
    const k = steps().findIndex(([l]) => l === j);
    playing = false;
    if (k >= 0) { go(k); return; }
    exploring = true; fromL = null;
    show(j, `Not a stop on this trip. Press ▶ Play to follow the message again.`); paintBars(); status();
  }));
  Site.loop(stack, (t, dt) => {
    if (!playing || exploring || !dt) return;
    elapsed += dt;
    if (elapsed >= DWELL) go(i + 1); else paintBars();
  });
}

/* ── Camera path diagram ────────────────────────────── */
function cameraPath(root) {
  const svg = root.querySelector('#l-path');
  const N = [
    ['PhotonVision', 'finds tags, sends results', 'Java program', 40],
    ['cscore', 'reads frames for PhotonVision', 'WPILib library', 118],
    ['V4L2  /dev/video0', 'Linux\'s standard video API', 'read, queue, dequeue', 238],
    ['uvcvideo driver', 'packets → whole frames', 'our patched module', 316],
    ['USB camera (UVC)', 'Thriftiest Cam, MJPEG', '1280×800 at 120 fps', 430],
  ];
  let h = `<rect class="band" x="0" y="10" width="440" height="180" rx="12" fill="#faf5ff"/><text x="428" y="30" text-anchor="end" style="font:700 11px var(--font);letter-spacing:.12em;fill:#6b1199">USER SPACE</text>`;
  h += `<rect class="band" x="0" y="206" width="440" height="190" rx="12" fill="#fff7ed"/><text x="428" y="226" text-anchor="end" style="font:700 11px var(--font);letter-spacing:.12em;fill:#c2410c">KERNEL SPACE</text>`;
  h += `<line x1="0" y1="198" x2="440" y2="198" stroke="#f59e0b" stroke-width="2" stroke-dasharray="6 5"/><text x="128" y="193" style="font:600 11px var(--font);fill:#c2410c">system calls cross here</text>`;
  h += `<text x="428" y="420" text-anchor="end" style="font:700 11px var(--font);letter-spacing:.12em;fill:#635a72">HARDWARE</text>`;
  h += `<path d="M110 ${N[4][3]} V${N[0][3] + 52}" stroke="#d4c0ee" stroke-width="4" fill="none"/>`;
  N.forEach(([t, s, m, y], i) => {
    h += `<g class="nd" data-i="${i}"><rect x="30" y="${y}" width="300" height="60" rx="12"/><text class="t" x="48" y="${y + 24}">${t}</text><text class="s" x="48" y="${y + 43}">${s}</text><text class="m" x="318" y="${y + 24}" text-anchor="end">${m}</text></g>`;
  });
  h += `<g id="l-fr"><rect x="-18" y="-11" width="36" height="22" rx="4" fill="#a3e635"/><text y="4" text-anchor="middle" style="font:700 10px var(--mono);fill:#1a0a2b">JPEG</text></g>`;
  svg.innerHTML = h;
  const fr = svg.querySelector('#l-fr'), nds = [...svg.querySelectorAll('.nd')];
  const ys = N.map((n) => n[3] + 30).reverse(); // bottom to top
  Site.loop(svg, (t) => {
    const u = (t * 0.28) % 1, seg = u * (ys.length - 1), k = Math.floor(seg), f = Site.ease(Math.min(1, (seg - k) * 1.6));
    const y = Site.lerp(ys[k], ys[Math.min(k + 1, ys.length - 1)], f);
    fr.setAttribute('transform', `translate(370 ${y})`);
    nds.forEach((n, i) => n.classList.toggle('hi', N.length - 1 - i === Math.round(seg)));
  });
}

/* ── USB seat-booking lab ───────────────────────────── */

function diffViewer(root) {
  const d = root.querySelector('#l-diff');
  Site.seg(root.querySelector('#l-diff-seg'), (v) => { d.classList.toggle('before', v === 'before'); d.classList.toggle('after', v === 'after'); });
}

/* ── systemd crash demo ─────────────────────────────── */
function serviceDemo(root) {
  const dot = root.querySelector('#l-dot'), state = root.querySelector('#l-state'), log = root.querySelector('#l-log');
  let policy = 'always', timers = [];
  Site.seg(root.querySelector('#l-rs'), (v) => (policy = v));
  const set = (cls, txt) => { dot.className = 'dot ' + cls; state.innerHTML = 'Active: ' + txt; };
  const line = (s) => { log.innerHTML += s + '<br>'; const ls = log.innerHTML.split('<br>'); if (ls.length > 6) log.innerHTML = ls.slice(-6).join('<br>'); };
  root.querySelector('#l-crash').onclick = () => {
    timers.forEach(clearTimeout); timers = [];
    log.innerHTML = '';
    set('bad', '<span style="color:#fb7185">failed</span> (Result: exit-code)');
    line('photonvision.service: Main process exited, status=1/FAILURE');
    if (policy === 'no') {
      timers.push(setTimeout(() => line('photonvision.service: Failed. <span style="color:#fb7185">No vision until someone restarts it.</span>'), 700));
      return;
    }
    timers.push(setTimeout(() => { set('mid', '<span style="color:#fbbf24">activating (auto-restart)</span>'); line('photonvision.service: Scheduled restart job, restart counter is at 1.'); }, 1000));
    timers.push(setTimeout(() => line('Started PhotonVision.'), 1500));
    timers.push(setTimeout(() => { set('', '<span style="color:#4ade80">active (running)</span>'); line('Cameras connected, detecting again (about 8 s end to end on the real Jetson).'); }, 3200));
  };
}

/* ── Boot replay ────────────────────────────────────── */
function bootReplay(root) {
  const lab = root.querySelector('#l-boot'), clock = root.querySelector('#l-clock');
  const MAX = 60, pct = (s) => (100 * s) / MAX;
  const TR = {
    before: { segs: [[0, 6.9, 'kernel 6.9 s', '#c4b5fd'], [6.9, 11.9, 'services', '#67e8f9'], [11.9, 56.9, 'snapd.seeded ≈ 45 s (unused!)', '#fb7185']], marks: [[12, 'PhotonVision started ~12 s'], [56.9, 'boot finished']] },
    after: { segs: [[0, 8.8, 'kernel 8.8 s', '#c4b5fd'], [8.8, 16.5, 'services 7.7 s', '#67e8f9'], [16.5, 20.1, 'cams', '#a3e635']], marks: [[14.7, 'PhotonVision 14.7 s'], [20, 'tags detected ~20 s']] },
  };
  for (const [k, tr] of Object.entries(TR)) {
    const lane = lab.querySelector(`.lane[data-t="${k}"]`);
    lane.innerHTML = tr.segs.map(([a, b, l, c]) => `<div class="seg-b" data-a="${a}" data-b="${b}" style="left:${pct(a)}%;background:${c}">${l}</div>`).join('');
    lane.insertAdjacentHTML('afterend', tr.marks.map(([s, l], i) => `<div class="mark${i ? ' up' : ''}${s > 50 ? ' end' : ''}" data-s="${s}" style="left:${pct(s)}%"><span>${l}</span></div>`).join(''));
  }
  lab.querySelectorAll('.track').forEach((t) => (t.style.marginBottom = '34px'));
  let t0 = null, done = false;
  const render = (s) => {
    clock.textContent = s.toFixed(1) + ' s';
    lab.querySelectorAll('.seg-b').forEach((e) => { const a = +e.dataset.a, b = +e.dataset.b; e.style.width = pct(Site.clamp(s - a, 0, b - a)) + '%'; });
    lab.querySelectorAll('.mark').forEach((e) => (e.style.opacity = s >= +e.dataset.s ? 1 : 0));
  };
  const play = root.querySelector('#l-boot-play');
  play.onclick = () => { t0 = null; done = false; render(0); play.textContent = '↺ Restart'; };
  render(0);
  Site.loop(lab, (t) => {
    if (done) return;
    if (t0 === null) { t0 = t; play.textContent = '↺ Restart'; }
    const s = Site.reduced ? 57 : Math.min(57, (t - t0) * 4);
    render(s);
    if (s >= 57) { done = true; play.textContent = '▶ Replay'; }
  });
}

/* ── 12-pin button header illustration ──────────────── */
function header12(root) {
  const svg = root.querySelector('#l-hdr');
  let h = '<rect x="30" y="22" width="160" height="60" rx="6" fill="#1f1b23"/>';
  // Illustration only: two rows of six, odd pins on top. Check the board's silkscreen.
  for (let c = 0; c < 6; c++) for (let r = 0; r < 2; r++) {
    const n = c * 2 + r + 1, x = 48 + c * 25, y = 38 + r * 28, on = n === 9 || n === 10;
    h += `<rect x="${x - 6}" y="${y - 6}" width="12" height="12" rx="2" fill="${on ? '#fbbf24' : '#c8b88a'}"/><text x="${x}" y="${r ? y + 22 : y - 10}" text-anchor="middle" font-size="9" fill="${on ? '#6b1199' : '#9a8fb0'}" font-weight="${on ? 700 : 400}" font-family="var(--font)">${n}</text>`;
  }
  h += '<rect x="141" y="28" width="14" height="44" rx="4" fill="#8b5cf6" opacity=".85"/><text x="110" y="104" text-anchor="middle" font-size="10" fill="#635a72" font-family="var(--font)">jumper on 9 + 10 (illustration)</text>';
  svg.innerHTML = h;
}
