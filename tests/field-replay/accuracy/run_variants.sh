#!/usr/bin/env bash
# Accuracy-knob replays (far_replay's --subpix/--edgefit/--cos/... options) of the TXMAN1 matches,
# for judge.py. Run ON THE JETSON after tests/field-replay/run.sh has prepared DATA/replay:
#   tests/field-replay/accuracy/run_variants.sh [DATA [VARIANT...]]   DATA default /data/scratch/txman1
# Writes DATA/replay/<match>/out/<variant>/<session>.{csv,log}; resumes. Only one far_replay on the
# Jetson at a time, ANYONE's: before each replay it waits (10 s polls, 2 h deadline) until no
# far_replay runs and tj < 85 C; nice 19; paused (SIGSTOP) above 92 C until under 85 C.
# Whole run under an 8 h deadline. Doesn't rebuild: build far_replay first.
set -uo pipefail
BUILD=$HOME/build/bos-detector
DATA=${1:-/data/scratch/txman1}
shift || true
if [[ -z ${ACC_UNDER_TIMEOUT:-} ]]; then
  rc=0
  ACC_UNDER_TIMEOUT=1 timeout --kill-after=30 28800 "$0" "$DATA" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: accuracy replays didn't finish in 8 hours" >&2
  exit "$rc"
fi
B="--off --mwbd 20"
declare -A OPTS=(
  [a_sub1]="$B --mse 10 --subpix 1"
  [a_sub2]="$B --mse 10 --subpix 2"
  [a_sub3]="$B --mse 10 --subpix 3"
  [a_edgefit]="$B --mse 10 --edgefit"
  [a_edgefitu]="$B --mse 10 --edgefit-undist"
  [a_edgefitu_sub2]="$B --mse 10 --edgefit-undist --subpix 2"
  [a_norefine]="$B --mse 10 --no-refine-edges"
  [a_base]="$B --mse 10"  # base again, for timings under the same conditions
  [a_mse5]="$B --mse 5"
  [a_mse7.5]="$B --mse 7.5"
  [a_mse2.5_cos0.94]="$B --mse 2.5 --cos 0.94"
  [a_mse10_cos0.94]="$B --mse 10 --cos 0.94"
  [a_mse20_cos0.94]="$B --mse 20 --cos 0.94"
  [a_mse2.5_cos0.996]="$B --mse 2.5 --cos 0.996"
  [a_mse10_cos0.996]="$B --mse 10 --cos 0.996"
  [a_mse20_cos0.996]="$B --mse 20 --cos 0.996"
)
ORDER=(a_base a_mse5 a_mse7.5 a_sub1 a_sub2 a_sub3 a_edgefit a_edgefitu a_edgefitu_sub2 a_norefine
       a_mse10_cos0.94 a_mse10_cos0.996 a_mse2.5_cos0.94 a_mse20_cos0.94 a_mse2.5_cos0.996 a_mse20_cos0.996)
(($#)) && ORDER=("$@")

tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
wait_turn() {  # no far_replay running and tj < 85 C, polled every 10 s, 2 h deadline
  local t
  for _ in $(seq 720); do
    if ! pgrep -f "$BUILD/far_replay" >/dev/null; then
      t=$(tj)
      [[ -z $t ]] && return 0
      awk -v t="$t" 'BEGIN{exit !(t < 85)}' && return 0
    fi
    sleep 10
  done
  echo "TIMEOUT: no turn on the Jetson in 2 h (far_replay busy or tj ${t:-?} C)" >&2
  return 1
}
hot_pause() {
  local pid=$1 kids t stopped=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10; t=$(tj); [[ -z $t ]] && continue
    kids=$(pgrep -P "$pid")
    if ((!stopped)) && awk -v t="$t" 'BEGIN{exit !(t > 92)}'; then
      echo "tj $t C: pausing" >&2; kill -STOP $kids 2>/dev/null; stopped=1
    elif ((stopped)) && awk -v t="$t" 'BEGIN{exit !(t < 85)}'; then
      kill -CONT $kids 2>/dev/null; stopped=0
    fi
  done
}
OUT=$DATA/replay
for v in "${ORDER[@]}"; do
  [[ -n ${OPTS[$v]:-} ]] || { echo "unknown variant $v" >&2; exit 2; }
  for sdir in "$OUT"/TXMAN1_*/sessions/*/; do
    m=$(basename "$(dirname "$(dirname "$sdir")")"); s=$(basename "$sdir")
    dst=$OUT/$m/out/$v
    [[ -s $dst/$s.log ]] && grep -q "^Time:" "$dst/$s.log" && continue
    mkdir -p "$dst"
    wait_turn || exit 3
    # shellcheck disable=SC2046
    nice -n 19 timeout --kill-after=10 1800 "$BUILD/far_replay" "$sdir" --out "$dst/$s.csv" ${OPTS[$v]} \
        $(cat "$sdir/calib.args") >"$dst/$s.log" 2>&1 &
    pid=$!
    hot_pause "$pid"
    if ! wait "$pid"; then echo "TIMEOUT or FAIL: $v $m $s" >&2; rm -f "$dst/$s.csv"; continue; fi
    echo "$v $m $s: $(grep '^Time:' "$dst/$s.log") $(grep '^Refine:' "$dst/$s.log")"
  done
done
