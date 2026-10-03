# WPILib 2027 alpha-7 migration

The deployed configuration is a 2026-era pair with Jetson bench results. The
robot uses WPILib 2027.0.0-alpha-6 with PhotonLib v2027.0.0-alpha-2. The Jetson
runs the 2026 FRC-Team-4143 CUDA fork, based on WPILib 2026.2.1. The
robot-network integration test has not passed, so the pair is not fully
validated.

WPILib 2027.0.0-alpha-7 is the next migration target. Its [release notes](https://github.com/wpilibsuite/allwpilib/releases/tag/v2027.0.0-alpha-7)
say alpha-6 and earlier vendordeps do not work with alpha-7. As of 2026-09-25,
no PhotonLib alpha-7 tag was found in the official PhotonVision release feed.
The current alpha-2 tag pins WPILib alpha-6. Do not replace the robot
vendordep with a development asset and call the pair supported.

The audited PhotonVision main revision
[`1f419c9d`](https://github.com/PhotonVision/photonvision/commit/1f419c9de3a6a0787571648d18211537a83fdca9)
pins alpha-7, and PR [#2566](https://github.com/PhotonVision/photonvision/pull/2566)
changes the timestamp field names and serde hashes. Both are source evidence,
not released PhotonLib alpha-7 pins.

## What the migration must cover

1. Rebase the CUDA PhotonVision fork and its patches onto reviewed
   PhotonVision source that pins WPILib 2027.0.0-alpha-7.
2. Port the native bridge from the old `wpi/jni_util.h` and `wpi/RawFrame.h`
   includes to the alpha-7 headers, then rebuild the detector on ARM64.
   Alpha-7 requires C++23 and G++ 14; JetPack 6 ships GCC 11.
3. Build PhotonLib from reviewed alpha-7-compatible source or wait for a tagged
   release. Do not use the alpha-2 vendordep or label a development asset as a
   release.
4. Create or import the robot project for WPILib alpha-7 and re-import every
   vendordep.
5. Flash SystemCore image 14 and install FIRST Driver Station alpha-7.
6. Run the camera, AprilTag, pose, time-sync, NetworkTables, and memory tests
   on the Jetson.
7. Test the Jetson and SystemCore together on the competition network.

A successful x86 build does not validate CUDA, NVJPG, OpenCV, TensorRT, ARM64
linking, or the robot protocol. Those checks require the real Jetson and robot.
