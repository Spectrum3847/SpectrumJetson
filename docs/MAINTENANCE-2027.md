# Keeping this working: October 2026, then the 2027 season

From the code audit of 2026-10-01. Five reviews covered:
- the per-frame vision path;
- the server and dashboard;
- the native detector;
- install, system and tests;
- 2027 compatibility and the robot side.

Each finding was checked against the code before anything was changed. What was fixed is in [AUDIT-2026-10.md](AUDIT-2026-10.md). This page is the plan: what to freeze for October, what blocks 2027, and how to keep our changes portable.

## October 2026: freeze it

The event build works because three things are identical between our 2026 PhotonVision and the robot's WPILib 2027 alpha-6 + PhotonLib v2027.0.0-alpha-2:
- the PhotonPipelineResult message format (hash `4b2ff16a964b5e2bf04be0c1454d91c4`),
- the NetworkTables protocol (`v4.1.networktables.first.wpi.edu`),
- the time-sync packets.

Rules until the event is over:

- **Robot code stays on GradleRIO `2027.0.0-alpha-6` and PhotonLib `v2027.0.0-alpha-2`.**
  - **PhotonLib after alpha-7 (upstream `a6167b04`, #2566, 2026-09-17):** it renamed the metadata timestamps to nanoseconds, which changes the hash. PhotonLib then refuses our results (`verifyVersion` throws).
  - **WPILib alpha-7 even with PhotonLib alpha-2:** don't. allwpilib `c65465b00` (#9335) made `nt::Now()` and cscore timestamps nanoseconds, while the time-sync packet keeps its layout and version byte. The clock offset would then be wrong, with no error. This is inferred from the source, not tested.
- **The Jetson runs a release we've tested**, identified by its bundle's sha256, and takes nothing from PhotonVision main after `a9ad078b`.
- **Robot code logs the message hash at startup** (`PhotonPipelineResult.photonStruct.getInterfaceUUID()`) and raises an alert if it isn't `4b2ff16a…`. PhotonLib also prints an error banner on a mismatch, but a log line is easier to find after a match.
- **The robot's control word:** WPILib 2027 publishes it as the `/FMSInfo/ControlWord` struct, not the `/FMSInfo/FMSControlData` integer that 2026 robots publish. `photonvision-62` reads both. Without it, idle mode kept every camera at ~30 fps for the whole match (AUDIT, C1). Test it on the SystemCore before the event: Match Ready shows the robot state, and health-check reports fps while the robot is enabled. Without a SystemCore, `tests/systemcore-rehearsal/run.sh` (run on the laptop) runs the real WPILib 2027 alpha-6 robot runtime, and the Jetson connects to it. On 2026-10-01 PhotonVision decoded its control word correctly in every phase (disabled, teleop, auto, FMS attached), idled while disabled, and named the match recording from 2027's match data. PhotonLib 2027 alpha-2 decoded every result.
- **Camera names:** the robot code (`Vision.java`, as of `189cb33`) still asks for `orin-front`, `orin-left` and `orin-right`. The Jetson's cameras are `TopLeft`, `TopRight` and so on, so as written those cameras never connect (issue #10, item 1).

## What blocks PhotonVision 2027 on this Jetson

**The operating system, not the compiler.**
- **The libraries:** PhotonVision main builds its ARM native libraries with native-utils 2027.14.2, whose toolchain is `arm64-trixie` (Debian 13: GCC 14, glibc 2.41). JetPack 6 is Ubuntu 22.04, with `GLIBCXX_3.4.30` and glibc 2.35.
- **Why that's likely fatal:** the x86 WPILib alpha-6 libraries on our laptop already need `GLIBCXX_3.4.31`, which is why Glass and simulation fail on 22.04. Libraries built on trixie very likely won't load on the Jetson.
- **To confirm before planning anything:** `objdump -T` on the `.so` files inside a main linuxarm64 jar, checking which `GLIBC_` and `GLIBCXX_` versions they need.
- **Java isn't a problem:** JDK 25 is available on 22.04, and PhotonVision's installer already puts `openjdk-25-jre-headless` there.

If they don't fit 22.04, two ways forward:
1. **JetPack 7 (Ubuntu 24.04, CUDA 13).** The cleaner long-term answer. The bos detector, TensorRT, the NVJPG decoder and the camera driver patch all need rebuilding and re-testing on it.
2. **PhotonVision 2027 in a trixie container on JetPack 6**, with the GPU passed through. It keeps the proven CUDA 12.6 stack. There's more to set up, and USB camera hot-plug inside a container needs care.

Bundling a newer `libstdc++` alone doesn't fix a glibc requirement.

## Make our native code independent of WPILib (do this first, either way)

`libspectrum-gpu-apriltag.so` links WPILib 2026.2.1's `libwpiutil` (`wpi::Now()`, `jni_util`) and uses WPILib's `libapriltag`, OpenCV's `cv::Mat*` and the Java class path `edu.wpi.first.apriltag.AprilTagDetection`. Inside a 2027 JVM, the 2027 libraries with the same names load instead, and the symbols won't match. Plan:
- **Plain JNI:** no `wpi::java` helpers, and our own copy of the `WPI_RawFrame` struct, whose layout is unchanged in 2027.
- **Plain buffers:** a pointer and a stride instead of a `cv::Mat*`, and flat arrays back to Java instead of `AprilTagDetection` objects. The class moves to `org.wpilib…` in 2027; `GpuDetectorJNI.cc:72` hard-codes the old name.
- **Self-contained:** link the AprilTag C library statically, with hidden symbols.
- **Explicit units:** Java passes the timestamp unit in, microseconds now and nanoseconds in 2027.

Then GCC 11 and CUDA 12.6 on the Jetson are enough for the native side for as long as JetPack 6 lasts.

## Our patches against PhotonVision main

`upstream_watch.py` only tries our patches on the dormant 4143 fork. The audit applied all 62 (00-61) to the fork, then test-merged that into PhotonVision main `4651dbae`:
- **The merge:** 4143's own changes alone gave 5 conflicts. Our whole stack gave **63 conflicts in 27 files**. The worst were `VisionModule` (10), `VisionRunner` (6), `CameraCalibrationCard` (6), `USBFrameProvider` (5) and `UICalibrationData` (4).
- **Compiling:** a clean merge still isn't a build. 27 patches use Jackson, which 2027 replaces with Avaje Jsonb (#2503, #2512), or the old `edu.wpi.first` package names (2027 uses `org.wpilib`).
- **Silently wrong in 2027:** nine patches assume microseconds, would compile, and would then be off by 1000×. They are 07 (44 lines), 13 (12), 08, 09 and 18 (7 each), and 02, 24, 29 and 56.

| Group | Patches |
|---|---|
| Upstream mostly did it (keep a small remainder) | 00; 11 (#2484/#2499); 12 (#2511, 2 leaks remain); 21 (#2478); 23 (#2437/#2479/#2480); 42 (#2617); 01 and 04 fold into the CUDA rework |
| Small fixes upstream still lacks (offerable, with Allen's OK) | 03, 36 (yaw sign comment), 33, 37, 38, 39, 41, 43, 44, 47, 48 |
| Self-contained features (portable after the renames) | 05-08, 10, 14, 16, 17, 19, 20, 22, 24-26, 29-32, 34, 35, 40, 45, 46, 49-57, 59-63 |
| Invasive edits in upstream's busiest files | the frame path 02/09/13/18/27 (13 patches edit `USBFrameProvider`); 21 patches edit `VisionModule`, 20 edit `RequestHandler`, 13 edit `Server`; 28/39/10 edit the Input tab |

## How to port, after the event

1. **Port onto PhotonVision main, not the 4143 fork**, which hasn't changed since 2026-01-30.
   - Make CUDA a detector option inside the normal `AprilTagPipeline`, not a separate pipeline type.
   - That removes a pipeline type, a settings type and a UI tab, and picks up upstream's pipeline fixes for free.
   - It also removes the duplicated `AprilTagCudaPipeline` (about 250 lines copied from `AprilTagPipeline`; patches 22, 61 and 62 had to edit both copies).
2. **Shrink the footprint in upstream files first**, on a branch:
   - one `SpectrumRoutes.register(app)` call in `Server.java` instead of 14 patches adding routes, with the handlers in a `SpectrumRequestHandler`;
   - one listener hook in `VisionModule`;
   - a Jetson subclass of `USBFrameProvider`, with the USB-port, reset and reconnect code moved out of the 707-line file;
   - one `SpectrumTime` helper with explicit units;
   - one small JSON adapter, so the Jackson-to-Avaje change touches one file;
   - one `SpectrumPaths` class: today the settings, Rewind and robot-state paths are repeated in Java and in `10-data-partition.sh`.
3. **Frontend:**
   - move the Input-tab additions and the ~256 lines added to `CameraAndPipelineSelectCard` into child components;
   - add one shared polling helper (with an in-flight guard, a timeout and stop-on-unmount);
   - main needs Node 24 and runs `vue-tsc`.
4. **Build the jar off the Jetson** in upstream's CI container (`wpilib/aarch64-cross-debian:trixie`). The laptop has no Docker, so this means GitHub Actions or installing Podman.
5. **Extend `upstream_watch.py`** with a weekly trial merge into PhotonVision main, reporting the conflict count, so the size of the port is visible all season.
6. **Start the 2027 settings fresh** from the team camera defaults (`photonvision-06`) plus re-imported calibrations, rather than migrating the database. #2503 dropped some old migrations.
7. **Upstreaming** (needs Allen's OK, and student-written changes): PhotonVision's policy since `eceecc89` (2026-09-30) allows AI tools but closes anything that reads as model-written, and their `AGENTS.md` tells agents never to open issues or PRs. If per-tag quality should go into the message format, the window is before 2027 stable: the format only changes between seasons.

## The robot side

**Built (2026-10-01): [SpectrumVision](../robot-vision/README.md)**, in `robot-vision/`. It's a library that wraps PhotonLib, not a replacement, with builds for WPILib 2026 (roboRIO) and 2027 alpha-6 (SystemCore) from one source. What's below is the reasoning behind it.

**Recommendation: a library that wraps PhotonLib, not a replacement.**

**Why not replace PhotonLib:**
- It would have to follow every message-format change.
- It would have to run the time-sync server (UDP 5810), and would clash with PhotonLib if both were present.
- It would lose PhotonLib's simulation (`VisionSystemSim`), which the robot code's `SimVision` uses.
- Upstream says the raw NetworkTables API isn't supported for robot code (#2488).

**What a wrapper adds that PhotonLib lacks**, all on top of stock PhotonVision:
- **Per-tag quality.** Edge distance, undistortion shift and both reprojection errors can be computed on the robot from the corners and calibration PhotonLib already gives. Only the decision margin needs our `/photonvision/<camera>/tagQuality` topic (`photonvision-61`), matched by `sequenceID`.
- **Single-tag disambiguation with the gyro.** Keep a tag only when best < 0.4 × alternate, then pick the candidate closest to the gyro heading.
- **Trust models** (standard deviations) and gates: ambiguity, outside the field, spin rate, height, stale.
- **Multi-camera ordering by capture time.** WPILib's pose estimator discards an older measurement that arrives after a newer one; the robot code's `OrderedVisionUpdates` already works around this.
- **CTRE swerve `addVisionMeasurement`** with the timebase conversion unit-tested.
- **Compact AdvantageKit records**, one per observation, instead of raw results (README, bandwidth).
- **Alerts** from `/photonvision/jetson/*`: throttling, temperature, fps, decode failures, quiet mode.
- **Handling robot-code contracts:**
  - call `setEnabled(true)` at init, because a camera disabled before a robot-code restart stays disabled;
  - filter tags listed in `/photonvision/excludedTagsActive`, which are still sent as single-tag targets;
  - know that the event profile overrides a pipeline set before the field connects.

Sketch (WPILib 2027 style):

```java
VisionSystem vision = VisionSystem.builder(Field.loadDefault())
    .camera(PhotonCameraIO.of("TopLeft"),  robotToTopLeft)
    .camera(PhotonCameraIO.of("TopRight"), robotToTopRight)
    .heading(HeadingSource.of(drivetrain::getYaw, drivetrain::getYawRate)) // timestamped buffer
    .solver(Solver.multiTagThen(Solver.singleTagGyroDisambiguated(0.4)))
    .gates(Gates.aprilTagDefaults())
    .trust(StdDevModel.tagQuality())          // falls back to distance² over tag count
    .sink(PoseSink.ctre(drivetrain))
    .build();

vision.periodic(); // robotPeriodic: read all cameras, order by capture time, gate, add

record TagObs(int id, double yawRad, double pitchRad, double distM,
              double margin, double edgePx, double reprojBestPx, double reprojAltPx) {}
record FrameObs(String camera, long seq, double tSec, boolean multiTag,
                Pose3d fieldToCamBest, Pose3d fieldToCamAlt, TagObs[] tags) {}
```

**Most of it exists already.** The robot repo's `frc.spectrumLib.localization` (about 1.5k lines) already has gating, std-dev models, per-source tracks, an EKF and AdvantageKit logging. The work is:
1. Lift that out and give it a better `PhotonIO`.
2. Move the pose solve out of the IO layer, so replay can re-run it.
3. Add tests: simulation tests and recorded-log tests, built twice, against alpha-2 (`AprilTagFieldLayout`) and 2027 (`Field`).
4. Publish it as a vendordep with an example project before January kickoff.

Rough size: 4-6 student-weeks (an estimate, not measured).
