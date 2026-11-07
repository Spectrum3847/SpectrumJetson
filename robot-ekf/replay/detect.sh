#!/usr/bin/env bash
# TagEkf replay, stage 1: TXMAN1 frames -> NAPA (min tag 22) -> full-tag fit -> one CSV of sightings per camera
# recording (tagfit_bench replay --dump: NAPA and fitted corners, both IPPE poses, fit time). Runs on any x86-64 or
# aarch64 Linux with g++ and libjpeg; on the Windows laptop through Docker:
#   robot-ekf/replay/detect.sh docker DATA OUT      (DATA: <match>/<camera>/*.mjpeg, e.g. ~/build/txman1)
#   robot-ekf/replay/detect.sh native DATA OUT      (inside the container, or on Linux)
# ONLY=Q19 detects one match folder. replay/batch.sh runs every TXMAN1 match.
# Calibrations are the cameras' deployed files (calibrations/SJ-TC01 orin-left, SJ-TC02 orin-right); CAL=-refit uses
# the 2026-10-31 refits instead (TC02's deployed model has no valid ray near its edges). The fit uses
# the live defaults (fast float path, lens LUT, warm start with 1 iteration, 2 cold iterations).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
MODE=${1:?usage: detect.sh docker|native DATA OUT}
DATA=$(cd "${2:?DATA}" && pwd)
mkdir -p "${3:?OUT}"
OUT=$(cd "$3" && pwd)
if [[ $MODE == docker ]]; then
  # One image with the compiler, built once (DETECT_IMAGE to override).
  IMAGE=${DETECT_IMAGE:-robot-ekf-detect:24.04}
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq g++ libjpeg-turbo8-dev patch >/dev/null
'       | docker build -q -t "$IMAGE" - >/dev/null
  fi
  # MSYS_NO_PATHCONV: Git Bash would rewrite the container paths
  MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "$REPO" 2>/dev/null || echo "$REPO"):/repo"     -v "$(cygpath -w "$DATA" 2>/dev/null || echo "$DATA"):/data:ro" -v "$(cygpath -w "$OUT" 2>/dev/null || echo "$OUT"):/out"     -e CAL="${CAL:-}" -e ONLY="${ONLY:-}" "$IMAGE" bash /repo/robot-ekf/replay/detect.sh native /data /out
  exit
fi
B=$OUT/build
mkdir -p "$B"
"$REPO/scripts/jetson/napa-src.sh" "$B/napa-src"
S=$REPO/native/sc-vision
CF=(-O2 -Wall -fno-wrapv)
gcc "${CF[@]}" -Wno-unused-parameter -Wno-sign-compare -std=gnu99 -c "$B/napa-src/napa_core.c" -I"$B/napa-src" -o "$B/napa_core.o"
gcc "${CF[@]}" -std=gnu11 -c "$S/src/pose.c" -o "$B/pose.o"
gcc "${CF[@]}" -std=gnu11 -c "$S/src/tagfit.c" -o "$B/tagfit.o"
g++ "${CF[@]}" -std=gnu++2b -I"$S/src" -I"$B/napa-src" "$S/tools/tagfit_bench.cc" "$B/tagfit.o" "$B/pose.o" \
  "$B/napa_core.o" -o "$B/tagfit_bench" -ljpeg -lm
declare -A CALS=([orin-left]=SJ-TC01-1280x800${CAL:-}.json [orin-right]=SJ-TC02-1280x800${CAL:-}.json)
for m in "$DATA"/*/; do
  match=$(basename "$m")
  [[ -z ${ONLY:-} || $match == "$ONLY" ]] || continue
  for cam in orin-left orin-right; do
    for f in "$m$cam"/*.mjpeg; do
      [[ -f $f ]] || continue
      o=$OUT/$match-$cam-$(basename "$f" .mjpeg).dets.csv
      "$B/tagfit_bench" replay "$f" "$REPO/calibrations/${CALS[$cam]}" --min-tag 22 --fast --lut 0 --warm \
        --warm-iters 1 --iters 2 --no-cmp --dump "$o" > "${o%.csv}.log"
      cp "${f%.mjpeg}.csv" "$OUT/$match-$cam-$(basename "$f" .mjpeg).frames.csv"
      echo "$o: $(($(wc -l < "$o") - 1)) sightings"
    done
  done
done
