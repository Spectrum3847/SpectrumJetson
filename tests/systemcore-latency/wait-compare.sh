#!/bin/bash
# PhotonVision's stream path on our uvcvideo: the watcher blocking on UVCIOC_SJ_WAIT (kernel/uvcvideo-progress-wait
# .patch) vs polling every 0.1 ms. performance governor (restored), CD settings, min 32. Short runs.
#   wait-compare.sh [SECS] [URB]     default 20 s, urb_packets 2
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/../../scripts/systemcore/uvcvideo-load.sh
secs=${1:-20}
urb=${2:-2}
P=/sys/devices/system/cpu/cpufreq/policy0
orig=$(cat $P/scaling_governor)
echo performance | sudo -n tee $P/scaling_governor >/dev/null
trap 'echo "$orig" | sudo -n tee $P/scaling_governor >/dev/null; "$L" stock >/dev/null; echo "restored: governor $(cat $P/scaling_governor), stock uvcvideo"' EXIT
export OUT=${OUT:-$HOME/shared/latency/wait} KTRACE_PSIZE=1600
mkdir -p "$OUT"
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec"
"$L" urb "$urb"
# shellcheck disable=SC2086
"$HERE/run.sh" pv "$secs" "pv-wait-$urb" $S >/dev/null 2>&1
# shellcheck disable=SC2086
"$HERE/run.sh" pv "$secs" "pv-poll-$urb" $S SPECTRUM_STREAM_WAIT=poll >/dev/null 2>&1
for n in "pv-wait-$urb" "pv-poll-$urb"; do
  printf '%-12s ' "$n"
  grep -E "^(first USB packet -> pose|TAIL last packet -> tags)" "$OUT/$n.table" | awk '{printf "%s %s/%s/%s | ", $1" "$2, $(NF-2), $(NF-1), $NF}'
  awk '{printf "proc %s%% of a core | ", $4}' "$OUT/$n.cpu"
  grep -h -o -E "waiting for bytes by [A-Za-z_ ]+|watcher CPU [0-9.]+ ms/frame" "$OUT/$n.journal" | sort -u | tr '\n' ' '
  echo
done
