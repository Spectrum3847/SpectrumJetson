#!/usr/bin/env bash
# NAPA and AprilTag 3 (CPU) replays of the TXMAN1 matches, ON THE JETSON, after tests/field-replay/run.sh
# has prepared DATA/replay and build.sh has built napa_replay:
#   tests/napa-eval/run.sh [DATA [VARIANT...]]   DATA default /data/scratch/txman1
# Writes DATA/replay/<match>/out/<variant>/<session>.{csv,log} for judge.py / analyze.py; resumes.
# Accuracy runs only (4 frames at a time, so the logged times are contended: timing is timing.sh).
# Waits (10 s polls, 2 h deadline) until no detector-replay / napa_replay / graph_bench runs and tj < 85 C;
# nice 19. Whole run under a 4 h deadline (prints TIMEOUT).
set -uo pipefail
WORK=${WORK:-$HOME/build/napa-eval}
DATA=${1:-/data/scratch/txman1}
shift || true
if [[ -z ${NAPA_UNDER_TIMEOUT:-} ]]; then
  rc=0
  NAPA_UNDER_TIMEOUT=1 timeout --kill-after=30 14400 "$0" "$DATA" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: napa-eval replays didn't finish in 4 hours" >&2
  exit "$rc"
fi
declare -A OPTS=(
  [napa]="--backend napa --min-tag 32 --hamming 1"      # NAPA's default min_tag_px, our hamming
  [napa22]="--backend napa --min-tag 22 --hamming 1"    # the README's smallest tag
  [napa16]="--backend napa --min-tag 16 --hamming 1"    # stride 1: every pixel
  [napa_h3]="--backend napa --min-tag 16 --hamming 3"   # NAPA's recommended hamming (3, connected errors)
  [napafar]="--backend napafar --base-min 32 --far-min 16"    # detector/napa far search: 32 full frame, 16 crops/sweeps
  [napafar12]="--backend napafar --base-min 32 --far-min 12"  # same with 12 in crops/sweeps
  [at3_d2]="--backend at3 --decimate 2"                 # PhotonVision CPU settings, decimate 2
  [at3_d1]="--backend at3 --decimate 1"                 # PhotonVision's default decimate 1
)
ORDER=(napa napa22 napa16 napa_h3 at3_d2 at3_d1)  # napafar, napafar12: name them
(($#)) && ORDER=("$@")
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
wait_turn() {
  local t
  for _ in $(seq 720); do
    if ! pgrep -x detector-replay >/dev/null && ! pgrep -f graph_bench >/dev/null && ! pgrep -x napa_replay >/dev/null; then
      t=$(tj)
      [[ -z $t ]] && return 0
      awk -v t="$t" 'BEGIN{exit !(t < 85)}' && return 0
    fi
    sleep 10
  done
  echo "TIMEOUT: no turn on the Jetson in 2 h" >&2
  return 1
}
for v in "${ORDER[@]}"; do
  [[ -n ${OPTS[$v]:-} ]] || { echo "unknown variant $v" >&2; exit 2; }
  for m in "$DATA"/replay/TXMAN1_*; do
    mkdir -p "$m/out/$v"
    for s in "$m"/sessions/*/; do
      s=${s%/}; name=$(basename "$s")
      [[ -s $m/out/$v/$name.log ]] && grep -q '^Time:' "$m/out/$v/$name.log" && continue
      wait_turn || exit 1
      echo "$(date +%T) $v $(basename "$m") $name"
      # shellcheck disable=SC2086
      nice -n 19 timeout 3600 "$WORK/napa_replay" "$s" ${OPTS[$v]} --parallel 4 --out "$m/out/$v/$name.csv" \
        >"$m/out/$v/$name.log" 2>&1 || { echo "TIMEOUT/failure: $v $name (see log)" >&2; rm -f "$m/out/$v/$name.log"; }
    done
  done
done
echo "done"
