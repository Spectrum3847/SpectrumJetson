Object.assign(Site.glossary, {
  'Ethernet': 'The wired network standard: a cable with 8 wires carrying data as packets. The Jetson connects to the robot network with one.',
  'IP address': 'A device\'s address on a network, four numbers like 10.85.15.15. FRC robots use 10.TE.AM.x, built from the team number.',
  'packet': 'A small chunk of data sent over a network, wrapped in headers that say where it\'s from and where it\'s going.',
  'topic': 'A named value in NetworkTables, written like a path (/photonvision/TopLeft/rawBytes). Programs publish to it or subscribe to it.',
});

Site.chapter('networktables', (root) => {
  const $ = (s) => root.querySelector(s);
  const NS = 'http://www.w3.org/2000/svg';

  /* ── Network diagram ───────────────────────────────────── */
  {
    const svg = $('#n-net');
    const box = (x, y, w, h, title, sub, fill = '#fff', stroke = '#d4c0ee') =>
      `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="12" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/>
       <text x="${x + w / 2}" y="${y + h / 2 - 4}" text-anchor="middle" style="font:700 15px var(--font-heading);fill:#4c0070">${title}</text>
       <text x="${x + w / 2}" y="${y + h / 2 + 15}" text-anchor="middle" style="font:500 12px var(--mono);fill:#6b1199">${sub}</text>`;
    const J = [95, 230], R = [280, 110], S = [465, 230], D = [465, 55];
    svg.innerHTML = `
      <path id="n-w1" d="M${J[0]} ${J[1] - 30} C ${J[0]} 140, ${R[0] - 80} ${R[1]}, ${R[0] - 50} ${R[1]}" fill="none" stroke="#06b6d4" stroke-width="4" stroke-linecap="round"/>
      <path id="n-w2" d="M${R[0] + 50} ${R[1]} C ${S[0] - 60} ${R[1]}, ${S[0]} 150, ${S[0]} ${S[1] - 30}" fill="none" stroke="#06b6d4" stroke-width="4" stroke-linecap="round"/>
      <path d="M${R[0] + 40} ${R[1] - 20} Q ${R[0] + 110} ${D[1] - 10}, ${D[0] - 62} ${D[1]}" fill="none" stroke="#c4b5fd" stroke-width="2.5" stroke-dasharray="4 6"/>
      <text x="36" y="150" style="font:600 11px var(--font);fill:#0e7490">Ethernet</text>
      <text x="${(S[0] + R[0]) / 2 + 22}" y="${R[1] + 26}" style="font:600 11px var(--font);fill:#0e7490">Ethernet</text>
      <text x="${R[0] + 88}" y="${D[1] + 2}" style="font:600 11px var(--font);fill:#8b5cf6">Wi-Fi</text>
      ${box(R[0] - 50, R[1] - 25, 100, 50, 'Radio', 'switch')}
      ${box(J[0] - 80, J[1] - 30, 160, 64, 'Jetson', '10.85.15.15', '#faf5ff', '#8b5cf6')}
      ${box(S[0] - 80, S[1] - 30, 160, 64, 'SystemCore', '10.85.15.2', '#fffbeb', '#f59e0b')}
      ${box(D[0] - 62, D[1] - 25, 124, 50, 'Driver laptop', 'on Wi-Fi')}
      <g style="font:500 11px var(--font);fill:#635a72">
        <text x="${J[0] - 80}" y="${J[1] + 92}">4 cameras on USB</text>
        <text x="${J[0] - 80}" y="${J[1] + 108}">(not on the network)</text>
        <text x="${S[0] - 80}" y="${S[1] + 58}">runs robot code and the</text>
        <text x="${S[0] - 80}" y="${S[1] + 74}">NetworkTables server</text>
      </g>
      <g id="n-pk"></g>`;
    for (let i = 0; i < 4; i++) svg.insertAdjacentHTML('beforeend', `<rect x="${J[0] - 76 + i * 22}" y="${J[1] + 60}" width="18" height="12" rx="3" fill="#1f1b23"/><line x1="${J[0] - 67 + i * 22}" y1="${J[1] + 60}" x2="${J[0] - 67 + i * 22}" y2="${J[1] + 35}" stroke="#94a3b8" stroke-width="1.5"/>`);
    const w1 = svg.querySelector('#n-w1'), w2 = svg.querySelector('#n-w2'), pk = svg.querySelector('#n-pk');
    const L1 = w1.getTotalLength(), L2 = w2.getTotalLength();
    const at = (u) => (u < L1 / (L1 + L2) ? w1.getPointAtLength((u * (L1 + L2))) : w2.getPointAtLength(u * (L1 + L2) - L1));
    Site.loop(svg, (t) => {
      let s = '';
      for (let i = 0; i < 5; i++) {
        const u = (t * 0.22 + i / 5) % 1, p = at(u);
        s += `<rect x="${p.x - 9}" y="${p.y - 6}" width="18" height="12" rx="3" fill="#8b5cf6" stroke="#fff" stroke-width="1.5"/>`;
      }
      for (let i = 0; i < 2; i++) {
        const u = 1 - ((t * 0.15 + i / 2 + 0.25) % 1), p = at(u);
        s += `<rect x="${p.x - 7}" y="${p.y - 5}" width="14" height="10" rx="3" fill="#f59e0b" stroke="#fff" stroke-width="1.5"/>`;
      }
      pk.innerHTML = s;
    });
    svg.insertAdjacentHTML('beforeend', `<g style="font:600 11px var(--font)"><rect x="10" y="12" width="12" height="9" rx="2" fill="#8b5cf6"/><text x="28" y="21" fill="#635a72">results to the robot</text><rect x="10" y="30" width="12" height="9" rx="2" fill="#f59e0b"/><text x="28" y="39" fill="#635a72">robot to Jetson</text></g>`);
  }

  /* ── Packet layers ─────────────────────────────────────── */
  {
    const layers = [...root.querySelectorAll('#n-layers .layer')];
    Site.seg($('#n-layer'), (v) => { const k = +v; layers.forEach((l, i) => l.classList.toggle('off', k > 0 && i !== k - 1)); });
  }

  /* ── Pub/sub ───────────────────────────────────────────── */
  {
    const svg = $('#n-pubsub');
    const C = { pv: [105, 55], dash: [415, 55], robot: [260, 400] };
    const topics = [
      { k: 'raw', n: '/photonvision/TopLeft/rawBytes', v: '—', subs: ['robot', 'dash'] },
      { k: 'has', n: '/photonvision/TopLeft/hasTarget', v: 'false', subs: ['dash'] },
      { k: 'pir', n: '/photonvision/TopLeft/pipelineIndexRequest', v: '0', subs: ['pv'] },
      { k: 'pis', n: '/photonvision/TopLeft/pipelineIndexState', v: '0', subs: ['robot', 'dash'] },
      { k: 'rec', n: '/photonvision/rewind/record', v: 'false', subs: ['pv', 'dash'] },
    ];
    const rowY = (i) => 188 + i * 30;
    const client = (id, x, y, title, sub, col) => `<g id="n-c-${id}"><rect x="${x - 88}" y="${y - 32}" width="176" height="64" rx="12" fill="#251038" stroke="${col}" stroke-width="2"/><text x="${x}" y="${y - 6}" text-anchor="middle" style="font:700 15px var(--font-heading);fill:#fff">${title}</text><text x="${x}" y="${y + 14}" text-anchor="middle" style="font:500 11px var(--font);fill:#b8a9d4">${sub}</text></g>`;
    let html = `<rect x="16" y="136" width="488" height="200" rx="14" fill="#1a0a2b" stroke="#8b5cf6" stroke-width="2" stroke-dasharray="6 5"/>
      <text x="32" y="162" style="font:700 12px var(--font);letter-spacing:.12em;fill:#c4b5fd">NT SERVER · SYSTEMCORE · PORT 5810</text>`;
    html += `<path d="M${C.pv[0]} ${C.pv[1] + 32} V136" stroke="#b8a9d4" stroke-width="2" stroke-opacity=".4"/><path d="M${C.dash[0]} ${C.dash[1] + 32} V136" stroke="#b8a9d4" stroke-width="2" stroke-opacity=".4"/><path d="M${C.robot[0]} ${C.robot[1] - 32} V336" stroke="#b8a9d4" stroke-width="2" stroke-opacity=".4"/>`;
    topics.forEach((t, i) => {
      html += `<g id="n-t-${t.k}"><rect x="28" y="${rowY(i) - 17}" width="464" height="25" rx="6" fill="rgba(255,255,255,.04)"/><text x="38" y="${rowY(i)}" style="font:500 11.5px var(--mono);fill:#f4efff">${t.n.replace('/photonvision/', '…/')}</text><text class="v" x="482" y="${rowY(i)}" text-anchor="end" style="font:600 11.5px var(--mono);fill:#a3e635">${t.v}</text></g>`;
    });
    html += client('pv', ...C.pv, 'PhotonVision', 'client · on the Jetson', '#c4b5fd');
    html += client('dash', ...C.dash, 'Dashboard', 'client · on the laptop', '#67e8f9');
    html += client('robot', ...C.robot, 'Robot code', 'same program as the server', '#fcd34d');
    html += '<g id="n-fly"></g>';
    svg.innerHTML = html;
    const fly = svg.querySelector('#n-fly');
    const flights = [];
    const glow = {};
    const row = (k) => svg.querySelector('#n-t-' + k);
    const setV = (k, v) => { row(k).querySelector('.v').textContent = v; topics.find((t) => t.k === k).v = v; glow[k] = 1; };
    const edge = (id) => (id === 'robot' ? [C.robot[0], 336] : [C[id][0], 136]);
    const go = (from, to, col, dur, done) => flights.push({ from, to, col, t: 0, dur, done });
    let seq = 0, busy = 0;
    const publish = (who, k, v, then) => {
      const t = topics.find((x) => x.k === k);
      busy++;
      go(C[who], edge(who), who === 'pv' ? '#c4b5fd' : who === 'robot' ? '#fcd34d' : '#67e8f9', 0.5, () => {
        go(edge(who), [260, rowY(topics.indexOf(t)) - 4], '#fff', 0.35, () => {
          setV(k, v);
          t.subs.forEach((s) => { const e = edge(s); go([260, rowY(topics.indexOf(t)) - 4], e, '#a3e635', 0.35, () => go(e, C[s], '#a3e635', 0.45, () => { glow['c' + s] = 1; })); });
          setTimeout(() => { busy--; then && then(); }, 900);
        });
      });
    };
    // "Record" and "pipeline" are toggles, so their button labels follow the current value.
    const btn = (k) => root.querySelector(`[data-pub="${k}"]`);
    const labels = () => {
      btn('record').textContent = topics.find((x) => x.k === 'rec').v === 'true' ? 'Robot: stop Rewind' : 'Robot: start Rewind';
      btn('pipe').textContent = `Dashboard: switch to pipeline ${topics.find((x) => x.k === 'pir').v === '0' ? 1 : 0}`;
    };
    const log = (m) => ($('#n-log').textContent = m);
    const events = {
      result: () => { seq++; const has = seq % 3 !== 0; publish('pv', 'raw', `${has ? 1 + (seq % 2) : 0} tag${has && seq % 2 ? 's' : ''} #${4000 + seq}`); publish('pv', 'has', has ? 'true' : 'false'); return 'PhotonVision publishes a new result: rawBytes and hasTarget. The robot and the dashboard subscribed, so both get it.'; },
      record: () => { const on = topics.find((x) => x.k === 'rec').v !== 'true'; publish('robot', 'rec', on ? 'true' : 'false'); return `Robot code sets rewind/record = ${on}. PhotonVision subscribed, so it ${on ? 'starts' : 'stops'} recording.`; },
      pipe: () => { const nv = topics.find((x) => x.k === 'pir').v === '0' ? '1' : '0'; publish('dash', 'pir', nv, () => publish('pv', 'pis', nv)); return `The dashboard asks for pipeline ${nv}. PhotonVision switches, then publishes pipelineIndexState = ${nv} to confirm.`; },
    };
    const flash = (who) => { glow['c' + who] = 1; };
    const sender = { result: 'pv', record: 'robot', pipe: 'dash' };
    // A demo plays until the first click, then only the student's own messages run.
    let demo = true, clock = 0, autoI = 0;
    root.querySelectorAll('[data-pub]').forEach((b) => (b.onclick = () => {
      demo = false;
      flash(sender[b.dataset.pub]);
      log('You: ' + events[b.dataset.pub]());
      labels();
    }));
    Site.loop(svg, (t, dt) => {
      clock += dt;
      if (demo && !busy && clock % 2.2 < dt) { const k = ['result', 'result', 'pipe', 'result', 'record'][autoI++ % 5]; flash(sender[k]); log('Demo: ' + events[k]()); labels(); }
      let s = '';
      for (let i = flights.length - 1; i >= 0; i--) {
        const f = flights[i]; f.t += dt / f.dur;
        if (f.t >= 1) { flights.splice(i, 1); f.done && f.done(); continue; }
        const x = Site.lerp(f.from[0], f.to[0], f.t), y = Site.lerp(f.from[1], f.to[1], f.t);
        s += `<circle cx="${x}" cy="${y}" r="6" fill="${f.col}" stroke="#0e0518" stroke-width="2"/>`;
      }
      fly.innerHTML = s;
      for (const k in glow) {
        glow[k] = Math.max(0, glow[k] - dt * 1.2);
        if (k[0] === 'c' && k.length > 2 && !topics.find((x) => x.k === k)) { const g = svg.querySelector(`#n-c-${k.slice(1)} rect`); if (g) g.setAttribute('fill', `rgba(163,230,53,${0.25 * glow[k]})`); if (g && glow[k] === 0) g.setAttribute('fill', '#251038'); }
        else { const r = row(k); if (r) r.querySelector('rect').setAttribute('fill', `rgba(163,230,53,${0.04 + 0.3 * glow[k]})`); }
      }
    });
  }

  /* ── Topic tree ────────────────────────────────────────── */
  {
    const U = 'up', D = 'down';
    const T = (n, o = {}, kids) => ({ n, ...o, kids });
    const tree = T('/photonvision', { d: 'PhotonVision\'s root table. Everything the Jetson and the robot code share lives under here, in folders (sub-tables). Folders aren\'t values themselves; they just group topics.' }, [
      T('TopLeft', { d: 'One folder per camera, named after the camera. We name our cameras after the USB port they\'re plugged into (TopLeft is hub port 2.1). TopRight, BottomLeft and BottomRight have the same topics.' }, [
        T('rawBytes', { dir: U, type: 'raw bytes (PhotonPipelineResult)', d: 'The main result, published once per processed frame (up to ~120 times a second). Everything PhotonVision found in that frame, packed into compact binary. PhotonLib\'s getAllUnreadResults() reads this topic and unpacks it. Open it to see what\'s inside.', ex: '[5B 0F 00 00 … ] ~100–300 bytes' }, [
          T('metadata', { type: 'struct', d: 'sequenceID (counts frames, so you can spot drops), captureTimestampMicros (when the light was captured: mid-exposure, thanks to photonvision-13), publishTimestampMicros (when it was sent), timeSinceLastPong (how recently time sync heard from the robot).' , ex: 'sequenceID: 81234\ncaptureTimestampMicros: 1530270118\npublishTimestampMicros: 1530283204' }),
          T('targets[ ]', { type: 'list of PhotonTrackedTarget', d: 'One entry per tag found. Each has fiducialId (the tag\'s ID), yaw and pitch (degrees from the image center; yaw is positive to the right, pitch positive up), area (% of the image), skew, bestCameraToTarget and altCameraToTarget (the two 3D poses of the tag that fit the corners), poseAmbiguity, and detectedCorners (the tag\'s four corners in pixels).', ex: 'fiducialId: 7\nyaw: -12.4  pitch: 3.1\narea: 0.82\nposeAmbiguity: 0.06' }),
          T('bestCameraToTarget', { type: 'Transform3d', d: 'Where the tag is relative to the camera (x forward, y left, z up, plus rotation), from the single-tag solve. A square tag can often be explained by two different poses; this is the one with the lower reprojection error.', ex: 'x 3.42 m, y 0.71 m, z 0.18 m' }),
          T('poseAmbiguity', { type: 'double', d: 'The ratio of the best pose\'s error to the alternate pose\'s error. Near 0: the best pose clearly wins. Near 1: the two candidates fit about equally well, so the single-tag pose may be flipped. Robot code usually rejects single-tag poses above about 0.2.', ex: '0.06' }),
          T('multitagResult', { type: 'optional MultiTargetPNPResult', d: 'When 2+ tags are visible (and multi-tag is on, which our cameras default to), PhotonVision solves the camera\'s field pose from all their corners at once: estimatedPose (best and alternate, with reprojection errors and ambiguity) and fiducialIDsUsed. Much less ambiguous than any single tag.', ex: 'fiducialIDsUsed: [7, 8]\nbestReprojErr: 0.41 px' }),
        ]),
        T('hasTarget, targetYaw, targetPitch, targetArea, targetSkew, targetPose', { dir: U, type: 'boolean / double / Transform3d', d: 'Easy-to-read copies of the best target, for dashboards and quick tests. targetYaw is positive to the right (the opposite of WPILib\'s counter-clockwise angles). Robot code should use rawBytes through PhotonLib instead: it has every target and the timestamps.', ex: 'hasTarget: true\ntargetYaw: -12.4' }),
        T('latencyMillis, fps, heartbeat', { dir: U, type: 'double / integer', d: 'Upstream PhotonVision\'s stats: latency of the last result, frames per second, and a counter that goes up every result so you can tell the camera is alive.', ex: 'latencyMillis: 13.2\nfps: 121.8' }),
        T('pipelineIndexRequest → pipelineIndexState', { dir: D, type: 'integer', d: 'Robot code (or a dashboard) writes the pipeline it wants into pipelineIndexRequest (PhotonLib: setPipelineIndex). PhotonVision switches and reports the active one in pipelineIndexState. Our profiles use the same number on every camera (e.g. 0 = event field, 1 = practice field).', ex: 'pipelineIndexState: 0' }),
        T('driverModeRequest, fpsLimitRequest', { dir: D, type: 'boolean / integer', d: 'Driver mode turns off processing and just streams video. fpsLimitRequest caps the camera\'s processing rate from robot code (e.g. while disabled, to run cooler).', ex: 'fpsLimitRequest: -1 (no limit)' }),
        T('enabledRequest → enabled', { dir: D, ours: 1, type: 'boolean', d: 'PhotonLib\'s camera.setEnabled(false) writes enabledRequest; the camera stops processing until it\'s set true again. Every camera starts enabled when PhotonVision starts. We ported this server side from newer upstream PhotonVision (photonvision-11).', ex: 'enabled: true' }),
        T('cameraIntrinsics, cameraDistortion', { dir: U, type: 'double[ ]', d: 'The calibration in use: the camera matrix (focal length ~737 px and image center for our cameras) and all 8 lens-distortion coefficients. PhotonLib\'s getCameraMatrix() and getDistCoeffs() read these.', ex: '[737.8, 0, 650.5, 0, 737.8, 362.4, 0, 0, 1]' }),
        T('settingsJson', { dir: U, ours: 1, type: 'string (JSON)', d: 'The camera\'s full current settings: pipeline settings, video mode, which lens calibration is in use, and the camera controls as actually set. Rebuilt every 5 s but only sent when something changes, so AdvantageKit records it in every log (photonvision-24).', ex: '{"pipeline":"Event","exposureMs":5.0,…}' }),
        T('robotToCamera', { dir: D, ours: 1, type: 'Transform3d struct', d: 'Robot code publishes where this camera is mounted on the robot (from CAD or the last calibration). Field calibration needs it for the cameras\' x, y and yaw (photonvision-30).', ex: 'x 0.30, y 0.25, z 0.45 m, pitch −20°' }),
        T('fieldcal', { d: 'Results from our Field Calibration page.' }, [
          T('robotToCamera', { dir: U, ours: 1, type: 'Transform3d struct', d: 'The camera mount that field calibration solved for, measured from the tags. Robot code can compare it with its own and catch a bumped camera.', ex: 'x 0.302, y 0.247, z 0.453 m' }),
        ]),
        T('health', { ours: 1, d: 'Per-camera health, published once a second (photonvision-16, -29, -31, -33).' }, [
          T('fps, pipelineMs, pipelineMsMax, latencyMs, frames', { dir: U, ours: 1, type: 'double / integer', d: 'Results per second, average and worst pipeline time over the last second, average latency from capture to result, and total frames since start.', ex: 'fps: 121.9\npipelineMs: 3.1\nlatencyMs: 13.4' }),
          T('decodeFailures', { dir: U, ours: 1, type: 'integer', d: 'Frames our JPEG decoder rejected. A rising count means corrupt JPEGs are getting through.', ex: '0' }),
          T('recoveries', { dir: U, ours: 1, type: 'integer', d: 'How many times the stuck-camera watchdog reconnected or reset this camera (photonvision-29): reconnect after 3 s without usable frames, a USB reset 5 s later.', ex: '0' }),
          T('problem', { dir: U, ours: 1, type: 'string', d: 'A plain-English reason when the camera is in trouble, e.g. "not answering on USB port 1-2.1: replug it, or power-cycle the robot" or a USB bandwidth failure. Empty when all is well.', ex: '""' }),
        ]),
        T('mount', { ours: 1, d: 'The camera\'s mount measured from the tags while the robot is level (photonvision-17), every 0.5 s over the last 2 s of multi-tag frames.' }, [
          T('heightM, pitchDeg, rollDeg (+ Std)', { dir: U, ours: 1, type: 'double', d: 'Mean camera height, pitch and roll, and their spread. With the robot level on the floor these equal the camera\'s mount on the robot. Signs match robotToCamera (tilted up = negative pitch).', ex: 'heightM: 0.452\npitchDeg: -19.8' }),
          T('fieldXM, fieldYM, fieldYawDeg, reprojErrorPx, samples', { dir: U, ours: 1, type: 'double / integer', d: 'The camera\'s position and heading on the field (for robot code to combine with its own pose), the multi-tag reprojection error, and how many frames went into the window (0 means nothing else updated).', ex: 'samples: 214' }),
        ]),
      ]),
      T('jetson', { ours: 1, d: 'Jetson-wide health, published every second (photonvision-16, -20, -24). Robot code can raise alerts from these.' }, [
        T('gpuLoadPct', { dir: U, ours: 1, type: 'double', d: 'How busy the GPU is. About 12% on average with 2 cameras at 122 fps.', ex: '12.0' }),
        T('cpuTempC, gpuTempC, tjTempC, socTempC', { dir: U, ours: 1, type: 'double', d: 'Temperatures from the chip\'s thermal zones. About 43 °C on the bench with the fan at full speed; throttling starts at 99 °C.', ex: 'tjTempC: 43.1' }),
        T('fanRpm', { dir: U, ours: 1, type: 'double', d: 'The fan\'s real speed from its tachometer (not just what it was told). ~5,600 rpm at full speed.', ex: '5586' }),
        T('powerW, cpuGpuPowerW, socPowerW', { dir: U, ours: 1, type: 'double', d: 'Power from the board\'s power monitors: the whole board, the CPU/GPU rail and the SoC rail. About 9 W with 2 cameras detecting.', ex: 'powerW: 9.1' }),
        T('jpegDecoder, jpegHardwareOff, jpegChecksOk, jpegChecksDiffer', { dir: U, ours: 1, type: 'string / boolean / integer', d: 'Which JPEG decoder is running (nvjpg or libjpeg-turbo), whether the hardware decoder was switched off, and how the ongoing hardware-vs-CPU frame checks went.', ex: 'jpegDecoder: "nvjpg"\njpegChecksDiffer: 0' }),
        T('throttle, overCurrentEvents', { dir: U, ours: 1, type: 'string / integer', d: 'Why the Jetson is slowing itself down: None, OVER-CURRENT (the supply sagged, e.g. battery brownout), HIGH TEMP, or CPU/GPU CLOCK CAPPED (photonvision-20). A Jetson version of the Raspberry Pi\'s under-voltage flag.', ex: 'throttle: "None"' }),
        T('heartbeat', { dir: U, ours: 1, type: 'integer', d: 'Goes up by 1 every publish. If it stops changing, the telemetry (or PhotonVision) has stopped.', ex: '48211' }),
        T('settingsJson', { dir: U, ours: 1, type: 'string (JSON)', d: 'The PhotonVision build, detector and decoder settings, the tags left out of multi-tag, and a fingerprint of the field layout, for the robot log.', ex: '{"build":"…","detector":"bos",…}' }),
      ]),
      T('rewind', { ours: 1, d: 'Rewind: recording every camera to the Jetson\'s SSD (photonvision-07).' }, [
        T('record', { dir: D, ours: 1, type: 'boolean', d: 'Record while true. Robot code sets it from enable until 10 s after disable, with the FMS attached. If the robot disconnects while it\'s true, the Jetson keeps recording 60 s more.', ex: 'true' }),
        T('label', { dir: D, ours: 1, type: 'string', d: 'Optional name for the recording, read when a recording starts. Empty: the FMS match name (e.g. Q12).', ex: '"shooter-test-3"' }),
        T('recording, session, freeGB, framesDropped', { dir: U, ours: 1, type: 'boolean / string / double / integer', d: 'Whether it\'s recording now, the current recording\'s name, free SSD space, and frames it couldn\'t save.', ex: 'recording: true\nfreeGB: 181.4' }),
      ]),
      T('clock', { ours: 1, d: 'The robot\'s date, for the Jetson.' }, [
        T('unixMs', { dir: D, ours: 1, type: 'integer', d: 'Robot code publishes System.currentTimeMillis() once the Driver Station has set the robot\'s clock. The Jetson (no clock battery, no internet at events) sets its date from it (photonvision-08). For logs and file names, not vision timing.', ex: '1791651302000' }),
      ]),
      T('excludedTags', { dir: D, ours: 1, type: 'integer[ ]', d: 'Tags to leave out of every camera\'s multi-tag solve, e.g. one mounted wrong at an event. Combined with the list typed on the Settings page (photonvision-22). Left-out tags are still reported as targets.', ex: '[7, 12]' }),
      T('excludedTagsActive', { dir: U, ours: 1, type: 'integer[ ]', d: 'The combined list actually in use.', ex: '[7, 12]' }),
    ]);
    const el = $('#n-tree'), info = $('#n-info');
    let selBtn = null;
    const pathOf = [];
    const render = (node, path) => {
      const li = document.createElement('li');
      const b = document.createElement('button');
      const kids = node.kids && node.kids.length;
      b.setAttribute('role', 'treeitem');
      b.innerHTML = `<span class="tw">${kids ? '▸' : ''}</span><span class="${kids ? 'folder' : ''}${node.ours ? ' ours' : ''}">${node.n}</span>${node.dir ? `<span class="dir ${node.dir}">${node.dir === 'up' ? 'to robot' : 'to Jetson'}</span>` : ''}`;
      const full = path + (path.endsWith('/') ? '' : '/') + node.n;
      b.onclick = () => {
        if (kids) { li.classList.toggle('open'); b.querySelector('.tw').textContent = li.classList.contains('open') ? '▾' : '▸'; }
        selBtn && selBtn.classList.remove('sel'); selBtn = b; b.classList.add('sel');
        const patch = (node.d.match(/photonvision-\d+/g) || []).join(', ');
        info.innerHTML = `<h5>${full.replace(/^\/\//, '/')}</h5><div class="meta">${node.type ? `<span>${node.type}</span>` : '<span>folder</span>'}${node.dir ? `<span style="color:${node.dir === 'up' ? '#c4b5fd' : '#fcd34d'}">${node.dir === 'up' ? 'Jetson → robot' : 'robot → Jetson'}</span>` : ''}${node.ours ? '<span style="color:#a3e635">added by us</span>' : ''}${patch ? `<span>${patch}</span>` : ''}</div><p>${node.d}</p>${node.ex ? `<div class="ex">${node.ex}</div><p class="hint" style="margin-top:6px">Example value, made up.</p>` : ''}`;
      };
      li.appendChild(b);
      if (kids) { const ul = document.createElement('ul'); node.kids.forEach((k) => ul.appendChild(render(k, full))); li.appendChild(ul); }
      node.btn = b; node.li = li;
      return li;
    };
    const ul = document.createElement('ul'); ul.appendChild(render(tree, '')); el.appendChild(ul);
    void pathOf;
    // open the root and TopLeft, select rawBytes
    tree.btn.click(); tree.kids[0].btn.click(); tree.kids[0].kids[0].btn.click();
  }

  /* ── USB port picker ───────────────────────────────────── */
  {
    const note = $('#n-port-note');
    const txt = {
      TopLeft: 'TopLeft: top row, left, hub port 2.1. One of our two Thriftiest Cams. In robot code: new PhotonCamera("TopLeft"). Its calibration (fx 737.8 px, 0.87 px error) belongs to this camera in this port.',
      TopRight: 'TopRight: top row, right, hub port 2.3. Our other Thriftiest Cam (fx 737.0 px, 0.97 px error). Swap it with TopLeft and each would use the other\'s calibration, silently.',
      BottomLeft: 'BottomLeft: bottom row, left, hub port 2.2. Used on the bench by a Global Shutter camera; the name is ready for a third AprilTag camera.',
      BottomRight: 'BottomRight: bottom row, right, hub port 2.4 (expected). With our capped camera driver, all four USB-A ports can stream at once, sharing one USB 2.0 budget.',
    };
    root.querySelectorAll('#n-ports .port').forEach((b) => (b.onclick = () => { root.querySelectorAll('#n-ports .port').forEach((x) => x.classList.toggle('on', x === b)); note.textContent = txt[b.dataset.n]; }));
  }
});
