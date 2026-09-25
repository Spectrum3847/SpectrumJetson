Object.assign(Site.glossary, {
  'journal': 'A filesystem\'s notebook of changes it\'s about to make. After a power cut, the journal lets it finish or undo half-done changes instead of corrupting files.',
  'brownout': 'When the battery voltage sags so low (usually from motors pulling hard) that electronics misbehave or reset.',
  'throttling': 'A chip deliberately slowing its clocks to protect itself, because it\'s too hot or its power supply is struggling.',
});

Site.chapter('failsafes', (root) => {
  const $ = (s) => root.querySelector(s);
  const font = (px, w = 600, mono) => `${w} ${px}px ${mono ? 'JetBrains Mono, monospace' : 'Plus Jakarta Sans, sans-serif'}`;

  /* ── Watchdog dog ──────────────────────────────────────── */
  {
    const cv = $('#f-dog'), st = Site.canvas(cv, (cv.clientWidth || cv.parentElement.clientWidth || root.clientWidth) < 500 ? 0.78 : 0.62);
    const since = $('#f-since'), state = $('#f-state'), fb = $('#f-freeze'), pb = $('#f-panic');
    let mode = 'run', lastPat = 0, sim = 0, boot = 0, panicAt = 0, hearts = [];
    const SPEED = 6, LIMIT = 30;
    fb.onclick = () => { if (mode === 'boot' || mode === 'panic') return; if (mode === 'run') { mode = 'frozen'; fb.textContent = '🔥 Unfreeze'; } else if (mode === 'frozen') { mode = 'run'; lastPat = sim; fb.textContent = '🧊 Freeze Linux'; } };
    pb.onclick = () => { if (mode === 'run' || mode === 'frozen') { mode = 'panic'; panicAt = sim; } };
    Site.loop(cv, (t, dt) => {
      const { ctx, w, h } = st;
      sim += dt * SPEED;
      if (mode === 'run' && sim - lastPat > 6) { lastPat = sim; hearts.push({ x: 0, y: 0, a: 1 }); }
      if (mode === 'frozen' && sim - lastPat > LIMIT) { mode = 'boot'; boot = sim; fb.textContent = '🧊 Freeze Linux'; }
      if (mode === 'panic' && sim - panicAt > 3) { mode = 'boot'; boot = sim; }
      if (mode === 'boot' && sim - boot > 20) { mode = 'run'; lastPat = sim; fb.textContent = '🧊 Freeze Linux'; }
      const el = mode === 'boot' ? 0 : sim - lastPat;
      since.textContent = mode === 'boot' ? '—' : Math.min(el, LIMIT).toFixed(1) + ' s';
      state.textContent = { run: 'running', frozen: 'frozen!', panic: 'kernel panic', boot: 'rebooting' }[mode];
      const busy = mode === 'boot' || mode === 'panic';
      if (fb.disabled !== busy) { fb.disabled = pb.disabled = busy; fb.title = pb.title = busy ? 'Wait: the Jetson is rebooting' : ''; }
      fb.classList.toggle('on', mode === 'frozen'); fb.setAttribute('aria-pressed', mode === 'frozen');
      state.style.color = mode === 'run' ? '#a3e635' : mode === 'boot' ? '#67e8f9' : '#fda4af';
      const frac = Site.clamp(el / LIMIT, 0, 1);
      ctx.fillStyle = '#0e0518'; ctx.fillRect(0, 0, w, h);
      const s = Math.min(w / 460, h / 285);
      ctx.save(); ctx.translate(w * 0.42, h * 0.58); ctx.scale(s, s);
      // floor shadow
      ctx.fillStyle = 'rgba(0,0,0,.35)'; ctx.beginPath(); ctx.ellipse(10, 78, 120, 14, 0, 0, 7); ctx.fill();
      const angry = mode === 'boot' && sim - boot < 3;
      const wag = mode === 'run' ? Math.sin(t * 14) * 0.5 : mode === 'frozen' ? Math.sin(t * 3) * 0.1 : 0;
      const shake = angry ? Math.sin(t * 50) * 3 : 0;
      ctx.translate(shake, 0);
      // tail
      ctx.save(); ctx.translate(-78, -8); ctx.rotate(-0.7 + wag); ctx.fillStyle = '#c08a4a'; ctx.beginPath(); ctx.ellipse(0, -22, 8, 24, 0, 0, 7); ctx.fill(); ctx.restore();
      // legs
      ctx.fillStyle = '#a8743c'; for (const lx of [-58, -30, 30, 54]) { ctx.beginPath(); ctx.roundRect(lx - 9, 30, 18, 46, 8); ctx.fill(); }
      // body
      ctx.fillStyle = '#c08a4a'; ctx.beginPath(); ctx.ellipse(0, 18, 90, 42, 0, 0, 7); ctx.fill();
      ctx.fillStyle = '#e6c08f'; ctx.beginPath(); ctx.ellipse(10, 34, 50, 20, 0, 0, 7); ctx.fill();
      // collar
      ctx.fillStyle = '#8b5cf6'; ctx.beginPath(); ctx.roundRect(56, -28, 16, 40, 6); ctx.fill();
      ctx.fillStyle = '#fcd34d'; ctx.beginPath(); ctx.arc(64, 14, 6, 0, 7); ctx.fill();
      // head
      const tilt = mode === 'frozen' ? -0.15 * frac : 0;
      ctx.save(); ctx.translate(92, -34); ctx.rotate(tilt);
      ctx.fillStyle = '#8a5a2b'; ctx.beginPath(); ctx.ellipse(-26, -24, 13, 26, -0.5 + (angry ? -0.6 : 0), 0, 7); ctx.fill();
      ctx.fillStyle = '#c08a4a'; ctx.beginPath(); ctx.arc(0, 0, 38, 0, 7); ctx.fill();
      ctx.fillStyle = '#e6c08f'; ctx.beginPath(); ctx.ellipse(26, 12, 26, 18, 0, 0, 7); ctx.fill();
      ctx.fillStyle = '#1f1b23'; ctx.beginPath(); ctx.arc(46, 4, 7, 0, 7); ctx.fill();
      // eyes
      ctx.fillStyle = '#1f1b23';
      if (mode === 'run') { ctx.lineWidth = 3; ctx.strokeStyle = '#1f1b23'; ctx.beginPath(); ctx.arc(8, -10, 6, Math.PI * 1.1, Math.PI * 1.9); ctx.stroke(); }
      else { ctx.beginPath(); ctx.arc(8, -10, angry ? 4 : 5, 0, 7); ctx.fill(); if (angry) { ctx.lineWidth = 3; ctx.strokeStyle = '#1f1b23'; ctx.beginPath(); ctx.moveTo(-2, -22); ctx.lineTo(16, -16); ctx.stroke(); } }
      // mouth
      ctx.strokeStyle = '#1f1b23'; ctx.lineWidth = 2.5; ctx.beginPath();
      if (angry) { ctx.fillStyle = '#7f1d1d'; ctx.ellipse(30, 24, 12, 8, 0, 0, 7); ctx.fill(); ctx.fillStyle = '#fff'; ctx.fillRect(22, 17, 4, 5); ctx.fillRect(34, 17, 4, 5); }
      else if (mode === 'run') { ctx.arc(30, 18, 9, 0.2, Math.PI - 0.2); ctx.stroke(); ctx.fillStyle = '#f472b6'; ctx.beginPath(); ctx.ellipse(32, 30, 5, 8, 0, 0, 7); ctx.fill(); }
      else { ctx.moveTo(22, 24); ctx.lineTo(38, 22); ctx.stroke(); }
      ctx.restore();
      ctx.restore();
      // petting hand (systemd)
      const px = w * 0.42 + 10 * s, py = h * 0.58 - 78 * s;
      if (mode === 'run') {
        const ph = ((sim - lastPat) / 6);
        const dy = Math.sin(Math.min(1, ph * 3) * Math.PI) * 18 * s;
        ctx.font = `${Math.round(34 * s)}px serif`; ctx.textAlign = 'center'; ctx.fillText('✋', px, py - 30 * s + dy);
        ctx.fillStyle = '#c4b5fd'; ctx.font = font(Math.max(10, 12 * s), 700); ctx.fillText('systemd', px, py - 64 * s);
      }
      hearts = hearts.filter((hh) => (hh.a -= dt * 0.8) > 0);
      for (const hh of hearts) { ctx.globalAlpha = hh.a; ctx.font = `${Math.round(22 * s)}px serif`; ctx.textAlign = 'center'; ctx.fillText('💜', w * 0.42 + 110 * s + (1 - hh.a) * 20 * s, h * 0.58 - 90 * s - (1 - hh.a) * 50 * s); }
      ctx.globalAlpha = 1;
      if (mode === 'frozen') { ctx.font = `${Math.round(40 * s)}px serif`; ctx.textAlign = 'center'; ctx.fillText('🧊', px - 40 * s, py - 30 * s); }
      if (mode === 'panic') { ctx.fillStyle = '#fda4af'; ctx.font = font(Math.max(11, 13 * s), 800, true); ctx.textAlign = 'center'; ctx.fillText(`Kernel panic! rebooting in ${Math.max(0, 3 - (sim - panicAt)).toFixed(1)} s`, w / 2, 24); }
      if (angry) { ctx.fillStyle = '#fcd34d'; ctx.font = font(Math.max(18, 30 * s), 800); ctx.textAlign = 'center'; ctx.fillText('WOOF! RESET!', w * 0.72, h * 0.2); }
      if (mode === 'boot' && !angry) {
        ctx.fillStyle = '#67e8f9'; ctx.font = font(Math.max(11, 14 * s), 700); ctx.textAlign = 'center';
        const bt = sim - boot;
        ctx.fillText(bt < 16.5 ? `Booting… ${bt.toFixed(1)} s (boot takes 16.5 s)` : `Starting PhotonVision… detecting at ~20 s`, w / 2, 24);
      }
      // timer bar
      const bx = 16, by = h - 26, bw = w - 32;
      ctx.fillStyle = 'rgba(255,255,255,.08)'; ctx.beginPath(); ctx.roundRect(bx, by, bw, 12, 6); ctx.fill();
      const col = frac < 0.6 ? '#a3e635' : frac < 0.85 ? '#f59e0b' : '#f43f5e';
      ctx.fillStyle = col; ctx.beginPath(); ctx.roundRect(bx, by, Math.max(12, bw * frac), 12, 6); ctx.fill();
      ctx.fillStyle = '#b8a9d4'; ctx.font = font(10.5, 600); ctx.textAlign = 'left'; ctx.fillText('watchdog timer', bx, by - 6);
      ctx.textAlign = 'right'; ctx.fillText('30 s → hardware reset', bx + bw, by - 6);
    });
  }

  /* ── Fault injection lab ───────────────────────────────── */
  const FAULTS = [
    { id: 'unplug', icon: '🔌', name: 'Camera unplugged', time: '~1 s after replug', secs: 0.9, m: 1,
      src: 'tests/camera-replug/run.sh (TopLeft pulled for 7.4 s)',
      steps: [
        ['fault', ['camA'], '', 'TopLeft\'s cable is pulled.'],
        ['detect', ['pv'], 'at once', 'cscore (PhotonVision\'s camera library) sees the disconnect and retries about every 0.3 s.'],
        ['info', ['camB', 'robot'], '', 'TopRight keeps detecting the whole time. One camera never takes the others down.'],
        ['recover', ['camA', 'hub', 'kern'], '+0.35 s', 'Plugged back in: the kernel finds it, and cscore reconnects at 1280×800 in 0.35 s.'],
        ['recover', ['pv', 'gpu', 'robot'], '+0.9 s', 'Detecting again on the same detector (calibration kept) 0.9 s after replugging. Full 105 fps within 2 s.'],
      ] },
    { id: 'corrupt', icon: '🧩', name: 'Camera stuck sending garbage', time: '~9 s', secs: 9.1, m: 1,
      src: 'photonvision-29, bench test with its test hook on TopRight',
      steps: [
        ['fault', ['camB'], '', 'TopRight is connected but sends only corrupt frames ("invalid JPEG image received"). Seen once after rapid restarts.', 'TopRight is connected but sends only corrupt frames ("invalid JPEG image received").'],
        ['detect', ['pv'], '+3 s', 'The stuck-camera watchdog sees no usable frame for 3 s and reconnects the camera.'],
        ['detect', ['pv', 'kern', 'hub'], '+8 s', 'Still nothing 5 s later: a USB-level reset, like unplugging and replugging it in software.'],
        ['recover', ['camB', 'kern'], '+9.1 s', 'The kernel re-finds the camera and re-applies its USB bandwidth cap. cscore reconnects.'],
        ['recover', ['pv', 'robot'], '', '"delivering frames again, after a USB reset." The health/recoveries topic counts it.'],
      ] },
    { id: 'cuda', icon: '⚡', name: 'One CUDA error', time: 'one frame', secs: 0.0083, m: 1,
      src: 'bos-01 + detector/, fault injection with /tmp/spectrum-971-fault-every',
      steps: [
        ['fault', ['gpu'], '', 'A GPU call fails on one frame.'],
        ['detect', ['gpu', 'pv'], 'same frame', 'The error is caught instead of crashing the program (it used to abort everything).', 'The error is caught; the program keeps running.'],
        ['recover', ['gpu'], 'next frame', 'That frame is skipped and the detector is rebuilt on the next one.'],
        ['info', ['robot'], '', 'Tested with 1 error every 100 frames: no restart, 99% of frames still detected.'],
      ] },
    { id: 'gpu', icon: '🧨', name: 'GPU context broken', time: '~8 s (was 62 s)', ts: '~8 s', cl: '~8 s', secs: 8, m: 1,
      src: 'CUDA error handling, fault injection: every frame failing',
      steps: [
        ['fault', ['gpu'], '', 'Every frame fails: the GPU context itself is broken.'],
        ['detect', ['gpu'], '1 s', 'After each failure the detector checks the GPU (cudaDeviceSynchronize). Broken for a full second? It exits cleanly with _exit.'],
        ['detect', ['sysd'], '+1.7 s', 'PhotonVision has exited. systemd notices at once (Restart=always).'],
        ['recover', ['sysd', 'pv'], '', 'systemd restarts PhotonVision. No crash report, no core dump.'],
        ['recover', ['gpu', 'robot'], '+8 s', 'Detecting again 6.2 s after the exit: about 8 s in total. Before our fixes: about 62 s.', 'Detecting again 6.2 s after the exit: about 8 s in total.'],
      ] },
    { id: 'crash', icon: '💥', name: 'PhotonVision crashes', time: 'seconds', cl: '≈ 6 s', secs: 6.2, m: 0,
      src: 'Restart=always and StartLimitIntervalSec=0 (09-robot-tuning.sh); JVM core dumps off (06-install-fork-jar.sh)',
      steps: [
        ['fault', ['pv'], '', 'The Java program dies, for any reason.'],
        ['detect', ['sysd'], 'at once', 'systemd sees its service exit.'],
        ['recover', ['sysd', 'pv'], '', 'Restart=always restarts it, with no limit on how many times (StartLimitIntervalSec=0). Java core dumps are off, so a native crash doesn\'t stall writing a huge file first.'],
        ['recover', ['gpu', 'robot'], '≈ 6 s', 'Back to detecting in about 6 s: the restart time we measured after the GPU fault exit.'],
        ['info', ['ssd'], '', 'If the program file itself is broken, the install script\'s saved photonvision.jar.prev gets it running again.'],
      ] },
    { id: 'hang', icon: '🧊', name: 'Linux freezes', time: '≈ 50 s', secs: 50, m: 0,
      src: 'zz-spectrum-watchdog.conf (RuntimeWatchdogSec=30s), kernel.panic=3; boot time measured after reboot',
      steps: [
        ['fault', ['kern', 'sysd'], '', 'The whole operating system locks up. Nothing in software can react.'],
        ['detect', ['wd'], '30 s', 'systemd stops petting the hardware watchdog. After 30 s the watchdog resets the board.'],
        ['info', ['kern'], '', 'A kernel panic is quicker: kernel.panic=3 reboots 3 s after it. (The default was to sit frozen.)', 'A kernel panic is quicker: the Jetson reboots itself 3 s after it.'],
        ['recover', ['kern', 'sysd', 'pv'], '+16.5 s', 'Linux boots in 16.5 s. PhotonVision starts.'],
        ['recover', ['gpu', 'robot'], '≈ +20 s', 'Detecting about 20 s after the reset. Total ≈ 50 s: added up from measured parts, not timed end to end.'],
      ] },
    { id: 'power', icon: '🔋', name: 'Power cut mid-recording', time: '~20 s after power returns', secs: 20, m: 1,
      src: 'tests/power-cut/run.sh, power pulled 21.4 s into a recording',
      steps: [
        ['fault', ['pwr', 'ssd'], '', 'Power is pulled while Rewind is recording to the SSD.'],
        ['info', ['ssd'], '', 'Already done ahead of time: data reaches the SSD within ~3 s, Rewind syncs every 2 s, the log is kept on the SSD.'],
        ['detect', ['kern', 'ssd'], 'next boot', 'ext4 replays its journal: "recovery complete". 0 filesystem errors.'],
        ['recover', ['sysd', 'pv', 'gpu', 'robot'], '~20 s', 'PhotonVision back, both calibrations loaded, detecting ~20 s after power returns.'],
        ['info', ['ssd'], '', 'The recording kept 20.0 of 21.4 s: 1.4 s lost, every saved frame complete. The log survived up to 3 s before the cut.'],
      ] },
    { id: 'xhci', icon: '🧯', name: 'USB controller dies', time: '~2 s reset', secs: 2, m: 1,
      src: '14-usb-watchdog.sh, tested with a faked "HC died" kernel line',
      steps: [
        ['fault', ['xhci'], '', 'The kernel reports the USB controller dead ("HC died"). Every camera drops off.'],
        ['detect', ['kern'], 'at once', 'Our USB watchdog reads the kernel log and spots the message.'],
        ['recover', ['xhci', 'hub'], '~2 s', 'It resets the USB controller (at most once a minute) in about 2 s. It never reboots the Jetson.'],
        ['recover', ['camA', 'camB', 'pv'], '', 'Cameras re-connect, and it reports which came back within 60 s. (A stuck Thriftiest Cam won\'t: see the next fault.)'],
      ] },
    { id: 'hub', icon: '⚠️', name: 'USB hub reset (known issue)', time: 'until power is cut', secs: Infinity, m: 1,
      src: 'tests/usb-hub-reset/run.sh; photonvision-33 for the problem message',
      steps: [
        ['fault', ['hub', 'camA', 'camB'], '', 'The USB hub resets while the cameras stay powered (a static shock can do this). Both Thriftiest Cams stop answering.'],
        ['detect', ['kern'], '', 'Kernel: "device descriptor read/64, error -110", then "unable to enumerate USB device".'],
        ['info', ['hub'], '~40 s', 'Other cameras (the Global Shutters) come back by themselves in about 40 s: each stuck port holds up the hub ~20 s.'],
        ['detect', ['pv', 'robot'], '', 'health/problem says: "not answering on USB port 1-2.1: replug it, or power-cycle the robot".'],
        ['fault', ['xhci', 'wd'], '', 'Nothing in software revives them: port power off (the 5 V is always on), a controller reset, even a reboot.'],
        ['recover', ['pwr', 'camA', 'camB'], 'pit', 'Only cutting the camera\'s power works: replug it, or power-cycle the robot between matches.'],
      ] },
    { id: 'heat', icon: '🌡️', name: 'Overheating', time: 'no outage', secs: 0, m: 1,
      src: 'Fan and fanless tests (TECHNICAL.md "Match readiness", "Fanless")',
      steps: [
        ['info', ['fan'], '', 'The fan runs at full speed from boot: the hottest sensor went from 56 to 43 °C on the bench.', 'The fan runs at full speed from boot (about 43 °C on the bench).'],
        ['fault', ['fan'], '', 'Suppose the fan dies.'],
        ['detect', ['fan', 'robot'], '', 'health-check.sh reads the fan\'s speed sensor and FAILs under 1,000 rpm. Temperatures are on NetworkTables.'],
        ['info', ['gpu'], 'minutes', 'Fan off at full power: 42 → 85 °C in about 10 minutes. The chip only starts throttling at 99 °C and shuts down at 104.5 °C.'],
        ['recover', ['robot'], '', 'A dead fan isn\'t fatal in a match: the Jetson slowly climbs toward its throttle point. The throttle topic would say HIGH TEMP.'],
      ] },
    { id: 'sag', icon: '📉', name: 'Battery sag / brownout', time: 'no outage if power stays', secs: 0, m: 1,
      src: 'Power board test 2026-09-25; photonvision-20 throttle reason',
      steps: [
        ['fault', ['pwr'], '', 'Motors pull hard and the robot battery sags.'],
        ['recover', ['pwr'], '', 'The Jetson runs from a 15 V boost regulator, which kept it running with its input down at 5 V in our test.'],
        ['detect', ['gpu', 'robot'], '', 'If the chip\'s supply current spikes, it throttles itself, and /photonvision/jetson/throttle reads OVER-CURRENT.'],
        ['info', ['ssd'], '', 'If power is lost completely, it\'s a power cut: see that fault.'],
      ] },
    { id: 'mode', hist: 1, icon: '🔍', name: 'Camera silently at 320×240', time: '~1–2 s', secs: 1.5, m: 0,
      src: 'photonvision-27; seen at about 1 in 20 PhotonVision starts',
      steps: [
        ['fault', ['camB'], '', 'A startup race leaves TopRight streaming 320×240 while PhotonVision believes 1280×800.'],
        ['info', ['pv'], 'before', 'Old behavior: the frames were silently upscaled. Detection ran at 122 fps on a blurry image, with less range and no error anywhere.'],
        ['detect', ['pv'], '1 s', 'Now a size mismatch never falls back: the frame is dropped, and after 1 s of mismatches the camera is closed and reopened.'],
        ['recover', ['camB', 'pv'], '', 'Reopening makes cscore apply the right video mode again.'],
        ['detect', ['robot'], '', 'health-check.sh also FAILs any camera whose real format differs from what PhotonVision set.'],
      ] },
    { id: 'flood', hist: 1, icon: '📜', name: 'Log flood', time: 'prevented', secs: 0, m: 1,
      src: 'photonvision-33; journal size in 09-robot-tuning.sh',
      steps: [
        ['fault', ['pv', 'ssd'], '', 'With cameras gone, PhotonVision logged an error for every attempt: about 20,000 lines a minute.'],
        ['info', ['ssd'], '', 'At the old 300 MB log limit, that kept only ~25 minutes of history, pushing out the evidence you\'d need.'],
        ['recover', ['pv'], '', 'Now: log the first failure, then at most one line per 5 s with a count ("and 248 more since the last message").'],
        ['recover', ['ssd'], '', 'The system log also keeps up to 2 GB now.'],
      ] },
  ];

  {
    const svg = $('#f-sys');
    const comps = {
      camA: ['TopLeft cam', 'USB 2.1'], camB: ['TopRight cam', 'USB 2.3'], pwr: ['Power', '15 V boost'],
      hub: ['USB hub', 'inside the Jetson'], xhci: ['USB controller', 'one USB 2.0 bus'], kern: ['Linux kernel', 'uvcvideo driver'],
      pv: ['PhotonVision', 'Java program'], gpu: ['CUDA detector', 'on the GPU'], sysd: ['systemd', 'restarts services'],
      robot: ['Robot', 'NetworkTables'], wd: ['HW watchdog', '30 s timer'], ssd: ['SSD', 'ext4 + journal'], fan: ['Fan', 'full speed'],
    };
    const links = [['camA', 'hub'], ['camB', 'hub'], ['hub', 'xhci'], ['xhci', 'kern'], ['kern', 'pv'], ['pv', 'gpu'], ['pv', 'robot'], ['sysd', 'pv'], ['wd', 'sysd'], ['pv', 'ssd'], ['pwr', 'hub'], ['fan', 'gpu']];
    const WIDE = { vb: [860, 400], bw: 170, bh: 54, pos: { camA: [20, 30], camB: [20, 120], pwr: [20, 310], hub: [230, 75], xhci: [230, 170], kern: [230, 265], pv: [450, 120], gpu: [450, 215], sysd: [450, 310], robot: [670, 30], wd: [670, 310], ssd: [670, 120], fan: [670, 215] } };
    const NARROW = { vb: [400, 590], bw: 176, bh: 58, pos: { camA: [12, 12], camB: [212, 12], hub: [112, 96], xhci: [12, 180], pwr: [212, 180], kern: [12, 264], pv: [212, 264], gpu: [212, 348], robot: [12, 348], sysd: [212, 432], wd: [12, 432], ssd: [12, 516], fan: [212, 516] } };
    let L = null, cur = FAULTS[0], stepI = 0, timer = 0, compState = {};
    const draw = () => {
      L = (svg.clientWidth || svg.parentElement.clientWidth) < 560 ? NARROW : WIDE;
      svg.setAttribute('viewBox', `0 0 ${L.vb[0]} ${L.vb[1]}`);
      const c = (id) => [L.pos[id][0] + L.bw / 2, L.pos[id][1] + L.bh / 2];
      let h = '';
      for (const [a, b] of links) { const [x1, y1] = c(a), [x2, y2] = c(b); h += `<line class="lk" data-a="${a}" data-b="${b}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="rgba(196,181,253,.25)" stroke-width="2"/>`; }
      for (const id in comps) {
        const [x, y] = L.pos[id];
        h += `<g class="cp" data-id="${id}"><rect x="${x}" y="${y}" width="${L.bw}" height="${L.bh}" rx="11" fill="#1f1030" stroke="rgba(196,181,253,.35)" stroke-width="1.5"/><text x="${x + L.bw / 2}" y="${y + L.bh / 2 - 3}" text-anchor="middle" style="font:700 15px var(--font-heading);fill:#f4efff">${comps[id][0]}</text><text x="${x + L.bw / 2}" y="${y + L.bh / 2 + 15}" text-anchor="middle" style="font:500 11.5px var(--font);fill:#b8a9d4">${comps[id][1]}</text></g>`;
      }
      svg.innerHTML = h;
    };
    new ResizeObserver(() => { const was = L; draw(); if (was !== L) paint(); }).observe(svg.parentElement);
    const COL = { fault: '#f43f5e', detect: '#f59e0b', recover: '#a3e635', info: '#67e8f9' };
    const paint = () => {
      svg.querySelectorAll('.cp').forEach((g) => {
        const s = compState[g.dataset.id], r = g.querySelector('rect');
        r.setAttribute('stroke', s ? COL[s] : 'rgba(196,181,253,.35)');
        r.setAttribute('stroke-width', s ? 3 : 1.5);
        r.setAttribute('fill', s ? `color-mix(in srgb, ${COL[s]} 18%, #1f1030)` : '#1f1030');
      });
      svg.querySelectorAll('.lk').forEach((l) => {
        const a = compState[l.dataset.a], b = compState[l.dataset.b];
        const s = a && b ? (a === 'fault' || b === 'fault' ? 'fault' : a === 'recover' && b === 'recover' ? 'recover' : a) : null;
        l.setAttribute('stroke', s ? COL[s] : 'rgba(196,181,253,.25)'); l.setAttribute('stroke-width', s ? 3 : 2);
      });
    };
    const stepsEl = $('#f-steps'), title = $('#f-title'), time = $('#f-time'), srcEl = $('#f-src');
    const select = (f) => {
      cur = f; stepI = 0; timer = 0; compState = {};
      title.textContent = f.icon + ' ' + f.name;
      time.innerHTML = f.ts ? `<span class="full">${f.time}</span><span class="short">${f.ts}</span>` : f.time; time.classList.toggle('bad', f.secs === Infinity);
      srcEl.textContent = 'Source: ' + f.src + (f.m ? '' : '. Times marked ≈ are estimates.');
      // a step's 5th element is its short-mode wording (the short tour describes the system, not its history)
      stepsEl.innerHTML = f.steps.map(([k, , at, txt, sh]) => `<li class="${k}">${at ? `<b class="at">${at}</b>` : ''}${sh === undefined ? txt : `<span class="full">${txt}</span><span class="short">${sh}</span>`}</li>`).join('');
      paint(); advance();
      root.querySelectorAll('#f-faults button').forEach((b) => b.classList.toggle('on', b.dataset.id === f.id));
      chart && chart();
    };
    const advance = () => {
      if (stepI >= cur.steps.length) return;
      const [k, ids] = cur.steps[stepI];
      ids.forEach((id) => (compState[id] = k));
      stepsEl.children[stepI].classList.add('on');
      stepI++; paint();
    };
    const fl = $('#f-faults');
    fl.innerHTML = FAULTS.map((f) => `<button data-id="${f.id}"${f.hist ? ' class="full"' : ''}>${f.icon} ${f.name}</button>`).join('');
    fl.onclick = (e) => { const b = e.target.closest('button'); if (b) select(FAULTS.find((f) => f.id === b.dataset.id)); };
    $('#f-replay').onclick = () => select(cur);
    let chart = null;
    draw();
    Site.loop(svg, (t, dt) => {
      timer += dt;
      if (timer > (Site.reduced ? 0.2 : 1.7) && stepI < cur.steps.length) { timer = 0; advance(); }
      // pulse the newest highlighted components
      const pulse = 0.5 + 0.5 * Math.sin(t * 6);
      svg.querySelectorAll('.cp').forEach((g) => { if (compState[g.dataset.id]) g.querySelector('rect').setAttribute('stroke-opacity', (0.6 + 0.4 * pulse).toFixed(2)); });
    });

    /* recovery-time chart */
    const csvg = $('#f-chart');
    chart = () => {
      const narrow = (csvg.clientWidth || csvg.parentElement.clientWidth) < 600;
      const W = narrow ? 360 : 900, lab = narrow ? 128 : 250, rh = 24, top = 30;
      const H = top + FAULTS.length * rh + 30;
      csvg.setAttribute('viewBox', `0 0 ${W} ${H}`);
      const x0 = lab + 10, x1 = W - (narrow ? 20 : 150);
      const lo = Math.log10(0.005), hi = Math.log10(100);
      const X = (s) => x0 + ((x1 - x0) * (Math.log10(s) - lo)) / (hi - lo);
      let h = '';
      [[0.01, '10 ms'], [0.1, '0.1 s'], [1, '1 s'], [10, '10 s'], [100, '100 s']].forEach(([s, l]) => { h += `<line x1="${X(s)}" y1="${top - 8}" x2="${X(s)}" y2="${H - 24}" stroke="#e9ddf7"/><text x="${X(s)}" y="${H - 8}" text-anchor="middle" style="font:500 11px var(--mono);fill:#635a72">${l}</text>`; });
      FAULTS.forEach((f, i) => {
        const y = top + i * rh, on = f === cur;
        const name = narrow && f.name.length > 19 ? f.name.slice(0, 18) + '…' : f.name;
        h += `<text x="${lab}" y="${y + 15}" text-anchor="end" style="font:${on ? 700 : 500} ${narrow ? 11 : 12.5}px var(--font);fill:${on ? '#3c0060' : '#635a72'}">${name}</text>`;
        if (f.secs === Infinity) {
          h += `<rect x="${x0}" y="${y + 4}" width="${x1 - x0}" height="14" rx="4" fill="url(#f-inf)" opacity="${on ? 1 : 0.55}"/>`;
          if (!narrow) h += `<text x="${x1 + 8}" y="${y + 15}" style="font:700 11.5px var(--font);fill:#dc2626">until power cut</text>`;
        } else if (f.secs > 0) {
          h += `<rect x="${x0}" y="${y + 4}" width="${X(f.secs) - x0}" height="14" rx="4" fill="${on ? '#8b5cf6' : '#c4b5fd'}" opacity="${f.m ? 1 : 0.5}"/>`;
          if (!narrow) h += `<text x="${X(f.secs) + 6}" y="${y + 15}" style="font:600 11.5px var(--font);fill:#4c0070">${f.cl || f.time}</text>`;
        } else {
          h += `<text x="${x0 + 2}" y="${y + 15}" style="font:600 11.5px var(--font);fill:#16a34a">✓ ${f.time}</text>`;
        }
        if (f.id === 'gpu') h += `<rect x="${x0}" y="${y + 4}" width="${X(62) - x0}" height="14" rx="4" fill="none" stroke="#dc2626" stroke-dasharray="3 3" stroke-width="1.2"/>` + (narrow ? '' : `<text x="${X(62) + 6}" y="${y + 15}" style="font:600 11px var(--font);fill:#dc2626">was 62 s</text>`);
      });
      csvg.innerHTML = `<defs><pattern id="f-inf" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="8" height="8" fill="#fecaca"/><rect width="4" height="8" fill="#f87171"/></pattern></defs>` + h;
    };
    new ResizeObserver(() => chart()).observe(csvg.parentElement);
    select(FAULTS[0]);
  }

  /* ── health-check terminal: the real output, loaded verbatim ── */
  {
    const pre = $('#f-term');
    // our notes, shown under the line that contains the key (not part of the output)
    const NOTES = {
      'running 13212s': 'PhotonVision had been up 3.7 hours without a restart',
      'h0: 60 fps': 'h0–h3: one CUDA detector per camera. ~1 ms per frame here (no tags in view)',
      'NVJPG hardware': 'the hardware JPEG decoder, checked against the CPU decoder: 0 differences',
      'calibration loaded for only 2 of 4': 'the two Global Shutter test cameras aren\'t calibrated yet; the Thriftiest Cams are',
      'on USB port 2.1': 'every camera found on the port it belongs to (names follow ports)',
      'bandwidth cap': 'our capped camera driver, with per-port allocations',
      'USB bandwidth reserved': '4 cameras use 3840 of the ~6720-byte USB 2.0 budget',
      'not connected to the robot': 'expected: this ran on the bench, not on the robot',
      'Wi-Fi is connected': 'on the to-do list: Wi-Fi goes off before competition',
      'fan: NVIDIA fan control': 'the fan was on NVIDIA\'s quiet profile for this capture; the check confirms it really spins',
      'filesystem: no ext4 errors': 'no damage from power cuts',
      'boot time: 16.517s': 'matches systemd-analyze: 16.5 s',
    };
    const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
    const fmt = (s) => {
      let h = esc(s).replace(/^  PASS /, '  <span class="p">PASS</span> ').replace(/^  WARN /, '  <span class="w">WARN</span> ').replace(/^  FAIL /, '  <span class="f">FAIL</span> ');
      if (/^== /.test(s)) h = `<span class="h">${h}</span>`;
      if (/^(READY|NOT READY)/.test(s)) h = `<span class="r">${h}</span>`;
      const k = Object.keys(NOTES).find((n) => s.includes(n));
      return k ? h + `\n<span class="a">        ◂ ${esc(NOTES[k])}</span>` : h;
    };
    let lines = null, started = false;
    fetch('assets/from-jetson/terminal/health-check.txt').then((r) => r.text()).then((t) => {
      lines = ['<span class="c">$ ~/SpectrumJetson/scripts/jetson/health-check.sh 4</span>', ...t.replace(/\r/g, '').replace(/\s+$/, '').split('\n').map(fmt)];
      go();
    }).catch(() => { pre.textContent = 'Could not load health-check.txt'; });
    const go = () => {
      if (!lines || !started) return;
      if (Site.reduced) { pre.innerHTML = lines.join('\n'); return; }
      let i = 0;
      const tick = () => { pre.innerHTML = lines.slice(0, ++i).join('\n') + (i < lines.length ? '\n<span class="p">▌</span>' : ''); if (i < lines.length) setTimeout(tick, i === 1 ? 700 : 80); };
      tick();
    };
    Site.onVisible(pre, (v) => { if (v && !started) { started = true; go(); } }, '-20% 0px');
  }

  /* ── Telemetry dashboard ───────────────────────────────── */
  {
    const dash = $('#f-dash');
    const tiles = [
      ['gpuLoadPct', '%'], ['tjTempC', '°C'], ['fanRpm', 'rpm'], ['powerW', 'W'], ['jpegDecoder', ''], ['throttle', ''], ['overCurrentEvents', ''], ['heartbeat', ''],
    ];
    dash.innerHTML = tiles.map(([k]) => `<div class="tile" data-k="${k}"><small>${k}</small><b>–</b>${k === 'gpuLoadPct' || k === 'tjTempC' ? '<canvas></canvas>' : ''}</div>`).join('');
    const el = (k) => dash.querySelector(`[data-k="${k}"]`);
    const spark = { gpuLoadPct: [], tjTempC: [] };
    const S = { gpu: 12, temp: 43, fan: 5586, pw: 9.1, oc: 0, hb: 48200, sagT: 99, fanDead: false, deadT: 0 };
    const fanB = $('#f-fan'), sagB = $('#f-sag');
    let acc = 1;
    const now = () => (acc = 1); // redraw on the next frame, so every click shows at once
    sagB.onclick = () => { S.sagT = 0; S.oc++; now(); };
    fanB.onclick = () => { S.fanDead = !S.fanDead; S.deadT = 0; if (!S.fanDead) S.temp = 43; now(); };
    $('#f-reset').onclick = () => { S.fanDead = false; S.temp = 43; S.sagT = 99; S.oc = 0; now(); };
    Site.loop(dash, (t, dt) => {
      acc += dt; if (acc < 0.5) return; const step = Math.min(acc, 0.6); acc = 0;
      fanB.textContent = S.fanDead ? '🌀 Fan dead: press to fix' : '🌀 Fan dies'; fanB.classList.toggle('on', S.fanDead); fanB.setAttribute('aria-pressed', S.fanDead);
      sagB.classList.toggle('on', S.sagT < 10); sagB.textContent = S.sagT < 10 ? '🔋 Battery sagging…' : '🔋 Battery sags';
      S.hb += 1; S.sagT += step;
      S.gpu = Site.clamp(12 + (Math.random() - 0.5) * 12 + (Math.random() < 0.08 ? 10 : 0), 8, 24);
      if (S.fanDead) {
        S.deadT += step * 60; // 60x: seconds of sim per second
        S.fan = 0;
        S.temp = 99 - (99 - 43) * Math.exp(-S.deadT / 396); // our RC model: ~6.6 min time constant, 99 C steady state at full power
      } else { S.fan = 5586 + (Math.random() - 0.5) * 60; S.temp = 43 + (Math.random() - 0.5) * 0.6; }
      S.pw = 9.1 + (Math.random() - 0.5) * 0.8 + (S.sagT < 2 ? -0.6 : 0);
      const thr = S.temp >= 98.5 ? 'HIGH TEMP (cpu, gpu)' : S.sagT < 10 ? 'OVER-CURRENT' : S.oc ? `Prev. over-current (${S.oc})` : 'None';
      const set = (k, v, cls) => { const e = el(k); e.querySelector('b').textContent = v; e.classList.toggle('warn', cls === 'warn'); e.classList.toggle('bad', cls === 'bad'); };
      set('gpuLoadPct', S.gpu.toFixed(0) + ' %');
      set('tjTempC', S.temp.toFixed(1) + ' °C', S.temp > 85 ? 'bad' : S.temp > 70 ? 'warn' : '');
      set('fanRpm', Math.round(S.fan).toLocaleString(), S.fan < 1000 ? 'bad' : '');
      set('powerW', S.pw.toFixed(1) + ' W');
      set('jpegDecoder', 'nvjpg');
      set('throttle', thr, thr === 'None' ? '' : thr.startsWith('Prev') ? 'warn' : 'bad');
      set('overCurrentEvents', S.oc, S.oc ? 'warn' : '');
      set('heartbeat', S.hb);
      el('throttle').querySelector('b').style.fontSize = thr.length > 10 ? '.95rem' : '';
      spark.gpuLoadPct.push(S.gpu); spark.tjTempC.push(S.temp);
      for (const k in spark) {
        const a = spark[k]; if (a.length > 40) a.shift();
        const cv = el(k).querySelector('canvas'), w = cv.clientWidth, h = 26, d = Math.min(2, devicePixelRatio || 1);
        cv.width = w * d; cv.height = h * d; const c = cv.getContext('2d'); c.scale(d, d);
        const lo = k === 'gpuLoadPct' ? 0 : 30, hi = k === 'gpuLoadPct' ? 40 : 105;
        c.strokeStyle = k === 'gpuLoadPct' ? '#c4b5fd' : S.temp > 70 ? '#f43f5e' : '#a3e635'; c.lineWidth = 1.5; c.beginPath();
        a.forEach((v, i) => { const x = (i / 39) * w, y = h - ((v - lo) / (hi - lo)) * h; i ? c.lineTo(x, y) : c.moveTo(x, y); }); c.stroke();
      }
    });
  }

  /* ── Boot bars ─────────────────────────────────────────── */
  {
    const svg = $('#f-boot');
    const build = () => {
      const n = (svg.clientWidth || svg.parentElement.clientWidth) < 600;
      const W = n ? 440 : 900, x0 = n ? 64 : 150, x1 = W - (n ? 44 : 50), fs = n ? 12 : 12;
      svg.setAttribute('viewBox', `0 0 ${W} 190`);
      const X = (s) => x0 + (s / 60) * (x1 - x0);
      let h = '';
      for (let s = 0; s <= 60; s += n ? 20 : 10) h += `<line x1="${X(s)}" y1="20" x2="${X(s)}" y2="160" stroke="#e9ddf7"/><text x="${X(s)}" y="178" text-anchor="middle" style="font:500 ${fs}px var(--mono);fill:#635a72">${s} s</text>`;
      const bar = (y, a, b, col, label) => `<rect x="${X(a)}" y="${y}" width="${X(b) - X(a)}" height="34" rx="6" fill="${col}"/>${label ? `<text x="${(X(a) + X(b)) / 2}" y="${y + 22}" text-anchor="middle" style="font:600 ${fs}px var(--font);fill:#fff">${label}</text>` : ''}`;
      h += `<text x="${x0 - 10}" y="52" text-anchor="end" style="font:700 14px var(--font-heading);fill:#635a72">Stock</text>`;
      h += bar(30, 0, 6.9, '#94a3b8', n ? '' : 'kernel') + bar(30, 6.9, 56.9, '#cbd5e1', n ? 'services 50 s' : 'services: 50.0 s (snapd alone waited 45 s)');
      h += `<text x="${X(56.9) + 5}" y="52" style="font:700 ${fs}px var(--font);fill:#635a72">${n ? '57 s' : '56.9 s'}</text>`;
      h += `<text x="${x0 - 10}" y="112" text-anchor="end" style="font:700 14px var(--font-heading);fill:#4c0070">Tuned</text>`;
      h += bar(90, 0, 8.8, '#6b1199', n ? '' : 'kernel 8.8 s') + bar(90, 8.8, 16.5, '#8b5cf6', n ? '' : '7.7 s');
      h += `<text x="${X(16.5) + 5}" y="${n ? 84 : 112}" style="font:700 ${fs}px var(--font);fill:#4c0070">16.5 s</text>`;
      h += `<line x1="${X(14.7)}" y1="82" x2="${X(14.7)}" y2="150" stroke="#06b6d4" stroke-width="2" stroke-dasharray="4 3"/><text x="${X(14.7) - 4}" y="150" text-anchor="end" style="font:600 11.5px var(--font);fill:#0e7490">${n ? 'PV starts' : 'PhotonVision starts 14.7 s'}</text>`;
      h += `<line x1="${X(20)}" y1="82" x2="${X(20)}" y2="150" stroke="#16a34a" stroke-width="2.5"/><text x="${X(20) + 5}" y="150" style="font:700 11.5px var(--font);fill:#15803d">${n ? 'detecting ~20 s' : 'first tag detected ~20 s'}</text>`;
      svg.innerHTML = h;
    };
    new ResizeObserver(build).observe(svg.parentElement);
  }
});
