#!/bin/bash
# PhotonVision's normal V4L2 path with the stock uvcvideo (32-packet URBs) vs ours with small URBs, plus sc-vision,
# on the SystemCore. performance governor for the session (restored after), the CD-baseline camera settings, min 32.
#   urb-compare.sh [SECS] [URBS]       default 30 s, URBS "4 2"
# PhotonVision runs: whole-frame NAPA + libjpeg-turbo ("pv-whole") and stream decoder (mjdec) + streaming NAPA
# ("pv-stream"). Each driver is loaded at run time (scripts/systemcore/uvcvideo-load.sh); the stock one is put back.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/../../scripts/systemcore/uvcvideo-load.sh
secs=${1:-30}
urbs=${2:-4 2}
P=/sys/devices/system/cpu/cpufreq/policy0
orig=$(cat $P/scaling_governor)
echo performance | sudo -n tee $P/scaling_governor >/dev/null
trap 'echo "$orig" | sudo -n tee $P/scaling_governor >/dev/null; "$L" stock >/dev/null; echo "restored: governor $(cat $P/scaling_governor), stock uvcvideo"' EXIT
export OUT=${OUT:-$HOME/shared/latency/urb}
mkdir -p "$OUT"
WHOLE="SPECTRUM_JPEG_DECODER=turbo SPECTRUM_NAPA_STREAM=0"
STREAM="SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec"
COMMON="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0"
row() {
  local f=$OUT/$1.table
  printf '%-18s ' "$1"
  grep -E "^(first USB packet -> pose|V4L2 timestamp -> pose|TAIL last packet -> tags)" "$f" |
    awk '{printf "%s %s/%s/%s | ", $1" "$2, $(NF-2), $(NF-1), $NF}'
  grep -E "^\(hw timestamp -> first USB packet\)" "$f" | awk '{printf "stamp lag p50 %s | ", -$(NF-2)}'
  awk '{printf "proc %s%% of a core", $4}' "$OUT/$1.cpu"
  echo
}
for d in stock $urbs; do
  if [[ $d == stock ]]; then "$L" stock; else "$L" urb "$d"; fi
  export KTRACE_PSIZE=1600
  # shellcheck disable=SC2086
  "$HERE/run.sh" pv "$secs" "pv-whole-$d" $COMMON $WHOLE >/dev/null 2>&1
  # shellcheck disable=SC2086
  "$HERE/run.sh" pv "$secs" "pv-stream-$d" $COMMON $STREAM >/dev/null 2>&1
done
"$L" stock >/dev/null
EXPOSURE_MS=0.2 "$HERE/run.sh" native "$secs" "scv" --cpu 3 --fifo 40 --pkts 2 --exposure 2 --gain 128 --gamma 100 \
  --backlight 0 --min-tag 22 --calib /opt/sc-vision/etc/calib.json >/dev/null 2>&1
for d in stock $urbs; do row "pv-whole-$d"; row "pv-stream-$d"; done
printf '%-18s ' scv
grep -E "^(first USB packet -> pose|TAIL last packet -> pose)" "$OUT/scv.table" | awk '{printf "%s %s/%s/%s | ", $1" "$2, $(NF-2), $(NF-1), $NF}'
awk '{printf "proc %s%% of a core\n", $4}' "$OUT/scv.cpu"
