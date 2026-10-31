#!/usr/bin/env bash
# Field replay: TXMAN1 match recordings through detector-replay with each detector variant, then every
# sighting checked against the robot's logged pose (analyze.py; RESULTS.md has the findings).
# Run ON THE JETSON, with the matches downloaded from robotlog into DATA/<match>/:
#   tests/field-replay/run.sh [DATA [VARIANT...]]     DATA default /data/scratch/txman1
# Writes DATA/replay/<match>/ (prep.py's tables, out/<variant>/<session>.{csv,log}) and
# DATA/replay/report.txt. Resumes: a variant's session already replayed is skipped.
# One replay at a time, at nice 19, under a timeout, and only once the Jetson is cool (the hottest
# sensor, tj, under 85 C: it's fanless, and PhotonVision's thermal guard caps the cameras when
# hot); the whole run under an 8 h deadline.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$HOME/build/gpu-detector
DATA=${1:-/data/scratch/txman1}
shift || true
if [[ -z ${FIELD_REPLAY_UNDER_TIMEOUT:-} ]]; then
  rc=0
  FIELD_REPLAY_UNDER_TIMEOUT=1 timeout --kill-after=30 28800 "$0" "$DATA" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the field replay didn't finish in 8 hours" >&2
  exit "$rc"
fi

# Variants: name and detector-replay options. base = what runs now (mwbd 20, mse 10, no far search).
declare -A OPTS=(
  [base]="--off --mwbd 20 --mse 10"
  [mse2.5]="--off --mwbd 20 --mse 2.5"
  [mse15]="--off --mwbd 20 --mse 15"
  [mse20]="--off --mwbd 20 --mse 20"
  [mwbd5]="--off --mwbd 5 --mse 10"
  [mwbd10]="--off --mwbd 10 --mse 10"
  [mwbd30]="--off --mwbd 30 --mse 10"
  [mcp50]="--off --mwbd 20 --mse 10 --mcp 50"
  [mcp100]="--off --mwbd 20 --mse 10 --mcp 100"
  [fullres]="--off --mwbd 20 --mse 10 --fullres"
  [far]="--mwbd 20 --mse 10"
  [half]="--off --mwbd 20 --mse 10 --half"
)
ORDER=(base mse2.5 mse15 mse20 half fullres far mwbd5 mwbd10 mwbd30 mcp50 mcp100)
(($#)) && ORDER=("$@")

if ! nice cmake --build "$BUILD" --target detector-replay --parallel 3 >/tmp/field-replay-build.log 2>&1; then
  tail -20 /tmp/field-replay-build.log; echo "FAIL: detector-replay didn't build" >&2; exit 2
fi

# Waits (up to 30 min) until tj is under 85 C. tegrastats prints e.g. "tj@84.5C".
wait_cool() {
  local t
  for _ in $(seq 180); do
    t=$(timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2)
    [[ -z $t ]] && return 0
    awk -v t="$t" 'BEGIN{exit !(t < 85)}' && return 0
    sleep 10
  done
  echo "TIMEOUT: tj still ${t} C after 30 min; stopping" >&2
  return 1
}

# While a replay runs: pause it (SIGSTOP) when tj > 92 C, resume under 85 C.
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
hot_pause() {
  local pid=$1 kids t stopped=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10; t=$(tj); [[ -z $t ]] && continue
    kids=$(pgrep -P "$pid")
    if ((!stopped)) && awk -v t="$t" 'BEGIN{exit !(t > 92)}'; then
      echo "tj $t C: pausing the replay" >&2; kill -STOP $kids 2>/dev/null; stopped=1
    elif ((stopped)) && awk -v t="$t" 'BEGIN{exit !(t < 85)}'; then
      kill -CONT $kids 2>/dev/null; stopped=0
    fi
  done
}

OUT=$DATA/replay
for src in "$DATA"/TXMAN1_*/; do
  m=$(basename "$src")
  [[ -f $OUT/$m/robot.npz ]] || nice -n 19 python3 "$HERE/prep.py" "$src" "$OUT/$m" || exit 1
done
for v in "${ORDER[@]}"; do
  [[ -n ${OPTS[$v]:-} ]] || { echo "unknown variant $v" >&2; exit 2; }
  for sdir in "$OUT"/TXMAN1_*/sessions/*/; do
    m=$(basename "$(dirname "$(dirname "$sdir")")")
    s=$(basename "$sdir")
    dst=$OUT/$m/out/$v
    [[ -s $dst/$s.log ]] && grep -q "^Time:" "$dst/$s.log" && continue
    mkdir -p "$dst"
    wait_cool || exit 3
    # shellcheck disable=SC2046
    nice -n 19 timeout --kill-after=10 1800 "$BUILD/detector-replay" "$sdir" --out "$dst/$s.csv" ${OPTS[$v]} \
        $(cat "$sdir/calib.args") >"$dst/$s.log" 2>&1 &
    pid=$!
    hot_pause "$pid"
    if ! wait "$pid"; then
      echo "TIMEOUT or FAIL: $v $m $s (see $dst/$s.log)" >&2
      rm -f "$dst/$s.csv"
      continue
    fi
    echo "$v $m $s: $(grep '^Time:' "$dst/$s.log")"
  done
done
nice -n 19 timeout 3600 python3 "$HERE/analyze.py" "$OUT" --json "$OUT/report.json" >"$OUT/report.txt" 2>&1 \
  || echo "TIMEOUT or FAIL: analyze.py (see $OUT/report.txt)" >&2
echo "Report: $OUT/report.txt"
