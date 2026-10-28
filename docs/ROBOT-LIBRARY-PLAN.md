# Robot-side library plan: one package for the Jetson, the EKF and everything around them

*Drafted 2026-10-27, from the TXMAN1 logs ([TXMAN1-JETSON-REVIEW.md](TXMAN1-JETSON-REVIEW.md)) and the vision code in `2026-FM-SystemCore` as of `377b4a1` (2026-10-23).*

Several teams are buying Orin Nanos to build what we built. The Jetson side is scripted in this repo. The robot side is not. Today it lives in two places that grew apart:

- **`robot-vision/` (SpectrumVision)** in this repo. It's clean, tested, and builds for 2026 and 2027. But no robot has run it in a match.
- **FM's robot code** (`2026-FM-SystemCore`). It's what ran at TXMAN1 and what we fixed afterwards. About 6,000 lines of it are generic, mixed in with FM-only code.

This plan merges the two into one library another team can add in an afternoon. A team that adds it should get:
- every custom thing the Jetson publishes (health, telemetry, mount estimate, Rewind control, clock, field map, excluded tags), with alerts;
- a pose pipeline whose defaults survived real matches;
- the EKF, logged next to their estimator so they can see whether it's better before they trust it;
- pre-match checks;
- logs that replay.

## What exists, and where

