#!/usr/bin/env bash
# Builds detector-replay with patches/detector-20-early-reject.patch ON THE JETSON, from a copy of the bos tree
# scripts/jetson/07-build-gpu-detector.sh prepared (~/build/bos: detector-01..19 applied). Never touches the
# installed library or ~/build/gpu-detector.   tests/early-reject/build.sh [WORK]   (~/build/early-reject)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${1:-$HOME/build/early-reject}
SRC=$HOME/build/bos
[[ -f $SRC/third_party/971apriltag/apriltag_detect.cc ]] || { echo "run scripts/jetson/07-build-gpu-detector.sh first" >&2; exit 1; }
grep -q spectrum_early "$SRC/third_party/971apriltag/apriltag_detect.cc" && { echo "$SRC already has detector-20" >&2; exit 1; }
mkdir -p "$WORK/bos/third_party"
rm -rf "$WORK/bos/third_party/971apriltag"
cp -a "$SRC/third_party/971apriltag" "$WORK/bos/third_party/"
ln -sfn "$SRC/third_party/abseil-cpp" "$WORK/bos/third_party/abseil-cpp"
(cd "$WORK/bos" && patch -s -p1 <"$REPO/patches/detector-20-early-reject.patch")
export PATH=$PATH:/usr/local/cuda/bin
JAVA_HOME=$(ls -d /usr/lib/jvm/java-25-openjdk-arm64 /usr/lib/jvm/java-17-openjdk-arm64 2>/dev/null | head -1 || true)
export JAVA_HOME
timeout 600 cmake -S "$REPO/detector" -B "$WORK/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBOS_DIR="$WORK/bos" \
  -DAPRILTAG_DIR="$HOME/build/apriltag-src/apriltag" >/dev/null
timeout 1800 nice cmake --build "$WORK/build" --parallel 4 --target detector-replay
echo "built $WORK/build/detector-replay"
