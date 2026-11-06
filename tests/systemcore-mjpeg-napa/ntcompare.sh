#!/usr/bin/env bash
# PhotonVision vs sc-vision as a PhotonLib client sees them, ON THE PI, under /tmp/camera.lock: each publisher runs
# in turn with the camera settings it is configured with, and nt_check + topcpu.py measure it (no config change:
# PV runs from its stored pipeline; sc-vision gets SCV_ARGS).
#   ntcompare.sh OUT [SECS] [MIN_TAG]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
SECS=${2:-20}
MIN=${3:-32}
SCV_ARGS=${SCV_ARGS:---cpu 3 --fifo 40 --pkts 2 --exposure 2 --gain 128 --calib /opt/sc-vision/etc/calib.json --nt 127.0.0.1 --name thrifty --mid-offset-ms 2.6}
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
measure() {
  sudo python3 "$HERE/topcpu.py" "$SECS" 10 >"$OUT/$1.cpu" &
  "$HOME/bench/bin/nt_check" --camera thrifty --secs "$SECS" 2>&1 | grep -v -E '^NT:|topic /photon' >"$OUT/$1.nt"
  wait
  { echo "== $1"; grep -E "results in|capture ->|poseAmbiguity|bestCameraToTarget\.(x|qw|qx) |altCameraToTarget\.x " "$OUT/$1.nt"
    head -3 "$OUT/$1.cpu"; } | tee -a "$OUT/summary.txt"
}
sudo systemctl start photonvision
sleep 45
measure pv
sudo systemctl stop photonvision
sleep 2
# shellcheck disable=SC2086
sudo /opt/sc-vision/bin/sc-vision $SCV_ARGS --min-tag "$MIN" --secs $((SECS + 8)) >"$OUT/scv.log" 2>&1 </dev/null &
sleep 4
measure scv
wait
ls ${SCMN_THR:-/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0} >/dev/null 2>&1 || sudo /opt/sc-vision/bin/sc-vision-rebind
