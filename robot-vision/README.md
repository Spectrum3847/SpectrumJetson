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
| Jetson throttling / hot | over-current, a temperature or clock cap, or ≥ 92 °C | SpectrumJetson |
| Jetson in quiet mode while enabled | it should leave quiet mode within 0.1 s of an enable | SpectrumJetson |

Thresholds are public fields on the `VisionHealth` object.

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

This tests both builds, compiles the examples, runs both simulation tests, and makes the drop-in zips. It needs JDK 17 and JDK 25, which the WPILib installers put in `~/wpilib/2026/jdk` and `~/wpilib/2027/jdk` (or set `JAVA17_HOME` / `JAVA25_HOME`). Both builds use the local WPILib installs' Maven repos (`~/wpilib/<year>/maven`), and the 2027 build needs its install.

**On Windows:** run `build.sh` from Git Bash. It finds the WPILib installs in `C:\Users\Public\wpilib` (the 2027 alphas install to folders like `2027_alpha5`), and the simulation tests use the Windows desktop libraries from those installs.

**Where dependencies come from:**
- **CTRE Phoenix 6:** from CTRE's Maven repository.
- **AdvantageKit:** from its GitHub releases' offline Maven repo, which `build.sh` downloads. Some school web filters block frcmaven.wpi.edu, where it's normally hosted (ours does).

**How one source serves two WPILibs:**
- **The source:** `src/main` is written against WPILib 2026.
- **Package renames:** WPILib 2027 renamed its packages (`edu.wpi.first.*` to `org.wpilib.*`). `tools/port2027.py` generates the 2027 copy by rewriting each import from a checked table, and stops on anything it doesn't know.
- **Real API differences:** these live in `src/compat2026` and `src/compat2027`:
  - `Alert` levels;
  - `PubSubOption.sendAll` versus `SEND_ALL`;
  - `PhotonCamera.setEnabled`, which PhotonLib 2026 lacks.
- **Rules for contributors:** write WPILib names only in import lines, never inline. Put anything version-specific in a compat class.

**Tests:** 27, run on both builds (Java 17 and 25), plus the 2026 simulation test. All the examples compile in both builds against the real CTRE and AdvantageKit libraries. The tests cover:
- solvers: exact on synthetic frames; ambiguity resolved by the gyro; the trig solve ignoring a flipped tag;
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
