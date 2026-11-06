#!/bin/bash
# sc-vision's per-frame decode scale (full / 1/2 / 1/4: mjdec's reduced IDCT, NAPA on the smaller image with min tag
# / scale, corners back to full-res pixels) on each camera: CPU per frame, detection, pose and corner noise.
#   scale-compare.sh [SECS] [CAMS] [SCALES]     default 15 s, "SJ-05 SJ-SW01", "1 2 4"; min tag 22 at full scale
# Holds /tmp/camera.lock for the whole run; PhotonVision must be stopped (sc-vision takes the camera).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
secs=${1:-15}
cams=${2:-SJ-05 SJ-SW01}
scales=${3:-1 2 4}
OUT=${OUT:-$HOME/shared/latency/scale}
export OUT
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera busy"; exit 1; }
export SC_VISION_HAVE_LOCK=1
[[ $(systemctl is-active photonvision) == active ]] && { echo "PhotonVision is running: not taking its camera"; exit 1; }
for c in $cams; do
  if [[ $c == SJ-05 ]]; then cal=/opt/sc-vision/etc/calib.json; cargs="--exposure 2 --gain 128 --gamma 100 --backlight 0 --sharpness 1"
  else cal=$HOME/builder/swyft-cal.json; cargs="--usb 0bda:3035"; fi
  for s in $scales; do
    # shellcheck disable=SC2086
    "$HERE/run.sh" native "$secs" "scale-$c-$s" --serial "$c" --cpu 3 --fifo 40 --pkts 2 $cargs --min-tag 22 \
      --calib "$cal" --scale "$s" > "$OUT/scale-$c-$s.runlog" 2>&1
    grep -h "processed at" "$OUT/scale-$c-$s.log" 2>/dev/null | tail -1
  done
done
for c in $cams; do
  for s in $scales; do python3 "$HERE/scale_summary.py" "$OUT/scale-$c-$s.csv"; done
done
