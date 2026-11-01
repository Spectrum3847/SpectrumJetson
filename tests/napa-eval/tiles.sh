#!/usr/bin/env bash
# Flat-tile share on real field frames (the GPU idea, README): every 2nd frame of every TXMAN1 session through
# napa_replay_stats --tile-stats, ON THE JETSON. Then: python3 tests/napa-eval/tiles.py OUT_DIR
#   tests/napa-eval/tiles.sh [DATA] [OUT_DIR]      30 min deadline (prints TIMEOUT)
set -uo pipefail
WORK=${WORK:-$HOME/build/napa-eval}
DATA=${1:-/data/scratch/txman1}
OUT=${2:-$WORK/tiles}
mkdir -p "$OUT"
end=$((SECONDS + 1800))
for s in "$DATA"/replay/TXMAN1_*/sessions/*/; do
  s=${s%/}
  ((SECONDS < end)) || { echo "TIMEOUT: tiles.sh past 30 min" >&2; exit 1; }
  nice -n 19 timeout 900 "$WORK/napa_replay_stats" "$s" --backend napa --every 2 --parallel 4 --tile-stats \
    --times "$OUT/$(basename "$s").csv" >/dev/null || echo "TIMEOUT/failure: $s" >&2
done
