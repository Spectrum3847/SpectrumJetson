#!/usr/bin/env bash
# Per-frame CPU detect time, NAPA vs AprilTag 3, ON THE JETSON, pinned to 4 cores (the SystemCore's CM5
# has 4 Cortex-A76): every 4th frame of TXMAN1 Q17 (session 2) and Q24 (all), 1280x800.
#   tests/napa-eval/timing.sh [DATA] [OUT_DIR] [CASE...]     then: python3 tests/napa-eval/timing.py OUT_DIR
# Clocks should be at full (sudo spectrum-clocks mode full; mode auto after). Waits for no other replay and
# tj < 85 C before each case; 1 h deadline (prints TIMEOUT). Cases:
#   <det>_t1   one frame at a time, one thread          (latency, one camera)
#   at3_*_t4   one frame at a time, AprilTag's 4 threads (latency, one camera, 4 cores)
#   <det>_p4   4 frames at once, one thread each        (4 cameras sharing 4 cores: latency and throughput)
set -uo pipefail
WORK=${WORK:-$HOME/build/napa-eval}
DATA=${1:-/data/scratch/txman1}
OUT=${2:-$WORK/timing}
if [[ -z ${NAPA_UNDER_TIMEOUT:-} ]]; then
  rc=0
  NAPA_UNDER_TIMEOUT=1 timeout --kill-after=30 3600 "$0" "$DATA" "$OUT" "${@:3}" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: timing didn't finish in 1 hour" >&2
  exit "$rc"
fi
mkdir -p "$OUT"
SESSIONS=("$DATA"/replay/TXMAN1_Q17/sessions/0002_* "$DATA"/replay/TXMAN1_Q24/sessions/*)
declare -A CASES=(
  [napa_t1]="--backend napa --min-tag 32"
  [napa_p4]="--backend napa --min-tag 32 --parallel 4"
  [napa16_t1]="--backend napa --min-tag 16"
  [napa16_p4]="--backend napa --min-tag 16 --parallel 4"
  [at3_d2_t1]="--backend at3 --decimate 2 --nthreads 1"
  [at3_d2_t4]="--backend at3 --decimate 2 --nthreads 4"
  [at3_d2_p4]="--backend at3 --decimate 2 --nthreads 1 --parallel 4"
  [at3_d1_t4]="--backend at3 --decimate 1 --nthreads 4"
  # detector/napa far search: every frame (its tracking and sweep schedule run on the recording's clock)
  [napafar_t1]="--backend napafar --base-min 32 --far-min 16 --every 1"
  [napafar12_t1]="--backend napafar --base-min 32 --far-min 12 --every 1"
)
ORDER=(napa_t1 napa_p4 napa16_t1 napa16_p4 at3_d2_t1 at3_d2_t4 at3_d2_p4 at3_d1_t4)
(($# > 2)) && ORDER=("${@:3}")   # cases to run, e.g. napafar_t1 napafar12_t1
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
for c in "${ORDER[@]}"; do
  for _ in $(seq 360); do
    if ! pgrep -x detector-replay >/dev/null && ! pgrep -x napa_replay >/dev/null && ! pgrep -f graph_bench >/dev/null; then
      t=$(tj); [[ -z $t ]] && break
      awk -v t="$t" 'BEGIN{exit !(t < 80)}' && break
    fi
    sleep 10
  done
  echo "$(date +%T) $c tj $(tj)"
  : >"$OUT/$c.csv"
  for s in "${SESSIONS[@]}"; do
    # shellcheck disable=SC2086
    taskset -c 0-3 timeout 900 "$WORK/napa_replay" "$s" --every 4 ${CASES[$c]} --times "$OUT/$c.tmp" >/dev/null ||
      echo "TIMEOUT/failure: $c $s" >&2
    if [[ -s $OUT/$c.csv ]]; then tail -n +2 "$OUT/$c.tmp" >>"$OUT/$c.csv"; else cat "$OUT/$c.tmp" >"$OUT/$c.csv"; fi
  done
  rm -f "$OUT/$c.tmp"
done
echo "tj at end $(tj)"
