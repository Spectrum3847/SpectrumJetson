#!/usr/bin/env bash
# Build our GPU AprilTag detector, libspectrum-gpu-apriltag.so: Austin Schuh's current CUDA
# AprilTag detector (frc971/bos third_party/971apriltag) + our patches (patches/detector-*.patch)
# + our JNI bridge (detector/). Before 2026-10-31 this was 07-build-bos-detector.sh, building
# ~/build/bos-detector/lib971apriltag.so with patches/bos-*.patch; the first run moves that folder.
# Drop-in replacement for the FRC-Team-4143 GpuDetectorJNI build (05-*.sh): same Java API.
#
# Also builds libspectrumnvjpg.so, the optional NVJPG hardware JPEG decoder that
# libspectrum-gpu-apriltag.so loads when SPECTRUM_JPEG_DECODER=nvjpg (detector/nvjpg_decoder.h).
#
# Run ON THE JETSON (after 02-jetpack.sh: CUDA, JDK). Builds only; does NOT install.
# No WPILib needed (detector/wpi_compat.h): the AprilTag C library is built in from source.
# Install with 08-select-detector.sh gpu (it installs both libraries), or by hand:
#   sudo install -m 755 ~/build/gpu-detector/libspectrum-gpu-apriltag.so /usr/lib/libspectrum-gpu-apriltag.so
#   sudo install -m 755 ~/build/gpu-detector/libspectrumnvjpg.so /usr/lib/libspectrumnvjpg.so
#   sudo systemctl restart photonvision
#   (rollback: rerun 05-build-gpudetector.sh, which installs the 4143 build)
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

BOS_REPO=https://github.com/frc971/bos.git
BOS_SHA=62e93b4   # 2026-09-07; third_party/971apriltag last changed in 1dbdf51 (2026-05-19)
# The AprilTag C library: the AprilRobotics commit WPILib 2027 alpha-8 bundles
# (allwpilib upstream_utils/apriltag.py, "master on 2026-08-07").
APRILTAG_REPO=https://github.com/AprilRobotics/apriltag.git
APRILTAG_SHA=b7c0ebe9aa20f82ec7a828579004f9e706bfecd9
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$HOME/build/bos
APRILTAG_SRC=$HOME/build/apriltag-src/apriltag   # in a directory named apriltag: <apriltag/...>
OUT=$HOME/build/gpu-detector
# The build folder's old name: move it (keeps CMake's cache; CMake follows the move after a reconfigure).
if [[ -d $HOME/build/bos-detector && ! -e $OUT ]]; then
  echo "==> Moving ~/build/bos-detector to $OUT (2026-10-31 rename)"
  mv "$HOME/build/bos-detector" "$OUT"
  rm -f "$OUT/CMakeCache.txt"   # it records the old folder; configure afresh
  rm -rf "$OUT/CMakeFiles"
fi

# Only for jni.h; the library runs in whichever JVM loads it.
JAVA_HOME=$(ls -d /usr/lib/jvm/java-25-openjdk-arm64 /usr/lib/jvm/java-17-openjdk-arm64 2>/dev/null | head -1 || true)
export JAVA_HOME
export PATH=$PATH:/usr/local/cuda/bin
command -v cmake >/dev/null && command -v ninja >/dev/null && dpkg -s libjpeg-turbo8-dev libopencv-dev >/dev/null 2>&1 ||
  sudo apt-get install -y cmake ninja-build build-essential libjpeg-turbo8-dev libopencv-dev

if [[ ! -d $APRILTAG_SRC/.git ]]; then
  git clone --filter=blob:none "$APRILTAG_REPO" "$APRILTAG_SRC"
fi
git -C "$APRILTAG_SRC" fetch -q origin || echo "==> Can't reach $APRILTAG_REPO; using the local clone"
git -C "$APRILTAG_SRC" checkout -q -f "$APRILTAG_SHA"

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
for p in "$REPO_ROOT"/patches/detector-*.patch; do
  [[ -e $p ]] || continue
  echo "==> Applying $(basename "$p")"
  git apply "$p"
done

cmake -S "$REPO_ROOT/detector" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBOS_DIR="$SRC" \
  -DAPRILTAG_DIR="$APRILTAG_SRC"
cmake --build "$OUT" --parallel 4 --target 971apriltag_jni
# The hardware JPEG decoder and TensorRT are optional (the CMake skips them when their libraries
# are missing), and each is built on its own so one failing doesn't stop the detector.
for t in spectrumnvjpg spectrumtrt_jni; do
  cmake --build "$OUT" --parallel 4 --target "$t" || echo "==> $t didn't build (optional)"
done

echo
ldd "$OUT/libspectrum-gpu-apriltag.so" | grep -E "not found|wpi|apriltag|cudart" || true
# Exported: the JNI entry points and spectrum_cuda_* only (nothing from AprilTag or abseil).
echo "exported: $(nm -D --defined-only "$OUT/libspectrum-gpu-apriltag.so" | awk '{print $3}' | grep -v -E '^(Java_|JNI_|spectrum_cuda_)' | wc -l) symbols besides JNI and spectrum_cuda_*"
echo "Built $OUT/libspectrum-gpu-apriltag.so and $OUT/libspectrumnvjpg.so (not installed)"
echo "Check the hardware JPEG decoder with tests/jpeg-hw/run.sh"
