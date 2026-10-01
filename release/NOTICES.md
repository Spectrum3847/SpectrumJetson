# Notices for the prebuilt bundle

`spectrum-jetson-prebuilt-*.tar.gz` (made by `scripts/jetson/make-prebuilt-bundle.sh`) contains
compiled code from these projects. Each keeps its own license; the license texts are in this
bundle next to this file.

| Files | From | License |
| --- | --- | --- |
| `build/bos-detector/lib971apriltag.so`, `build/fieldcal-detect/fieldcal_detect`, `build/bos-detector/far_search_test` | The CUDA AprilTag detector by Austin Schuh and FRC 971 Spartan Robotics, as published in [RealtimeRoboticsGroup/aos](https://github.com/RealtimeRoboticsGroup/aos) (`frc/orin`, Apache-2.0), built from the copy in [frc971/bos](https://github.com/frc971/bos) (commit `62e93b4`, `third_party/971apriltag`), with SpectrumJetson's `patches/bos-*.patch` applied, and SpectrumJetson's JNI bridge and tools (`detector/`, GPL-3.0). | Apache-2.0 (`LICENSE-Apache-2.0-aos.txt`) for the detector; GPL-3.0 for SpectrumJetson's code |
| `wpi/util/RawFrame.h` and `PixelFormat.h`, compiled into `lib971apriltag.so` | [WPILib allwpilib](https://github.com/wpilibsuite/allwpilib) v2027.0.0-alpha-7 headers, unmodified. Copyright (c) 2009-2026 FIRST and other WPILib contributors. | BSD-3-Clause (`LICENSE-BSD-3-allwpilib.md`) |
| `build/bos-detector/libspectrumnvjpg.so`, `libspectrumtrt.so` | SpectrumJetson (`detector/`). They link against NVIDIA JetPack libraries, which aren't included. | GPL-3.0 |
| `photonvision-spectrum-*-linuxarm64.jar` | [PhotonVision](https://github.com/PhotonVision/photonvision) (main `1f419c9d`, WPILib 2027.0.0-alpha-7) with SpectrumJetson's `patches/photonvision-2027-alpha7-migration.patch`, which carries FRC-Team-4143's CUDA pipeline and our patches. Source: this repo and those projects. | GPL-3.0 |

The detector's copy in bos has no license file of its own; it's credited here under the Apache-2.0
license its author publishes it with in aos. If the authors would like this handled differently,
open an issue on [Spectrum3847/SpectrumJetson](https://github.com/Spectrum3847/SpectrumJetson) and
we'll change it.
