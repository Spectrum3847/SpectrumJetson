#!/usr/bin/env bash
# A/B of NAPA speed experiments ON THE JETSON, after build.sh with NAPA_EXPERIMENTS (WORK/exp-NAME/):
#   tests/napa-profile/exp.sh [DATA] NAME...
# 1. Accuracy replays of all 13 TXMAN1 sessions as tests/napa-eval/run.sh: variants napa16_NAME and
#    napafar_NAME (out/<variant>/), then same.py against napa16_s2 / napafar_s2 (the unchanged build): an
#    experiment must print IDENTICAL.
# 2. Timing as tests/napa-eval/timing.sh (napa_t1, napa16_t1, napafar_t1), the unchanged build and each
#    experiment alternating, ROUNDS (2) times, into WORK/timing-ab/<round>/<build>/.
# Waits for no photonvision.jar / detector-replay / napa_replay / graph_bench and tj < 85 C before each
# step (60 s polls, 4 h deadline); 4 h for the whole run. Prints TIMEOUT.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/build/napa-profile}
DATA=${1:-/data/scratch/txman1}
shift
ROUNDS=${ROUNDS:-2}
if [[ -z ${NAPA_EXP_UNDER_TIMEOUT:-} ]]; then
  rc=0
  NAPA_EXP_UNDER_TIMEOUT=1 timeout --kill-after=30 28800 "$0" "$DATA" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: exp.sh didn't finish" >&2
  exit "$rc"
fi
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
busy() { pgrep -f photonvision.jar >/dev/null || pgrep -x detector-replay >/dev/null || pgrep -x napa_replay >/dev/null ||
  pgrep -f graph_bench >/dev/null; }
wait_turn() {
  local t
  for _ in $(seq 240); do
    if ! busy; then
      t=$(tj); [[ -z $t ]] && return 0
      awk -v t="$t" 'BEGIN{exit !(t < 85)}' && return 0
    fi
    sleep 60
  done
  echo "TIMEOUT: no turn on the Jetson in 4 h" >&2
  exit 1
}
EVAL=$HERE/../napa-eval
for n in "$@"; do
  [[ -x $WORK/exp-$n/napa_replay ]] || { echo "no $WORK/exp-$n/napa_replay (build.sh NAPA_EXPERIMENTS)" >&2; exit 2; }
  wait_turn
  # run.sh variants napa16_s2 / napafar_s2 with this build's binary, written as napa16_$n / napafar_$n.
  for v in napa16 napafar; do
    for m in "$DATA"/replay/TXMAN1_*; do
      mkdir -p "$m/out/${v}_$n"
      for s in "$m"/sessions/*/; do
        s=${s%/}; name=$(basename "$s")
        [[ -s $m/out/${v}_$n/$name.log ]] && grep -q '^Time:' "$m/out/${v}_$n/$name.log" && continue
        wait_turn
        if [[ $v == napa16 ]]; then o="--backend napa --min-tag 16 --hamming 1"; else o="--backend napafar --base-min 32 --far-min 16"; fi
        # shellcheck disable=SC2086
        nice -n 19 timeout 3600 "$WORK/exp-$n/napa_replay" "$s" $o --parallel 4 --out "$m/out/${v}_$n/$name.csv" \
          >"$m/out/${v}_$n/$name.log" 2>&1 || { echo "TIMEOUT/failure: $v $n $name" >&2; rm -f "$m/out/${v}_$n/$name.log"; }
      done
    done
    python3 "$HERE/same.py" "$DATA/replay" "${v}_s2" "${v}_$n"
  done
done
mkdir -p "$WORK/exp-base"
ln -sf "$WORK/napa_replay" "$WORK/exp-base/napa_replay"
for r in $(seq "$ROUNDS"); do
  for n in base "$@"; do
    wait_turn
    echo "$(date +%T) timing round $r $n tj $(tj)"
    # shellcheck disable=SC2097,SC2098  # timing.sh gets the per-experiment WORK; the output path uses ours
    WORK=$WORK/exp-$n "$EVAL/timing.sh" "$DATA" "$WORK/timing-ab/$r/$n" napa_t1 napa16_t1 napafar_t1 >/dev/null 2>&1 ||
      echo "timing failure: $n round $r" >&2
  done
done
python3 "$HERE/abtime.py" "$WORK/timing-ab"
echo "exp done"
