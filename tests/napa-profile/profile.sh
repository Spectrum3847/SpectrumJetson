#!/usr/bin/env bash
# NAPA stage timers and perf call graphs on real TXMAN1 frames, ON THE JETSON, after build.sh:
#   tests/napa-profile/profile.sh [DATA] [OUT] [CASE...]      then: python3 tests/napa-profile/prof.py OUT
# Frames: as tests/napa-eval/timing.sh (Q17 session 2 + Q24, every 4th frame, 4,517 frames; far case every
# frame, its tracking needs consecutive frames). One thread, taskset to cores 0-3. Cases:
#   prof32, prof16, proffar   napa_replay_prof --profile (stage ns, per-level ns and candidate counts per frame)
#   perf32, perf16, perffar   perf record -g (frame pointers) of napa_replay (-g -O3), Q24 sessions only
# Waits until no photonvision.jar / detector-replay / napa_replay / graph_bench and tj < 85 C (60 s polls,
# 4 h deadline); the whole run has a 2 h deadline after that. Prints TIMEOUT on either.
set -uo pipefail
WORK=${WORK:-$HOME/build/napa-profile}
DATA=${1:-/data/scratch/txman1}
OUT=${2:-$WORK/profile}
PERF=${PERF:-$(ls /usr/lib/linux-*tools*/perf 2>/dev/null | head -1)}
if [[ -z ${NAPA_UNDER_TIMEOUT:-} ]]; then
  rc=0
  NAPA_UNDER_TIMEOUT=1 timeout --kill-after=30 21600 "$0" "$DATA" "$OUT" "${@:3}" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: napa-profile didn't finish" >&2
  exit "$rc"
fi
mkdir -p "$OUT"
SESSIONS=("$DATA"/replay/TXMAN1_Q17/sessions/0002_* "$DATA"/replay/TXMAN1_Q24/sessions/*)
declare -A CASES=(
  [prof32]="--backend napa --min-tag 32 --every 4"
  [prof16]="--backend napa --min-tag 16 --every 4"
  [proffar]="--backend napafar --base-min 32 --far-min 16 --every 1"
  [perf32]="--backend napa --min-tag 32 --every 1"
  [perf16]="--backend napa --min-tag 16 --every 2"
  [perffar]="--backend napafar --base-min 32 --far-min 16 --every 1"
)
ORDER=(prof32 prof16 proffar perf32 perf16 perffar)
(($# > 2)) && ORDER=("${@:3}")
tj() { timeout 5 tegrastats --interval 1000 2>/dev/null | head -1 | grep -o 'tj@[0-9.]*' | cut -d@ -f2; }
busy() { pgrep -f photonvision.jar >/dev/null || pgrep -x detector-replay >/dev/null || pgrep -x napa_replay >/dev/null ||
  pgrep -f "napa_replay_(prof|exp) " >/dev/null || pgrep -f graph_bench >/dev/null; }
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
for c in "${ORDER[@]}"; do
  wait_turn
  echo "$(date +%T) $c tj $(tj)"
  case $c in
    prof*)
      : >"$OUT/$c.csv"
      for s in "${SESSIONS[@]}"; do
        # shellcheck disable=SC2086
        taskset -c 0-3 timeout 1200 "$WORK/napa_replay_prof" "$s" ${CASES[$c]} --profile "$OUT/$c.tmp" >/dev/null ||
          echo "TIMEOUT/failure: $c $s" >&2
        if [[ -s $OUT/$c.csv ]]; then tail -n +2 "$OUT/$c.tmp" >>"$OUT/$c.csv"; else cat "$OUT/$c.tmp" >"$OUT/$c.csv"; fi
      done
      rm -f "$OUT/$c.tmp" ;;
    perf*)
      [[ -x $PERF ]] || { echo "no perf binary" >&2; continue; }
      for s in "$DATA"/replay/TXMAN1_Q24/sessions/*; do
        # shellcheck disable=SC2086
        taskset -c 0-3 timeout 1200 "$PERF" record -q -F 2000 -g -o "$OUT/$c-$(basename "$s").data" \
          "$WORK/napa_replay" "$s" ${CASES[$c]} >/dev/null 2>&1 || echo "TIMEOUT/failure: $c $s" >&2
      done
      for f in "$OUT/$c"-*.data; do
        timeout 600 "$PERF" report -q -i "$f" --no-children --sort symbol --dsos napa_replay --percentage relative 2>/dev/null |
          grep -v '^$' | head -40 >"${f%.data}.flat.txt"
        timeout 600 "$PERF" report -q -i "$f" --children --sort symbol --dsos napa_replay --percentage relative -g none 2>/dev/null |
          grep -v '^$' | head -40 >"${f%.data}.children.txt"
        timeout 900 "$PERF" annotate -i "$f" --stdio -l napa_detect 2>/dev/null | head -400 >"${f%.data}.annotate.txt"
      done ;;
  esac
done
echo "tj at end $(tj)"
