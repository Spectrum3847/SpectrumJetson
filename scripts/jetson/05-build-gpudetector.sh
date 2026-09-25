#!/usr/bin/env bash
# Build the legacy FRC-Team-4143 GpuDetectorJNI bridge and install lib971apriltag.so.
# This remains a compatibility path. The maintained detector build is 07-build-bos-detector.sh.
set -euo pipefail

REPO=https://github.com/FRC-Team-4143/GpuDetectorJNI.git
SHA=ef9fc1ec7e43116849e71fef1ab335ba630274a7
SRC=$HOME/build/GpuDetectorJNI
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ALLWPILIB_DIR=${ALLWPILIB_DIR:-$HOME/build/allwpilib-v2027.0.0-alpha-7}

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-arm64}
export PATH=$PATH:/usr/local/cuda/bin

[[ -f $ALLWPILIB_DIR/wpiutil/src/main/native/include/wpi/util/RawFrame.h ]] || {
  echo "Missing AllWPILib alpha-7 headers. Run 04-build-allwpilib.sh first." >&2
  exit 1
}

if [[ ! -d $SRC/.git ]]; then
  git clone "$REPO" "$SRC"
fi
cd "$SRC"
git checkout -q -f "$SHA"
git reset -q --hard "$SHA"
git clean -fdq
for p in "$REPO_ROOT"/patches/gpudetector-*.patch; do
  [[ -e $p ]] || continue
  echo "==> Applying $(basename "$p")"
  git apply "$p"
done

echo "==> Building bundled apriltag"
cmake -S third_party/apriltag -B third_party/apriltag/build -DCMAKE_BUILD_TYPE=Release
cmake --build third_party/apriltag/build --parallel 1

echo "==> Building lib971apriltag with C++20 and AllWPILib alpha-7 headers"
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DALLWPILIB_DIR="$ALLWPILIB_DIR"
cmake --build build --parallel 1

sudo install -m 755 build/lib971apriltag.so /usr/lib/lib971apriltag.so
sudo ldconfig

echo "==> Dependency check"
if ldd /usr/lib/lib971apriltag.so | grep "not found"; then
  echo "Unresolved libraries above." >&2
  exit 1
fi
ldd /usr/lib/lib971apriltag.so | grep -E "cudart|apriltag" || true
echo "Installed /usr/lib/lib971apriltag.so"
echo "Run tests/gpudetector-handles/run.sh and tests/detector-frame-sizes/run.sh on the Jetson."
