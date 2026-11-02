#!/usr/bin/env bash
# detector-20's early check on all TXMAN1 sessions, ON THE JETSON, with the installed settings (mwbd 20,
# mse 10, far search on, CPU RefineEdges = ladder level 3, calibrations):
#   tests/early-reject/run.sh [VARIANT...]     (default: all below)   DATA=/data/scratch/txman1
# Writes OUT/<variant>/<match>/<session>.{det.csv,stats.csv,log}; resumes. Variants ending in _nocal replay
# without the calibrations (the uncalibrated-camera path: RefineEdges without undistortion).
# Waits (10 s polls) for no PhotonVision, no other replay and tj < 85 C before each session; nice 19;
# 30 min per session; whole run under a 6 h deadline (prints TIMEOUT).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${DATA:-/data/scratch/txman1}
OUT=${OUT:-$HOME/build/early-reject/out}
BIN=$HOME/build/early-reject/build/detector-replay
if [[ -z ${ER_UNDER_TIMEOUT:-} ]]; then
  rc=0
  ER_UNDER_TIMEOUT=1 timeout --kill-after=30 21600 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: early-reject replays didn't finish in 6 hours" >&2
  exit "$rc"
fi
declare -A OPTS=(
  [base]=""
  [s0]="--early-reject 0"
  [s1]="--early-reject 1"
  [s2]="--early-reject 2"
  [s3]="--early-reject 3"
  [s4]="--early-reject 4"
  [b2]="--early-reject 2 --early-mode border"
  [b4]="--early-reject 4 --early-mode border"
  [k2]="--early-reject 2 --early-mode scales"
  [base_nocal]=""
  [s2_nocal]="--early-reject 2"
  [s3_nocal]="--early-reject 3"
)
ORDER=(base s2 s1 s3 s0 s4 b2 b4 k2 base_nocal s2_nocal s3_nocal)
(($#)) && ORDER=("$@")
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
wait_turn() {
  local t
  for _ in $(seq 1080); do
    if ! pgrep -f photonvision.jar >/dev/null && ! pgrep -x detector-replay >/dev/null && ! pgrep -x napa_replay >/dev/null; then
      t=$(tj); [[ -z $t ]] && return 0
      awk -v t="$t" 'BEGIN{exit !(t < 85)}' && return 0
    fi
    sleep 10
  done
  echo "TIMEOUT: no turn on the Jetson in 3 h" >&2
  return 1
}
for v in "${ORDER[@]}"; do
  [[ -v OPTS[$v] ]] || { echo "unknown variant $v" >&2; exit 2; }
  for s in "$DATA"/replay/TXMAN1_*/sessions/*/; do
    s=${s%/}; m=$(basename "$(dirname "$(dirname "$s")")"); name=$(basename "$s")
    dst=$OUT/$v/$m/$name
    mkdir -p "$(dirname "$dst")"
    [[ -s $dst.log ]] && grep -q '^Time' "$dst.log" && continue
    wait_turn || exit 1
    cal=$(cat "$s/calib.args" 2>/dev/null)
    [[ $v == *_nocal ]] && cal=""
    echo "$(date +%T) $v $m $name"
    # shellcheck disable=SC2086
    nice -n 19 timeout --kill-after=10 1800 "$BIN" "$s" --mwbd 20 --mse 10 --out "$dst.det.csv" \
      --early-stats "$dst.stats.csv" ${OPTS[$v]} $cal >"$dst.log" 2>&1 || echo "TIMEOUT/failure: $v $name (see $dst.log)" >&2
  done
done
echo "done"
