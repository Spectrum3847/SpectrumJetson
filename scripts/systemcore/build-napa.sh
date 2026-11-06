#!/usr/bin/env bash
# Cross-build the CPU detector libraries for the SystemCore (Raspberry Pi 5 / CM5, 4x Cortex-A76) on the
# laptop, with WPILib's SystemCore toolchain (aarch64-systemcore2027-linux-gnu-gcc, whose sysroot matches the
# SystemCore image: glibc 2.42, libjpeg-turbo 3). Works from Git Bash on Windows or from Linux.
#   scripts/systemcore/build-napa.sh [OUT]      OUT default ~/builder/sc-napa
# Produces libspectrum-napa-apriltag.so, libspectrum-stream.so and napa_test (run napa_test on the target).
# Install: scripts/systemcore/install-photonvision.sh copies them to the SystemCore.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$HOME/builder/sc-napa}
# shellcheck source=scripts/systemcore/toolchain.sh
. "$REPO/scripts/systemcore/toolchain.sh"
export CC=$SC_CC CXX=$SC_CXX TARGET_ARCH=aarch64 JAVA_HOME=$SC_JNI
mkdir -p "$OUT"
"$REPO/scripts/jetson/07-build-napa-detector.sh" "$OUT"
