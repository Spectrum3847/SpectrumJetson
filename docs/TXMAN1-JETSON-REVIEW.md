# TXMAN1 (Oct 16-17, 2026): what the Jetson did on 8515's robot

**Method.** Read straight from the wpilogs on [robotlog.spectrum3847.org](https://robotlog.spectrum3847.org), team 8515, robot FM (`2026-FM-SystemCore`).
- **Which logs:** the 8 logs with Jetson data: Q34 (Saturday morning) and the seven FMS matches robotlog files as "Test r4"-"r20" (Saturday, about 12:15-5 PM: the playoff period). On Friday robot code didn't read the Orin cameras (FM `7b753bb`, `c27d772`), though the Jetson ran them.
- **FM's clock was wrong on Saturday.** From Saturday morning on, FM's robot clock ran **13 h 34 min behind**, so robotlog shows those matches as Friday 7 PM to Saturday 3 AM. Q34 and r19 are in Dye's logs too, at exactly that offset (Q34: Dye 9:54 AM Saturday, FM "8:19 PM Friday"). Q30 and Q32 are probably Saturday too. The times in this review are corrected. A SystemCore without its clock set seems to resume from the time it last saved. The Jetson takes its clock from the robot, so its logs carry the same error. FM's README already asks whether the SystemCore gets its clock from the DS; this suggests it doesn't, at least not reliably.
- **What the robot logged:** every NetworkTables topic the Jetson publishes (FM's `JetsonNTIO`/`PhotonOrinIO` record them), its own pose sources, and the EKF.
- **What's missing:** nothing from the Jetson itself. No PhotonVision log, no kernel log, no Rewind files were uploaded (see F5).

Parsing scripts: a small WPILog reader, nothing robot-specific. The numbers below are from the logs. Where a cause is inferred rather than seen, it says so.

## Summary

The Jetson's AprilTag path worked when it was running:
- 120 fps per camera while enabled;
- 15-17 ms capture-to-robot latency;
- 2-3 ms GPU pipeline time, 6-10 ms worst frame;
- 18-28% GPU load, 9-10 W;
- 62-70 °C;
- no throttling during a match;
- no JPEG fallbacks, no Rewind dropped frames.

Time sync was good: robot-side latency matched the Jetson's own number.

It fails in two ways:
- **Cameras die mid-match and stay dead** (F1). That happened in 7 of 8 runs.
- **The robot can't tell** (F2). It keeps receiving results, with timestamps from boot.

Most NT drops weren't the Jetson's fault (F3). They're a robot network problem every coprocessor sees.

## Findings

### F1. A camera stops mid-match and never comes back until power-cycle (7 of 8 runs)

**It got much more frequent on Saturday.**

| Day | Matches with Jetson data | Camera deaths | From |
|---|---|---|---|
| Friday afternoon | Q13, Q17, Q19, Q24 | 1 (Q13) | The Jetson's own logs |
| Saturday | Q34, then r4-r20 | 7 of 8 (r19 survived) | Robot logs |

The cameras ran the same both days: 120 fps per camera while enabled (Q17's journal), with the same Jetson software. What changed between Friday's last match and Saturday is the first question for the pit crew:
- Was a camera remounted or a cable rerouted? FM's commits that day measured orin-left's mount from Q17 video and changed the Orin mounts (`1c8ffa1`, `3ab436b`).
- Was the robot rewired or repaired Friday night?
- Did robot code start reading the cameras? It did (`c27d772`), but that's NetworkTables traffic. The failure starts in USB, before PhotonVision, so it's an unlikely cause.

| Run | Enabled (auto / teleop start, s) | Camera death (s) | Which | Jetson `recoveries` after |
|---|---|---|---|---|
| Q34 | 517 / 540 | 549.9 (+10 s teleop) | right | 0 |
| r4 | 528 / 551 | 560.6 (+9 s) | **both, same instant** | right 1, 2 (+3 s, +8 s), then none; left 0 |
| r7 | 665 / 688 | 740.2, 786.2 | right, then left | 0 |
| r10 | 409 / 432 | 504.1 (+72 s) | **both** | right 1, 2, then none; left 0 |
| r13 | 583 / 606 | 616.8 (+11 s) | right | 0 |
| r16 | 495 / 518 | 547.4 (+30 s) | right | 0 |
| r19 | 200 / 223 | none | none | none |
| r20 | 325 / 348 | 332.4 (+7 s, **in auto**) | **both** | right 1, 2, then none; left 0 |

What the logs show at each death:
- **The Jetson notices, then looks quiet.** The camera's health fps falls (for example 96 → 35 → 0 over two samples), then its health topics stop changing in the robot log. The Jetson is still publishing 0 each second; NT4 drops the repeats (see [Root cause](#root-cause-in-our-code)). At the next NT reconnect `fps = 0` shows up again, minutes later.
- **The process is alive.** Jetson heartbeat, temperatures and power keep updating.
- **Power falls with it.** Power drops from ~10 W to ~7 W, the same as no cameras running: the GPU work stopped.
- **The watchdog gives up or never fires.** It tried twice on the right camera (r4, r10, r20), then stopped. On the left camera it never fired at all, including when both died together.
- **Only a reboot fixes it.** Each new robot log starts with the Jetson booting (a 14-17 s heartbeat gap) and both cameras streaming again. Nothing short of power-cycling brought one back.
- **The trigger, from the Jetson's own log (Q13, added 2026-10-27).** The USB hub disabled the camera's port for a signal error: `disabled by hub (EMI?)`. The camera then never answered the kernel again. See [Root cause](#root-cause-in-our-code).
  - **Not a plain brownout.** Battery voltage at death was 8.2-9.6 V, and each run dipped lower than that (6.9-7.5 V) without killing a camera.
  - **Not over-current.** `overCurrentEvents` stayed 0 and `throttle` read None.
  - **Both at once fits a shared cause.** Both cameras dying at the same instant (r4, r10, r20) fits one glitch on the hub they share.

Cost: in r4 the robot had Orin poses for 9 s of a 140 s teleop. In r20, for 7 s of auto and none of teleop.

### F2. A dead camera still sends ~50 results a second, timestamped at boot

After each death the robot's `getAllUnreadResults()` kept returning about one result per robot loop for the dead camera:
- `ResultsPerSecond` ~49;
- `LatencyMs` = now minus capture time = 534,740 ms at r4's death, growing 1 s per second.

Every one of those results is stamped about 26 s into the robot's boot, around when time sync first came up: a zero or fixed Jetson timestamp converted to robot time.

- **What contained it:** the robot's gates (stale estimate, future timestamp after FM `259020a`). No pose from them was fused.
- **What it still cost:** they polluted every latency and rate number in the log, and they hid the death from anything that counts results.
- **The robot did see it:** `PhotonCamera.isConnected()` went false, because the camera's heartbeat stops.

The same mechanism probably explains FM's Q19 note, "Orin frames up to 333 s ahead." The cause in our PhotonVision patches is in [Root cause](#root-cause-in-our-code).

### F3. Network drops hit every wired coprocessor at once (1-4 per match, 1.5-6 s)

PhotonVision's NT connection dropped 18 times across the 8 runs, all while enabled.
- **The Limelights dropped too.** In 15 of the 18, all three Limelights' NT clients dropped within 0.6 s of the Jetson's. In 17 of the 18, at least one did.
- **The dashboard didn't.** Elastic, over Wi-Fi to the same NT server, stayed connected.
- **Voltage is a suspect.** The battery was at 7.5-8.5 V in the 2.5 s before most of them.

So the robot's wired Ethernet segment loses link: the switch, its power feed, or the SystemCore's Ethernet port. A dropping NT server would have dropped Elastic too. That's a robot wiring/power issue, not a Jetson one. The Jetson reconnected in ~1.5 s every time (r10 491.8: 6 s).

What the drops cost on the Jetson side:
- **Rewind splits.** Rewind sometimes starts a new session when the connection returns. r4 has three sessions for one match: 0017, then 0018 after the drop at 536 s, then 0019 after the drop at 679 s.
- **Settings resend.** `settingsJson`, the JPEG decoder and the throttle string all blank, then re-publish.

### F4. Thermal and power: fine, one surface-temperature flag

- **Temperature:** Tj peaked at 70 °C while enabled. `throttle` read `HIGH TEMP (surface)` once, in r13 at 745 s: disabled, after the match, for 2 s.
- **Fan:** `fanRpm` read 0 or NaN throughout, so either the fan mode is "no fan" or the tach isn't read. FM alerts below 1000 rpm, so that alert was either firing or suppressed every match. Check which mode FM's Jetson is in (Settings > Robot state > Cooling).
- **Power:** 7-11 W.

### F5. We can't see inside the Jetson after a match

The match folder on robotlog holds:
- the robot wpilog;
- three Limelight `.rwnd` files per match (camera clocks still on 2025-10-13: the Limelights have no time source).

It has no Jetson Rewind, no PhotonVision log and no `dmesg`. FM's robot code only started reading `uptimeSeconds`, CPU and RAM on 10-19 (`47f2637`): the metrics topic is `/photonvision//metrics/<host>`, and FM read a fixed host. So for every finding above:
- we can't say whether the USB device disappeared;
- we can't say whether uvcvideo logged errors;
- we can't say what the watchdog tried.

**Update 2026-10-27:** the Jetson's journals (six boots), 16 PhotonVision logs and one Rewind session were uploaded by hand. They answered Q13 (Root cause), and showed three more gaps:
- **The Jetson's clock often never reached the robot's time.** Several boots logged with the same restored date, "2026-10-15 15:2x", including Q13. A log can be tied to a match only by the `Event: TXMAN1, Match: Q13` line PhotonVision logs on FMS connect. [inferred: the clock file `timesyncd` restores from can't be updated under `ro-root.sh on`.]
- **Idle boots stop logging after 60 s.** Quiet mode closes the PhotonVision log and moves the journal to RAM after 60 s disabled. That part is lost at power-off.
- **Most boots aren't there at all.** The journal kept only these six. None of the r4-r20 boots is among them, so their deaths are still unexplained.

R7 (`export-match.sh`) should save each boot's log under its match name, before the next boot can replace it.

### F6. Most rejected Orin frames are the yaw-rate gate, set for Limelights

FM's `MAX_YAW_RATE_RAD_PER_SEC = 1.6` applies to every source.

| Run | Orin-Left rejections | of which "Rotation Speed" |
|---|---|---|
| r4 | 700 | 513 |
| r16 | 4,104 | 2,963 |

The gyro and TxTy sources show the same pattern.

The Orin cameras run 5 ms exposures at 120 fps, so they can take much faster turns than a Limelight. SpectrumVision's default is 3.5 rad/s.

### F7. orin-right's measured mount is ~2-3° steeper than configured

The Jetson's own mount estimate (`<cam>/mount/*`, from multi-tag frames while still):

| Camera | Pitch (median, last) | Roll |
|---|---|---|
| orin-left | -18.2°, -18.9° | 0.9° |
| orin-right | -21.2°, -19.9° | -1.3° |

FM's config has -18° for both. "Roll/Pitch Rejection" is the next-largest Orin reject after yaw rate: right 671 in r16, 109 in r4. The left camera's pitch was measured from Q17 video (FM `1c8ffa1`); the right's wasn't.

### F8. The EKF loses itself after a gyro drift

FM's `TagEkf` (logged-only, added 10-17) agreed with the fused pose in most runs: median 0.21-0.24 m, heading 3-3.6°.

r16 is the run with ~10° of Pigeon drift (FM `34f0254`). There:
- error vs the fused pose was p90 6.7 m, max 19.5 m;
- heading error reached 83°;
- 47,722 tag sightings were rejected by its χ² gate;
- it relocalized 22 times.

Once the heading is off, every sighting fails the gate, and inflating P after 1 s doesn't bring it back. It needs a heading correction it can't reject: a multi-tag pose, or the fused heading after a gross-heading fix. It also needs a reset path. Q34 relocalized 66 times, worth a look too.

### F9. Things that worked and should stay

- **The control word:** idle mode switched to 120 fps at enable in every run (photonvision-62).
- **Time sync:** 15-17 ms latency on the robot side, same as the Jetson's own.
- **Rewind:** recorded every match on the FMS signal; 0 frames dropped; 165 GB free.
- **JPEG:** hardware decode (`nvjpg`), 0 differing checks.
- **Mount estimate:** stable (std < 0.5° pitch) and already useful (F7).

## Root cause in our code

This is from reading the patches. **[code]** means the patch does it. **[inferred]** means it comes from cscore/NT4 behaviour or a hardware hypothesis that the missing Jetson logs (F5) would confirm or rule out.

**The cameras: confirmed in one match, Q13.** The Jetson's logs reached robotlog on 2026-10-27. They cover six boots: four idle boots, one shop boot, and the Jetson's boot for Q13. In Q13 robot code wasn't reading the Orin cameras (FM `7b753bb`), but the Jetson ran them anyway. PhotonVision copies kernel messages into its log (`KernelLogLogger`), so the Q13 log has both sides. orin-left (USB port `1-2.1`), 14 s into teleop:

```
usb 1-2-port1: disabled by hub (EMI?), re-enabling...
usb 1-2.1: USB disconnect, device number 4
usb 1-2.1: new high-speed USB device number 6 using tegra-xusb
usb 1-2.1: device descriptor read/64, error -110        (x4)
usb 1-2-port1: attempt power cycle
usb 1-2.1: device descriptor read/8, error -110         (x4)
usb 1-2-port1: unable to enumerate USB device
```

- **What the camera did.**
  - **The trigger:** the Orin's own USB hub saw a signal error on that port and disabled it. That's the kernel's "EMI?": interference, static discharge, or a connector glitch on the camera's link. It wasn't over-current, and it wasn't the camera's stream stalling.
  - **Why it stayed dead:** it came back wedged. It never answered the kernel's requests again (error -110, a timeout), which is the same signature as our bench hub-reset test.
  - **Nothing could revive it:** the kernel's "power cycle" doesn't remove 5 V on this board, so nothing short of a real power cut helps.
- **What PhotonVision did.** At the same second, cscore logged `VIDIOC_DQBUF failed: No such device`. It then tried to reopen `/dev/v4l/by-path/...2.1` three times a second for the next two minutes. "Error grabbing image" repeated 246 times per 5 s: the ~50 a second of F2. The watchdog took no action, as found from the code. [code]
- **How often it shows up in the uploaded logs: once.** I searched all 16 PhotonVision logs and 6 journals for USB disconnects, enumeration failures, uvcvideo and xHCI errors, and "No such device". Four FMS matches are in them, tied to a match by PhotonVision's `Event: TXMAN1, Match: ...` line:
  - **Q13:** orin-left died, as above.
  - **Q17, Q19, Q24:** no USB errors. Both cameras streamed through the whole match: Rewind recorded 4,241-4,243 teleop frames per camera (2,497 in Q19's teleop session).

  The rest are the shop on Oct 14, two practice connects and idle boots, with no camera errors. The robot logs add Saturday's deaths in Q34 and r4-r20, whose Jetson logs weren't uploaded. So at TXMAN1 we can count 8 deaths in 12 runs: 1 of 4 on Friday, 7 of 8 on Saturday. One has a kernel log, and it shows this signature.
- **Why the other runs probably match.** The same pattern holds in the logged runs: a camera going away mid-match, both cameras sometimes at once, no over-current. Two cameras dying together fits one glitch hitting the hub they share. [inferred: the other boots' logs aren't in the upload]
- **Still to rule out: the controller.** No `HC died` or xHCI errors appear in what we have.

**F2's results with timestamps from boot.** When a grab fails, the vision loop sends `new CVPipelineResult(0, …, new Frame())`, a blank result with capture time 0, and doesn't sleep. [code] `photonvision-63-audit-fixes.patch` ~L623
- **Why ~50 a second:** with Low Latency Mode off, the grab is `grabRawSinkFrameTimeoutLastTime`, and its `lastTime` only advances on success (`photonvision-09`). After the first 0.25 s timeout, cscore's error frame keeps coming back immediately, and the sink sleeps 20 ms between bad frames. That's ~50 Hz. [inferred]
- **Why it lands near 26 s:** upstream publishes capture time + the time-sync offset. With capture time 0, every result lands on the robot at "the offset", about 26 s into the robot's boot. [inferred]
- **Why `isConnected()` goes false:** the sequence ID is 0 for every one of them.

**The watchdog stops trying.** [code] `photonvision-29` ~L145
- **What it does while connected with no frames:** reopen at 3 s, then a USB device reset at 8 s, then a reset every 30 s.
- **What it does once cscore reports the camera disconnected:** it only calls `notConnected()`, which resets its clock. Nothing more is tried.
- **What that means at TXMAN1:**
  - the right camera got its reopen and reset (`recoveries` 1, 2), never came back as connected, and the watchdog stopped there;
  - the left camera was seen disconnected at once, so it got nothing (`recoveries` 0).

**Health that seems to freeze.** The Jetson does keep publishing health for a dead camera: `fps 0`, `pipelineMs 0`, and `frames`/`recoveries` unchanged. [code] `photonvision-16`, `63`
- **Why the robot logs nothing:** none of those publishers set `keepDuplicates`. NT4 drops a value identical to the last one, so nothing changes in the robot log until a reconnect re-sends it. The tag-quality publisher (`photonvision-61`) does set it. [inferred: NT4 default]
- **`problem` clears itself.** "not answering…" stays set only while the matching kernel line is under 90 s old. Then it goes back to "" though the camera is still dead. [code] `photonvision-33` ~L61

**The evidence exists but isn't kept.**
- **Journal:** the persistent journal (scratch partition) holds `journalctl -k` and the PhotonVision and usb-watchdog logs. [code] `09-robot-tuning.sh`
- **Quiet mode loses part of it:** after a match quiet mode moves the journal to RAM, so that part is lost at the power cycle. [code] `spectrum-quiet.sh`
- **No per-match capture:** nothing gathers the logs per match.
- **usb-watchdog makes it worse:** if the xHCI controller ever dies, its rebind is a hub-level reset, which leaves Thriftiest Cams stuck. It may turn a short fault into a permanent one. [code: its own docstring]

## What to change

### On the Jetson (this repo)

R1-R3 are in `photonvision-75` (2026-10-27): unit-tested on the build host, not yet run on the Jetson. Details: [TECHNICAL.md](TECHNICAL.md), under `photonvision-29`.

| # | Change | Fixes | Priority |
|---|---|---|---|
| R1 | Don't publish `rawBytes` for a result with capture time 0 (the blank-result branches in `photonvision-63`), so a dead camera's `getAllUnreadResults()` comes back empty. Also, sleep in the empty-frame branch. | F2 | must |
| R2 | Health that can't freeze: a per-camera `heartbeat`, `state` (streaming / stalled / recovering / disconnected / gave-up) and `lastFrameAgeMs`, published from the 1 s timer, not from results; `keepDuplicates` on fps; `problem` stays set until the camera is back; bandwidth retries counted in `recoveries` | F1, F2 | must |
| R3 | Watchdog escalation (`photonvision-29`, `31`, `43`, `66`). While the camera is disconnected but its device is still in sysfs: reset the port or rebind uvcvideo. Once the device is gone: set state "gone from USB, needs a power cut". Keep retrying while connected with no frames, up to a cap, then report "gave-up". | F1 | must |
| R4 | Found in Q13: the hub disables the port for a signal error ("EMI?"), and the camera comes back wedged (Root cause). Next: reproduce it on the bench with motor wiring and static, and fix the wiring. If more boots' logs arrive, check the other deaths have the same signature. | F1 | must |
| R4b | Stop the trigger at the source: cables, strain relief, case grounding, ferrites, supply. Report the wedge to The Thrifty Bot. Reconsider usb-watchdog's controller rebind. See [Camera power, or other cameras](#camera-power-or-other-cameras). | F1 | must |
| R5 | Rewind holds a recording through an NT drop of up to 10 s instead of splitting it | F3 | should |
| R6 | Publish `bootId`/`uptimeSeconds`, `ntReconnects`, `usbEvents`/`lastUsbEvent` under `/photonvision/jetson/` | F1, F3, F5 | should |
| R7 | `export-match.sh`: one zip per match with `journalctl -k`/`-u photonvision`/`-u usb-watchdog` for the match window, `lsusb -t`, uvcvideo stats, Rewind CSV tails and health, uploadable to robotlog. Keep the journal on disk through quiet mode, or flush it before. Log the port's last kernel lines at INFO when a camera leaves "streaming". | F5 | must |
| R8 | Health-check and Match Ready: report the fan mode and tach, and say "no fan configured" plainly | F4 | nice |

### In FM's robot code (until the library replaces it)

| # | Change | Fixes |
|---|---|---|
| C1 | Drop results whose capture time is older than 0.5 s before `ResultsPerSecond`/`LatencyMs` see them. Alert on `isConnected()` false while enabled: the Jetson's `fps = 0` never reaches the log until a reconnect, so FM's 0-fps alert couldn't have fired. | F2 |
| C2 | Per-source yaw-rate limit: Orin ~3.5 rad/s, Limelight stays 1.6. Replay r16 to check. | F6 |
| C3 | orin-right pitch to about -20.5° and roll -1.3°, from the Jetson's estimate. Then replay r4 and r16 and compare Roll/Pitch rejections. | F7 |
| C4 | Find why the ethernet segment drops: switch power source, cable strain, SystemCore port. Log the radio/switch voltage if possible. | F3 |
| C5 | TagEkf: accept multi-tag pose updates for heading, detect divergence (rejection fraction over 1 s), reset to the fused pose | F8 |
| C6 | The robot clock: set it from the DS/FMS time each boot, and make a pre-match check fail when it's more than a minute off. FM ran 13 h 34 min behind all Saturday, so the Jetson, Rewind names and robotlog were all wrong. | F5 |

### Camera power, or other cameras

**Decision (2026-10-27): keep the Thriftiest Cams and stop what wedges them.**
- **No switching hubs:** they cost more than the cameras.
- **No bench Global Shutter (32e4:0144):** it's too limited, with poor connectors and no good case. That's why we bought Thriftiests.
- **Other OV9281 boards are no better:** the Arducam B0332 (also sold by AndyMark as am-5749) is a bare board with a cable. AndyMark lists it at 100 fps at 1280x800. Whether it recovers from a hub reset is unknown.

A wedged Thriftiest needs its 5 V cut. The Orin devkit's USB ports can't do that: their supplies are always-on ([TECHNICAL.md](TECHNICAL.md), USB hub reset test). So the plan, in order:

1. **Stop the glitch (R4).** Q13's log shows the hub disabling the port for a signal error ("EMI?"), not a camera or software fault. So the fixes are on the wiring:
   - **The cable path:** USB cables away from motor and motor-controller wiring, as short as they reach, ferrites at both ends.
   - **Shielded cables:** with the shield connected.
   - **Static:** camera cases grounded to the robot frame or fully isolated, never floating. Static from the carpet is a known FRC USB killer.
   - **Strain relief and latching connectors**, so a hit doesn't move the plug.

   On the bench, reproduce the glitch: two cameras at 120 fps, then wave a running motor's wiring past the cables, and touch a charged probe to the camera case. Watch for `disabled by hub (EMI?)` in `journalctl -k -f`. Then confirm each fix stops it.
2. **Report it to The Thrifty Bot**, with Q13's kernel log (above) and the repro: `tests/usb-hub-reset`, the kernel's `device descriptor read/64, error -110`, and only a power cut recovering. The camera's firmware should come back after a bus suspend or reset, and they may be able to fix it.
3. **Lose less when it happens anyway.** R1-R3 make a dead camera visible at once: on the robot, in Match Ready and in the log. The robot then leans on its other sources, and the pit knows to power-cycle.
4. **Not chosen: a purpose-built hub that really switches port power.** Spliced cables are out: they add connectors and noise paths, which is the kind of fault we're chasing. Candidates to bench-test, none tried yet:
   - **Yepkit YKUSH3:** per-port switching, with its own control tool, `ykush-control`.
   - **Realtek RTS5411-based hubs:** reported to switch port power with uhubctl.
   - **Acroname's industrial managed hubs:** software port enable and per-port current monitoring, through their BrainStem API.

   Each one has to pass three tests:
   - a meter on the port shows 5 V actually drops when switched off. Our Orin's own hub claims per-port switching and doesn't do it;
   - a wedged Thriftiest comes back, in `tests/usb-hub-reset`;
   - it survives vibration and a 7 V brownout with two cameras at 120 fps.

   Mounting and powering one more box on the robot is its own cost.
MIPI CSI cameras would remove USB entirely, but PhotonVision has no Jetson CSI path. That's a much bigger project.

### For the shared library

See [ROBOT-LIBRARY-PLAN.md](ROBOT-LIBRARY-PLAN.md).
