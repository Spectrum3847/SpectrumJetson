#!/usr/bin/env bash
# Build lib971apriltag.so from Austin Schuh's current CUDA AprilTag detector
# (frc971/bos third_party/971apriltag) with our JNI bridge (detector/).
# Drop-in replacement for the FRC-Team-4143 GpuDetectorJNI build (05-*.sh): same Java API.
#
# Also builds libspectrumnvjpg.so, the optional NVJPG hardware JPEG decoder that
# lib971apriltag.so loads when SPECTRUM_JPEG_DECODER=nvjpg (detector/nvjpg_decoder.h).
#
# Run ON THE JETSON after 04-build-allwpilib.sh. Builds only; does NOT install.
# Install with 08-select-detector.sh bos (it installs both libraries), or by hand:
#   sudo install -m 755 ~/build/bos-detector/lib971apriltag.so /usr/lib/lib971apriltag.so
#   sudo install -m 755 ~/build/bos-detector/libspectrumnvjpg.so /usr/lib/libspectrumnvjpg.so
#   sudo systemctl restart photonvision
#   (rollback: rerun 05-build-gpudetector.sh, which installs the 4143 build)
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

BOS_REPO=https://github.com/frc971/bos.git
BOS_SHA=62e93b4   # 2026-09-07; third_party/971apriltag last changed in 1dbdf51 (2026-05-19)
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$HOME/build/bos
OUT=$HOME/build/bos-detector

export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH=$PATH:/usr/local/cuda/bin

[[ -f /usr/local/lib/libwpiutil.so ]] || { echo "Run 04-build-allwpilib.sh first." >&2; exit 1; }

if [[ ! -d $SRC/.git ]]; then
  git clone --filter=blob:none "$BOS_REPO" "$SRC"
fi
cd "$SRC"
# Offline (an event, or DNS down) is fine once the pinned commit is in the clone.
git fetch -q origin || echo "==> Can't reach $BOS_REPO; using the local clone"
git cat-file -e "$BOS_SHA^{commit}" 2>/dev/null ||
  { echo "bos $BOS_SHA isn't in $SRC: the first build needs the internet" >&2; exit 1; }
git checkout -q -f "$BOS_SHA"
# Only abseil is needed (the pinned commit bos uses); skip json and bos-logs.
git submodule update --init --depth 1 third_party/abseil-cpp
for p in "$REPO_ROOT"/patches/bos-*.patch; do
  [[ -e $p ]] || continue
  echo "==> Applying $(basename "$p")"
  git apply "$p"
done

cmake -S "$REPO_ROOT/detector" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBOS_DIR="$SRC"
cmake --build "$OUT" --parallel 4 --target 971apriltag_jni spectrumtrt_jni spectrumnvjpg

echo
ldd "$OUT/lib971apriltag.so" | grep -E "not found|wpiutil|apriltag|cudart" || true
echo "Built $OUT/lib971apriltag.so and $OUT/libspectrumnvjpg.so (not installed)"
echo "Check the hardware JPEG decoder with tests/jpeg-hw/run.sh"
