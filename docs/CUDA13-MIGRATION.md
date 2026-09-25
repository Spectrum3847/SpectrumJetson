# WPILib 2027 alpha-7 migration contract

Status: **UNVERIFIED. Real Jetson and robot-network testing are required.**

This branch is a source-level port of the SpectrumJetson CUDA, Rewind, field-calibration, telemetry,
and camera-recovery features to PhotonVision source that targets WPILib `2027.0.0-alpha-7`.
It is not a tested deployment recipe. The tested JetPack 6 stack uses PhotonVision
`d8c9e8e1d3d4036f077a92f10f3a513ef4849765` and AllWPILib `v2026.2.1`.

Do not replace the tested stack with this branch until every applicable item below passes.
Do not carry JetPack 6 performance results into the alpha-7 report.

## Immutable source pins

- PhotonVision source: `1f419c9de3a6a0787571648d18211537a83fdca9`
- AllWPILib tag: `v2027.0.0-alpha-7`
- AllWPILib annotated tag object: `b3232873240d60fe9f3d8ed6587e2770392f206c`
- AllWPILib commit: `83df3ee3ce1e892f76970ec21c8efdc00a104d4a`
- CUDA detector source: `frc971/bos` commit `62e93b4e1ba81bb2cab5d6a0d34346b7051fe0d7`
- Legacy detector source: `FRC-Team-4143/GpuDetectorJNI` commit
  `ef9fc1ec7e43116849e71fef1ab335ba630274a7`

There is no stable PhotonVision alpha-7 release pin in this migration. The PhotonVision source
commit above is a development snapshot, so every built jar must record its exact commit and the
SpectrumJetson commit that packaged it.

## Source changes

The migration applies one reproducible patch,
`patches/photonvision-2027-alpha7-migration.patch`, to the pinned PhotonVision source. It carries
the current SpectrumJetson behavior onto alpha-7 instead of replaying the old 2026 patch series.
It covers the numbered series through `photonvision-34`, as of SpectrumJetson `dcbf1af`. A change
to a numbered patch on `main` must be ported into the migration patch too.

The port includes these compatibility changes:

- Java packages and vendordep types use the alpha-7 `org.wpilib` namespace.
- Raw camera timestamps and rewind timing use nanoseconds.
- AprilTag and CameraServer come from the matching alpha-7 vendordeps.
- Custom JSON persistence uses PhotonVision's Avaje dependency.
- The JNI bridge uses `WPI_RawFrame` and `WPI_PixelFormat` from alpha-7's C-compatible headers.
- The direct JNI method descriptor remains
  `(Ljava/lang/String;IIF[DDD[D)V`.
- C++ code avoids the C++23-only `wpi/util/jni_util.hpp` implementation in the current bridge.

These are source changes, not proof of runtime compatibility. In particular, the bridge currently
compiles its own translation unit as C++20 while AllWPILib alpha-7 requires C++23 and G++ 14.x.
The complete target must compile and link with one tested toolchain.

## Host checks

Run from a clean checkout of the candidate branch:

```sh
git diff --check origin/main...HEAD
bash -n scripts/host/03-build-photonvision-fork.sh
bash -n scripts/jetson/*.sh
bash -n tests/*/run.sh
scripts/host/03-build-photonvision-fork.sh
unzip -t out/photonvision-*-linuxarm64.jar
```

Record the exact PhotonVision source commit, AllWPILib tag object and commit, Node version, pnpm
version, Java version, Gradle version, and final jar SHA-256.

A successful x86 host jar build does not prove that the ARM64 jar, CUDA bridge, OpenCV runtime, or
robot protocol works.

## Target Jetson checks

Use a spare or recoverable Jetson image. Record:

```sh
cat /etc/nv_tegra_release
cat /etc/os-release
uname -a
gcc --version
g++ --version
/usr/local/cuda/bin/nvcc --version
/usr/lib/jvm/java-25-openjdk-arm64/bin/java -version
```

Alpha-7 requires C++23 and G++ 14.x. A build with an older compiler is a failed target build, not
a result to hide. Do not assume the documented JetPack 6 image supports this stack.

From a clean candidate checkout, run:

```sh
scripts/host/03-build-photonvision-fork.sh
scripts/jetson/04-build-allwpilib.sh
scripts/jetson/07-build-bos-detector.sh
```

Then install the matching jar and native libraries with the scripts in this repository. Verify:

```sh
ldd /usr/lib/lib971apriltag.so
nm -D /usr/lib/lib971apriltag.so | grep Java_org_photonvision_jni_GpuDetectorJNI
journalctl -u photonvision
```

There must be no unresolved WPILib, OpenCV, JNI, CUDA, NVJPG, Abseil, or TensorRT symbols. The
PhotonVision jar and native libraries must come from the same candidate revision.

## Jetson runtime matrix

Run these on the target Jetson with the candidate commits recorded:

```sh
tests/detector-frame-sizes/run.sh
tests/gpudetector-handles/run.sh 25
tests/jpeg-hw/run.sh
tests/detector-ab/run.sh faults
tests/rewind-ab/run.sh 30 2
tests/robot-clock/run.sh
tests/jetson-telemetry/run.sh
tests/camera-replug/run.sh 5
tests/jvm-check.sh
tests/cpu-profile.sh
```

For at least 10 minutes per camera configuration, test one camera and then two cameras with:

- AprilTagCuda enabled.
- An 8-coefficient lens calibration.
- Three-dimensional and multi-tag pose enabled.
- Resolution and pipeline changes while running.
- USB unplug and replug.
- Graceful and sticky CUDA faults.
- Rewind recording and export.
- MJPEG hardware and CPU decoding.
- TensorRT detection if the candidate includes it.

Acceptance requires no stale frame, wrong tag ID, JNI exception, leaked detector handle, unexpected
restart, out-of-memory kill, or monotonic memory growth. Report fresh FPS, detection latency, CPU,
GPU, and memory numbers. Do not reuse the JetPack 6 measurements.

## Robot-network gate

Keep the robot on its tested PhotonLib release until this joint test passes. A matching alpha-7
PhotonLib vendordep, WPILib alpha-7, SystemCore image 14, and compatible FIRST Driver Station must
be used together.

On the real robot network:

- Connect the SystemCore to the Jetson.
- Read `PhotonCamera.getLatestResult()` repeatedly.
- Confirm there is no PhotonLib or coprocessor message-hash mismatch.
- Confirm there is no version-mismatch warning or error.
- Verify valid single-tag and multi-tag poses.
- Verify timestamps use the timebase expected by the robot pose estimator.
- Confirm there is no 1000x timestamp offset or stale zero timestamp.
- Confirm PhotonLib can set camera enable state.
- Confirm robot-clock time sync, Rewind timestamps, and the Jetson date path remain healthy.
- Reboot each device in both orders and repeat after reconnect.

If robot hardware is unavailable, this PR must exclude robot compatibility from its claims.
