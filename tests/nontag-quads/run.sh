#!/usr/bin/env bash
# Per-frame quad counts on all TXMAN1 sessions with the instrumented detector-replay (build.sh), ON THE
# JETSON, settings as installed (mwbd 20, mse 10, CPU RefineEdges, calibrations), far search off:
#   tests/nontag-quads/run.sh [DATA [OUT]]    DATA /data/scratch/txman1 (tests/field-replay/run.sh prepared it)
# Writes OUT/<match>/<session>.qs.csv (instrument.py's columns) and .log (detector-replay's summary).
# Waits for no other replay and tj < 85 C; one session at a time, nice 19; 3 h deadline (prints TIMEOUT).
set -uo pipefail
DATA=${1:-/data/scratch/txman1}
OUT=${2:-$HOME/build/nontag-quads/out}
BIN=$HOME/build/nontag-quads/build/detector-replay
if [[ -z ${QS_UNDER_TIMEOUT:-} ]]; then
  rc=0
  QS_UNDER_TIMEOUT=1 timeout --kill-after=30 10800 "$0" "$DATA" "$OUT" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: quad counts didn't finish in 3 hours" >&2
  exit "$rc"
fi
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
for m in "$DATA"/replay/TXMAN1_*; do
  mkdir -p "$OUT/$(basename "$m")"
  for s in "$m"/sessions/*/; do
    s=${s%/}; name=$(basename "$s"); dst=$OUT/$(basename "$m")/$name
    [[ -s $dst.log ]] && grep -q '^Time' "$dst.log" && continue
    for _ in $(seq 360); do
      if ! pgrep -x detector-replay >/dev/null && ! pgrep -x napa_replay >/dev/null; then
        t=$(tj); [[ -z $t ]] && break
        awk -v t="$t" 'BEGIN{exit !(t < 85)}' && break
      fi
      sleep 10
    done
    echo "$(date +%T) $(basename "$m") $name"
    # shellcheck disable=SC2046
    SPECTRUM_QS_OUT=$dst.qs.csv SPECTRUM_QS_EARLY=1 nice -n 19 timeout --kill-after=10 1800 "$BIN" "$s" --off \
      --mwbd 20 --mse 10 --out "$dst.det.csv" $(cat "$s/calib.args" 2>/dev/null) >"$dst.log" 2>&1 ||
      echo "TIMEOUT/failure: $name (see $dst.log)" >&2
  done
done
echo done
