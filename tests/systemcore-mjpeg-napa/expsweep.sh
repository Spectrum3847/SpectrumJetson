#!/usr/bin/env bash
# Exposure x gain sweep on the live tag, ON THE PI, with PhotonVision stopped (holds /tmp/camera.lock throughout).
#   expsweep.sh OUT_DIR [SECS] [EXPOSURES_0.1ms] [GAINS] [MIN_CONTRAST]
#   e.g. expsweep.sh ~/bench/results/sweep 8 "2 5 10 20 50" "32 64 96 128" 20
# Per combination: scmn_live --mode fused (latency, detection rate, pose mean/sd) and a 240-frame capture
# (Rewind session for offline decode/NAPA timing and min_contrast replays). Restores the camera's controls.
set -uo pipefail
OUT=${1:?OUT_DIR}
SECS=${2:-8}
EXPS=${3:-"2 5 10 20 50"}
GAINS=${4:-"32 64 96 128"}
MC=${5:-20}
B=${SCMN_BIN:-$HOME/bench/bin}
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=/dev/video0
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 120 9 || { echo "camera lock busy" >&2; exit 1; }
orig=$(v4l2-ctl -d $DEV -C exposure_time_absolute,gain,auto_exposure | tr -d ' ' | sed 's/(.*//')
echo "original controls: $orig" | tee "$OUT/controls.txt"
restore() {
  for kv in $orig; do v4l2-ctl -d $DEV -c "${kv/:/=}"; done
  echo "restored: $(v4l2-ctl -d $DEV -C exposure_time_absolute,gain | tr '\n' ' ')"
}
trap restore EXIT
v4l2-ctl -d $DEV -c auto_exposure=1
for e in $EXPS; do
  for g in $GAINS; do
    v4l2-ctl -d $DEV -c exposure_time_absolute="$e" -c gain="$g"
    tag=e${e}_g${g}
    em=$(awk "BEGIN{print $e/10}")
    "$B/scmn_live" --mode fused --secs "$SECS" --cpu 2 --min-contrast "$MC" --exposure-ms "$em" \
      --csv "$OUT/$tag.csv" >"$OUT/$tag.txt" 2>"$OUT/$tag.err"
    v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=240 --stream-to="$OUT/$tag.mjpeg" >/dev/null 2>&1
    python3 "$HERE/mjpeg2rewind.py" "$OUT/$tag.mjpeg" "$OUT/sessions/$tag" >/dev/null && rm -f "$OUT/$tag.mjpeg"
    echo "$tag: $(grep -E 'frames with a tag' "$OUT/$tag.txt" | sed 's/;.*//') | $(grep 'mid-exposure' "$OUT/$tag.txt" | head -1 | tr -s ' ')"
  done
done
