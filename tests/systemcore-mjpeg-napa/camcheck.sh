#!/usr/bin/env bash
# Per-camera offline-identity check from a short live capture, ON THE PI, under /tmp/camera.lock:
#   camcheck.sh OUT NAME DEV WxH [FRAMES] [v4l2 ctrl=val ...]      e.g. camcheck.sh ~/bench/results/swyft swyft /dev/video2 1280x800 240
# Captures FRAMES MJPEG frames (v4l2-ctl), converts to a Rewind session, prints the JPEG layout (components,
# sampling, restart interval, tables) and entropy split (jpegbits.py), then mjdec vs libjpeg-turbo identity +
# speed (decver-style), fused stream decode + streaming NAPA identity, and NAPA detections. Restores the
# controls it changed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
NAME=${2:?NAME}
DEV=${3:?DEV}
WH=${4:?WxH}
N=${5:-240}
shift 5 || shift $#
B=${SCMN_BIN:-$HOME/bench/bin-fix}
LIB=${SCMN_BUILDER_LIB:-$HOME/bench/bin/libscvision-dec-1ab9065.so}
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
restore=()
for kv in "$@"; do
  k=${kv%%=*}
  restore+=("$k=$(v4l2-ctl -d "$DEV" -C "$k" | awk '{print $2}')")
  v4l2-ctl -d "$DEV" -c "$kv"
done
v4l2-ctl -d "$DEV" -C exposure_time_absolute,gain,gamma,sharpness,backlight_compensation,brightness,contrast >"$OUT/$NAME.controls" 2>&1
v4l2-ctl -d "$DEV" --set-fmt-video="width=${WH%x*},height=${WH#*x},pixelformat=MJPG" --stream-mmap=4 \
  --stream-count="$N" --stream-to="$OUT/$NAME.mjpeg" >"$OUT/$NAME.capture.log" 2>&1
for kv in "${restore[@]}"; do v4l2-ctl -d "$DEV" -c "$kv"; done
exec 9>&-
python3 "$HERE/mjpeg2rewind.py" "$OUT/$NAME.mjpeg" "$OUT/$NAME" --cam cam --width "${WH%x*}" --height "${WH#*x}"
python3 "$HERE/jpegbits.py" "$OUT/$NAME/cam" --frames 2
SCMN_BUILDER_LIB=$LIB "$B/scmn_bench" decode "$OUT/$NAME" --cpu 3 --dec turbo,builder 2>&1 | grep -E "decode:|turbo|scvision|DECODE" | sed 's/(mean.*n [0-9]*)//'
SCMN_BUILDER_LIB=$LIB "$B/scmn_bench" fused "$OUT/$NAME" --cpu 3 --dec stream,builder --chunk 3072 --min-contrast 20 2>&1 |
  grep -E "detections|stream     tail|scvision-mjdec tail|frames differ|FUSED" | sed 's/(mean.*n [0-9]*)//'
SCMN_BUILDER_LIB=$LIB "$B/scmn_bench" fuzz "$OUT/$NAME" --dec builder --max-frames 120 2>&1 | grep -E "FUZZ|CRASH|HANG"
