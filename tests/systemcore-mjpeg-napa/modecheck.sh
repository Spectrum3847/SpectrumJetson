#!/usr/bin/env bash
# Before/after check for camera firmware modes, ON THE PI, under /tmp/camera.lock (one camera, uvcvideo path):
#   modecheck.sh OUT LABEL [DEV] [SECS]
# Lists the camera's MJPEG modes, then for every MJPEG size: scmn_live --mode fused for SECS (frame period, USB
# transfer time = v4l2 ts -> last byte seen, tail, CPU per frame, tag rate, pose mean/sd, drops). Then a 240-frame
# 1280x800 capture through camcheck.sh (JPEG layout, decoder + streaming-NAPA identity, NAPA margins), so a
# firmware change can be checked against the same numbers taken before it ("1280x800 unchanged").
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
LABEL=${2:?LABEL}
DEV=${3:-${SCMN_THR:-/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0}}
SECS=${4:-5}
B=${SCMN_BIN:-$HOME/bench/bin}
mkdir -p "$OUT"
R=$OUT/$LABEL
{
  exec 9>/tmp/camera.lock
  flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
  v4l2-ctl -d "$DEV" --info | grep -E "Card|Bus|Driver version"
  lsusb -v -d "$(udevadm info -q property -n "$DEV" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p'):" 2>/dev/null | grep -m1 bcdDevice
  v4l2-ctl -d "$DEV" --list-formats-ext | tee "$R.modes" | grep -c Size | sed 's/^/size entries: /'
  sizes=$(awk '/MJPG/{m=1} /YUYV/{m=0} m && /Size/{print $3}' "$R.modes" | sort -u)
  for s in $sizes; do
    "$B/scmn_live" --dev "$DEV" --mode fused --secs "$SECS" --cpu 3 --width "${s%x*}" --height "${s#*x}" 2>&1 </dev/null |
      grep -E "frames \(|frames with|v4l2 ts ->|EOI seen ->|per-frame|pose \(" | sed "s/^/[$s] /"
  done
  exec 9>&-
} 2>&1 | tee "$R.txt"
"$HERE/camcheck.sh" "$OUT" "$LABEL-1280x800" "$DEV" 1280x800 240 2>&1 | grep -v '^$' | tee -a "$R.txt"
