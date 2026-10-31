# SpectrumVision: robot-side AprilTag pose estimation on top of PhotonLib

Good pose estimates from PhotonVision cameras, into your drivetrain's pose estimator, with little code:

```java
vision = VisionSystem.builder(AprilTagFieldLayout.loadField(AprilTagFields.kDefaultField))
    .camera("TopLeft", robotToTopLeft)
    .camera("TopRight", robotToTopRight)
    .sink(PoseSink.wpilib(poseEstimator))
    .currentEstimate(poseEstimator::getEstimatedPosition)
    .build();

// robotPeriodic(), after odometry:
vision.addMotion(Timer.getTimestamp(), gyroYaw, yawRateRadPerSec, speedMetersPerSec);
vision.periodic();
```

Each loop it reads every camera, solves each frame into a robot pose, rejects the bad ones with gates you can see and tune, gives the rest a standard deviation, and sends them to the estimator oldest first. It also raises dashboard alerts when something's wrong.

**Builds:**
- **WPILib 2026** (roboRIO, PhotonLib v2026.3.x, Java 17);
- **WPILib 2027 alpha-6** (SystemCore, PhotonLib v2027.0.0-alpha-2, Java 25).

**Compatibility:**
- Works with **stock PhotonVision**.
- With [SpectrumJetson](../README.md)'s PhotonVision it also uses the Jetson's per-tag quality, health topics and excluded tags.
- It wraps PhotonLib rather than replacing it, so PhotonLib's simulation, version checks and time sync all still work.

