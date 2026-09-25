#!/usr/bin/env bash
# Build lib971apriltag.so from Austin Schuh's CUDA AprilTag detector in frc971/bos.
# The SpectrumJetson JNI bridge uses C++20 and AllWPILib alpha-7 C headers.
set -euo pipefail

BOS_REPO=https://github.com/frc971/bos.git
BOS_SHA=62e93b4
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
git fetch -q origin || echo "==> Can't reach $BOS_REPO; using the local clone"
git cat-file -e "$BOS_SHA^{commit}" 2>/dev/null ||
  { echo "bos $BOS_SHA is not in $SRC. The first build needs internet." >&2; exit 1; }
git checkout -q -f "$BOS_SHA"
git reset -q --hard "$BOS_SHA"
git clean -fdq
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
