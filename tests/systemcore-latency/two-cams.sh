#!/bin/bash
# sc-vision on the Thriftiest (1bcf:28c5) and the Swyft (0bda:3035): each alone, then both at once on separate cores.
# performance governor for the session (restored after). Short runs. Holds /tmp/camera.lock (both cameras).
#   two-cams.sh [SECS] [MINTAG]     default 20 s, min tag 32
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
secs=${1:-20}
m=${2:-32}
BIN=${SC_VISION_BIN:-/opt/sc-vision/bin/sc-vision}
CAL=${CAL:-/opt/sc-vision/etc/calib.json}
OUT=${OUT:-$HOME/shared/latency/twocam}
mkdir -p "$OUT"
P=/sys/devices/system/cpu/cpufreq/policy0
orig=$(cat $P/scaling_governor)
exec 9>/tmp/camera.lock
flock -w 120 9 || { echo "camera busy"; exit 1; }
echo performance | sudo -n tee $P/scaling_governor >/dev/null
trap 'echo "$orig" | sudo -n tee $P/scaling_governor >/dev/null' EXIT
COMMON="--fifo 40 --pkts 2 --min-tag $m --calib $CAL"
TH="--usb 1bcf:28c5 --cpu 3 --exposure 2 --gain 128 --gamma 100 --backlight 0"
SW="--usb 0bda:3035 --cpu 2"
cpu() { sudo -n awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
run() {  # run NAME ARGS... (one sc-vision; prints its table)
  local name=$1; shift
  # shellcheck disable=SC2086
  sudo -n "$BIN" --csv "$OUT/$name.csv" --secs "$secs" "$@" > "$OUT/$name.log" 2>&1
}
# shellcheck disable=SC2086
run th-alone $COMMON $TH
# shellcheck disable=SC2086
run sw-alone $COMMON $SW
# both at once
# shellcheck disable=SC2086
sudo -n "$BIN" --csv "$OUT/th-both.csv" --secs "$secs" $COMMON $TH > "$OUT/th-both.log" 2>&1 &
p1=$!
# shellcheck disable=SC2086
sudo -n "$BIN" --csv "$OUT/sw-both.csv" --secs "$secs" $COMMON $SW > "$OUT/sw-both.log" 2>&1 &
p2=$!
wait $p1 $p2
for n in th-alone sw-alone th-both sw-both; do
  ex=0.2; [[ $n == sw* ]] && ex=1.0
  printf '== %s: %s\n' "$n" "$(grep -o 'alt [0-9]* ([0-9]* B/uframe)' "$OUT/$n.log")"
  python3 "$HERE/native_analyze.py" "$OUT/$n.csv" --exposure-ms $ex |
    grep -E "frames in|^first USB packet -> pose|^TAIL last packet -> pose|^first -> last|vision thread CPU|frames with a tag"
done
