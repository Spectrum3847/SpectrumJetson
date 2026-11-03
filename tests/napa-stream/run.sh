#!/usr/bin/env bash
# Streaming NAPA vs whole-frame NAPA on the TXMAN1 sessions, ON THE JETSON, after build.sh:
#   tests/napa-stream/run.sh identity [DATA]   every session, min16 and far: in-process bit-for-bit compare,
#        and CSVs DATA/replay/<match>/out/{stream16,whole16,streamfar,wholefar}/<session>.csv for
#        tests/napa-profile/same.py (DATA/replay stream16 whole16 must print IDENTICAL)
#   tests/napa-stream/run.sh timing [DATA]     paced replay (8-row bands over 8 ms), one thread on core 3,
#        clocks at full (spectrum-clocks mode full, back to auto after), results in WORK/timing-*.txt/csv
# Waits until no PhotonVision / replay runs and tj < 85 C (10 s polls, 2 h). Whole run under 4 h (TIMEOUT).
set -uo pipefail
WORK=${WORK:-$HOME/build/napa-stream}
MODE=${1:?identity|timing}
DATA=${2:-/data/scratch/txman1}
if [[ -z ${NS_UNDER_TIMEOUT:-} ]]; then
  rc=0
  NS_UNDER_TIMEOUT=1 timeout --kill-after=30 14400 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: napa-stream $MODE didn't finish in 4 hours" >&2
  exit "$rc"
fi
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
wait_turn() {
  local t
  for _ in $(seq 720); do
    if ! pgrep -x detector-replay >/dev/null && ! pgrep -f graph_bench >/dev/null && ! pgrep -x napa_replay >/dev/null &&
      ! pgrep -f photonvision.jar >/dev/null; then
      t=$(tj)
      [[ -z $t ]] && return 0
      awk -v t="$t" 'BEGIN{exit !(t < 85)}' && return 0
    fi
    sleep 10
  done
  echo "TIMEOUT: no turn on the Jetson in 2 h" >&2
  return 1
}
if [[ $MODE == identity ]]; then
  fail=0
  for cfg in min16 far; do
    tag=${cfg/min16/16}
    for m in "$DATA"/replay/TXMAN1_*; do
      mkdir -p "$m/out/stream$tag" "$m/out/whole$tag"
      for s in "$m"/sessions/*/; do
        s=${s%/}; name=$(basename "$s")
        wait_turn || exit 1
        r=$(nice -n 19 timeout 3600 "$WORK/napa_stream_replay" "$s" --config "$cfg" --out "$m/out/stream$tag/$name.csv" \
          --out-whole "$m/out/whole$tag/$name.csv" 2>&1)
        echo "$cfg $(basename "$m") $name: $(echo "$r" | grep -E 'mismatches|IDENTICAL|DIFFERENT|TIMEOUT' | tr '\n' ' ')"
        echo "$r" | grep -q '^IDENTICAL' || fail=1
      done
    done
  done
  [[ $fail == 0 ]] && echo "ALL IDENTICAL" || echo "SOME DIFFERENT"
  exit $fail
fi
# timing
trap 'sudo -n spectrum-clocks mode auto >/dev/null 2>&1' EXIT
for cfg in min16 far; do
  for m in TXMAN1_Q24 TXMAN1_Q17; do
    s=$(ls -d "$DATA/replay/$m/sessions"/*/ | head -1)
    wait_turn || exit 1
    sudo -n spectrum-clocks mode full >/dev/null 2>&1 || echo "warning: could not set clocks full" >&2
    echo "$(date +%T) timing $cfg $m (tj $(tj))"
    taskset -c 3 timeout 3600 "$WORK/napa_stream_replay" "$s" --config "$cfg" --mode timing --every 2 \
      --times "$WORK/timing-$cfg-$m.csv" >"$WORK/timing-$cfg-$m.txt" 2>&1 || echo "failure/TIMEOUT: $cfg $m" >&2
    cat "$WORK/timing-$cfg-$m.txt"
    sudo -n spectrum-clocks mode auto >/dev/null 2>&1
  done
done
echo "done"
