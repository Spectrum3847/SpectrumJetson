Object.assign(Site.glossary, {
  'pipeline': 'One saved set of settings for a camera in PhotonVision: its type (like AprilTagCuda), exposure, resolution and detector settings. A camera can have several, numbered from 0, and runs one at a time.',
  'Driver mode': 'A PhotonVision pipeline that does no vision processing: it just streams a picture for the drivers.',
});

Site.chapter('camsetup', (root) => {
  const $ = (s) => root.querySelector(s);
  const LAB = '#0e0518', INK = '#f4efff', MUTED = '#b8a9d4', AMBER = '#f59e0b', LIME = '#a3e635', ROSE = '#fda4af';
  const D2R = Math.PI / 180;

  /* ── Plug in the cameras ──────────────────────────────
     Four cameras on four mounts. PhotonVision gives each port its saved name and calibration;
     robot code gives each name a mount. A camera's pose estimate is its real field pose, turned
     about the tag it sees by the calibration error, then walked back through the mount robot
     code *thinks* it has. */
  {
    const PORTS = [
      { name: 'TopLeft', hub: '2.1' }, { name: 'TopRight', hub: '2.3' },
      { name: 'BottomLeft', hub: '2.2' }, { name: 'BottomRight', hub: '2.4' },
    ];
    // mounts in robot coordinates: x forward, y left (m), yaw (rad). Robot code: port p -> MOUNTS[p].
    const MOUNTS = [
      { x: 0.3, y: 0.3, t: 35 * D2R, label: 'front-left', color: '#c4b5fd' },
      { x: 0.3, y: -0.3, t: -35 * D2R, label: 'front-right', color: '#67e8f9' },
      { x: -0.3, y: 0.3, t: 145 * D2R, label: 'back-left', color: AMBER },
      { x: -0.3, y: -0.3, t: -145 * D2R, label: 'back-right', color: LIME },
    ];
    // Each lens's principal point cx (px). TopLeft's and TopRight's are our real bench calibrations;
    // the other two and the spare are made-up values in the same range.
    const LENS0 = [650.5, 597.9, 624.3, 611.8], SPARE = 612.0, FX = 737.4, TAG_D = 3;
    const S = { cable: [0, 1, 2, 3], lens: LENS0.slice(), calib: LENS0.slice(), sel: -1, last: 'reset', solver: 'mt2' };

    const compose = (a, b) => ({ x: a.x + Math.cos(a.t) * b.x - Math.sin(a.t) * b.y, y: a.y + Math.sin(a.t) * b.x + Math.cos(a.t) * b.y, t: a.t + b.t });
    const inverse = (a) => ({ x: -(Math.cos(a.t) * a.x + Math.sin(a.t) * a.y), y: -(-Math.sin(a.t) * a.x + Math.cos(a.t) * a.y), t: -a.t });
    const wrap = (a) => Math.atan2(Math.sin(a), Math.cos(a));
    const ROBOT = { x: 0, y: 0, t: 0 };

    // per port: where the camera really is, the tag it sees, and where it says the robot is
    const solve = () => PORTS.map((P, p) => {
      const m = S.cable[p], cam = compose(ROBOT, MOUNTS[m]), tag = compose(cam, { x: TAG_D, y: 0, t: 0 });
      const dth = Math.atan((S.lens[m] - S.calib[p]) / FX);
      const c = Math.cos(dth), s = Math.sin(dth), vx = cam.x - tag.x, vy = cam.y - tag.y;
      const seen = { x: tag.x + c * vx - s * vy, y: tag.y + s * vx + c * vy, t: cam.t + dth };
      let est;
      if (S.solver === 'mt1') est = compose(seen, inverse(MOUNTS[p])); // full pose from the tag
      else { // heading from the gyro: the tag's direction is taken along the camera's *configured* yaw
        const a = ROBOT.t + MOUNTS[p].t + dth, cp = { x: tag.x - TAG_D * Math.cos(a), y: tag.y - TAG_D * Math.sin(a), t: ROBOT.t + MOUNTS[p].t };
        est = compose(cp, inverse(MOUNTS[p]));
      }
      return { m, cam, tag, est, mountOk: m === p, calOk: Math.abs(S.lens[m] - S.calib[p]) < 0.5, miss: Math.hypot(est.x - ROBOT.x, est.y - ROBOT.y), dt: Math.abs(wrap(est.t - ROBOT.t)) };
    });
    let sol = solve();
    const disp = sol.map((r) => ({ ...r.est }));

    const portsEl = $('#cs-ports');
    portsEl.innerHTML = PORTS.map((P, p) => `<button class="port" data-p="${p}" aria-pressed="false"><div class="sock"></div><div class="nm">${P.name}<small>hub ${P.hub}</small></div><div class="cam"></div><div class="st"></div></button>`).join('');
    const btns = [...portsEl.querySelectorAll('.port')];
    const fmtM = (m) => (m < 0.995 ? Math.round(m * 100) + ' cm' : m.toFixed(2) + ' m');

    const NOTES = {
      reset: 'Every camera is in its own port with its own calibration. All four views agree on where the robot is.',
      swap: '<b>Front-left and front-right cables swapped.</b> PhotonVision now calls the front-left camera TopRight and gives it TopRight\'s calibration, and robot code applies TopRight\'s mount to it. With the heading from the gyro, each tag is looked for in the wrong direction and the robot lands metres away. Camera Matching still says Active: the two cameras look identical to it.',
      replace: '<b>The front-left camera was replaced</b> with a new one in the same port. It got TopLeft\'s name and settings, which is fine, and the old lens\'s calibration, which isn\'t. A smaller miss, but a real one. Press Recalibrate.',
    };
    const update = () => {
      sol = solve();
      btns.forEach((b, p) => {
        const r = sol[p], M = MOUNTS[r.m], spare = r.m === 0 && S.lens[0] === SPARE;
        b.classList.toggle('sel', S.sel === p); b.setAttribute('aria-pressed', S.sel === p);
        b.querySelector('.cam').innerHTML = `<i style="background:${M.color}"></i>${M.label} camera${spare ? ' (new)' : ''}`;
        const st = b.querySelector('.st');
        if (r.mountOk && r.calOk) { st.className = 'st ok'; st.textContent = '✓ right mount, right calibration'; }
        else if (r.mountOk) { st.className = 'st warn'; st.textContent = '⚠ another lens\'s calibration'; }
        else { st.className = 'st bad'; st.textContent = `✗ robot code thinks: ${MOUNTS[p].label}${r.calOk ? '' : ', wrong lens'}`; }
        b.setAttribute('aria-label', `${PORTS[p].name} port, hub ${PORTS[p].hub}: ${M.label} camera. ${st.textContent}`);
      });
      const nm = sol.filter((r) => r.mountOk).length, nc = sol.filter((r) => r.calOk).length;
      const worst = sol.reduce((a, r) => (r.miss > a.miss ? r : a), sol[0]);
      const e1 = $('#cs-r-mount'); e1.textContent = `${nm} of 4`; e1.style.color = nm < 4 ? ROSE : '';
      const e2 = $('#cs-r-cal'); e2.textContent = `${nc} of 4`; e2.style.color = nc < 4 ? AMBER : '';
      const e3 = $('#cs-r-miss'); e3.textContent = worst.miss < 0.005 ? '0 cm' : fmtM(worst.miss) + (worst.dt > 2 * D2R ? `, ${Math.round(worst.dt / D2R)}°` : '');
      e3.style.color = worst.miss > 0.5 ? ROSE : worst.miss > 0.02 ? AMBER : '';
      $('#cs-r-match').textContent = '4 Active';
      let note = NOTES[S.last];
      if (S.last === 'recal') note = nm < 4 ? '<b>Every port now has the right calibration for the lens in it</b>, but the swapped cameras still miss by far more: robot code still applies the wrong mount. Recalibrating can\'t fix a swapped cable. Put the cables back.' : '<b>The calibrations match the lenses again.</b> Every view agrees on where the robot is.';
      if (S.last === 'manual') note = nm === 4 && nc === 4 ? NOTES.reset : nm < 4 ? `<b>${4 - nm} cameras are in someone else's port.</b> Each gets that port's name and calibration, and robot code walks back through the wrong mount. Camera Matching can't tell.` : 'Cables are right, but not every calibration belongs to the lens in its port.';
      if (S.sel >= 0) note = `<b>${PORTS[S.sel].name} picked.</b> Tap another port to swap the two cables, or the same one to cancel.`;
      $('#cs-note').innerHTML = note;
    };
    Site.seg($('#cs-solver'), (v) => { S.solver = v; update(); });
    const reset = () => { S.cable = [0, 1, 2, 3]; S.lens = LENS0.slice(); S.calib = LENS0.slice(); S.sel = -1; };
    root.querySelectorAll('[data-act]').forEach((b) => (b.onclick = () => {
      const a = b.dataset.act;
      if (a === 'reset') reset();
      if (a === 'swap') { reset(); S.cable = [1, 0, 2, 3]; }
      if (a === 'replace') { reset(); S.lens[0] = SPARE; }
      if (a === 'recal') { S.calib = PORTS.map((P, p) => S.lens[S.cable[p]]); S.sel = -1; }
      S.last = a; update();
    }));
    portsEl.addEventListener('click', (e) => {
      const b = e.target.closest('.port'); if (!b) return;
      const p = +b.dataset.p;
      if (S.sel < 0) S.sel = p;
      else if (S.sel === p) S.sel = -1;
      else { const q = S.sel; [S.cable[p], S.cable[q]] = [S.cable[q], S.cable[p]]; S.sel = -1; S.last = 'manual'; }
      update();
    });

    const cv = $('#cs-robot'); const st = Site.canvas(cv, 0.9);
    const draw = () => {
      const { ctx, w, h } = st; if (!w) return;
      const k = Math.min(w / 8.6, h / 7.9), cx = w / 2, cy = h / 2;
      const Sx = (x, y) => [cx - y * k, cy - x * k];
      const toScr = (pose, px, py) => Sx(pose.x + Math.cos(pose.t) * px - Math.sin(pose.t) * py, pose.y + Math.sin(pose.t) * px + Math.cos(pose.t) * py);
      ctx.fillStyle = LAB; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = 'rgba(196,181,253,.07)'; ctx.lineWidth = 1;
      for (let m = -5; m <= 5; m++) { let a = Sx(m, -6), b = Sx(m, 6); ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...b); ctx.stroke(); a = Sx(-6, m); b = Sx(6, m); ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...b); ctx.stroke(); }
      const robot = (pose, stroke, dash, lw, fill) => {
        const c = [[0.4, 0.4], [0.4, -0.4], [-0.4, -0.4], [-0.4, 0.4]].map(([a, b]) => toScr(pose, a, b));
        ctx.beginPath(); c.forEach((p, i) => (i ? ctx.lineTo(...p) : ctx.moveTo(...p))); ctx.closePath();
        if (fill) { ctx.fillStyle = fill; ctx.fill(); }
        ctx.setLineDash(dash); ctx.strokeStyle = stroke; ctx.lineWidth = lw; ctx.stroke(); ctx.setLineDash([]);
        const f1 = toScr(pose, 0.4, 0.28), f2 = toScr(pose, 0.4, -0.28); // front bumper
        ctx.lineWidth = lw + 2; ctx.beginPath(); ctx.moveTo(...f1); ctx.lineTo(...f2); ctx.stroke(); ctx.lineWidth = 1;
      };
      // each camera: its view wedge, the tag it sees
      sol.forEach((r) => {
        const M = MOUNTS[r.m], c = Sx(r.cam.x, r.cam.y), half = 40 * D2R;
        ctx.fillStyle = M.color + '14'; ctx.beginPath(); ctx.moveTo(...c);
        for (let a = -half; a <= half + 1e-6; a += half / 6) ctx.lineTo(...Sx(r.cam.x + Math.cos(r.cam.t + a) * TAG_D * 1.12, r.cam.y + Math.sin(r.cam.t + a) * TAG_D * 1.12));
        ctx.closePath(); ctx.fill();
        ctx.strokeStyle = M.color + '66'; ctx.setLineDash([3, 4]); ctx.beginPath(); ctx.moveTo(...c); ctx.lineTo(...Sx(r.tag.x, r.tag.y)); ctx.stroke(); ctx.setLineDash([]);
        // tag: a short wall facing the camera
        const s = 0.22, tx = -Math.sin(r.cam.t) * s, ty = Math.cos(r.cam.t) * s;
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 4; ctx.beginPath(); ctx.moveTo(...Sx(r.tag.x + tx, r.tag.y + ty)); ctx.lineTo(...Sx(r.tag.x - tx, r.tag.y - ty)); ctx.stroke(); ctx.lineWidth = 1;
      });
      robot(ROBOT, '#fff', [], 2, 'rgba(124,58,237,.35)');
      sol.forEach((r) => { const c = Sx(r.cam.x, r.cam.y); ctx.fillStyle = MOUNTS[r.m].color; ctx.beginPath(); ctx.arc(c[0], c[1], 5, 0, 7); ctx.fill(); });
      // where each camera says the robot is
      ctx.font = '600 11px JetBrains Mono';
      sol.forEach((r, p) => {
        const d = disp[p], col = MOUNTS[r.m].color;
        const q = Sx(d.x, d.y), pad = 16;
        if (q[0] < pad || q[0] > w - pad || q[1] < pad || q[1] > h - pad) { // off the picture: an arrow at the edge
          const ex = Math.min(w - pad, Math.max(pad, q[0])), ey = Math.min(h - pad, Math.max(pad, q[1])), ang = Math.atan2(q[1] - cy, q[0] - cx);
          ctx.save(); ctx.translate(ex, ey); ctx.rotate(ang); ctx.fillStyle = col; ctx.beginPath(); ctx.moveTo(8, 0); ctx.lineTo(-6, -6); ctx.lineTo(-6, 6); ctx.closePath(); ctx.fill(); ctx.restore();
          const lbl = `${PORTS[p].name} ${Math.hypot(d.x, d.y).toFixed(1)} m`, tw = ctx.measureText(lbl).width;
          ctx.fillStyle = col; ctx.fillText(lbl, Math.min(w - tw - 4, Math.max(4, ex - tw / 2)), ey < h / 2 ? ey + 22 : ey - 14);
          return;
        }
        robot(d, col, [5, 4], 1.5, null);
        if (Math.hypot(d.x, d.y) > 0.12 || Math.abs(wrap(d.t)) > 0.05) {
          ctx.fillStyle = col; ctx.textAlign = 'center'; ctx.fillText(PORTS[p].name, q[0], q[1] + 4); ctx.textAlign = 'left';
        }
      });
      ctx.font = '10px JetBrains Mono'; ctx.fillStyle = MUTED; ctx.fillText('top-down · grid 1 m · robot front is up', 8, h - 8);
      ctx.fillStyle = INK; ctx.font = '600 11px Plus Jakarta Sans'; ctx.fillText('tag', ...Sx(sol[0].tag.x + 0.25, sol[0].tag.y - 0.1));
    };
    Site.loop(cv, (t, dt) => {
      const a = 1 - Math.exp(-(dt || 0.016) * 7);
      sol.forEach((r, p) => { const d = disp[p]; d.x += (r.est.x - d.x) * a; d.y += (r.est.y - d.y) * a; d.t += wrap(r.est.t - d.t) * a; });
      draw();
    });
    update();
    requestAnimationFrame(draw);
  }

  /* ── Bench sheet ──────────────────────────────────── */
  {
    const STEPS = [
      ['Plug in and name', 'Active on Camera Matching, named after its port; cable and port labelled', 1],
      ['USB bandwidth', 'Streaming, not "squeezed" (under 90%), largest frame fits 1.3x+', 2],
      ['Team defaults', 'AprilTagCuda, 1280x800 MJPEG, 5.0 ms, cutoff 15, Low Latency off', 3],
      ['Focus and lock', 'Centre 100%, grid near 100% everywhere, lens glued', 4],
      ['Exposure', 'Far tags found without flicker; about 120 fps', 5],
      ['Calibrate', '100+ snapshots, error under 1 px, fx near 737 px; 3D came on', 6],
      ['Measure the mount', 'robotToCamera in robot code; mount estimate agrees', 7],
      ['Copy to siblings', 'Copy settings done; settingsJson matches', 8],
      ['Final checks and backup', 'fps, distances, pose on a measured spot, AndyMark layout, Export Settings', 9],
    ];
    const KEY = 'vt-camsetup';
    let data = {};
    try { data = JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (e) { data = {}; }
    if (!data || typeof data !== 'object' || Array.isArray(data)) data = {};
    const save = () => { try { localStorage.setItem(KEY, JSON.stringify(data)); } catch (e) {} };
    let cam = 'TopLeft';
    const list = $('#cs-sheet');
    list.innerHTML = STEPS.map(([t, pass, n], i) => `<li><label><input type="checkbox" data-i="${i}"><span><b>${n}. ${t}</b><small>${pass}</small></span><a href="#cs-s${n}">step ${n} ↑</a></label></li>`).join('');
    const boxes = [...list.querySelectorAll('input')];
    const show = () => {
      const s = data[cam] || [];
      boxes.forEach((b, i) => { b.checked = !!s[i]; b.closest('li').classList.toggle('done', !!s[i]); });
      const n = boxes.filter((b) => b.checked).length;
      $('#cs-count').textContent = n === 9 ? `${cam} ready ✓` : `${n} of 9`;
      $('#cs-bar').style.width = (100 * n) / 9 + '%';
    };
    list.addEventListener('change', (e) => {
      const b = e.target.closest('input'); if (!b) return;
      (data[cam] = data[cam] || [])[+b.dataset.i] = b.checked;
      save(); show();
    });
    $('#cs-clear').onclick = () => { delete data[cam]; save(); show(); };
    Site.seg($('#cs-cam'), (v) => { cam = v; show(); });
  }
});
