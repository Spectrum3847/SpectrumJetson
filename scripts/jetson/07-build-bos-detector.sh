#!/usr/bin/env bash
# Build lib971apriltag.so from Austin Schuh's CUDA AprilTag detector in frc971/bos
# (third_party/971apriltag) with our JNI bridge (detector/), which uses C++20 and the
# AllWPILib alpha-7 C headers.
#
# Also builds libspectrumnvjpg.so, the optional NVJPG hardware JPEG decoder that
# lib971apriltag.so loads when SPECTRUM_JPEG_DECODER=nvjpg (detector/nvjpg_decoder.h).
#
# Run ON THE JETSON after 04-build-allwpilib.sh. Builds only; does NOT install.
# Install with 08-select-detector.sh bos (it installs both libraries), or by hand:
#   sudo install -m 755 ~/build/bos-detector/lib971apriltag.so /usr/lib/lib971apriltag.so
#   sudo install -m 755 ~/build/bos-detector/libspectrumnvjpg.so /usr/lib/libspectrumnvjpg.so
#   sudo systemctl restart photonvision
set -euo pipefail

BOS_REPO=https://github.com/frc971/bos.git
BOS_SHA=62e93b4   # 2026-09-07; third_party/971apriltag last changed in 1dbdf51 (2026-05-19)
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$HOME/build/bos
OUT=$HOME/build/bos-detector
ALLWPILIB_DIR=${ALLWPILIB_DIR:-$HOME/build/allwpilib-v2027.0.0-alpha-7}

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-arm64}
export PATH=$PATH:/usr/local/cuda/bin

[[ -f $ALLWPILIB_DIR/wpiutil/src/main/native/include/wpi/util/RawFrame.h ]] || {
  echo "Missing AllWPILib alpha-7 headers. Run 04-build-allwpilib.sh first." >&2
  exit 1
}

if [[ ! -d $SRC/.git ]]; then
  git clone --filter=blob:none "$BOS_REPO" "$SRC"
fi
cd "$SRC"
# Offline (an event, or DNS down) is fine once the pinned commit is in the clone.
git fetch -q origin || echo "==> Can't reach $BOS_REPO; using the local clone"
git cat-file -e "$BOS_SHA^{commit}" 2>/dev/null ||
  { echo "bos $BOS_SHA is not in $SRC. The first build needs internet." >&2; exit 1; }
git checkout -q -f "$BOS_SHA"
git reset -q --hard "$BOS_SHA"
git clean -fdq
# Only abseil is needed (the pinned commit bos uses); skip json and bos-logs.
git submodule update --init --depth 1 third_party/abseil-cpp
for p in "$REPO_ROOT"/patches/bos-*.patch; do
  [[ -e $p ]] || continue
  echo "==> Applying $(basename "$p")"
  git apply "$p"
done

cmake -S "$REPO_ROOT/detector" -B "$OUT" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBOS_DIR="$SRC" -DALLWPILIB_DIR="$ALLWPILIB_DIR"
cmake --build "$OUT" --parallel 1 --target 971apriltag_jni spectrumtrt_jni spectrumnvjpg

echo
ldd "$OUT/lib971apriltag.so" | grep -E "not found|apriltag|cudart" || true
echo "Built $OUT/lib971apriltag.so and $OUT/libspectrumnvjpg.so. Nothing was installed."
echo "Run tests/jpeg-hw/run.sh, tests/gpudetector-handles/run.sh, and tests/detector-frame-sizes/run.sh on the Jetson."
