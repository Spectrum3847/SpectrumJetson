Site.chapter('pit', (root) => {
  const $ = (s) => root.querySelector(s);
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  /* ── Symptom finder ──────────────────────────────────────
     A small decision tree. A question node has q (the question), short (its breadcrumb label),
     optional help, and yes / no (the next node's id; yesLabel / noLabel rename the buttons).
     A leaf has title, cause, steps (quickest first), confirm, why [href, label], and optional
     warn (a red box) and more (shown in the Full course only). Content is ours, so it's HTML. */
  const DASH = '<code>10.85.15.15:5800</code>';
  const NOREBOOT = '<b>Don\'t reboot the Jetson</b> (or press Reboot Device). A reboot doesn\'t cut USB power, so a stuck camera stays stuck, and a reboot with stuck cameras has hung the Jetson twice.';
  const SYMPTOMS = [
    ['notargets', '🎯', 'The robot says it sees no targets'],
    ['missing', '📷', 'A camera is missing'],
    ['lowfps', '🐢', 'Low fps'],
    ['flicker', '💡', 'Tags flicker in and out'],
    ['pose', '📍', 'Pose jumps, or the robot is in the wrong place'],
    ['nodash', '🌐', 'Can\'t reach the dashboard'],
    ['pvdown', '⛔', 'PhotonVision won\'t start'],
    ['version', '🧩', 'Robot code error about PhotonLib\'s version'],
    ['noboot', '🔌', 'The Jetson won\'t come back after a reboot'],
    ['stream', '🖥️', 'A camera\'s stream won\'t show in the browser'],
    ['blackcal', '⬛', 'The image is black during calibration'],
    ['calfail', '🏁', 'Calibration fails'],
  ];
  const N = {
    /* no targets */
    notargets: { q: 'Open the dashboard (' + DASH + ') and hold a tag in front of that camera. Does PhotonVision draw a box on it?', short: 'Boxed on the dashboard?', yes: 'nt_topic', no: 'nt_fps' },
    nt_topic: { q: 'In a NetworkTables viewer on the robot side, is <code>/photonvision/&lt;camera name&gt;</code> there, and updating?', short: 'Topics on the robot?', help: 'AdvantageScope or the driver dashboard can show NetworkTables. Look for the camera\'s name under <code>photonvision</code>.', yes: 'L_name', no: 'L_nt' },
    nt_fps: { q: 'Is that camera\'s fps normal on the dashboard (about 120)?', short: 'fps normal?', yes: 'L_nodetect', no: 'lowfps' },
    L_name: {
      title: 'The robot code is asking for a different camera name',
      cause: 'PhotonVision is sending results, but <code>new PhotonCamera("…")</code> in the robot code uses a name that doesn\'t match exactly. Names are case-sensitive: <code>TopLeft</code> is not <code>topLeft</code> or <code>Top Left</code>.',
      steps: [
        'Compare the name in the robot code with the camera\'s name on the dashboard, letter for letter. Ours are <code>TopLeft</code>, <code>TopRight</code>, <code>BottomLeft</code> and <code>BottomRight</code>, after their USB ports.',
        'Fix the robot code, not the Jetson: renaming the camera in PhotonVision would break the other places that use the name.',
        'If the names match, check that the camera wasn\'t swapped into another port (it would take that port\'s name).',
        'Check the robot code reads every loop with <code>getAllUnreadResults()</code> and doesn\'t throw away results it doesn\'t like.',
      ],
      confirm: 'The robot code reports targets while you hold a tag up.',
      why: ['#photonlib', 'Chapter 18: PhotonLib on the robot'],
    },
    L_nt: {
      title: 'PhotonVision isn\'t talking to the robot\'s NetworkTables',
      cause: 'The Jetson sees tags, but its results aren\'t reaching the SystemCore.',
      steps: [
        'Check the Ethernet cable at both ends: the Jetson and the radio or switch. Look for link lights.',
        'In PhotonVision\'s Settings, <b>Team Number/NetworkTables Server Address</b> must be <code>8515</code>.',
        '<b>Run NetworkTables Server (Debugging Only)</b>, under Advanced Networking in Settings, must be off. With it on, PhotonLib can\'t work.',
        'Is the robot on, and robot code running? PhotonVision is a NetworkTables client: it needs the SystemCore\'s server.',
        'Run the health check: under "Robot connection" it should say <code>NT connected to 10.85.15.2…</code>.',
      ],
      confirm: 'The camera\'s topics appear under <code>/photonvision/</code> on the robot, and <code>/photonvision/jetson/heartbeat</code> counts up once a second.',
      why: ['#networktables', 'Chapter 15: Talking to the SystemCore'],
    },
    L_nodetect: {
      title: 'The camera works, but doesn\'t find the tag',
      cause: 'Frames are arriving at full speed, so it\'s the pipeline or the picture.',
      steps: [
        'Check the camera is on its AprilTag pipeline, not in driver mode or on a game-piece pipeline. Robot code can switch these, so check it too.',
        'Tag family should be 36h11 (the FRC tags).',
        'Try closer: a tag at 1–2 m, straight on. If that works, the far tag is just too small or blurry (see "Tags flicker").',
        'Too dark? Exposure should be about 5 ms, with auto exposure off. The decision margin cutoff is 15.',
        'Wipe the lens. Check focus with the Focus card on the Camera page.',
      ],
      confirm: 'A box on the tag in the dashboard, and <code>tags/frame</code> above 0 in the <code>971 stats</code> log line.',
      why: ['#settings', 'Chapter 4: Camera settings'],
      more: 'The pipeline type for our GPU detector is the CUDA AprilTag one. If the health check says "CUDA detector not loaded", no camera is on it.',
    },

    /* missing camera */
    missing: { q: 'Was it working, then disappeared after a hit, a static shock or a USB glitch?', short: 'Gone after a glitch?', help: 'Its <code>health/problem</code> topic, or the log, may say <em>"not answering on USB port …: replug it, or power-cycle the robot."</em>', yes: 'L_stuck', no: 'mi_listed' },
    mi_listed: { q: 'Does PhotonVision\'s Camera Matching page list the camera at all?', short: 'Listed in Camera Matching?', help: 'Over SSH, <code>lsusb -t</code> answers the same question.', yes: 'mi_bw', no: 'L_cable' },
    mi_bw: { q: 'Is it listed but not streaming, with "No space left on device" or "Not enough bandwidth" in the log?', short: 'Bandwidth error?', yes: 'L_bw', no: 'L_notset' },
    L_stuck: {
      title: 'A stuck camera: it needs its power cut',
      cause: 'A USB glitch can leave a Thriftiest Cam unable to answer until its power is cut. Nothing in software brings it back, and neither does a reboot.',
      warn: NOREBOOT,
      steps: [
        'Replug that camera: pull its USB plug, wait 2 s, push it back into its own labeled port.',
        'Or, between matches, power-cycle the whole robot. That cuts power to every camera at once.',
        'If it keeps happening, check that plug\'s glue and strain relief: a loose plug is the likely cause.',
      ],
      confirm: 'The camera is detecting about 1 s after it\'s plugged back in: ~120 fps on the dashboard, and its <code>health/problem</code> no longer says "not answering".',
      why: ['#failsafes', 'Chapter 16: Built for match day'],
      more: 'The kernel log shows <code>device descriptor read/64, error -110</code>, then "unable to enumerate USB device". After a USB hub reset, other kinds of camera come back by themselves in about 40 s; the Thriftiest Cams don\'t.',
    },
    L_cable: {
      title: 'The Jetson can\'t see the camera: cable or plug',
      cause: 'The camera isn\'t connecting at all, usually the cable, an adapter, or a plug that isn\'t fully in.',
      steps: [
        'Reseat both ends of the cable. Make sure it\'s in its own labeled port.',
        'Swap in a spare cable.',
        'Cameras go in the USB-A ports. The USB-C port only works through a hub.',
        'Over SSH, <code>usb-bandwidth.py</code> or the health check names the port that failed. <code>error -71</code> or a camera showing up as low-speed means the data wires aren\'t connecting.',
      ],
      confirm: 'The camera shows up in Camera Matching with its name, and streams at ~120 fps.',
      why: ['#camsetup', 'Chapter 20: Setting up a camera'],
    },
    L_bw: {
      title: 'Out of USB bandwidth',
      cause: 'Every USB 2.0 port on the Jetson shares one budget. Each camera reserves a slice when it starts, and the last one didn\'t fit.',
      steps: [
        'On the Camera Matching page, open the USB bandwidth card and lower another camera\'s allocation (or this one\'s) so the total fits.',
        'Moving the camera to another port doesn\'t help: the USB-A ports, the USB-C port and any hub all share the same budget.',
        'Over SSH, <code>usb-bandwidth.py</code> shows what each camera reserves and prints the fix.',
      ],
      confirm: 'Every camera streams, and each still shows ~120 fps. (A squeezed Thriftiest Cam keeps its frame rate by compressing harder.)',
      why: ['#camsetup', 'Chapter 20: Setting up a camera'],
    },
    L_notset: {
      title: 'Plugged in, but not set up, or in the wrong port',
      cause: 'PhotonVision sees the camera but isn\'t running it, or it\'s in another camera\'s port.',
      steps: [
        'On Camera Matching, activate the camera if it\'s listed as unused.',
        'Check it\'s in its labeled port. Every Thriftiest Cam has the same serial number, so PhotonVision tells them apart by port. A camera in the wrong port takes that port\'s name <em>and calibration</em>.',
        'Restart PhotonVision (Settings › Device Control › Restart Software).',
      ],
      confirm: 'The camera streams under its own name (TopLeft etc.), at ~120 fps.',
      why: ['#camsetup', 'Chapter 20: Setting up a camera'],
    },

    /* low fps */
    lowfps: { q: 'Are all the cameras slow, not just one?', short: 'All cameras?', yesLabel: 'All of them', noLabel: 'Just one', yes: 'lf_thr', no: 'L_exposure' },
    lf_thr: { q: 'Does the Settings page show CPU Throttling as something other than <code>None</code>?', short: 'Throttling?', yes: 'L_throttle', no: 'L_allslow' },
    L_exposure: {
      title: 'Exposure too long: the units trap',
      cause: 'A frame can\'t be shorter than its exposure. USB cameras count exposure in units of 100 µs, so a raw value of 295 is 29.5 ms, which caps the camera at about 34 fps.',
      steps: [
        'On the camera\'s Input tab, turn auto exposure off.',
        'Set Exposure to about 5 ms (raw value 50). Our slider shows milliseconds, e.g. "Exposure (5.0 ms)". Anything over 8.3 ms (83) can\'t reach 120 fps.',
        'Check the video mode is 1280x800 MJPEG. An uncompressed mode can\'t reach 120 fps over USB 2.0.',
      ],
      confirm: 'The camera\'s fps number reads about 120. (The video in the browser is capped at 30 fps on purpose: judge by the number.)',
      why: ['#settings', 'Chapter 4: Camera settings'],
      more: 'A camera copied from another one, or set up with calibration settings (about 15 ms), is the usual way a long exposure sneaks in.',
    },
    L_throttle: {
      title: 'The Jetson is slowing itself down',
      cause: 'The throttle reason says why: <code>OVER-CURRENT</code> when the supply sagged, <code>HIGH TEMP</code> when it\'s too hot, or a capped clock.',
      steps: [
        '<code>OVER-CURRENT</code>: swap in a fresh battery, and check the Jetson\'s power wiring and connector.',
        '<code>HIGH TEMP</code>: is the fan spinning? Is anything blocking the airflow? The health check reads the fan\'s real speed.',
        '<code>Prev. over-current (N)</code> only means it happened earlier. It isn\'t throttling now.',
      ],
      confirm: 'CPU Throttling says <code>None</code>, and fps is back to ~120.',
      why: ['#failsafes', 'Chapter 16: Built for match day'],
    },
    L_allslow: {
      title: 'Every camera slow, no throttling',
      cause: 'Most likely the same long exposure on every camera (settings can be copied between cameras), or the Jetson isn\'t in its full-speed mode.',
      steps: [
        'Check each camera\'s exposure: about 5 ms, auto exposure off.',
        'Run the health check. It should say <code>power mode MAXN SUPER</code> and <code>clocks locked</code>, and name any camera under 30 fps.',
        'Restart PhotonVision (Settings › Device Control › Restart Software).',
      ],
      confirm: 'Every camera reads ~120 fps; the <code>971 stats</code> lines say about 120 calls/s.',
      why: ['#settings', 'Chapter 4: Camera settings'],
    },

    /* flicker */
    flicker: { q: 'Does it flicker even with the robot still and the tag close (1–3 m)?', short: 'Close and still?', yes: 'L_lights', no: 'L_range' },
    L_lights: {
      title: 'Decision margin near the cutoff: light is the problem',
      cause: 'Each tag gets a <span class="term">decision margin</span> score. If it\'s hovering near our cutoff of 15, the tag drops in and out. Dim light, or lights that flicker, cause it.',
      steps: [
        'Watch the margin: the <code>971 stats</code> log line shows <code>margin avg … min …</code>.',
        'Run <code>tests/flicker-check/run.sh</code> under these lights. If the frames pulse, set exposure to 83 (8.3 ms): that covers one full flicker of mains-powered lights.',
        'If they don\'t pulse, lower the cutoff a little. Retune on the event field, not in the pit.',
      ],
      confirm: 'The tag stays boxed for 10 s straight, and the margin sits well above the cutoff.',
      why: ['#settings', 'Chapter 4: Camera settings'],
    },
    L_range: {
      title: 'Far or fast: that\'s the edge of what the camera can see',
      cause: 'A far tag is only a few pixels across, and a moving robot smears it. Near the limit, some frames find it and some don\'t. That\'s normal.',
      steps: [
        'Keep exposure short (about 5 ms): longer smears the tag while the robot moves.',
        'Check focus with the Focus card; a soft image loses far tags first.',
        'In robot code, trust far single tags less (bigger standard deviations) instead of trying to see farther.',
      ],
      confirm: 'Close tags are rock steady; only far or fast ones come and go.',
      why: ['#settings', 'Chapter 4: Camera settings'],
    },

    /* pose */
    pose: { q: 'Is it wrong by a steady amount: always shifted or turned the same way?', short: 'Steady offset?', yes: 'L_offset', no: 'po_move' },
    po_move: { q: 'Does it jump mostly while the robot is turning or driving fast?', short: 'Only while moving?', yes: 'L_timing', no: 'L_jumps' },
    L_offset: {
      title: 'Something in the setup doesn\'t match the real robot or field',
      cause: 'A steady error means a wrong number, not noise. Check these in order.',
      steps: [
        '<b>Field layout:</b> both sides must use the <b>2026 Rebuilt AndyMark</b> layout: PhotonVision (Settings › AprilTag Field Layout) and robot code (<code>AprilTagFields.k2026RebuiltAndymark</code>). Tags sit a few cm differently on the welded field.',
        '<b>Ports:</b> is every camera in its labeled port? A swapped camera uses the other camera\'s name and calibration.',
        '<b>Camera mount:</b> the robot code\'s <code>robotToCamera</code> for that camera must match where it really is. Measure it. A camera knocked crooked needs a new number.',
        '<b>Calibration:</b> if a lens turned, recalibrate at 1280x800.',
      ],
      confirm: 'Park on a spot you know: each camera alone puts the robot there, within a few cm.',
      why: ['#coords', 'Chapter 19: Coordinate systems'],
      more: 'To find the bad camera, look at each camera\'s pose alone. If only one is off, it\'s that camera\'s mount, port or calibration; if all are off the same way, it\'s the field layout or the robot code.',
    },
    L_timing: {
      title: 'The pose is stamped with the wrong time',
      cause: 'If vision is matched to the wrong moment, the robot has already moved on, and turning makes it worst.',
      steps: [
        'Robot code must pass the result\'s timestamp to <code>addVisionMeasurement</code>, not the current time.',
        'Check time sync: the health check should say "time sync pointed at the robot".',
        'Trust vision less while spinning fast, or use the gyro heading (below).',
      ],
      confirm: 'Driving in circles, the vision pose stays with the wheel pose instead of swinging wide.',
      why: ['#latency', 'Chapter 14: Latency and timestamps'],
    },
    L_jumps: {
      title: 'Single-tag flips, or a bad tag',
      cause: 'One tag can give two answers (the ambiguity flip), especially far away. And at an event, a tag can be mounted wrong.',
      steps: [
        'Use the gyro heading: a heading-constrained solve can\'t flip.',
        'Reject single far tags with high ambiguity in robot code.',
        'If one tag ID is always involved, leave it out: Settings › AprilTag Field Layout › <b>Tags left out of multi-tag</b>.',
      ],
      confirm: 'Parked, the pose stays put within a few cm for 30 s.',
      why: ['#gyro', 'Chapter 13: Why the gyro helps'],
    },

    /* dashboard */
    nodash: { q: 'Are you on the bench, with the laptop plugged into the Jetson\'s USB-C port?', short: 'On the bench?', yes: 'L_bench', no: 'nd_ping' },
    nd_ping: { q: 'From the laptop, does <code>ping 10.85.15.15</code> get replies?', short: 'Ping answers?', help: 'The laptop must be on the robot\'s network (the radio). Its own address should start with <code>10.85.15.</code>', yes: 'L_pvnotanswering', no: 'L_network' },
    L_bench: {
      title: 'Use the USB-C address',
      cause: 'Over the USB-C cable the Jetson has a different address: <code>192.168.55.1</code>.',
      steps: [
        'Open <code>http://192.168.55.1:5800</code>.',
        'Give it 20 s after power-on.',
        'No luck? Try another USB-C cable: some only charge and carry no data.',
        '<code>ping 192.168.55.1</code>. If it answers but the page doesn\'t load, PhotonVision isn\'t running: see "PhotonVision won\'t start".',
      ],
      confirm: 'The dashboard loads.',
      why: ['#networktables', 'Chapter 15: Talking to the SystemCore'],
    },
    L_pvnotanswering: {
      title: 'The Jetson is up, but PhotonVision isn\'t answering',
      cause: 'The network is fine. The program behind the page isn\'t running.',
      steps: [
        'SSH in and run <code>systemctl status photonvision</code>.',
        'Restart it: <code>sudo systemctl restart photonvision</code>. Give it a few seconds.',
        'Still down? Go to "PhotonVision won\'t start".',
      ],
      confirm: 'The dashboard loads at ' + DASH + '.',
      why: ['#linux', 'Chapter 6: Linux and drivers'],
    },
    L_network: {
      title: 'The laptop can\'t reach the Jetson',
      cause: 'Either the laptop isn\'t on the robot network, or the Jetson isn\'t on it (no power, no cable, or still booting).',
      steps: [
        'Connect the laptop to the robot\'s radio. Its own address should start with <code>10.85.15.</code>',
        'Is the Jetson powered? Give it 20 s after power-on.',
        'Check the Ethernet link lights at the Jetson and at the radio or switch. Reseat the cable.',
        'Use the address, not a name: <code>photonvision.local</code> won\'t work, because our Jetson is called <code>photonvision-3847</code>, and names can be flaky on robot networks anyway.',
        'Nothing after a minute? See "The Jetson won\'t come back".',
      ],
      confirm: '<code>ping 10.85.15.15</code> answers, and the dashboard loads.',
      why: ['#networktables', 'Chapter 15: Talking to the SystemCore'],
      more: 'The Jetson\'s static address, 10.85.15.15, is set in PhotonVision\'s Settings › Networking. Don\'t change it at an event: robot code and this page both rely on it.',
    },

    /* PhotonVision won't start */
    pvdown: { q: 'Does <code>journalctl -u photonvision -n 50</code> mention a "corrupt jarfile"?', short: 'Corrupt jarfile?', help: 'SSH in first. That shows the last 50 lines of PhotonVision\'s log.', yes: 'L_jar', no: 'L_pvother' },
    L_jar: {
      title: 'A bad PhotonVision program file was installed',
      cause: 'The <code>.jar</code> file is broken, e.g. a copy that stopped halfway.',
      steps: [
        'Put the last good one back: <code>sudo cp /opt/photonvision/photonvision.jar.prev /opt/photonvision/photonvision.jar</code>',
        'Then <code>sudo systemctl restart photonvision</code>.',
        'Later, reinstall with <code>06-install-fork-jar.sh</code>. It refuses a broken jar and keeps the old one as <code>.prev</code>.',
      ],
      confirm: 'The health check says <code>PASS running …</code>, and the dashboard loads.',
      why: ['#photonvision', 'Chapter 9: PhotonVision and our patches'],
    },
    L_pvother: {
      title: 'PhotonVision is crashing or restarting',
      cause: 'systemd restarts PhotonVision whenever it stops, so a crash usually looks like a dashboard that keeps disconnecting.',
      steps: [
        'Run the health check. It reports restarts since boot, running out of memory ("killed … out of memory"), and whether the GPU detector loaded.',
        'Read the log just before the restart (<code>journalctl -u photonvision -n 200</code>) for the first error.',
        'If the GPU breaks, the detector exits on purpose and PhotonVision is back in about 8 s. Over and over means get a mentor.',
        'Download the logs (Settings › Device Control › Download Logs) before anyone power-cycles.',
      ],
      confirm: 'The health check stops counting new restarts.',
      why: ['#failsafes', 'Chapter 16: Built for match day'],
    },

    /* PhotonLib version */
    version: {
      title: 'The robot\'s PhotonLib was upgraded',
      cause: 'Our Jetson runs a 2026 PhotonVision. The robot\'s PhotonLib must stay at <code>v2027.0.0-alpha-2</code>, which matches it on the wire. A newer PhotonLib can refuse the messages.',
      steps: [
        'Open <code>vendordeps/photonlib.json</code> in the robot project. The version must be <code>v2027.0.0-alpha-2</code>.',
        'If it changed, put the old file back from git (<code>git checkout -- vendordeps/photonlib.json</code>) and redeploy.',
        'Don\'t accept "update vendor dependencies" prompts for PhotonLib this season.',
      ],
      confirm: 'The error is gone after deploy, and targets arrive.',
      why: ['#photonlib', 'Chapter 18: PhotonLib on the robot'],
    },

    /* no boot */
    noboot: {
      title: 'The boot stopped before Linux started: power-cycle it',
      cause: 'Twice, after <code>sudo reboot</code>, the Jetson reset and never finished booting. The second time, cameras were stuck. The watchdog can\'t catch a hang this early.',
      warn: 'Next time cameras are stuck, <b>power-cycle instead of rebooting</b>.',
      steps: [
        'Power-cycle the robot: off, wait a few seconds, on.',
        'Wait about 20 s: that\'s when it starts detecting tags again.',
        'Tell a mentor when it happened and what came before. We\'re still hunting the cause.',
      ],
      confirm: 'The dashboard loads and every camera is at ~120 fps.',
      why: ['#failsafes', 'Chapter 16: Built for match day'],
    },

    /* stream */
    stream: { q: 'Do you have more than one PhotonVision tab or window open in this browser?', short: 'Several tabs open?', yes: 'L_connlimit', no: 'L_streamother' },
    L_connlimit: {
      title: 'The browser\'s connection limit',
      cause: 'Each video stream holds one connection open, and a browser allows only a few per address. Extra tabs use them up.',
      steps: [
        'Close the other PhotonVision tabs and windows.',
        'Reload this one with Ctrl+Shift+R.',
      ],
      confirm: 'Every camera\'s video shows.',
      why: ['#photonvision', 'Chapter 9: PhotonVision and our patches'],
    },
    L_streamother: {
      title: 'Only the video is missing, or the camera is?',
      cause: 'Check whether the camera is working and only the browser video is stuck.',
      steps: [
        'Reload with Ctrl+Shift+R.',
        'Look at the camera\'s fps number. At 0, the camera itself is out: go to "A camera is missing".',
        'Try another browser. An old one also hides the Settings page\'s Device Control card.',
      ],
      confirm: 'The video shows, and the fps reads ~120.',
      why: ['#photonvision', 'Chapter 9: PhotonVision and our patches'],
    },

    /* calibration */
    blackcal: {
      title: 'Calibration uses its own exposure',
      cause: 'The calibration card has its own camera settings, separate from the pipeline\'s short 5 ms exposure.',
      steps: [
        'In the calibration card: Auto Exposure off, Exposure about 150 (15 ms).',
        'That\'s fine for calibration, because the board is held still. Don\'t copy it into the AprilTag pipelines.',
      ],
      confirm: 'The board is clearly visible, and corners get marked.',
      why: ['#calibration', 'Chapter 11: Camera calibration'],
    },
    calfail: {
      title: 'Board size swapped',
      cause: '"Negative corner" or empty (null) intrinsics usually mean the board\'s width and height are the wrong way round.',
      steps: [
        'Set width 12 and height 9 (squares) for our board.',
        'Restart PhotonVision to clear the bad snapshots, then take them again.',
        '<code>check_board.py</code> in the repo checks a board photo.',
      ],
      confirm: 'The calibration finishes with a small reprojection error.',
      why: ['#calibration', 'Chapter 11: Camera calibration'],
    },
  };

  const symsEl = $('#pit-syms'), flow = $('#pit-flow'), card = $('#pit-card'), crumbs = $('#pit-crumbs');
  symsEl.innerHTML = SYMPTOMS.map(([id, ic, label]) => `<button type="button" data-id="${id}"><i aria-hidden="true">${ic}</i><span>${esc(label)}</span></button>`).join('');
  const symLabel = Object.fromEntries(SYMPTOMS.map(([id, , l]) => [id, l]));
  // path: [{ id, ans }] — each node visited, and the answer given there (the last has none)
  let path = [];

  const renderCrumbs = () => {
    // the symptom, then every answered question (tap one to go back to it), then where you are now
    const items = [`<li>${esc(symLabel[path[0].id])}</li>`];
    path.forEach((p, i) => {
      const n = N[p.id];
      if (!n.q) { items.push('<li aria-current="step">The fix</li>'); return; }
      if (!p.ans) { items.push(`<li aria-current="step">${esc(n.short)}</li>`); return; }
      const ans = esc(p.ans === 'yes' ? (n.yesLabel || 'Yes') : (n.noLabel || 'No'));
      items.push(`<li><button type="button" data-i="${i}" aria-label="Change your answer to: ${esc(n.short)} (you said ${ans})">${esc(n.short)}</button><span class="ans">${ans}</span></li>`);
    });
    crumbs.innerHTML = items.join('');
  };

  const renderNode = (focus) => {
    const n = N[path[path.length - 1].id];
    let h;
    if (n.q) {
      h = `<div class="kicker">Question ${path.length}</div><h5 tabindex="-1">${n.q}</h5>` +
        (n.help ? `<p class="qhelp">${n.help}</p>` : '') +
        `<div class="yn"><button type="button" class="y" data-a="yes">${esc(n.yesLabel || 'Yes')}</button><button type="button" data-a="no">${esc(n.noLabel || 'No')}</button></div>`;
    } else {
      h = `<div class="leaf"><div class="kicker">Likely cause</div><h5 tabindex="-1">${n.title}</h5><p class="cause">${n.cause}</p>` +
        (n.warn ? `<div class="warn">⚠️ ${n.warn}</div>` : '') +
        `<h6>Do this now</h6><ol>${n.steps.map((s) => `<li>${s}</li>`).join('')}</ol>` +
        `<h6>Fixed when</h6><div class="ok">✓ ${n.confirm}</div>` +
        (n.more ? `<p class="more full">${n.more}</p>` : '') +
        `<h6>Why</h6><p class="why"><a href="${n.why[0]}">${esc(n.why[1])} →</a></p>` +
        `<p class="hint" style="margin-top:12px">Not fixed? Press Start over and try the next-closest symptom, or run the health check.</p></div>`;
    }
    card.innerHTML = h;
    renderCrumbs();
    if (focus) card.querySelector('h5').focus({ preventScroll: true });
  };

  const show = (focus = true) => {
    const on = path.length > 0;
    symsEl.hidden = on; flow.hidden = !on;
    if (on) renderNode(focus);
    else if (focus) symsEl.querySelector('button').focus({ preventScroll: true });
    if (focus) { // keep the new question or answer on screen, just below the top bar
      const r = (on ? flow : symsEl).getBoundingClientRect();
      if (r.top < 70 || r.top > innerHeight * 0.7) scrollBy({ top: r.top - 90, behavior: Site.reduced ? 'auto' : 'smooth' });
    }
  };

  symsEl.addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (!b) return;
    path = [{ id: b.dataset.id }]; show();
  });
  card.addEventListener('click', (e) => {
    const b = e.target.closest('button[data-a]'); if (!b) return;
    const cur = path[path.length - 1];
    cur.ans = b.dataset.a;
    path.push({ id: N[cur.id][cur.ans] });
    show();
  });
  crumbs.addEventListener('click', (e) => {
    const b = e.target.closest('button[data-i]'); if (!b) return;
    path = path.slice(0, +b.dataset.i + 1); delete path[path.length - 1].ans; show();
  });
  $('#pit-back').onclick = () => {
    if (path.length <= 1) path = []; else { path.pop(); delete path[path.length - 1].ans; }
    show();
  };
  $('#pit-reset').onclick = () => { path = []; show(); };

  /* ── Health-check reports ─────────────────────────────── */
  {
    const CMD = '$ ssh -i ~/.ssh/jetson_ed25519 spectrum3847@10.85.15.15 \\\n    ~/SpectrumJetson/scripts/jetson/health-check.sh 4';
    const DET = '  PASS  971 library loaded (frc971/bos detector, min_white_black_diff 20, max_line_fit_mse 10, threads 6, CUDA wait block, GPU connections 32)';
    const tail = (boots) => [
      '== Robot connection',
      '  PASS  NT connected to 10.85.15.2:5810 (server team is 8515)',
      '  PASS  time sync pointed at the robot',
      '        addresses: enP8p1s0 10.85.15.15/8',
      '== System',
      '  PASS  power mode MAXN SUPER',
      '  PASS  clocks locked (CPU 1728 MHz, GPU 1020 MHz)',
      '  PASS  hottest sensor gpu-thermal 58 C',
      '  PASS  memory available 4630 MB',
      '  PASS  disk 12% used',
      '  PASS  fan: NVIDIA fan control, quiet profile, pwm 118/255, 2690 rpm',
      '  PASS  clock: 2026-10-17 16:42 UTC',
      '  PASS  filesystem: no ext4 errors recorded',
      `  PASS  system log kept across power cuts (${boots} boot(s) on file)`,
      '        boot time: 16.517s (multi-user.target)',
      '',
    ];
    const cam = (name, port) => [`  PASS  ${name} on USB port ${port} (480 Mbps, autosuspend off)`, `  PASS  ${name} streaming 1280x800 MJPG, as set`];
    const REPORTS = {
      ok: [
        '== PhotonVision', '  PASS  running 1840s, version dev-v2026.1.1-27-gd8c9e8e1',
        '== CUDA detector', DET,
        '  PASS  h0: 121 fps, detect 1.02 ms', '  PASS  h1: 122 fps, detect 0.98 ms', '  PASS  h2: 121 fps, detect 1.05 ms', '  PASS  h3: 122 fps, detect 1.01 ms',
        '  PASS  JPEG decode: NVJPG hardware, 486 frames/s (checks: 24110 ok, 0 differ)',
        '  PASS  calibration loaded for 4 detector(s), 8 lens coefficients',
        '== Cameras', ...cam('TopLeft', '2.1'), ...cam('BottomLeft', '2.2'), ...cam('TopRight', '2.3'), ...cam('BottomRight', '2.4'),
        '  PASS  camera driver: bandwidth cap 1bcf:28c5:1280',
        '  PASS  USB controller watchdog running',
        '  PASS  USB bandwidth reserved: bus 1: 5120 of ~6720 bytes per microframe (usb-bandwidth.py for details)',
        ...tail(14), 'READY (0 warning(s))',
      ],
      hit: [
        '== PhotonVision', '  PASS  running 2310s, version dev-v2026.1.1-27-gd8c9e8e1',
        '== CUDA detector', DET,
        '  PASS  h0: 121 fps, detect 1.03 ms', '  PASS  h2: 122 fps, detect 0.99 ms', '  PASS  h3: 121 fps, detect 1.04 ms',
        '  PASS  JPEG decode: NVJPG hardware, 365 frames/s (checks: 30251 ok, 0 differ)',
        '  PASS  calibration loaded for 4 detector(s), 8 lens coefficients',
        '== Cameras', ...cam('TopLeft', '2.1'), ...cam('TopRight', '2.3'), ...cam('BottomRight', '2.4'),
        '  FAIL  3 camera(s) found, expected 4',
        '  PASS  camera driver: bandwidth cap 1bcf:28c5:1280',
        '  PASS  USB controller watchdog running',
        '  FAIL  USB port 1-2.2: something plugged in there couldn\'t read its descriptor, couldn\'t be connected at all (in the last 10 min). That\'s usually the cable or adapter, or the plug not fully in; sometimes not enough power. Re-seat it, or try another cable or port. A camera that worked until a USB hub reset is stuck instead: replug it, or power-cycle the robot (a reboot doesn\'t cut USB power).',
        '  PASS  USB bandwidth reserved: bus 1: 3840 of ~6720 bytes per microframe (usb-bandwidth.py for details)',
        ...tail(14), 'NOT READY: 2 failure(s), 0 warning(s)',
      ],
    };
    // our notes: shown under the first line containing the key
    const NOTES = {
      ok: {
        'running 1840s': 'up 31 minutes with no restarts. A restart count would show up as a WARN here',
        'h3: 122 fps': 'h0–h3: one GPU detector per camera, all at ~120 fps. Under 30 fps gets a WARN (exposure too long?)',
        'calibration loaded for 4': 'every camera has its lens calibration',
        'TopLeft on USB port 2.1': 'every camera on its own port: names follow ports',
        'BottomRight streaming': 'really streaming the mode PhotonVision set, not a tiny image scaled up',
        'NT connected': 'talking to the SystemCore, as team 8515',
        'hottest sensor': 'WARN at 70 C, FAIL at 85 C',
        'fan: NVIDIA': 'read from the fan\'s speed sensor: it really spins',
        'READY': 'good to go. (A clean run still prints "0 warning(s)")',
      },
      hit: {
        'h3: 121 fps': 'only three detectors reporting: h1 is gone',
        '3 camera(s) found': 'BottomLeft (port 2.2) is missing from the list above',
        'USB port 1-2.2': 'the kernel tried and failed to talk to whatever is in port 2.2. It had been fine: reseat BottomLeft\'s plug first',
        'NOT READY': 'fix the FAILs, then run it again. Don\'t reboot the Jetson for this',
      },
    };
    const pre = $('#pit-hc');
    const fmtLine = (s) => {
      let h = esc(s).replace(/^  PASS /, '  <span class="p">PASS</span> ').replace(/^  WARN /, '  <span class="w">WARN</span> ').replace(/^  FAIL /, '  <span class="f">FAIL</span> ');
      if (/^== /.test(s)) h = `<span class="h">${h}</span>`;
      if (/^READY/.test(s)) h = `<span class="r">${h}</span>`;
      if (/^NOT READY/.test(s)) h = `<span class="rb">${h}</span>`;
      return h;
    };
    // the long FAIL line is broken up, so it (and its note) doesn't run miles to the right
    const wrapLong = (s) => {
      if (s.length < 120) return [s];
      const ind = s.match(/^ */)[0], out = []; let line = ind;
      for (const w of s.trim().split(' ')) { if ((line + ' ' + w).length > 100 && line.trim()) { out.push(line); line = '        ' + w; } else line = line.trim() ? line + ' ' + w : ind + w; }
      out.push(line); return out;
    };
    Site.seg($('#pit-hc-seg'), (v) => {
      const notes = { ...NOTES[v] };
      const lines = REPORTS[v].map((s) => {
        let h = wrapLong(s).map(fmtLine).join('\n');
        const k = Object.keys(notes).find((n) => s.includes(n));
        if (k) { h += `\n<span class="a">        ◂ ${esc(notes[k])}</span>`; delete notes[k]; }
        return h;
      });
      pre.innerHTML = `<span class="c">${esc(CMD)}</span>\n` + lines.join('\n');
    });
  }

  /* ── 971 stats line ───────────────────────────────────── */
  {
    const PARTS = [
      ['971 stats', 'Printed once a second for every AprilTag camera by our GPU detector, the 971 library (Austin Schuh and FRC 971\'s CUDA AprilTag detector).'],
      ['h1', 'Which detector. Each AprilTag camera gets its own: h0, h1, h2, h3. The number is not the camera\'s name, so count the lines: four cameras, four handles.'],
      ['1280x800:', 'The image size the detector gets. A Thriftiest Cam should be 1280x800.'],
      ['121.9 calls/s,', 'Frames per second reaching the detector. About 120 is healthy. The health check warns under 30: usually exposure too long.'],
      ['detect avg 1.21 ms max 2.03 ms,', 'How long the GPU took to find tags: the average and the worst frame in the last second. About 1 ms with nothing in view, a bit more with tags.'],
      ['jni 0.004 ms,', 'The cost of the hop from Java (PhotonVision) into the detector\'s C++. Tiny: ignore it.'],
      ['tags/frame 2,', 'How many tags it found per frame, on average. 0 means the camera sees none.'],
      ['margin avg 48.3 min 17.2', 'Decision margin: how confidently the tags were read, on average and the worst one. Only printed when tags are seen. A min close to our cutoff of 15 means tags about to flicker.'],
      ['[bos]', 'Which detector build is running: bos, Austin\'s current version. If there were GPU errors, an "errors N" part would appear just before this.'],
    ];
    const box = $('#pit-971'), out = $('#pit-971-out');
    box.innerHTML = PARTS.map(([t], i) => `<button type="button" data-i="${i}" aria-pressed="false">${esc(t)}</button>`).join('');
    const pick = (i) => {
      box.querySelectorAll('button').forEach((b, j) => { b.classList.toggle('on', j === i); b.setAttribute('aria-pressed', j === i); });
      out.innerHTML = `<p><b>${esc(PARTS[i][0].replace(/[,:]$/, ''))}</b>: ${esc(PARTS[i][1])}</p>`;
    };
    box.addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) pick(+b.dataset.i); });
    pick(3);
  }

  /* ── Copy buttons on the commands ─────────────────────── */
  const copyText = (text) => {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    // the Jetson serves this page over plain http, where the clipboard API isn't available
    return new Promise((ok, fail) => {
      const ta = document.createElement('textarea'); ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy') ? ok() : fail(); } catch (e) { fail(e); }
      ta.remove();
    });
  };
  root.querySelectorAll('#pit-cmds .line').forEach((line) => {
    const code = line.querySelector('code');
    const b = document.createElement('button'); b.type = 'button'; b.className = 'copy'; b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy: ' + code.textContent);
    b.onclick = () => copyText(code.textContent).then(() => { b.textContent = 'Copied'; b.classList.add('done'); setTimeout(() => { b.textContent = 'Copy'; b.classList.remove('done'); }, 1500); }, () => { b.textContent = 'Select it'; });
    line.appendChild(b);
  });

  /* ── Pit checklist (remembered in this browser for the day, when storage works) ── */
  {
    const list = $('#pit-check'), btns = [...list.querySelectorAll('button')], n = $('#pit-check-n'), KEY = 'vt-pit-check';
    const today = new Date().toDateString();
    let saved = [];
    try { const s = JSON.parse(localStorage.getItem(KEY) || 'null'); if (s && s.day === today) saved = s.on || []; } catch (e) {}
    btns.forEach((b, i) => b.setAttribute('aria-pressed', saved.includes(i) ? 'true' : 'false'));
    const count = () => {
      const vis = btns.filter((b) => b.offsetParent !== null || b.getClientRects().length);
      const done = vis.filter((b) => b.getAttribute('aria-pressed') === 'true').length;
      n.innerHTML = done === vis.length ? '<b>All checked. Good luck out there.</b>' : `<b>${done}</b> of ${vis.length} checked`;
      try { localStorage.setItem(KEY, JSON.stringify({ day: today, on: btns.map((b, i) => (b.getAttribute('aria-pressed') === 'true' ? i : -1)).filter((i) => i >= 0) })); } catch (e) {}
    };
    list.addEventListener('click', (e) => { const b = e.target.closest('button'); if (!b) return; b.setAttribute('aria-pressed', b.getAttribute('aria-pressed') === 'true' ? 'false' : 'true'); count(); });
    $('#pit-check-clear').onclick = () => { btns.forEach((b) => b.setAttribute('aria-pressed', 'false')); count(); };
    addEventListener('site:mode', count);
    count();
  }
});
