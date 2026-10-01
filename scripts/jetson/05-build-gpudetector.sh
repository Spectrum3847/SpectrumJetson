#!/usr/bin/env bash
# Build FRC 971's CUDA AprilTag detector (FRC-Team-4143/GpuDetectorJNI) and install
# lib971apriltag.so, which the 4143 PhotonVision fork loads via System.loadLibrary.
# Run ON THE JETSON after 04-build-allwpilib.sh has installed allwpilib v2026.2.1.
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

REPO=https://github.com/FRC-Team-4143/GpuDetectorJNI.git
SHA=ef9fc1ec7e43116849e71fef1ab335ba630274a7
SRC=$HOME/build/GpuDetectorJNI
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH=$PATH:/usr/local/cuda/bin

if ! ls /usr/local/lib/libwpiutil.so >/dev/null 2>&1; then
  echo "allwpilib is not installed (/usr/local/lib/libwpiutil.so missing). Run 04 first." >&2
  exit 1
fi

if [[ ! -d $SRC/.git ]]; then
  git clone "$REPO" "$SRC"
fi
cd "$SRC"
# Reset to the pinned commit, then apply our patches (see patches/).
git checkout -q -f "$SHA"
for p in "$REPO_ROOT"/patches/gpudetector-*.patch; do
  [[ -e $p ]] || continue
  echo "==> Applying $(basename "$p")"
  git apply "$p"
done

echo "==> Building bundled apriltag"
cmake -S third_party/apriltag -B third_party/apriltag/build -DCMAKE_BUILD_TYPE=Release
cmake --build third_party/apriltag/build --parallel "$(nproc)"

echo "==> Building lib971apriltag (CUDA arch 87)"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc
cmake --build build --parallel 4

sudo install -m 755 build/lib971apriltag.so /usr/lib/lib971apriltag.so
sudo ldconfig

echo "==> Dependency check"
if ldd /usr/lib/lib971apriltag.so | grep "not found"; then
  echo "Unresolved libraries above." >&2
  exit 1
fi
ldd /usr/lib/lib971apriltag.so | grep -E "wpiutil|cuda"
echo "Installed /usr/lib/lib971apriltag.so"