Contents: [Install](#install) · [Quick start](#quick-start) · [What to run, and why](#what-to-run-and-why) · [Solvers](#solvers) · [Gates](#gates) · [Trust (standard deviations)](#trust-standard-deviations) · [Testing and tuning](#testing-and-tuning) · [Logging and replay](#logging-and-replay) · [Alerts](#alerts) · [Robot-code checklist](#robot-code-checklist) · [Simulation](#simulation) · [Building this library](#building-this-library)

## Install

Copy the source into your robot project. It has no dependencies beyond WPILib and PhotonLib:

```bash
robot-vision/install.sh ~/path/to/your-robot-project 2026
```

or `2027` for a SystemCore project on WPILib 2027 alpha-6.

- **What it copies:** `src/main/java/org/spectrum3847/vision/` into the project. Your own code isn't touched.
- **Updating:** run it again.
- **What you need first:** the PhotonLib vendordep for the same year (VS Code: *WPILib: Manage Vendor Libraries*).
- **Without Bash:** the release zips (`SpectrumVision-wpilib2026-src.zip`, `SpectrumVision-wpilib2027-src.zip`) hold the same files.

**Which year?** It must match your robot project's WPILib and PhotonLib, and PhotonLib must match your coprocessor's PhotonVision.
- **2026 roboRIO:** WPILib 2026 with PhotonLib v2026.3.x.
- **2027 SystemCore:** WPILib **alpha-6** with PhotonLib **v2027.0.0-alpha-2**.
  - **PhotonLib:** don't move past alpha-2 while your coprocessor runs a 2026-based PhotonVision. PhotonLib after alpha-7 changed its message format, and then refuses the results.
  - **WPILib:** don't move past alpha-6. Alpha-7 changes time units in time sync without any error.
  - Details: [docs/MAINTENANCE-2027.md](../docs/MAINTENANCE-2027.md).

## Quick start

### WPILib swerve (`SwerveDrivePoseEstimator`)

See [examples/WpilibSwerveVision.java](examples/WpilibSwerveVision.java):

```java
vision = VisionSystem.builder(field)
    .camera("Front", robotToFront)
    .camera("Back", robotToBack)
    .sink(PoseSink.wpilib(estimator))
    .currentEstimate(estimator::getEstimatedPosition)
    .build();

// robotPeriodic(), after estimator.update(...):
vision.addMotion(Timer.getTimestamp(), gyro.getRotation2d(), yawRateRadPerSec, speedMetersPerSec);
vision.periodic();
```

### CTRE Phoenix 6 swerve (TunerX `CommandSwerveDrivetrain`)

See [examples/CtreSwerveVision.java](examples/CtreSwerveVision.java) (2026) or [examples/wpilib2027/CtreSwerveVision.java](examples/wpilib2027/CtreSwerveVision.java) (2027). Both compile against the real Phoenix 6 (26.3.0, and 26.50.0-alpha-1) in this library's build.

Phoenix keeps its own clock, so timestamps are converted both ways with a `ClockBridge`. Phoenix 2026 has `Utils.fpgaToCurrentTime`, but Phoenix 2027 dropped it, and the bridge works on both:

```java
var phoenix = new ClockBridge(Utils::getCurrentTimeSeconds);
vision = VisionSystem.builder(field)
    .camera("TopLeft", ROBOT_TO_TOP_LEFT)
    .sink(PoseSink.convertingTime(drivetrain::addVisionMeasurement, phoenix::toOther))
    .currentEstimate(() -> drivetrain.getState().Pose)
    .build();
// The gyro history at Phoenix's odometry rate, on its thread (the history is thread-safe):
drivetrain.registerTelemetry(state -> vision.addMotion(
    phoenix.fromOther(state.Timestamp), state.Pose.getRotation(),
    state.Speeds.omegaRadiansPerSecond, Math.hypot(state.Speeds.vxMetersPerSecond, state.Speeds.vyMetersPerSecond)));
```

- **Phoenix 2027:** the swerve state has `Velocity` (`vx`, `vy`, `omega`) instead of `Speeds`.
- **`registerTelemetry` has one slot:** if you already use it, call `vision.addMotion` from your existing callback.

### Two estimators side by side

`PoseSink.all(PoseSink.wpilib(estimator), ekf)` sends every accepted measurement to both: WPILib's estimator and an EKF, say, to compare which gives the better result.

## What to run, and why

1. **Every camera, every frame.** At 120 fps a robot gets 2–3 frames per camera per 20 ms loop. PhotonLib's `getAllUnreadResults()` returns them all, and `VisionSystem` uses them all.
2. **Each frame at its capture time.** WPILib's and CTRE's estimators replay odometry from the frame's timestamp. Never pass "now".
3. **Oldest first, across cameras.** WPILib's estimator discards a measurement older than one it already applied. `VisionSystem` sorts each loop's measurements before sending them.
4. **The gyro history, every loop.** Single-tag solves use it (the next section), as do the spin-rate and heading gates and the trust model's motion factor. Without it, single tags are used only when unambiguous, and those gates pass.
5. **The estimator's current pose** (`currentEstimate`), for the innovation gate.
6. **Measured camera mounts.** One degree of camera yaw is 7 cm at 4 m. SpectrumJetson's field calibration measures mounts. `vision.camera("TopLeft").setRobotToCamera(...)` changes one at runtime, for a turret or a measured correction.
7. **The same field layout** as the coprocessor. PhotonVision's multi-tag solve uses its own copy. `insideField`, `headingAgreesWithGyro` and `innovation` will flag a mismatch, but match them anyway.
8. **Loop order:** odometry update, then `vision.addMotion(...)`, then `vision.periodic()`, then use the estimate. `periodic()` takes ~40 µs a loop on a laptop for 4 cameras at 3 frames each (`TimingTest`). A roboRIO is perhaps 10–20× slower, still under a millisecond, but check your own loop time.

## Solvers

`Solvers.standard()` (the default):

| Frame | Pose | Type |
|---|---|---|
| PhotonVision's multi-tag result (2+ tags) | that solve, every corner of every tag in one fit | `MULTI_TAG` |
| One tag, gyro history covers the frame | the tag's **position** plus the gyro heading | `TAG_TRIG` |
| One tag, no gyro, ambiguity < 0.2 | the tag's best solution | `SINGLE_TAG` |
| One tag, ambiguous, gyro available (`preferTrig(false)`) | of the two solutions, the one closest to the gyro (within 15°) | `SINGLE_TAG_GYRO` |

**Why `TAG_TRIG` for single tags.** A single tag's two pose solutions (the "ambiguity") differ in how the tag is tilted, and that moves the solved robot position by a lot. Both solutions agree on where the tag is, though. Combining that position with the gyro heading gives a translation that ambiguity can't corrupt, and it's the most accurate single-tag translation at range. It's the same idea as PhotonLib's `PNP_DISTANCE_TRIG_SOLVE`. Its heading is the gyro's, so the trust model gives it no heading weight.

Change it with `Solvers.multiTagThen(Solvers.singleTag(new Solvers.SingleTagConfig().preferTrig(false)))`, or write your own `PoseSolver`.

### Multi-camera solve (optional, not the default yet)

`Solvers.multiCamera(config)` (`MultiCameraSolver`) solves **one robot pose from every corner of every tag of every camera**. It's for PhotonVision with its 3D mode off, where the coprocessor sends only 2D results and corners and the robot does the geometry. It returns `MULTI_CAMERA` candidates.

What it does:
- **Unknowns:** the robot's x, y and heading at one reference time, the newest frame's. The robot is taken as flat, so each camera's height and tilt come from its mount. That's why one tag on one camera still solves.
- **Gyro:** an optional heading prior, σ 1.5° by default.
- **Cameras at different times:** each frame is moved to the reference time with the odometry history, `Δ = odom(tRef)⁻¹ ∘ odom(tFrame)`. Odometry drift doesn't matter, only its changes do. Without odometry it uses the gyro's heading change, and without either the frames are taken as simultaneous.
- **Corners:** undistorted with each camera's OpenCV calibration (`getCameraMatrix()`, `getDistCoeffs()`), in OpenCV's pixel convention, which is what the 2027 fork sends. Set `cornerShiftPx` if a source differs.
- **Corner σ per tag:** set from the tag's size in pixels, its distance, how near it is to the image edge, and its decision margin. You can swap this out with `weighting(...)`.
- **The fit:** Levenberg–Marquardt with a Cauchy robust loss (or Huber), seeded from every tag on its own. A tag that still doesn't fit is dropped and flagged.
- **Out:** the pose, a 3×3 covariance for the EKF or a trust model, and every tag's residual for gates.

```java
var solver = Solvers.multiCamera(new MultiCameraSolver.Config());
var frames = new ArrayList<MultiCameraSolver.CameraFrame>();
for (var cam : vision.cameras()) {
    // the camera's newest frame; intrinsics from PhotonCamera.getCameraMatrix()/getDistCoeffs()
    frames.add(new MultiCameraSolver.CameraFrame(frame, intrinsics, cam.robotToCamera()));
}
solver.solve(frames, field, vision.motion(), MultiCameraSolver.PoseHistory.of(odometryBuffer), estimator.getEstimatedPosition())
      .ifPresent(r -> estimator.addVisionMeasurement(r.pose(), r.timestampSeconds(), VecBuilder.fill(r.stdDevs()[0], r.stdDevs()[1], r.stdDevs()[2])));
```

**Simulation results** (`MultiCameraSolverTest`): synthetic corners on the real 2026 field, 4 cameras, perfect mounts and calibration. The per-camera `MULTI_TAG` and `TAG_TRIG` columns are worked out from the same noisy corners. Translation error, median/p90:

| Corner noise | multi-camera | per-camera `MULTI_TAG` (mean of cameras) | `TAG_TRIG` (mean of tags) | multi-camera, 1 camera |
|---|---|---|---|---|
| 0.5 px | 0.1 / 0.6 cm | 1.6 / 19 cm | 1.7 / 4.9 cm | 0.8 / 11 cm |
| 1 px | 0.2 / 0.7 cm | 4.5 / 33 cm | 3.7 / 10 cm | 2.1 / 17 cm |
| 2 px | 0.4 / 1.6 cm | 7.5 / 52 cm | 7.8 / 18 cm | 2.8 / 47 cm |

Other results from the same test:
- **Heading error:** 0.03° against 1.3° for the per-camera solve at 1 px.
- **One tag, one camera, 0.5 px:** 1.9 / 4.1 cm with the gyro prior, and 5 / 50 cm without it.
- **One tag 12 px off:** 0.2 / 3.4 cm, where least squares gives 1.6 / 4.8 cm.
- **Covariance consistency:** mean NEES 2.6, against an ideal 3.
- **Speed:** about 170 µs a solve on the laptop for 4 cameras and 10 tags.

On a real robot, the mount and calibration errors will dominate these numbers.

## Gates

A gate rejects a pose candidate before it reaches the estimator, for a reason that's logged and counted. `Gates.recommended()`, in order:

| Gate | Default | Why |
|---|---|---|
| `uniqueFrames` | | The same frame never counts twice. |
| `timeSynced` | 0.5 s | PhotonVision's clock synced to the robot's recently (`timeSinceLastPong`). Right after a reconnect, timestamps can be seconds off. PhotonLib runs the time-sync server; it starts when robot code creates a `PhotonCamera`. |
| `maxAge` / `notFromFuture` | 0.5 s / 0.05 s | Stale frames, or a broken time sync. |
| `excludedTags` | yours + the Jetson's list | Tags known to be wrong (moved, damaged, mis-mapped). PhotonVision leaves them out of multi-tag but still reports them as single tags. |
| `insideField` | 0.5 m margin | A pose off the field is a bad solve. |
| `maxHeight` / `maxTilt` | 0.3 m / 20° | Robots stay on the floor. The 20° leaves room for a field's bumps and ramps; lower it on a flat field. |
| `maxAmbiguity` | 0.3 | Single-tag best solutions only (trig and gyro-resolved solves don't depend on it). |
| `maxDistance` | 4.5 m one tag, 7 m multi | Error grows with distance squared. Far single tags mostly add noise. |
| `maxReprojection` | 3 px | The solve doesn't fit its own corners: motion blur, a partly hidden tag, a bad calibration. |
| `maxYawRate` | 3.5 rad/s | Spinning blurs frames, and a timestamp error costs the most then. Raise it if your cameras' exposure is short (SpectrumJetson's 5 ms default is). |
| `headingAgreesWithGyro` | 15° | A full-pose solve that disagrees with the gyro is wrong: a flipped single tag, a wrong mount, or a wrong tag map. |
| `innovation` | 1 m / 30° from the estimate | No sudden jumps, unless 3 frames in a row agree with each other within 1 s (then the estimate is what's wrong: a bump, a collision, wheel slip). While disabled, everything passes, so a robot placed on the field re-localizes at once. |

Also available: `onlyTags`, `minEdgeDistance`, `minDecisionMargin` (SpectrumJetson), `maxSpeed`, and `Gate.of(name, predicate, reason)` for your own.

**Changing them** is one line each, and `GateSet` is immutable, so nothing else changes:

```java
.gates(Gates.recommended()
    .replace(Gates.maxYawRate(5.0))          // this robot's cameras handle spinning
    .replace(Gates.maxDistance(3.5, 7.0))     // tighter single-tag range
    .without("maxTilt")                       // ...or drop one
    .with(Gates.onlyTags(() -> Set.of(1, 2, 3))))
```

**Tune gates from evidence**, not by guessing:
1. Run a practice match or a replay.
2. Read `vision.stats().summary()`, also on NetworkTables at `/SpectrumVision/summary`:

   ```
   TopLeft: 812 frames, 790 candidates, 701 accepted; rejected maxDistance 60, maxYawRate 29
   ```
3. Look at `rejectedPoses` against `acceptedPoses` on AdvantageScope's field view.
4. Change one limit and run again.
5. Write the case down as a test (next section).

## Trust (standard deviations)

`TrustModel.recommended()`:

```
xy    = max(0.02 m,   0.02 · d² / n) · factors
theta = max(1.5°,     0.06 · d² / n) · factors     (multi-tag only; single-tag and trig: ignored)
```

Here `d` is the mean tag distance in metres and `n` the tag count. The `factors` multiply together:
- **Edge:** up to ×3 for a tag at the image edge, fading out by 60 px. Distortion is strongest there and the calibration weakest.
- **Reprojection:** ×(1 + error / 1.5 px).
- **Decision margin:** ×(40 / margin) below 40 (SpectrumJetson only).
- **Single-tag ambiguity:** ×(1 + 4·ambiguity).
- **Motion:** ×(1 + 0.15·speed + 0.4·|turn rate|).
- **Per camera:** `vision.camera(name).setTrustFactor(2)` trusts a wobbly or poorly calibrated camera half as much.

Every number is a public field: `var t = TrustModel.recommended(); t.xyPerMeterSquared = 0.03;` then `.trust(t)`.

**Tuning.** Too trusting makes the pose jitter with vision noise; too cautious makes it drift on odometry between corrections. The quick test:
1. Park the robot where it sees tags.
2. Log the estimate for 30 s.
3. If its standard deviation is far below the vision noise (accepted poses jumping about while the estimate sits still), you're too cautious. If the estimate jumps with each measurement, you're too trusting.
4. Then repeat while driving.

## Testing and tuning

`VisionScenario` runs the whole `VisionSystem` against a synthetic robot and synthetic cameras, in plain Java: no robot, no PhotonVision, no OpenCV. Use it to check a gate or trust change before a match. [examples/VisionTuningTest.java](examples/VisionTuningTest.java) is a complete test to copy into your project's `src/test/java`. It runs in this library's own test suite, so it's known to work.

```java
var cam = SyntheticCamera.typical("Front", 1);    // 1280x800, ~70°, a mild lens
cam.pixelNoise = 0.4;                              // corner noise, px
var s = new VisionScenario(field)
    .camera(cam, ROBOT_TO_CAMERA)
    .configure(b -> b.gates(Gates.recommended().replace(Gates.maxYawRate(5.0))));
s.run(0, 2, 0.02, t -> facingTag(tag, 2.5, -1 + t), /*yawRate*/ 0, /*speed*/ 1.0);
assertTrue(s.worstErrorMeters() < 0.10);
System.out.println(s.stats().summary());
```

**What the synthetic camera can do:**
- `ambiguity` and `flipSolutions` make single-tag ambiguity;
- `poseNoise` adds pose noise;
- `multiTag = false` turns multi-tag off.

`FakeCameraIO` feeds frames by hand for edge cases.

## Logging and replay

- **Default:** `NetworkTablesVisionLogger` publishes a compact summary under `/SpectrumVision/`:
  - `acceptedPoses` and `rejectedPoses` (`Pose2d[]`);
  - `acceptedStdDevs`;
  - `tagPoses`;
  - `lastRejection`;
  - per-camera counts;
  - `summary`.

  These are latest-value topics, so dashboards don't pull every frame over the radio.
- **AdvantageKit:** see [examples/AdvantageKitVision.java](examples/AdvantageKitVision.java). Log each camera's inputs as one `double[]` (`CameraIO.Inputs.framesAsArray()`, the compact record). In replay, the log feeds the same solvers, gates and trust, so you can change a gate and replay the match.
- **Don't log raw PhotonLib results.** They're about 10× bigger (0.3–0.9 MB/s at 5 cameras × 120 fps). AdvantageKit's NetworkTables publisher sends whatever you log to every connected dashboard, and roughly half of each tag's bytes are empty or duplicated. With AdvantageScope on the field, use Live Mode "Low Bandwidth".

## Alerts

`VisionHealth` (on by default) raises WPILib `Alert`s, which Elastic and AdvantageScope show:

| Alert | When | Needs |
|---|---|---|
| Camera X disconnected | PhotonLib says so, 10 s after start | any PhotonVision |
| Message format mismatch | the coprocessor's `rawBytes` type string isn't this PhotonLib's | any PhotonVision |
| Time sync stale | frames' `timeSinceLastPong` > 1 s | any PhotonVision |
| Vision rejecting every pose (top reason) | candidates arrive, none accepted for 3 s, while enabled | any PhotonVision |
| Camera X: N fps | below 20 fps while enabled | SpectrumJetson |
| Camera X: problem | the camera reports one: stuck, wrong mode, USB | SpectrumJetson |
| Camera X won't recover by itself: power-cycle the robot | its `health/state` is `gave-up` and it reports no problem | SpectrumJetson with `photonvision-81` |
| Jetson 5 V input dipped to N V | `inputVoltageLowestV` below `minJetsonInputV` (4.75 V: it's the module's 5 V input after the carrier's regulator, about 4.95 V; the 12 V supply isn't measured) | SpectrumJetson with `photonvision-82` |
| Jetson USB trouble (N): kernel line | `usbEvents` rose since robot code started | SpectrumJetson with `photonvision-82` |
| Jetson Ethernet link dropped N time(s) | `ethCarrierChanges` rose by 2 or more: its cable or the switch port | SpectrumJetson with `photonvision-82` |
| Jetson rebooted | `bootId` changed | SpectrumJetson with `photonvision-82` |
| Jetson clock not set from the robot | `clockSource` is `unset` after 10 s: publish `/photonvision/clock/unixMs` | SpectrumJetson with `photonvision-82` |
| Jetson SSD: ... | SSD media errors or critical warning, ext4 errors, or the settings partition read-only | SpectrumJetson with `photonvision-82` |
| Jetson RAM at N% | above `maxJetsonRamPct` (90) | SpectrumJetson with `photonvision-82` |

The photonvision-82 alerts stay up until robot code restarts, so the pit sees them after the match.
| Jetson throttling / hot | over-current, a temperature or clock cap, or ≥ 92 °C | SpectrumJetson |
| Jetson in quiet mode while enabled | it should leave quiet mode within 0.1 s of an enable | SpectrumJetson |

Thresholds are public fields on the `VisionHealth` object.

A camera mount that's wrong in robot code also raises an alert: see [Mount check](#mount-check).

## Mount check

A camera knocked, re-aimed, or measured wrong moves every pose from that camera, while each tag
detection still looks fine, so no gate catches it. At TXMAN1, team 8515's code had the left camera
at yaw 90° when it was at 84–87°, and the right camera was re-aimed between days (pitch −19° to
−25°); nothing noticed. `MountCheck` (on by default in `VisionSystem`) does.

**How it works.** For each frame (at most 25 a second per camera), it solves the camera's own field
pose from vision alone: a 6-DoF PnP on the tag corners with the camera's calibration (PhotonLib's
camera matrix, read automatically), or PhotonVision's own solve without it. Frames whose solve is
too uncertain (far or bunched-up tags, a lone tag that fits two ways) are left out. The camera's
pose implies a mount, compared with the one in code:

- **Height, roll and pitch** need no reference: the robot is flat on the floor, so they are the
  camera's own field height and tilt. Every usable frame checks them.
- **x, y and yaw** need the robot's pose from something other than that camera:
  - other cameras seeing tags at the same time (moved to one time with the estimator's motion).
    The largest group of cameras that agree with each other is the reference, so **one bad camera
    among three or more is the odd one out**;
  - two cameras that disagree: one of them is wrong. It's the one whose poses disagree more with
    the pose estimator, and whose height, roll or pitch are off;
  - otherwise the pose estimator, but only for a camera that gave less than 60% of its recent
    measurements (otherwise the estimator's pose is mostly that camera's own).

Samples are taken only with the robot slow (< 1 m/s, < 0.75 rad/s). The estimate is the median of
each camera's last 400 samples. A dimension is **SUSPECT** when it's more than **2° / 4 cm** off
(plus two standard errors of the median) after 40 samples, **BAD** at twice that. Settings are
public fields on `vision.mountCheck().config`.

**Pre-match check.** Disabled, robot still, every camera seeing tags for a few seconds (2 s at
25 Hz fills 40 samples):

```java
for (var r : vision.health().mountCheck()) {        // or vision.mountCheck().reports()
    System.out.println(r.camera() + " " + r.status() + ": " + r.message());
    // r.estimated().code(): the measured mount as Java, to paste into robot code
}
```

| Where | What |
|---|---|
| Alert (Elastic, AdvantageScope) | "Camera X mount wrong: yaw −5.2 deg (cameras:a+b); measured ..." (warning when SUSPECT, error when BAD). Stays up until `mountCheck().reset()`, so the pit sees it after a match. |
| `/SpectrumVision/mountCheck/summary` | "left OK, right BAD (yaw −5.2 deg)" (the Jetson's Match Ready view can show it) |
| `/SpectrumVision/mountCheck/<camera>/` | `status` (NO_DATA/OK/SUSPECT/BAD), `message`, `estimated` and `error` (x, y, z m, roll, pitch, yaw deg), `estimatedMount` (Pose3d, robot-relative: AdvantageScope draws it), `code`, `samples`, `reference`, `disagreement` (m, deg from the other cameras) |

After fixing a mount (or changing it with `camera.setRobotToCamera`, which restarts that camera's
samples on its own), call `vision.mountCheck().reset()`. A turret camera's mount moves:
`vision.mountCheck().ignore("Turret")`. Off: `.mountCheck(false)` on the builder.

**What it showed on TXMAN1** (`MountCheckTxman1Test`, 8515's detections replayed with the robot's
logged pose; the mounts their code had): orin-left BAD in all 6 matches (yaw 82–87° measured vs
90°, roll +1–2°; on Friday also height 0.48 m vs the placeholder's 0.25 m), orin-right BAD in 5
(pitch −24° in Q32 against −18° in code: the re-aim; Q27 had too few usable frames). That agrees
with the mounts tests/field-replay solved offline.

**Limits.**
- One camera alone: only height, roll and pitch, unless the estimator has another source (more
  cameras, or a camera that rarely feeds it). Its x/y/yaw then report NaN, reference "none".
- Two cameras that each see tags only on their own side (8515's): x/y/yaw against the estimator,
  which those same cameras fed, so errors read smaller than they are.
- A tilted robot (on a ramp, a bump, a lifted wheel) looks like a pitch or roll error; the check
  samples only when slow, but it can't tell a tilted floor.
- Cost: about 25–80 µs a frame on a laptop (one PnP, rate-limited to 25 Hz a camera); several
  times that on a roboRIO.

## Robot-code checklist

What robot code must get right, whichever library it uses:

- [ ] **Camera names exactly as PhotonVision shows them.** A wrong name never connects; the "disconnected" alert says which.
- [ ] **Matching versions:** PhotonLib = the coprocessor's PhotonVision (the "message format" alert checks). For October 2026 SystemCore: WPILib alpha-6 + PhotonLib alpha-2.
- [ ] **Cameras enabled at start.** `PhotonCameraIO` asks PhotonVision to enable each camera when robot code starts. A camera robot code disabled stays disabled across a robot-code restart otherwise.
- [ ] **Excluded tags filtered:** the `excludedTags` gate reads the Jetson's list.
- [ ] **Time sync:** PhotonLib's time-sync server runs in robot code (it starts with the first `PhotonCamera`). The `timeSynced` gate drops frames from before it synced.
- [ ] **The event profile:** with SpectrumJetson's "switch to the event pipeline when the FMS connects" on, a pipeline chosen before the field connected is replaced. If robot code picks pipelines, set them again after `DriverStation.isFMSAttached()`.
- [ ] **Timestamps in robot time**, and converted for CTRE (Quick start).
- [ ] **Measured mounts:** see What to run.
- [ ] **Bandwidth on the field:** don't subscribe dashboards to `/photonvision/*/rawBytes`. Don't turn on PhotonVision's "Publish protobuf".

## Simulation

```java
// robotInit, in simulation:
visionSim = VisionSim.attach(vision, VisionSim.thriftiestCam());
// simulationPeriodic, with the simulated drivetrain's TRUE pose (not the estimate):
visionSim.update(truePose);
```

This is PhotonLib's own simulation (`VisionSystemSim`), so it needs WPILib's desktop simulation, which includes OpenCV. The same `VisionSystem` code runs in simulation as on the robot.

**Tested:** `SimulationTest` runs exactly this, on both versions (`./gradlew :wpilib2026:simTest :wpilib2027:simTest`, run by `build.sh`). The chain is PhotonLib's simulated camera, a real `PhotonCamera`, `PhotonCameraIO`, `VisionSystem`, and a `SwerveDrivePoseEstimator`.
- **Placed wrong, disabled:** an estimate that started 1.12 m wrong ends within 1 mm.
- **Driving while enabled:** with odometry wrong by 10%, the estimate stays within 8 cm of the truth.
- **Tag quality:** computed on the robot from the simulated calibration.

### Simulating on Ubuntu 22.04

Windows, macOS and Ubuntu 24.04 need nothing here. On Ubuntu 22.04 the desktop libraries won't load out of the box, because 22.04's glibc (2.35) and C++ runtime are older than the ones they were built for:
- **PhotonLib (2026 and 2027)** needs a newer C++ runtime (`GLIBCXX_3.4.32`). Simulation fails at the first `PhotonCamera` with "photontargetingJNI could not be loaded".
- **WPILib 2027, CTRE Phoenix 6 2027 and the sim GUI** need the same, plus glibc 2.38. They use only five functions that are new in 2.38: `fmod`, `fmodf`, and the C23 versions of `strtol`, `sscanf` and `fscanf`. glibc 2.35 has all five under their older names.

One-time fix, no sudo, nothing system-wide:

```bash
robot-vision/tools/ubuntu2204-sim/setup.sh
```

After this, `./gradlew simulateJava`, VS Code's **WPILib: Simulate Robot Code**, and robot tests that load the HAL all work in every robot project on the machine. The robot project doesn't change.
- **How:** the setup installs a Gradle init script into `~/.gradle/init.d`. Each time GradleRIO unpacks the desktop libraries into `build/jni/release`, the script copies in a newer libstdc++ built for 22.04 (from the Ubuntu Toolchain PPA, SHA256-checked). It also runs `glibc238_compat.py` on the libraries, which points those five functions at glibc 2.35's equivalents.
- **Turning it off:** `setup.sh --remove` takes it out, and `-PnoUbuntu2204Sim` turns it off for one build. On a system with glibc 2.38 (Ubuntu 24.04 or newer) it does nothing.
- **What doesn't change:** robot (SystemCore and roboRIO) libraries are never touched.
- **When a library can't be fixed:** if a library needs a glibc 2.38 function that 22.04 doesn't have, the patcher leaves it alone and says so.
- **What the patch changes:** each library still has the same size and layout. Only the names and versions of those five function references change, and the now-unused GLIBC_2.38 requirement is removed.
- **Tested on this laptop with 2026-FM-SystemCore (WPILib 2027 alpha-6):** the full robot program, including Phoenix 6 sim, PhotonLib, AdvantageKit and the sim GUI.

**WPILib 2027's desktop tools** (Glass, SysId, OutlineViewer, DataLogTool, wpical) have the same problem, and the same fix:

```bash
robot-vision/tools/ubuntu2204-sim/wpilib-tools.sh
```

- **What it does:** patches copies of the tools in `~/wpilib/2027/tools/ubuntu2204/`, keeps the originals untouched in `ubuntu2204/original/`, and replaces `tools/glass` and the others with short scripts that run the patched copies.
- **VS Code:** it also adds the names VS Code's **Start Tool** looks for (`Glass`, `SysId`, ...). The 2027 programs ship lowercase, so VS Code on Linux didn't list them before.
- **After a WPILib tools update:** run it again.
- **Undoing it:** `--restore` puts the originals back.

A laptop that also flashes the Jetson should stay on 22.04: NVIDIA's flashing and SSD backup tools for JetPack 6 support only Ubuntu 20.04 and 22.04 as the host.

## Building this library

```bash
robot-vision/build.sh
```

This tests both builds, compiles the examples, runs both simulation tests, and makes the drop-in zips. It needs JDK 17 and JDK 25, which the WPILib installers put in `~/wpilib/2026/jdk` and `~/wpilib/2027/jdk` (or set `JAVA17_HOME` / `JAVA25_HOME`). The 2027 build uses the local WPILib 2027 install's Maven repo (`~/wpilib/2027/maven`).

**Where dependencies come from:**
- **CTRE Phoenix 6:** from CTRE's Maven repository.
- **AdvantageKit:** from its GitHub releases' offline Maven repo, which `build.sh` downloads. That also works where a web filter blocks frcmaven.wpi.edu, where it's normally hosted. (Ours doesn't, as of 2026-10-30.)

**How one source serves two WPILibs:**
- **The source:** `src/main` is written against WPILib 2026.
- **Package renames:** WPILib 2027 renamed its packages (`edu.wpi.first.*` to `org.wpilib.*`). `tools/port2027.py` generates the 2027 copy by rewriting each import from a checked table, and stops on anything it doesn't know.
- **Real API differences:** these live in `src/compat2026` and `src/compat2027`:
  - `Alert` levels;
  - `PubSubOption.sendAll` versus `SEND_ALL`;
  - `PhotonCamera.setEnabled`, which PhotonLib 2026 lacks.
- **Rules for contributors:** write WPILib names only in import lines, never inline. Put anything version-specific in a compat class.

**Tests:** 35, run on both builds (Java 17 and 25), plus the 2026 simulation test. All the examples compile in both builds against the real CTRE and AdvantageKit libraries. The tests cover:
- solvers: exact on synthetic frames; ambiguity resolved by the gyro; the trig solve ignoring a flipped tag;
- the multi-camera solve: exact without noise, time alignment, noise sweeps against the per-camera solvers, an outlier tag, covariance consistency (NEES), its speed;
- every gate, plus the innovation reset;
- the trust model's shape;
- lens undistortion round trips;
- Jetson quality matching, and the codec round trip;
- measurement ordering across cameras;
- camera trust, disable and mount changes;
- the example tuning test on the real 2026 field;
- `periodic()`'s cost;
- `ClockBridge`.

**Against real PhotonVision:** `tests/robot-vision-live` runs the library's input path on the Jetson against real PhotonVision output (fake cameras, fake robot): every frame with tags got the Jetson's per-tag quality matched (419 of 419 on 2026-10-01).
