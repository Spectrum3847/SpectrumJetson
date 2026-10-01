Object.assign(Site.glossary, {
  'cscore': 'WPILib\'s camera library: it reads cameras through the Linux driver and serves MJPEG video streams. PhotonVision uses it for every USB camera.',
  'upstream': 'The original project a fork was copied from. Fixes made there flow "downstream" to the forks.',
});

Site.chapter('photonvision', (root) => {
  const $ = (s) => root.querySelector(s);
  const BG = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', ACC = '#8b5cf6', SOFT = '#c4b5fd', LIME = '#a3e635', RED = '#f43f5e', AMBER = '#f59e0b';
  const narrow = root.clientWidth < 640;
  const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;');

  /* ── 1. PhotonVision data flow ────────────────────────── */
  {
    const svg = $('#pv-flow'), info = $('#pv-info');
    const N = {
      cam: ['USB camera', 'MJPEG 1280×800, 120 fps', 'The Thriftiest Cam compresses each 1280×800 frame into a JPEG (about 50 KB) and sends it over USB 2.0, 120 times a second.'],
      cscore: ['cscore', 'WPILib camera library', 'WPILib\'s camera library. It talks to the Linux camera driver, keeps the newest frame, and serves video streams.'],
      fp: ['USBFrameProvider', 'grab JPEG → gray image', 'Asks cscore for the newest frame, takes the camera\'s JPEG untouched, and has it decoded straight to gray on the Jetson\'s JPEG hardware.', ' (Our patch 09, with <code>--jpeg nvjpg</code>.)'],
      vr: ['VisionRunner', 'this camera\'s own thread', 'This camera\'s own thread: grab a frame, run the pipeline, pass the result on, repeat forever. It never sits waiting for a new frame; it takes the newest one.', ' (Low Latency Mode off: <a href="#speed">chapter 10</a>.)'],
      det: ['Detect on the GPU', 'AprilTagDetectionCudaPipe', 'Hands the gray image to the 971 detector on the GPU: about 1.7 ms. Out come tag IDs, corners and decision margins (chapter 08).'],
      pose: ['Pose', 'single-tag + multi-tag', 'With a lens calibration, each tag\'s corners become a 3D pose (single-tag), and all the tags in view are solved together against the field layout (multi-tag). Chapter 12.'],
      res: ['CVPipelineResult', 'everything about this frame', 'Everything PhotonVision knows about this frame: targets, corners, poses, and when the frame was captured.'],
      nt: ['NTDataPublisher', '→ NetworkTables', 'Packs the result into PhotonLib\'s message format (the one with the hash) and publishes it on NetworkTables (chapter 15).'],
      robot: ['Robot code', 'PhotonLib on the SystemCore', 'Robot code reads the result with PhotonLib on the SystemCore, over Ethernet, and fuses it with odometry (chapter 12).'],
      stream: ['Stream thread', 'shrink, draw boxes', 'OutputStreamPipeline shrinks the frame and draws the boxes and axes you see in the dashboard. Only while someone is watching, and at most 30 frames a second.', ' (Our patch 15.)'],
      mjpeg: ['MJPEG server', 'cscore MjpegServer', 'cscore\'s MjpegServer sends the video to your browser as a stream of JPEG pictures.'],
      browser: ['Dashboard', 'your web browser', 'The dashboard in your browser. Every open stream costs the Jetson CPU, so close it before measuring anything.'],
    };
    const inModule = new Set(['fp', 'vr', 'det', 'pose', 'res']);
    let P, VW, VH;
    if (!narrow) {
      VW = 1100; VH = 350;
      const w = 190, h = 64, X = [25, 240, 455, 670, 885], Y = [22, 142, 262];
      P = { cam: [X[0], Y[0]], cscore: [X[1], Y[0]], fp: [X[2], Y[0]], vr: [X[3], Y[0]], det: [X[4], Y[0]], pose: [X[4], Y[1]], res: [X[3], Y[1]], nt: [X[2], Y[1]], robot: [X[1], Y[1]], stream: [X[3], Y[2]], mjpeg: [X[2], Y[2]], browser: [X[1], Y[2]] };
      for (const k in P) P[k].push(w, h);
    } else {
      VW = 400; VH = 790;
      P = {};
      ['cam', 'cscore', 'fp', 'vr', 'det', 'pose', 'res'].forEach((k, i) => (P[k] = [20, 12 + i * 78, 360, 56]));
      P.nt = [20, 560, 172, 56]; P.stream = [208, 560, 172, 56]; P.robot = [20, 638, 172, 56]; P.mjpeg = [208, 638, 172, 56]; P.browser = [208, 716, 172, 56];
    }
    svg.setAttribute('viewBox', `0 0 ${VW} ${VH}`);
    const anchor = (a, b) => { // start/end points of an edge a→b
      const [ax, ay, aw, ah] = P[a], [bx, by, bw, bh] = P[b];
      if (Math.abs(ay - by) < 5) return bx > ax ? [[ax + aw, ay + ah / 2], [bx, by + bh / 2]] : [[ax, ay + ah / 2], [bx + bw, by + bh / 2]];
      const x = Site.clamp(bx + bw / 2, ax + 12, ax + aw - 12);
      return [[x, ay + ah], [x, by]];
    };
    const edges = [['cam', 'cscore'], ['cscore', 'fp'], ['fp', 'vr'], ['vr', 'det'], ['det', 'pose'], ['pose', 'res'], ['res', 'nt'], ['nt', 'robot'], ['res', 'stream'], ['stream', 'mjpeg'], ['mjpeg', 'browser']];
    let s = '<defs><marker id="pv-ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0L10 5L0 10z" fill="#b69ce0"/></marker></defs>';
    for (const [a, b] of edges) { const [[x1, y1], [x2, y2]] = anchor(a, b); s += `<path class="${b === 'stream' || a === 'stream' || a === 'mjpeg' ? 'sw' : ''}" d="M${x1} ${y1} L${x2} ${y2}" stroke="#d4c0ee" stroke-width="2.5" marker-end="url(#pv-ar)"/>`; }
    const fsT = narrow ? 15 : 15, fsS = narrow ? 12 : 12;
    for (const k in P) {
      const [x, y, w, h] = P[k], [t, sub] = N[k];
      s += `<g class="nd" data-k="${k}"><rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#fff" stroke="#d4c0ee" stroke-width="1.5"/>${inModule.has(k) ? `<rect x="${x}" y="${y + 8}" width="4" height="${h - 16}" rx="2" fill="#8b5cf6"/>` : ''}
        <text x="${x + 14}" y="${y + h / 2 - 3}" font-size="${fsT}" font-weight="700" fill="#4c0070" font-family="Outfit, sans-serif">${t}</text>
        <text x="${x + 14}" y="${y + h / 2 + 15}" font-size="${fsS}" fill="#635a72">${esc(sub)}</text></g>`;
    }
    s += '<g id="pv-dots"></g>';
    svg.innerHTML = s;
    svg.querySelectorAll('.nd').forEach((g) => g.addEventListener('click', () => {
      svg.querySelectorAll('.nd').forEach((x) => x.classList.toggle('sel', x === g));
      const [t, , d, extra] = N[g.dataset.k];
      info.innerHTML = `<b>${t}.</b> ${d}${extra && Site.mode === 'full' ? extra : ''}`;
    }));
    let watching = false;
    Site.seg($('#pv-view'), (v) => { watching = v === 'yes'; $('#pv-view-note').textContent = watching ? 'every 4th frame also goes to the stream (30 of 122 fps)' : 'the stream thread gets no frames at all'; });
    const chain = (ks) => { const pts = []; for (let i = 0; i < ks.length - 1; i++) { const [a, b] = anchor(ks[i], ks[i + 1]); pts.push(a, b); } return pts; };
    const main = chain(['cam', 'cscore', 'fp', 'vr', 'det', 'pose', 'res', 'nt', 'robot']);
    const branch = chain(['res', 'stream', 'mjpeg', 'browser']);
    const along = (pts, u) => {
      const L = []; let tot = 0;
      for (let i = 0; i < pts.length - 1; i++) { const d = Math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]); L.push(d); tot += d; }
      let r = u * tot;
      for (let i = 0; i < L.length; i++) { if (r <= L[i]) { const k = L[i] ? r / L[i] : 0; return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * k, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k]; } r -= L[i]; }
      return pts[pts.length - 1];
    };
    const dots = svg.querySelector('#pv-dots');
    const resFrac = (() => { const k = chain(['cam', 'cscore', 'fp', 'vr', 'det', 'pose', 'res']); let a = 0, b = 0; for (let i = 0; i < k.length - 1; i++) a += Math.hypot(k[i + 1][0] - k[i][0], k[i + 1][1] - k[i][1]); for (let i = 0; i < main.length - 1; i++) b += Math.hypot(main[i + 1][0] - main[i][0], main[i + 1][1] - main[i][1]); return a / b; })();
    Site.loop(svg, (t) => {
      let out = '';
      const SP = 0.16, GAP = 0.55;
      for (let n = Math.floor(t / GAP) - 12; n <= Math.floor(t / GAP); n++) {
        const u = (t - n * GAP) * SP; if (u < 0 || u > 1.6) continue;
        if (u <= 1) { const [x, y] = along(main, u); out += `<rect x="${x - 6}" y="${y - 6}" width="12" height="12" rx="3" fill="#8b5cf6"/>`; }
        if (watching && n % 4 === 0 && u > resFrac) {
          const v = (u - resFrac) / (1 - resFrac) * 0.9; if (v <= 1) { const [x, y] = along(branch, v); out += `<rect x="${x - 5}" y="${y - 5}" width="10" height="10" rx="3" fill="#f59e0b"/>`; }
        }
      }
      dots.innerHTML = out;
      svg.querySelectorAll('path.sw').forEach((p) => p.setAttribute('stroke', watching ? '#f59e0b' : '#e9ddf7'));
    });
  }

  /* ── 1b. Dashboard tour (real screenshots) ────────────── */
  {
    const D = 'assets/from-jetson/screenshots/';
    const T = [
      [D + 'dashboard-aprilcudatag-tab-crop.webp', 'The AprilCudaTag tab', 'The settings for the GPU detector. The fork\'s version of this tab was blank in the new web framework; our patch 01 rebuilt it, showing only settings that really do something: the tag family, the decision margin cutoff (15, our tuning at 5 ms) and pose iterations. Top left: <b>123 FPS, 14 ms latency</b> on TopLeft.', ['photonvision-01', 'photonvision-10']],
      [D + 'dashboard-output-tab-crop.webp', 'The Output tab', 'What gets sent to the robot. <b>Do Multi-Target Estimation</b> is on: all tags in view are solved together against the field layout. New cameras get it automatically once calibrated (patch 06).', ['photonvision-06']],
      [D + 'dashboard-targets-tab-crop.webp', 'The Targets tab', 'One row per tag seen, with its position and ambiguity, then the multi-tag pose of the camera on the field. It\'s empty here: no tag was in view. With 2+ tags and the robot level, our camera mount estimate also shows up on this tab (patch 17).', ['photonvision-17']],
      [D + 'copy-settings-dialog-crop.webp', 'Copy settings', 'From the pipeline menu (☰): pick a camera and pipeline to copy from, tick the groups, and optionally copy into every camera at once. Orientation, names and exposure limits are never copied.', ['photonvision-25']],
      [D + 'settings-top-crop.webp', 'The Settings page', 'Device Metrics on the right: CPU, <b>GPU usage</b> (our chart, patch 19: 16% here with 4 cameras), memory and temperature. On the left, the <b>CPU Throttling</b> row says why the Jetson would slow itself down (patch 20): "None".', ['photonvision-19', 'photonvision-20']],
    ];
    const img = $('#pv-tour-img'), txt = $('#pv-tour-txt');
    T.forEach(([src]) => { const im = new Image(); im.src = src; }); // preload: tab switches are instant
    Site.seg($('#pv-tour'), (v) => {
      const [src, h, d, chips] = T[+v];
      img.src = src; img.alt = h + ' in our PhotonVision';
      txt.innerHTML = `<h4>${h}</h4><p>${d}</p>${chips.map((c) => `<span class="chip">${c}</span>`).join('')}`;
    });
  }

  /* ── 2. Family tree ───────────────────────────────────── */
  {
    const C = [10, 187, 364], W = 165, H = 74, R = [16, 136, 256, 380];
    const box = (x, y, w, t, s1, s2, hl) => `<rect x="${x}" y="${y}" width="${w}" height="${H}" rx="12" fill="${hl ? '#8b5cf6' : '#fff'}" stroke="${hl ? '#6b1199' : '#d4c0ee'}" stroke-width="1.5"/>
      <text x="${x + 12}" y="${y + 24}" font-size="14" font-weight="700" fill="${hl ? '#fff' : '#4c0070'}" font-family="Outfit, sans-serif">${t}</text>
      <text x="${x + 12}" y="${y + 44}" font-size="11" fill="${hl ? '#f3e8ff' : '#635a72'}">${s1}</text><text x="${x + 12}" y="${y + 60}" font-size="11" fill="${hl ? '#f3e8ff' : '#635a72'}">${s2 || ''}</text>`;
    const arr = (x1, y1, x2, y2, lab, lx, ly) => `<path d="M${x1} ${y1} C ${x1} ${(y1 + y2) / 2}, ${x2} ${(y1 + y2) / 2}, ${x2} ${y2}" fill="none" stroke="#b69ce0" stroke-width="2" marker-end="url(#pv-ar2)" class="flowline"/>${lab ? `<text x="${lx}" y="${ly}" font-size="10.5" font-weight="600" fill="#6b1199">${lab}</text>` : ''}`;
    let s = '<defs><marker id="pv-ar2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" fill="#b69ce0"/></marker></defs>';
    s += `<text x="${C[0]}" y="10" font-size="10" font-weight="700" fill="#8b5cf6" letter-spacing="1.5">PHOTONVISION</text><text x="${C[2]}" y="10" font-size="10" font-weight="700" fill="#8b5cf6" letter-spacing="1.5">APRILTAG DETECTOR</text>`;
    s += box(C[0], R[0], W * 2 + 12, 'PhotonVision (upstream)', 'The official project · GPL-3.0', 'AprilTags on the CPU');
    s += box(C[2], R[0], W, 'aos: frc/orin', 'Austin Schuh\'s current', 'CUDA detector (971)');
    s += box(C[0], R[1], W, 'FRC 4143 fork', 'adds AprilTagCuda', 'commit d8c9e8e, Jan 2026');
    s += box(C[1], R[1], W, 'v2026.3.4', 'upstream\'s newest', '2026 release');
    s += box(C[2], R[1], W, 'frc971/bos', '971\'s build of it for', 'CUDA 12.6 (971apriltag)');
    s += box(C[0], R[2], W * 2 + 12, 'Our PhotonVision fork', '4143 + patch 00 (v2026.3.4)', '+ our patches 01–60', true);
    s += box(C[2], R[2], W, 'lib971apriltag.so', 'bos + bos-01 … bos-08', '+ our wrapper (detector/)', true);
    s += box(C[0], R[3], W * 3 + 24, 'On the Jetson', 'photonvision.jar (Java 17) loads lib971apriltag.so for every AprilTagCuda camera,', 'plus WPILib v2026.2.1\'s cscore and ntcore inside PhotonVision');
    s += arr(C[0] + 60, R[0] + H, C[0] + 60, R[1], 'forked', C[0] + 66, R[0] + H + 26);
    s += arr(C[1] + 60, R[0] + H, C[1] + 60, R[1], 'released', C[1] + 66, R[0] + H + 26);
    s += arr(C[2] + 80, R[0] + H, C[2] + 80, R[1], 'imported', C[2] + 86, R[0] + H + 26);
    s += arr(C[0] + 60, R[1] + H, C[0] + 90, R[2], 'our base', C[0] + 8, R[1] + H + 26);
    s += arr(C[1] + 60, R[1] + H, C[1] + 20, R[2], 'merged: patch 00', C[1] + 30, R[1] + H + 26);
    s += arr(C[2] + 80, R[1] + H, C[2] + 80, R[2], 'built + patched', C[2] + 86, R[1] + H + 26);
    s += arr(C[0] + 170, R[2] + H, C[0] + 170, R[3], 'jar', C[0] + 178, R[2] + H + 30);
    s += arr(C[2] + 80, R[2] + H, C[2] + 80, R[3], 'loaded by', C[2] + 88, R[2] + H + 30);
    $('#pv-tree').innerHTML = s;
  }

  /* ── 3. Wire-compatibility lab ────────────────────────── */
  {
    const V = [['v2027.0.0-alpha-2 (what we use)', true], ['up to the alpha-6 era', true], ['alpha-7 or newer', false]];
    Site.range($('#pv-ver'), (v) => {
      const [name, ok] = V[v];
      $('#pv-hash-ver').textContent = name;
      $('#pv-hash-code').textContent = ok ? '4b2ff16a…' : 'a different hash';
      $('#pv-hash-robot').classList.toggle('bad', !ok);
      $('#pv-hash-mid').textContent = ok ? '🤝' : '💥';
      $('#pv-hash-note').innerHTML = ok ? 'Hashes match: the robot accepts every result. (A different version <em>string</em> only logs a note.)' : 'Timestamps became nanoseconds in alpha-7, the message layout changed, and so did its hash. PhotonLib throws, and the robot code crashes reading this Jetson.';
    }, (v) => ['alpha-2', 'alpha-6', 'alpha-7+'][v]);
  }

  /* ── 4. Build + install animation ─────────────────────── */
  const GROUPS = {
    speed: ['Speed', '#65a30d'], reliability: ['Reliability & recovery', '#e11d48'], robot: ['Robot integration', '#2563eb'],
    usability: ['Usability & dashboard', '#0891b2'], field: ['Calibration & field', '#d97706'], pieces: ['Game pieces', '#ca8a04'], diag: ['Diagnostics', '#7c3aed'],
  };
  // [id, group, name, what & why, measured effect, story anchor]
  const PATCHES = [
    ['photonvision-00', 'reliability', 'Upstream v2026.3.4 merged', 'A season of official PhotonVision fixes on top of 4143\'s CUDA fork. A trial merge had no conflicts, and the message hash is unchanged.', '', ''],
    ['photonvision-01', 'usability', 'AprilCudaTag tab for Vue 3', 'The fork\'s settings tab was written for the old web framework and showed up blank. Ported, keeping only settings that do something.', '', ''],
    ['photonvision-02', 'speed', 'Gray capture', 'Ask cscore for grayscale frames for AprilTag pipelines. Only half the fix: cscore still decoded color inside (see 09).', 'Java CPU 155% → 111% of a core', ''],
    ['photonvision-03', 'usability', 'Uptime format fallback', 'Firefox 130 lacked Intl.DurationFormat, so the whole Device Control card, Restart button included, disappeared.', '', ''],
    ['photonvision-04', 'field', 'All 8 lens coefficients', 'Calibration makes 8 distortion numbers; the detector only got 5, so corners near the image edge came out slightly wrong.', 'log shows "(8 dist coeffs)"', ''],
    ['photonvision-05', 'robot', 'Wi-Fi and Bluetooth switches', 'Turn the Jetson\'s radios off from Settings > Networking: Bluetooth off, Wi-Fi off for events.', '', ''],
    ['photonvision-06', 'usability', 'Team camera defaults', 'A new camera starts with our tuned pipeline (AprilTagCuda, 1280×800, 5 ms, margin 15). 3D and multi-tag switch on once it\'s calibrated.', '', ''],
    ['photonvision-07', 'diag', 'Rewind', 'Records every camera\'s own JPEGs to the SSD while robot code asks, stamped with the robot\'s clock. Download from the web UI.', '3% of one core; ~1 GB a match', ''],
    ['photonvision-08', 'robot', 'Clock from the robot', 'The Jetson has no clock battery and no internet at events, so it sets its date from the robot\'s clock.', '', ''],
    ['photonvision-09', 'speed', 'Direct gray decode', 'Decode the camera\'s JPEG straight to gray in our detector library instead of cscore\'s hidden color decode.', '8.9 → 2.6 ms a frame; 122 fps', '#speed|In chapter 10 →'],
    ['photonvision-10', 'usability', 'Exposure in milliseconds', 'The raw value is in 100 µs units, so 295 meant 29.5 ms. The slider now shows ms; new cameras start at 5 ms and margin 15.', '', '#settings|In chapter 04 →'],
    ['photonvision-11', 'robot', 'setEnabled()', 'Robot code can pause a camera with PhotonCamera.setEnabled(). Server side ported from upstream #2484 and #2499.', '', ''],
    ['photonvision-12', 'reliability', 'OpenCV leak fixes', 'Upstream\'s sweep of native-memory leaks (#2511), hand-ported to our 2026 code.', '', ''],
    ['photonvision-13', 'robot', 'Mid-exposure timestamps', 'Each frame\'s time is moved to the middle of its exposure, so the robot matches it to the right moment.', '', 'pv-s13'],
    ['photonvision-14', 'pieces', 'TensorRT object detection', 'YOLO game-piece models run on the GPU through our TensorRT backend. Capped at 30 fps by default.', 'no measurable effect on tag cameras at 30 fps', ''],
    ['photonvision-15', 'speed', 'Stream only when watched', 'The dashboard stream only gets frames while someone is watching, at most 30 a second.', '0.49 → 0.43 cores', 'pv-s15'],
    ['photonvision-16', 'diag', 'Jetson telemetry', 'GPU load, temperatures, fan, power, decoder state and each camera\'s health on NetworkTables, once a second.', '', ''],
    ['photonvision-17', 'field', 'Camera mount estimate', 'With the robot level and 2+ tags in view: each camera\'s height, pitch and roll, averaged over 100 samples.', '', ''],
    ['photonvision-18', 'speed', 'Hardware color decode', 'Color frames (game pieces, driver mode) also decode on the Jetson\'s JPEG hardware, pixel-identical to cscore.', 'one color camera: 1.12 → 0.59 cores', ''],
    ['photonvision-19', 'diag', 'GPU usage chart', 'Device Metrics on the Settings page gets a GPU usage chart.', '', ''],
    ['photonvision-20', 'diag', 'Throttle reason', 'Says why the Jetson is slowing itself down: OVER-CURRENT when the supply sags, HIGH TEMP, or capped clocks.', '', ''],
    ['photonvision-21', 'usability', 'Thriftiest Cam support', 'Upstream\'s support for our camera model (#2478). It adds a gain slider, but our cameras have no gain control, so patch 54 hides it.', '', ''],
    ['photonvision-22', 'field', 'Excluded tags', 'List tags that are mounted wrong; every camera\'s multi-tag solve ignores them.', '', 'pv-s22'],
    ['photonvision-23', 'field', 'Calibration defaults', 'Our ChArUco board is the default (sizes in mm), 100 snapshots required, and automatic snapshots once a second.', '', ''],
    ['photonvision-24', 'diag', 'Settings in the robot log', 'Each camera\'s complete settings as JSON on NetworkTables, sent when they change, so every match log shows them.', '', ''],
    ['photonvision-25', 'usability', 'Copy settings', 'Copy chosen groups of settings from one camera to another, or to every camera at once.', '', 'pv-s25'],
    ['photonvision-26', 'usability', 'Tuning guide', 'What to set, in what order, and why, right on the camera\'s Input tab, with recommended values in each tooltip.', '', ''],
    ['photonvision-27', 'reliability', 'Stuck at 320×240', 'A startup race left a camera at 320×240 while cscore stretched it to full size. Now a size mismatch reopens the camera (for real since patch 37).', '1.7 → 0.5 cores', 'pv-s27'],
    ['photonvision-28', 'usability', 'More camera controls', 'Contrast, gamma, sharpness and backlight compensation, which stock PhotonVision hides. Saved per pipeline.', '', ''],
    ['photonvision-29', 'reliability', 'Stuck-camera recovery', 'No usable frames for 3 s: reconnect. Still none 5 s later: reset the camera at the USB level, like a replug.', 'bench test: back in 9.1 s', 'pv-s29'],
    ['photonvision-30', 'field', 'Field calibration page', 'Push the robot to 10–20 spots; the Jetson solves the event\'s real tag positions and every camera\'s mount.', 'synthetic test: tags to a few mm', 'pv-s30'],
    ['photonvision-31', 'reliability', 'USB trouble detection', 'Watches the kernel log for "not enough bandwidth" and connection failures by port, reports them, and skips resets that can\'t help.', '', '#speed|In chapter 10 →'],
    ['photonvision-32', 'diag', 'USB bandwidth card', 'The Camera Matching page shows the shared USB budget, what each camera reserves and sends, and lets you change it.', '', '#speed|In chapter 10 →'],
    ['photonvision-33', 'diag', 'Quiet frame errors', 'With a camera gone, every failed grab was logged. Now the first one, then one line per 5 s with a count.', '~20,000 lines a minute → 1 per 5 s', ''],
    ['photonvision-34', 'field', 'Focus score', 'A live sharpness score on a 3×3 grid while you turn the lens, like Limelight\'s focus tool.', '', '#camera|In chapter 03 →'],
    ['photonvision-35', 'usability', 'Spectrum purple theme', 'Spectrum\'s purple, taken from our dino mascot, who now sits next to the PhotonVision logo in the sidebar. White cards with purple accents, and the theme toggle works on the first click.', '', ''],
    ['photonvision-36', 'robot', 'Yaw sign, written down right', 'Target yaw is positive to the right. PhotonVision\'s code and tests agree, but PhotonLib\'s comments and docs said left. Comments and docs fixed, and the Targets tab\'s columns labelled. No behavior change.', '', '#coords|In chapter 19 →'],
    ['photonvision-37', 'reliability', 'Stuck at 320×240, really fixed', 'Patch 27\'s recovery never worked: it only paused and restarted the stream. Now the camera switches to another mode and back, which really reopens it. Also stops copying every gray frame.', 'no frame copy: 1.23 → 1.14 cores (4 cameras)', ''],
    ['photonvision-38', 'reliability', 'Camera thread killed at startup', 'A camera\'s thread read the camera list while cameras were still being added, and crashed. That camera never ran until a restart.', '', ''],
    ['photonvision-39', 'usability', 'Extra sliders keep their value', 'Contrast, gamma, sharpness and backlight compensation changed the camera, but the slider snapped back to the old number.', '', ''],
    ['photonvision-40', 'usability', 'Detection masks', 'A Mask tab: draw boxes on the stream to ignore parts of the image (ceiling lights, truss), or to search only inside them.', '', '#camsetup|In chapter 20 →'],
    ['photonvision-41', 'usability', 'Dashboards stay in sync', 'A change in one dashboard never reached a second open one, which kept old values and could send them back.', 'a second tab updates within 2 s', ''],
    ['photonvision-42', 'reliability', 'Video mode not known yet', 'From upstream #2617: dashboard tabs could vanish while a camera was still starting up.', '', ''],
    ['photonvision-43', 'reliability', 'A reconnect that really reconnects', 'The stuck-camera watchdog\'s "reconnect" (patch 29) only paused the stream. Now it reopens the camera through another video mode, like patch 37.', 'bench: back without a USB reset', ''],
    ['photonvision-44', 'reliability', 'One camera, one device', 'From upstream #2352: reactivating a camera could tie two cameras to one device. Camera Matching cards now show the camera\'s name.', '', ''],
    ['photonvision-45', 'diag', 'Test hooks', 'Labels on every control and a read-only view of each camera\'s settings, so the browser test suite (tests/ui) can check the page against the Jetson.', '', ''],
    ['photonvision-46', 'usability', 'Start from, Switch all', 'New pipelines can <b>Start from</b> a copy of any camera\'s pipeline and be made on every camera at once. <b>Switch every camera</b> to pipeline N from the menu.', '', '#camsetup|In chapter 20 →'],
    ['photonvision-47', 'usability', 'Pipeline numbers', 'The Pipeline dropdown and Camera Matching show "N: name", so a mismatched profile is easy to spot.', '', ''],
    ['photonvision-48', 'speed', 'Hidden tabs stop their streams', 'A dashboard tab behind another tab, or minimised, disconnects its streams, so the Jetson stops encoding them. Also fixes streams that broke after a restart.', '', ''],
    ['photonvision-49', 'robot', 'Idle while disabled', 'While the robot is disabled, each camera runs at 30 fps instead of 122, back to full rate within 5 ms of enable. A garbage collection runs on disable.', '5 cameras: 9.7 → 7.8 W while disabled', '#pit|In chapter 21 →'],
    ['photonvision-50', 'usability', 'Full speed button', 'The dashboard says when the cameras are idling, with a <b>Full speed</b> button. Settings > Robot state sets the idle rate and shows what PhotonVision sees of the robot.', '', ''],
    ['photonvision-51', 'robot', 'Event pipeline', 'When the field (FMS) connects, every camera switches to the event pipeline, once. Anything after that sticks.', '', '#camsetup|In chapter 20 →'],
    ['photonvision-52', 'diag', 'Match Ready page', 'One screen before a match: READY or NOT READY from the health check, problems first, and a live tile per camera.', '', '#pit|In chapter 21 →'],
    ['photonvision-53', 'reliability', 'Settings snapshots', 'Save every setting under a name, restore it (a restore can be undone), or download it. One is saved by itself the first time the field connects each day.', 'about 2 MB each', '#camsetup|In chapter 20 →'],
    ['photonvision-54', 'diag', 'Tag contrast readout', 'Measures each tag\'s white margin and black border and says what to change. The Camera Gain slider hides on cameras with no gain control, like ours.', '', '#settings|In chapter 04 →'],
    ['photonvision-55', 'speed', 'Far-tag search', 'While no camera has a good view, the cameras also search their full-size images, one at a time, for tags too small for the normal search.', 'bench: 1.8× the range (6 m → 10 m)', ''],
    ['photonvision-56', 'reliability', 'Quiet mode', 'Power cuts only hurt an SSD while it\'s being written. After a match the Jetson stops writing: Rewind stops and the logs go to RAM. Any enable ends it.', 'enable to writable in 0.08 s', '#pit|In chapter 21 →'],
    ['photonvision-57', 'reliability', 'Thermal cap', 'Fanless Jetson: at 95 °C every camera is capped at 60 fps, until the chip is under 88 °C.', '', ''],
    ['photonvision-58', 'diag', 'Frames per camera', 'Counts the frames each camera has processed, so the test suite runs only on cameras that really stream.', '', ''],
    ['photonvision-59', 'reliability', 'Snapshot restore in place', 'Restore failed ("Device or resource busy") on a settings file that now lives on its own partition. It writes the file in place. Found by tests/ui.', '', ''],
    ['photonvision-60', 'diag', 'Fake cameras', 'Lists cameras that are plugged in but unused, so fake-cameras.sh can switch PhotonVision to virtual cameras playing a Rewind recording.', '', ''],
    ['bos-01', 'reliability', 'Non-fatal CUDA errors', 'A CUDA error throws instead of stopping the program: skip one frame, restart only if the GPU is broken for 1 s.', 'worst outage 62 s → 8 s', ''],
    ['bos-02', 'reliability', 'Blank frames', 'No zero-block kernel launch when there\'s nothing to detect: return "no detections" early.', 'blank frames pass at 5 resolutions', ''],
    ['bos-03', 'speed', 'No debug timing every frame', 'The detector asked the GPU for 22 timestamps after every frame, for a report that only prints in debug mode. All cameras share one CUDA lock, so they took turns on it.', '4 cameras: detect 3.1 → 2.2 ms, 0.36 fewer cores', ''],
    ['bos-04', 'speed', 'Fused BlobDiff', 'Find blob edges and drop the empty ones in one GPU step, not two (the original author\'s own to-do). ~5,000 replayed frames gave identical tags.', '4 cameras: detect 2.2 → 1.9 ms', ''],
    ['bos-05', 'speed', 'First stage as one CUDA graph', 'The first 13 GPU steps are recorded once and launched as one: 13 CUDA calls a frame become one, and each call took the shared lock.', '4 cameras: detect 1.3 → 1.2 ms', ''],
    ['bos-06', 'speed', 'Line-fit scan on its own stream', 'One step ran on CUDA\'s default stream, so each camera\'s step waited for the other cameras\' GPU work.', '', ''],
    ['bos-07', 'usability', 'Masks on the GPU', 'The detector side of detection masks: ignored pixels become "no contrast" right after thresholding, so nothing is found there.', 'tags outside the mask: identical corners', ''],
    ['bos-08', 'reliability', 'A frame that took minutes', 'A candidate tag with a corner far outside the image made one full-size search run for minutes. Such shapes are skipped, and the samples capped.', 'normal detection unchanged', ''],
    ['gpudetector-01', 'reliability', 'Clear stale CUDA errors', 'For the older 4143 detector: clear leftover errors after each stage and log which stage left one.', '', ''],
    ['gpudetector-02', 'diag', 'The "971 stats" line', 'Once a second: frames, ms per frame, tags per frame, decision margin. It showed the GPU was idle.', '', ''],
    ['gpudetector-03', 'reliability', 'Leak and handle fixes', 'Austin\'s fix for a leak on every tag decode, plus detector slots that are reused and checked.', 'stress test: 300 detectors', ''],
    ['uvcvideo payload cap', 'speed', 'Camera driver bandwidth cap', 'Our patch to Linux\'s USB camera driver: cap what each camera reserves on the shared USB 2.0 bus.', '4 cameras fit instead of 2', '#speed|In chapter 10 →'],
    ['uvcvideo urb packets', 'speed', 'Smaller USB batches', 'The driver looks at a camera\'s USB packets every 2 ms instead of every 4 ms (16 packets per batch, not 32), so each finished frame reaches PhotonVision sooner.', '5 cameras: 12.98 → 11.76 ms latency', ''],
  ];
  {
    const svg = $('#pv-build');
    let t0 = -99, bad = false, now = 0;
    const mark = (b) => { $('#pv-build-go').classList.toggle('primary', b === 'go'); $('#pv-build-bad').classList.toggle('primary', b === 'bad'); };
    $('#pv-build-go').onclick = () => { bad = false; t0 = now; mark('go'); };
    $('#pv-build-bad').onclick = () => { bad = true; t0 = now; mark('bad'); };
    const pv = PATCHES.filter((p) => p[0].startsWith('photonvision'));
    Site.loop(svg, (t) => {
      now = t;
      const e = t - t0 < 0 ? 99 : t - t0;
      let s = '';
      // base
      if (e >= 90) s += `<text x="30" y="40" font-size="14" font-weight="600" fill="#6b1199">Press a button to run the build.</text>`;
      s += `<rect x="30" y="248" width="280" height="36" rx="8" fill="#3c0060"/><text x="44" y="271" font-size="13" font-weight="700" fill="#fff">4143 fork @ d8c9e8e</text>`;
      const dt = 3 / pv.length, step = 190 / pv.length; // the stack fits the same box however many patches there are
      const n = Math.min(pv.length, Math.floor(e / dt) + (e < 90 ? 1 : 0));
      for (let i = 0; i < n; i++) {
        const y = 242 - i * step, [id, g] = pv[i], drop = Site.clamp((e - i * dt) / 0.15 + 0.3, 0, 1);
        s += `<rect x="30" y="${y - 5 - (1 - drop) * 40}" width="280" height="${step * 0.82}" rx="1.5" fill="${GROUPS[g][1]}" opacity="${drop}"/>`;
      }
      if (n > 0) s += `<text x="320" y="${Math.max(50, 246 - n * step)}" font-size="12" fill="#635a72">+ ${pv[n - 1][0].replace('photonvision-', 'patch ')}</text>`;
      s += `<text x="30" y="${238 - pv.length * step - 10}" font-size="11" fill="#8b5cf6" font-weight="700" letter-spacing="1">${n >= pv.length ? `ALL ${pv.length} PATCHES APPLIED` : n > 0 ? 'git apply…' : ''}</text>`;
      // jar
      const jb = Site.clamp((e - 3.4) / 0.8, 0, 1);
      if (e > 3.3) {
        s += `<path d="M420 150 H 470" stroke="#b69ce0" stroke-width="2"/><text x="480" y="108" font-size="12" fill="#635a72">gradle build, ~30 s</text>`;
        const jw = bad ? 3 : 150 * jb;
        s += `<rect x="480" y="120" width="150" height="60" rx="10" fill="#faf5ff" stroke="#d4c0ee"/><rect x="480" y="120" width="${jw}" height="60" rx="10" fill="${bad ? '#dc2626' : '#8b5cf6'}"/>`;
        s += `<text x="490" y="205" font-size="13" font-weight="700" fill="#4c0070">photonvision.jar</text><text x="490" y="223" font-size="12" fill="${bad ? '#dc2626' : '#635a72'}">${bad ? 'only 228 KB of 76 MB copied!' : jb < 1 ? 'building…' : '76 MB'}</text>`;
      }
      // install checks
      const steps = bad ? [['valid zip?', '✗ no: refused', '#dc2626'], ['photonvision.jar.prev', 'kept, still running', '#16a34a'], ['PhotonVision', '✓ stays up', '#16a34a']]
        : [['valid zip?', '✓ yes', '#16a34a'], ['old jar', '→ photonvision.jar.prev', '#6b1199'], ['restart PhotonVision', '✓ new PID checked', '#16a34a']];
      if (e > 4.4) s += `<path d="M640 150 H 675" stroke="#b69ce0" stroke-width="2"/><text x="690" y="60" font-size="12" font-weight="700" fill="#4c0070">06-install-fork-jar.sh</text>`;
      steps.forEach(([a, b, c], i) => {
        const on = e > 4.6 + i * 0.5;
        if (!on) return;
        const y = 76 + i * 62;
        s += `<rect x="690" y="${y}" width="290" height="50" rx="10" fill="#fff" stroke="${c}" stroke-width="1.8"/><text x="704" y="${y + 21}" font-size="13" font-weight="700" fill="#1f1b23">${a}</text><text x="704" y="${y + 39}" font-size="12.5" font-weight="600" fill="${c}">${b}</text>`;
      });
      svg.innerHTML = s;
    });
  }

  /* ── 5. Patch gallery ─────────────────────────────────── */
  {
    const fl = $('#pv-filters'), gal = $('#pv-gallery');
    const count = (g) => PATCHES.filter((p) => p[1] === g).length;
    fl.innerHTML = `<button data-g="all" class="on">All <small>${PATCHES.length}</small></button>` + Object.entries(GROUPS).map(([k, [n, c]]) => `<button data-g="${k}"><i style="background:${c}"></i>${n} <small>${count(k)}</small></button>`).join('');
    gal.innerHTML = PATCHES.map(([id, g, name, what, eff, story]) => `<div class="pcard" data-g="${g}" style="--c:${GROUPS[g][1]}"><div class="top"><span class="num">${id.replace('photonvision-', 'PV ')}</span><span style="font-size:.72rem;color:${GROUPS[g][1]};font-weight:700">${GROUPS[g][0]}</span></div><h5>${name}</h5><div>${what}</div><div class="eff">${eff}</div>${story ? (story[0] === '#' ? `<a class="more" href="${story.split('|')[0]}">${story.split('|')[1]}</a>` : `<a class="more" href="#${story}">Read the story ↓</a>`) : ''}</div>`).join('');
    fl.addEventListener('click', (e) => {
      const b = e.target.closest('button'); if (!b) return;
      fl.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
      gal.querySelectorAll('.pcard').forEach((c) => c.classList.toggle('hide', b.dataset.g !== 'all' && c.dataset.g !== b.dataset.g));
    });
  }

  /* ── 6. Story visuals ─────────────────────────────────── */
  // 27: sharp vs stretched
  {
    const cv = $('#pv-c27'), st = Site.canvas(cv, 0.62);
    const small = document.createElement('canvas'); small.width = small.height = 16;
    small.getContext('2d').drawImage(Site.tagCanvas(3, 200), 0, 0, 16, 16);
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st, s = Math.min(w * 0.3, h * 0.55), y = 22;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      ctx.font = '600 11px "Plus Jakarta Sans", sans-serif';
      ctx.imageSmoothingEnabled = false; ctx.drawImage(Site.tagCanvas(3, 200), w * 0.25 - s / 2, y, s, s);
      ctx.imageSmoothingEnabled = true; ctx.drawImage(small, w * 0.75 - s / 2, y, s, s);
      ctx.fillStyle = LIME; ctx.textAlign = 'center'; ctx.fillText('1280×800: what we set', w * 0.25, 14);
      ctx.fillStyle = AMBER; ctx.fillText('320×240, stretched to fit', w * 0.75, 14);
      ctx.fillStyle = MUTED; ctx.fillText('same 122 fps, no error: which would you notice?', w / 2, y + s + 20);
      const cy = h - 22, r = Math.min(8, w / 60), k = Math.floor(t * 4) % 24;
      for (let i = 0; i < 20; i++) {
        const x = w / 2 + (i - 9.5) * (r * 2.6);
        ctx.fillStyle = i === 13 ? RED : i <= k ? 'rgba(163,230,53,.8)' : 'rgba(255,255,255,.12)';
        ctx.beginPath(); ctx.arc(x, cy, r, 0, 7); ctx.fill();
      }
      ctx.fillStyle = MUTED; ctx.fillText('20 PhotonVision starts', w / 2, cy - r - 6); ctx.textAlign = 'left';
    });
  }
  // 15: stream only when watched
  {
    const cv = $('#pv-c15'), st = Site.canvas(cv, 0.5); let watch = false;
    Site.seg($('#pv-s15-seg'), (v) => (watch = v === '1'));
    Site.loop(cv, (t) => {
      const { ctx, w, h } = st;
      ctx.fillStyle = BG; ctx.fillRect(0, 0, w, h);
      const bw = w * 0.27, bh = 32, y1 = 8, y2 = y1 + bh + 34, xs = [0, (w - bw) / 2, w - bw];
      const box = (x, y, lab, on) => { ctx.fillStyle = on ? 'rgba(139,92,246,.35)' : 'rgba(255,255,255,.05)'; ctx.fillRect(x, y, bw, bh); ctx.strokeStyle = on ? SOFT : 'rgba(196,181,253,.25)'; ctx.strokeRect(x + .5, y + .5, bw - 1, bh - 1); ctx.fillStyle = on ? '#fff' : MUTED; ctx.font = '600 11.5px "Plus Jakarta Sans", sans-serif'; ctx.fillText(lab, x + 8, y + 20); };
      box(xs[0], y1, 'camera', true); box(xs[1], y1, 'pipeline', true); box(xs[2], y1, 'robot', true);
      box(xs[1], y2, 'stream thread', watch); box(xs[2], y2, 'browser', watch);
      ctx.fillStyle = ACC;
      for (let i = 0; i < 16; i++) { const u = (t * 1.2 + i / 16) % 1, x = bw + u * (w - 2 * bw); if (x > xs[1] - 4 && x < xs[1] + bw) continue; ctx.fillRect(x, y1 + bh / 2 - 2, 5, 5); }
      if (watch) { ctx.fillStyle = AMBER; for (let i = 0; i < 3; i++) { const u = (t * .6 + i / 3) % 1; ctx.fillRect(xs[1] + bw / 2 - 3, y1 + bh + u * (y2 - y1 - bh), 6, 6); ctx.fillRect(xs[1] + bw + u * (xs[2] - xs[1] - bw) - 3, y2 + bh / 2 - 3, 6, 6); } }
      ctx.fillStyle = '#fff'; ctx.font = '800 22px Outfit, sans-serif'; ctx.fillText(watch ? '0.47 cores' : '0.43 cores', 0, h - 24);
      ctx.fillStyle = MUTED; ctx.font = '600 11px "Plus Jakarta Sans", sans-serif'; ctx.fillText(watch ? 'was 0.52, with the stream at 121 fps; now 30 fps' : 'was 0.49: the stream thread worked for no one', 0, h - 6);
    });
  }
  // 13: timestamp timeline
  {
    const x0 = 14, sc = 30; // px per ms (the unknown camera delay is drawn at 3 ms)
    let s = '<defs><marker id="pv-ar3" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" fill="#dc2626"/></marker></defs>';
    const y = 58, bh = 34, tMid = x0 + 2.5 * sc, tFirst = x0 + 8 * sc + 4;
    s += `<rect x="${x0}" y="${y}" width="${5 * sc}" height="${bh}" rx="6" fill="#8b5cf6"/><text x="${x0 + 8}" y="${y + 14}" font-size="12" font-weight="700" fill="#fff">exposure</text><text x="${x0 + 8}" y="${y + 28}" font-size="12" fill="#f3e8ff">5 ms</text>`;
    s += `<rect x="${x0 + 5 * sc + 2}" y="${y}" width="${3 * sc}" height="${bh}" rx="6" fill="#f3e8ff" stroke="#c4b5fd" stroke-dasharray="4 3"/><text x="${x0 + 5 * sc + 8}" y="${y + 14}" font-size="12" fill="#6b1199">camera</text><text x="${x0 + 5 * sc + 8}" y="${y + 28}" font-size="12" fill="#6b1199">delay ?</text>`;
    s += `<rect x="${tFirst}" y="${y}" width="${4.7 * sc}" height="${bh}" rx="6" fill="#06b6d4"/><text x="${tFirst + 8}" y="${y + 14}" font-size="12" font-weight="700" fill="#fff">USB transfer</text><text x="${tFirst + 8}" y="${y + 28}" font-size="12" fill="#ecfeff">~4.9 ms</text>`;
    s += `<line x1="${tFirst}" y1="${y - 18}" x2="${tFirst}" y2="${y + bh + 6}" stroke="#1f1b23" stroke-width="2"/><text x="${tFirst}" y="${y - 24}" font-size="12" font-weight="600" text-anchor="middle" fill="#1f1b23">driver stamps: first packet</text>`;
    s += `<line x1="${tMid}" y1="${y - 4}" x2="${tMid}" y2="${y + bh + 42}" stroke="#16a34a" stroke-width="3"/><text x="${tMid - 4}" y="${y + bh + 58}" font-size="13" font-weight="700" fill="#16a34a">new stamp: mid-exposure</text>`;
    s += `<path d="M${tFirst} ${y + bh + 20} H ${tMid + 8}" stroke="#dc2626" stroke-width="2" stroke-dasharray="5 4" marker-end="url(#pv-ar3)"/><text x="${tMid + 14}" y="${y + bh + 15}" font-size="11.5" fill="#dc2626">subtract half the exposure</text>`;
    s += `<text x="${x0}" y="190" font-size="11.5" fill="#635a72">The camera's own delay is still to be measured on the robot.</text>`;
    const svg = $('#pv-c13'); svg.setAttribute('viewBox', '0 0 440 200'); svg.innerHTML = s;
  }
  // 29: recovery timeline
  {
    const x0 = 44, sc = 36;
    let s = `<line x1="${x0}" y1="84" x2="${x0 + 10 * sc}" y2="84" stroke="#d4c0ee" stroke-width="3"/>`;
    s += `<rect x="${x0}" y="72" width="${9.1 * sc}" height="24" rx="6" fill="#fee2e2"/><text x="${x0 + 3.4 * sc}" y="89" font-size="12" fill="#b91c1c">no usable frames</text>`;
    const ev = [[0, 'frames stop', '#dc2626', 1], [3, 'reconnect', '#d97706', -1], [8, 'USB reset', '#d97706', 1], [9.1, 'back ✓', '#16a34a', -1]];
    for (const [t, lab, c, up] of ev) {
      const x = x0 + t * sc;
      s += `<circle cx="${x}" cy="84" r="7" fill="${c}"/><line x1="${x}" y1="${up > 0 ? 58 : 110}" x2="${x}" y2="${up > 0 ? 77 : 91}" stroke="${c}" stroke-width="2"/><text x="${x}" y="${up > 0 ? 50 : 128}" font-size="13" font-weight="700" text-anchor="middle" fill="${c}">${lab}</text><text x="${x}" y="${up > 0 ? 34 : 144}" font-size="12" text-anchor="middle" fill="#635a72">${t} s</text>`;
    }
    s += `<text x="10" y="172" font-size="11.5" fill="#635a72">Bench test (TopRight). Still stuck? A USB reset every 30 s.</text>`;
    $('#pv-c29').innerHTML = s;
  }
  // 22: excluded tags
  {
    const box = $('#pv-tags'), note = $('#pv-tags-note'), off = new Set([7, 12]);
    const ids = Array.from({ length: 16 }, (_, i) => i + 1);
    box.innerHTML = ids.map((id) => `<button data-id="${id}" aria-label="Tag ${id}">${Site.tagSVG(id, 60)}<span>${id}</span></button>`).join('');
    const upd = () => {
      box.querySelectorAll('button').forEach((b) => b.classList.toggle('off', off.has(+b.dataset.id)));
      note.innerHTML = `Multi-tag uses <b style="color:#fff">${16 - off.size} of 16</b> tags in view. Excluded: ${off.size ? [...off].sort((a, b) => a - b).join(', ') : 'none'} (still reported, dimmed).`;
    };
    box.addEventListener('click', (e) => { const b = e.target.closest('button'); if (!b) return; const id = +b.dataset.id; off.has(id) ? off.delete(id) : off.add(id); upd(); });
    upd();
  }
  /* ── 7. Bug stories ───────────────────────────────────── */
  {
    const B = [
      ['🧠', 'Memory leak', 'Found by comparing 4143\'s copy with Austin\'s newest code, before it ever bit us.', 'The detector leaked two small matrices every time it decoded a tag.', 'Applied Austin\'s upstream fix (3e570d5a).', 'Tiny leaks add up over a long event.'],
      ['🎰', 'Detector slots', 'After enough pipeline changes: undefined behavior.', '10 detector slots, never reused. The 11th got handle −1 and read before the array.', 'Reuse slots, check every handle, free detectors (gpudetector-03). Stress test: 300 detectors.', 'Check every handle; give back what you take.'],
      ['🚩', 'Stale CUDA error', 'A CUB step failed on every frame after a pipeline switch.', 'CUDA\'s error flag stays set; newer CUB fails on any leftover error from an unchecked call.', 'Clear leftover errors before each frame; check the unchecked calls.', 'Check every error, or a later call pays for it.'],
      ['💣', 'One GPU error crashed everything', 'Any CUDA error took PhotonVision, and every camera, down.', 'Austin\'s code aborts the whole program on a CUDA error.', 'Skip one frame; restart only if the GPU context stays broken for 1 s (bos-01).', 'Contain failures: lose a frame, not the robot\'s eyes.'],
      ['⬛', 'Blank frames', 'A covered lens restarted PhotonVision in a loop.', 'No blobs meant a kernel launch with 0 blocks, an invalid launch.', 'Return "no detections" early (bos-02). Tested at 5 resolutions.', 'Test the boring inputs: a dark pit is a real case.'],
      ['⏳', '62-second restart', 'After a crash, vision was gone for about a minute.', 'Ubuntu\'s crash reporter spent 28 s writing a 156 MB file first.', 'Exit cleanly, no JVM core dumps. Worst case now ~8 s.', 'Measure how long recovery takes, not just that it happens.'],
      ['📄', 'Blank AprilCudaTag tab', 'The fork\'s settings tab showed nothing.', 'Written for Vue 2; the UI runs Vue 3.', 'Ported to Vue 3, showing only settings that work (photonvision-01).', 'Framework upgrades break old code quietly.'],
      ['🦊', 'Missing Device Control card', 'No Restart button in Firefox.', 'A brand-new browser feature (Intl.DurationFormat) Firefox 130 lacked.', 'Check for the feature and fall back (photonvision-03).', 'Don\'t assume every browser has the newest features.'],
      ['📦', 'Truncated jar', 'PhotonVision wouldn\'t start after a deploy.', 'Only 228 KB of a 76 MB jar was copied; we trusted the old process\'s log.', 'The installer refuses invalid jars and keeps the last good one.', 'Validate before you deploy; check the running process itself.'],
      ['🎨', 'Color decode hiding in cscore', 'Most of a CPU core per camera, even in "gray" mode.', 'cscore decoded every JPEG to full color, then converted to gray: 8.9 ms.', 'Decode straight to gray ourselves: 2.6 ms (photonvision-09).', 'Profile: the cost hid inside one library call.'],
      ['⏱️', 'Debug timing on every frame', 'With 4 cameras: 2.2 CPU cores, over half inside the Linux kernel, and 4.4 ms detects instead of 1.5.', 'After every frame the detector asked the GPU for 22 timestamps, for a report only printed in debug mode. All 4 cameras share one CUDA lock, so they took turns on it tens of thousands of times a second.', 'Record the timestamps only when the report is on (bos-03): detect 3.1 → 2.2 ms, 0.36 fewer cores. Found with Linux\'s ftrace and gdb.', 'Code that does nothing visible can still cost a lot, especially when it holds a shared lock.'],
      ['🔍', 'Camera stuck at 320×240', 'Shorter range and 1.7 cores, at 1 start in 20. No error.', 'Two startup steps raced to set the video mode; the fallback stretched tiny frames.', 'A size mismatch reopens the camera instead of falling back (photonvision-27).', 'A silent fallback hides failures. Make them loud.'],
      ['🔁', 'Stuck at 320×240, for real this time', 'TopRight came up at 320×240 again. The "reconnecting" warning repeated every 3 s for minutes.', 'The driver refused 1280×800 ("device busy"): the old connection wasn\'t released yet. The recovery only paused and restarted the stream, which never sends the format again. And the log said "Failed" on every start that worked.', 'Switch the camera to another mode and back, which really reopens it (photonvision-37). "Failed" now means a real failure.', 'Read the library\'s source before trusting what a function name says it does.'],
      ['🧵', 'A camera\'s thread killed at startup', 'One camera never ran, until PhotonVision restarted.', 'While cameras were still being added, its thread read the camera list for the dashboard and crashed (ConcurrentModificationException).', 'A list that\'s safe to read while it grows, and a dashboard update can no longer kill a camera thread (photonvision-38).', 'Two threads sharing a list need a list built for sharing.'],
      ['🧊', 'Frozen frames from the JPEG hardware', 'The hardware decoder looked fast, and said "success".', 'Called the usual way, it returned the first frame over and over.', 'Call it differently; re-check one frame per camera every 2 s against the CPU decoder.', 'Fast isn\'t correct. Compare the outputs.'],
      ['📈', 'Leak in NVIDIA\'s JPEG library', 'PhotonVision grew to 5.6 GB and Linux killed it, twice.', '~250 KB leaked every frame unless the library is in MJPEG mode.', 'One setting (mjpeg_decode); memory stays flat over 116,000 frames.', 'Run long tests and watch memory, not just speed.'],
      ['🔭', 'Lens model cut short', 'Corners near the image edge came out slightly off.', 'Calibration makes 8 distortion numbers; the detector got only 5.', 'A new setparams8 call passes all 8 (photonvision-04).', 'Pass all the data along: one missing number bends the answer.'],
      ['🎚️', 'Sliders that snapped back', 'Contrast, gamma and sharpness changed the picture, but the slider jumped back to the old number.', 'The slider only shows the stored value, and the change was sent without updating it.', 'Update the stored value too (photonvision-39). This bug is why we wrote the browser test suite, tests/ui.', 'Check what the page shows, not just what the camera does.'],
      ['🪞', 'Two dashboards out of sync', 'A second open dashboard kept old values, and could send them back over the first one\'s.', 'Each change went to the other dashboards without the camera\'s name, so they ignored it.', 'Send the camera\'s name with every change (photonvision-41). A second tab now updates within 2 s.', 'Test with two people at once, not one.'],
      ['🐌', 'A frame that took minutes', 'Replaying bench recordings with the far-tag search, a camera froze on one busy frame.', 'A candidate tag with a corner far outside the image made the corner-refining step take hundreds of millions of samples.', 'Skip shapes like that, and cap the samples (bos-08). Normal detection is unchanged.', 'Replay real recordings: they hold the cases nobody thought of.'],
      ['📂', 'An empty backup', 'With the settings partition destroyed, the Jetson would run on a "last-good" copy with no pipelines or calibrations.', 'The commit step checked for the database without sudo, couldn\'t see it, and skipped it.', 'Check with sudo, and stop if the copy fails. Found by tests/storage-fallback.', 'Test a backup by restoring it.'],
      ['💾', 'Snapshot restore failed', 'Restoring a settings snapshot failed with "Device or resource busy".', 'A settings file now lives on its own partition, mounted in place. A mounted file can be rewritten, not replaced.', 'Write it in place (photonvision-59). Found by tests/ui.', 'Run the tests again after moving where files live.'],
      ['🔌', 'A missing camera nobody mentioned', 'BottomLeft dropped off port 2.2, and Match Ready said nothing.', 'The health check only looked at cameras that were plugged in.', 'Every camera in PhotonVision\'s settings whose port is empty now FAILs, by name. Found by tests/ui.', 'Check for what should be there, not just what is.'],
    ];
    $('#pv-bugs').innerHTML = B.map(([ic, t, s, c, f, l]) => `<div class="bug reveal"><div><span style="font-size:1.3rem">${ic}</span>${t}</div><div class="s"><small>Symptom</small>${s}</div><div class="c"><small>Cause</small>${c}</div><div class="f"><small>Fix</small>${f}</div><div class="l"><small>Lesson</small>${l}</div></div>`).join('');
    Site.watchReveals($('#pv-bugs'));
  }
});
