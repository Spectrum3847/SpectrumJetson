#!/usr/bin/env bash
# Build fieldcal_detect (detector/fieldcal_detect.cc): replays a Rewind recording through the 971
# CUDA AprilTag detector, for field calibration (tools/fieldcal). Uses the bos checkout that
# 07-build-bos-detector.sh set up, with the same patches, so it's the detector PhotonVision runs.
#
# Run ON THE JETSON after 07-build-bos-detector.sh. Builds only this tool, in its own folder, and
# doesn't touch PhotonVision or lib971apriltag.so. About 2.5 min (measured).
#
#   --install   also install the solver (tools/fieldcal) and this tool to /opt/spectrum/fieldcal,
#               where PhotonVision's Field Calibration page runs them (photonvision-30). Rerun after
#               updating tools/fieldcal.
set -euo pipefail
INSTALL=0
[[ ${1:-} == --install ]] && INSTALL=1
DEST=/opt/spectrum/fieldcal

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$HOME/build/bos
OUT=$HOME/build/fieldcal-detect

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-arm64}
export PATH=$PATH:/usr/local/cuda/bin

[[ -f $SRC/third_party/971apriltag/apriltag.h ]] || { echo "Run 07-build-bos-detector.sh first." >&2; exit 1; }

cmake -S "$REPO_ROOT/detector" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBOS_DIR="$SRC"
# Low priority and 3 jobs: PhotonVision keeps running while this builds.
nice -n 10 cmake --build "$OUT" --parallel 3 --target fieldcal_detect

echo "Built $OUT/fieldcal_detect"

if (( INSTALL )); then
  sudo install -d -m 755 "$DEST/fieldcal"
  sudo rm -f "$DEST"/fieldcal/*.py
  sudo install -m 644 "$REPO_ROOT"/tools/fieldcal/fieldcal/*.py "$DEST/fieldcal/"
  sudo install -m 755 "$OUT/fieldcal_detect" "$DEST/fieldcal_detect"
  echo "Installed to $DEST: PhotonVision's Field Calibration page uses it."
fi
echo "Use: ~/SpectrumJetson/tools/fieldcal/fieldcal.sh solve /opt/photonvision/rewind/sessions/<recording> --layout <layout.json>"
