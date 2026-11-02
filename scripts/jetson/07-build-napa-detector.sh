#!/usr/bin/env bash
# Build libspectrum-napa-apriltag.so: NAPA (third_party/napa, Zachary Wilson, GPL-3.0-only, v0.5.1) + our
# far search and JNI bridge (detector/napa/), the CPU AprilTag backend of the Spectrum PhotonVision fork
# ("Tags on CPU (NAPA)" on the Jetson; the CPU detector for SystemCore / Raspberry Pi CM5 / x86_64).
# Plain gcc/g++, no CUDA, OpenCV or WPILib; aarch64 or x86_64 Linux. Runs the self-test (napa_test).
#   scripts/jetson/07-build-napa-detector.sh [OUT]     OUT default ~/build/napa-detector
# Builds only; install (PhotonVision loads it from java.library.path, like the GPU detector):
#   sudo install -m 755 ~/build/napa-detector/libspectrum-napa-apriltag.so /usr/lib/
# Without it installed, the fork's NAPA option falls back to its normal detector and logs why.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$HOME/build/napa-detector}
# NAPA as vendored plus our patches (patches/napa-*.patch): scripts/jetson/napa-src.sh.
N=$OUT/napa-src
"$REPO/scripts/jetson/napa-src.sh" "$N"
D=$REPO/detector/napa
mkdir -p "$OUT"
JAVA_HOME=${JAVA_HOME:-$(ls -d /usr/lib/jvm/java-25-openjdk-* /usr/lib/jvm/java-21-openjdk-* /usr/lib/jvm/java-17-openjdk-* $HOME/wpilib/2027/jdk 2>/dev/null | head -1 || true)}
[[ -f $JAVA_HOME/include/jni.h ]] || { echo "no jni.h: set JAVA_HOME to a JDK" >&2; exit 1; }
# Cross builds: CC/CXX (e.g. WPILib's SystemCore toolchain, aarch64-bookworm-linux-gnu-gcc, or
# x86_64-linux-gnu-gcc) and TARGET_ARCH (aarch64, x86_64); the self-test runs only on a native build.
CC=${CC:-gcc}
CXX=${CXX:-g++}
ARCH=${TARGET_ARCH:-$(uname -m)}
case $ARCH in
  aarch64) MF="-march=armv8-a+simd" ;;
  x86_64) MF="-msse4.1" ;;   # NAPA's SSE path needs SSSE3; every x86_64 robot PC has SSE4.1
  *) MF="" ;;
esac
CF="-O3 -fPIC -fvisibility=hidden -fno-wrapv $MF"
timeout 300 $CC $CF -std=gnu99 -c "$N/napa_core.c" -I"$N" -o "$OUT/napa_core.o"
for f in napa_far NapaDetectorJNI; do
  timeout 300 $CXX $CF -std=c++17 -Wall -Wextra -c "$D/$f.cc" -I"$N" -I"$D" -I"$JAVA_HOME/include" \
    -I"$JAVA_HOME/include/linux" -o "$OUT/$f.o"
done
$CXX -shared -Wl,-z,defs -o "$OUT/libspectrum-napa-apriltag.so" "$OUT/napa_core.o" "$OUT/napa_far.o" \
  "$OUT/NapaDetectorJNI.o" -lm -lpthread
timeout 300 $CXX -O2 -std=c++17 -Wall "$D/napa_test.cc" "$OUT/napa_far.o" "$OUT/napa_core.o" -I"$N" -I"$D" \
  -lm -lpthread -o "$OUT/napa_test"
if [[ $ARCH == "$(uname -m)" ]]; then
  timeout 60 "$OUT/napa_test"
else
  echo "cross build for $ARCH: run $OUT/napa_test on the target"
fi
echo "built $OUT/libspectrum-napa-apriltag.so ($ARCH)"
