#!/usr/bin/env bash
# A/B of spectrum-rt (USB interrupt on its own core + real-time camera threads) against the
# default, interleaved: off, on, off, on, ... Run ON THE JETSON with PhotonVision running.
# Reads PhotonVision's 10 s "Loop timing ... latency median X p95 Y max Z ms" lines (per camera) and
# prints, for each mode, the median of the windows' medians, of their p95s, and the worst max.
# LOAD=N adds N busy CPU processes at normal priority (stand-in for object detection / a busy
# robot); the cores are where the difference should show.
# Leaves spectrum-rt in the mode it found.
# Usage: [LOAD=N] tests/rt-ab/run.sh [rounds=3] [seconds per run=60]
set -uo pipefail
ROUNDS=${1:-3}
SECS=${2:-60}
LOAD=${LOAD:-0}
was=$(cat /etc/spectrum-rt 2>/dev/null || echo off)
pids=()
cleanup() {
  ((${#pids[@]})) && kill "${pids[@]}" 2>/dev/null
  sudo spectrum-rt "$was" >/dev/null
}
trap cleanup EXIT
for ((i = 0; i < LOAD; i++)); do (while :; do :; done) & pids+=($!); done
echo "spectrum-rt A/B: $ROUNDS rounds x ${SECS}s per mode, LOAD=$LOAD (was $was)"
results=$(mktemp)
for ((r = 1; r <= ROUNDS; r++)); do
  for mode in off on; do
    sudo spectrum-rt "$mode" >/dev/null
    sleep 12   # let a new 10 s window start in the new mode
    since=$(date '+%Y-%m-%d %H:%M:%S')
    sleep "$SECS"
    sudo journalctl -u photonvision --since "$since" --no-pager |
      grep -oE 'latency median [0-9.]+ p95 [0-9.]+ max [0-9.]+' |
      awk -v m="$mode" -v r="$r" '{print m, r, $3, $5, $7}' | tee -a "$results" |
      awk -v m="$mode" -v r="$r" '{n++; md+=$3; p+=$4; if ($5>mx) mx=$5}
        END {if (n) printf "  round %d %-3s %2d windows: median %.2f  p95 %.2f  max %.2f ms\n", r, m, n, md/n, p/n, mx;
             else printf "  round %d %-3s no latency lines (PhotonVision build without them?)\n", r, m}'
  done
done
echo "Overall (median of window medians / median of window p95s / worst max):"
python3 - "$results" <<'EOF'
import sys, statistics, collections
d = collections.defaultdict(lambda: ([], [], []))
for line in open(sys.argv[1]):
    m, _, med, p95, mx = line.split()
    d[m][0].append(float(med)); d[m][1].append(float(p95)); d[m][2].append(float(mx))
for m in ("off", "on"):
    if d[m][0]:
        print(f"  {m:3s}: median {statistics.median(d[m][0]):.2f}  p95 {statistics.median(d[m][1]):.2f}  "
              f"max {max(d[m][2]):.2f} ms  ({len(d[m][0])} windows)")
EOF
rm -f "$results"
