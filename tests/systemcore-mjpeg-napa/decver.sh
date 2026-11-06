#!/usr/bin/env bash
# Verify builder decoder builds (scmn_dec_* libraries) against libjpeg-turbo, ON THE PI: luma identity + CPU per
# session for each library, then fuzz the last one. Holds /tmp/camera.lock (keeps live runs off the CPU).
#   decver.sh LIB.so [LIB2.so ...]
set -uo pipefail
B=${SCMN_BIN:-$HOME/bench/bin}
D=$HOME/bench
SESS=${SESS:-"data/live2 data/synth422 data/cd-ctrl data/sweep/e2_g128 data/sweep/e50_g32 data/sweep/e5_g32 data/txman1/Q24"}
exec 9>/tmp/camera.lock
flock -w 600 9 || { echo "camera lock busy" >&2; exit 1; }
for s in $SESS; do
  printf '%-40s' "$s"
  for L in "$@"; do
    r=$(SCMN_BUILDER_LIB=$L "$B/scmn_bench" decode "$D/$s" --cpu 3 --dec builder 2>&1 | grep scvision)
    p=$(echo "$r" | sed -E 's/.*p50\/p95\/p99 ([0-9.]+) \/ ([0-9.]+) \/ ([0-9.]+).*/\1 \/ \2 \/ \3/')
    d=$(echo "$r" | grep -o '[0-9]* frames differ' | cut -d' ' -f1)
    printf '  %s: %s ms, %s differ' "$(basename "$L" .so)" "$p" "$d"
  done
  echo
done
last=${*: -1}
SCMN_BUILDER_LIB=$last "$B/scmn_bench" fuzz "$D/data/live2" --dec builder --max-frames 240 2>&1 | grep -E "FUZZ|CRASH|HANG"
SCMN_BUILDER_LIB=$last "$B/scmn_bench" fused "$D/data/sweep/e2_g128" --dec builder --chunk 3072 --cpu 3 2>&1 |
  grep -E "scvision|frames differ|FUSED" | sed 's/(mean.*n [0-9]*)//'