| Piece | SpectrumVision (`robot-vision/`) | FM robot code | In the library |
|---|---|---|---|
| PhotonLib camera IO | `PhotonCameraIO`: per-tag quality topic | `PhotonOrinIO`: raw result bytes for replay, decode-throw guard, disabled-rate limit | Merge. FM's replayable bytes plus SpectrumVision's quality matching. |
| Solvers | multi-tag, `TAG_TRIG`, gyro-resolved single tag | `OrinSolver`; `OrinGyroSourceIO` (constrained solvePnP "GYRO_PNP", 6328-style TxTy) | Merge. Constrained PnP becomes a `PoseSolver`. |
| Gates | `Gates`/`GateSet`, immutable, named, counted | `VisionGates`, `Gate.rejectIf`, `GateContext` | Keep SpectrumVision's API and add FM's gates: future timestamp, tilt, auto-start, z range. |
| Trust | `TrustModel` (d²/n, edge, reprojection, margin, motion) | `StdDevModel` tiers (Limelight), `ORIN_MODEL` | Keep `TrustModel`; tiers become a second model. |
| Ordering | sorts each loop's measurements | `OrderedVisionUpdates`: re-applies newer measurements when an older one arrives | Use FM's. It fixes what sorting can't: a late camera. |
| Fusion | `PoseSink` (WPILib, CTRE, all) | `PoseFusion`: fused + odometry + one shadow track per source | Port `PoseFusion` behind the `PoseSink` interface. |
| EKF | none | `TagEkf`: 971-style, per-tag bearing/range, χ² gate, replay to capture time | Port it, logged-only by default. Fix the heading loss first (review, R6). |
| Odometry screening | none | `OdometryGuard` (CAN-drop zeros, gyro fallback) | Port. A CANivore drop moved Q34's pose 45 m. |
| Jetson topics | health fps/problem, excluded tags | `JetsonNTIO`, `Jetson` (telemetry, alerts, Rewind, clock, field map, practice profile, mount-bumped) | Port FM's whole and publish it as a written contract (below). |
| Health and alerts | `VisionHealth` | `Jetson` alerts, `PreMatch` checks | One `VisionHealth` that knows every Jetson topic, plus a pre-match check API. |
| Field map | layout passed in | `TagField`, `FieldMapHash`, `FieldMapJson` (hash identical to the Jetson's) | Port. A mismatched map FAILs pre-match. |
| Other sources | none | Limelight (MT1/MT2 + raw fiducials), QuestNav (hand-rolled protobuf), SystemCore cameras | Optional modules. Many teams run a Limelight next to the Jetson. |
| Checks | none | `CameraHeadingCheck`, `ImuMountCheck` | Port. |
| Sim and test | `VisionScenario`, `SyntheticCamera`, `VisionSim` | `SimVision`; replay regression in CI | Keep both. Add a log-replay harness (below). |
| AdvantageKit | logger interface, no AKit dependency | AKit IO/inputs everywhere; derived sources re-solve in replay | Core stays AKit-free. An `-akit` module adds the IO layer. |

## What the logs say the library must do

From [TXMAN1-JETSON-REVIEW.md](TXMAN1-JETSON-REVIEW.md). Each requirement points at a finding there:

1. **Treat a dead camera as dead.**
   - Results with a capture time near zero, or minutes old, never reach a solver. At TXMAN1 the robot read about 50 such results a second from every dead camera.
   - The camera's state is visible: alive, stale, or dead.
   - When the Jetson reports fps 0 for a camera, an alert fires that names the camera.
   - (F1, F2)
2. **Ride through network drops.**
   - All wired clients dropped together 1-4 times a match, for 1.5-6 s each.
   - The library must not alert-storm.
   - It must keep the Rewind request latched.
   - It must recover without a robot restart.
   - It logs the drop, so the team chases the network, not the Jetson.
   - (F3)
3. **Gates sized for 120 fps cameras.**
   - Most rejected Orin frames failed the yaw-rate gate, which was set for Limelights.
   - Defaults per camera kind, and per-camera limits.
   - (F6)
4. **Use the Jetson's own mount estimate.** The right camera's estimated pitch was about 3° from its configured mount, and Roll/Pitch rejections followed. The library compares the configured mount with the measured one at every boot and says what to change. (F7)
5. **An EKF that can't lose itself.** In r16 the EKF stopped tracking (p90 6.7 m from the fused pose, 47,722 innovation rejections) after the gyro drifted. Before it is ever allowed to drive the robot it needs heading correction from multi-tag frames and a reset path that doesn't depend on its own gate. (F8)
6. **Logs that explain themselves.** Every Jetson topic logged under one prefix, with an AdvantageScope layout and a robotlog summary card: per-camera fps, the stall time, NT drops, Rewind sessions.

## Shape of the library

One repo, several artifacts, so a team pulls only what it runs:

```
spectrum-vision-core       observations, gates, trust, solvers (incl. constrained PnP, TxTy), ordering,
                           field map + hash, PoseSink, ClockBridge. WPILib only.
spectrum-vision-photon     PhotonLib camera IO, the Jetson client (every custom topic), VisionHealth, alerts.
spectrum-localization      PoseFusion (fused + shadows), TagEkf, OdometryGuard, pre-match checks.
spectrum-vision-akit       AdvantageKit IO/inputs for all of the above; replay re-solves derived sources.
spectrum-vision-limelight  optional: Limelight MT1/MT2 + raw fiducials as a source and EKF input.
spectrum-vision-questnav   optional: QuestNav without QuestNavLib (works on 2027).
```

The robot-facing API stays the SpectrumVision builder, extended:

```java
var jetson = Jetson.connect();                       // telemetry, clock, Rewind, field map, alerts
vision = VisionSystem.builder(field)
    .camera(jetson.camera("orin-left", ROBOT_TO_LEFT))
    .camera(jetson.camera("orin-right", ROBOT_TO_RIGHT))
    .source(Limelight.mt2("limelight-back", ...))    // optional
    .sink(PoseFusion.wpilib(estimator).withEkf(TagEkf.loggedOnly(drivetrainGeometry)))
    .currentEstimate(estimator::getEstimatedPosition)
    .build();
jetson.rewind().recordDuringFmsMatches();            // one line, default on
PreMatch.add(vision.checks()); PreMatch.add(jetson.checks());
```

Rules for the code:
- **No team constants inside the library.** FM's `VisionConfig` (mounts, seeding constants, the "LL-Back MT2 only while aiming" policy) stays in FM's code. The library offers each as an option with a neutral default.
- **Seeding and fusion policy are pluggable.** FM's disabled seeding with multi-tag confirmation, the gross-heading net, and the LL-Back heading fix are good defaults. They're `FusionPolicy` implementations a team can swap out, not code inside `Vision.periodic()`.
- **Everything that rejects a frame says why**, in a counter with a stable name. FM already does this, and it made this review possible.

## The Jetson ↔ robot contract

Today the topic list lives in three places: FM's README, `JetsonNTIO`, and our patches. A team with a different robot can't know what's there. Write it down as `docs/NT-CONTRACT.md` in this repo:
- every topic, its type, its rate, and who publishes it;
- what it means when the topic is absent.

Then:
- Add `/photonvision/jetson/contractVersion`. The robot library alerts when the Jetson is older or newer than it understands.
- **Test both sides against the same file.** A JSON listing of topics and types:
  - `JetsonNTIOTest` on the robot side and a fork test on the Jetson side both load it;
  - adding a topic on one side without the other fails CI.
- **Topics the review says are missing** (details in the review):

| Topic | Why |
|---|---|
| `<cam>/health/heartbeat`, `<cam>/health/lastFrameAgeMs`, `<cam>/health/state` (`streaming`, `stalled`, `recovering`, `disconnected`, `gave-up`) | Today a dead camera's health repeats the same values, NT4 drops the repeats, and the robot log shows nothing. A heartbeat always changes. |
| `<cam>/health/lastError` (string, rate-limited) | The reason for the last recovery attempt, in the robot log. |
| `jetson/usbEvents` (count) and `jetson/lastUsbEvent` (string) | A disconnect or reset seen by the kernel, so a USB drop is visible in the match log. |
| `jetson/uptimeSeconds` and `jetson/bootId` | Tell a reboot from a reconnect. Uptime is in stock metrics, but FM only started reading it on 10-19. |
| `jetson/ntReconnects` | The Jetson's view of the drops, to compare with the robot's. |
| `rewind/sessionFiles` | Which files hold this match, for log upload. |

## Logs other teams can use

- **One upload.** Team logs reach robotlog.spectrum3847.org as the wpilog plus the Limelight `.rwnd` files. The Jetson's Rewind and its own logs never made it. Add `scripts/jetson/export-match.sh <label>` on the Jetson. It writes one zip with Rewind, the PhotonVision log, `journalctl -k` and health snapshots for that match's time window. Teach the uploader to file it under the match.
- **AdvantageScope layout** shipped with the library: field with every source's accepted and rejected poses, per-camera fps/latency, Jetson temperature and power.
- **Replay harness.** `tools/replay_compare.py` and the Q24 replay check in FM's CI become a library tool. Point it at a wpilog, change a gate, see the accepted/rejected diff. Ship the TXMAN1 logs (r4, r16, Q34) as fixtures.

## Distribution

- **Vendordep JSON plus a Maven repo on GitHub Pages**, one version line per WPILib year:
  - `2026.x` for roboRIO;
  - `2027.0.0-alpha-6.x` for SystemCore.

  The source-copy installer stays as a fallback.
- **Compatibility matrix** in the README: Jetson release ↔ library version ↔ PhotonLib ↔ WPILib, with the alpha-7 warnings from [MAINTENANCE-2027.md](MAINTENANCE-2027.md).
- **Examples:** the existing WPILib, CTRE and AdvantageKit examples. Add one "Jetson + Limelight + EKF" project that is FM's setup with FM removed.

## Phases

| Phase | What | Done when |
|---|---|---|
| 0. Jetson fixes | The review's must-fix items, R1-R4 and R7 (no blank results, health that can't freeze, watchdog ladder, root cause, match export) | A bench test kills a camera's USB mid-stream at 120 fps: the robot sees `stalled` within 0.5 s, then either a recovery or `gave-up`, and no zero-timestamp results |
| 1. Contract | `NT-CONTRACT.md`, contract JSON, contract tests on both sides, `contractVersion` | Both CIs fail on a mismatch |
| 2. Port | FM's generic code into the modules above, behind SpectrumVision's API. FM then depends on the library. | FM's CI (scripted sims, Q24 replay) passes on the library |
| 3. EKF hardening | Heading correction, reset path, divergence detector. Replay r16 and Q34. | r16 replay: EKF within 0.3 m of the fused pose at p90. Still logged-only. |
| 4. Package | Vendordep, Maven, examples, AdvantageScope layout, replay tool | A new team project builds and simulates with only the vendordep and README |
| 5. Beta | Two or three other teams, each with an Orin | Their first event's logs uploaded and reviewed |

Phase 0 is in this repo and doesn't wait on the rest. Phases 1-2 are about a week of focused work each. FM's code is tested, so it's mostly moving it, not rewriting it.

## Open decisions

- **Library name and repo.** Keep it in `robot-vision/` here (one place for the Jetson and its robot side), or split it into its own repo once it's a vendordep? Recommendation: stay here until Phase 4, then decide.
- **Is the EKF ever the default?** Only after Phase 3, and only if replays show it beats the fused pose on our logs and on another team's.
- **Limelight and Quest modules:** do we support them or only accept contributions? They're FM-tested, but we don't own the hardware's future.
- **2027 PhotonVision.** When the Jetson moves to a 2027 PhotonVision ([MAINTENANCE-2027.md](MAINTENANCE-2027.md)), the message format changes, and the library's PhotonLib dependency moves with it.
