#!/usr/bin/env bash
# Builds the NAPA profiling replays ON THE JETSON (needs tests/napa-eval/build.sh's AprilTag objects first):
#   tests/napa-profile/build.sh [WORK]     WORK default ~/build/napa-profile
# WORK/napa_replay       as tests/napa-eval (vendored NAPA + patches/napa-*.patch), with -g for perf
# WORK/napa_replay_prof  plus napa-profile.patch, -DNAPA_PROFILE: --profile writes per-stage times and counts
# Trying changes: NAPA_EXPERIMENTS="NAME=a.patch[,b.patch] ..." adds WORK/exp-NAME/napa_replay per entry, each
# with those patches on top of ours (exp.sh runs them).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${1:-$HOME/build/napa-profile}
EVAL=${EVAL:-$HOME/build/napa-eval}
mkdir -p "$WORK"
cd "$WORK"
AT=${AT:-$HOME/build/apriltag-src/apriltag}
[[ -f $AT/apriltag.c ]] || AT=$EVAL/apriltag
ls "$EVAL"/at3/*.o >/dev/null || { echo "run tests/napa-eval/build.sh first (AprilTag objects)" >&2; exit 1; }
CF="-O3 -g -fno-omit-frame-pointer -fno-wrapv"
build() {  # build NAME DEFS SRC_DIR
  local name=$1 defs=$2 src=$3
  timeout 300 gcc $CF $defs -c "$src/napa_core.c" -I"$src" -o "$name-core.o"
  timeout 300 g++ $CF -std=c++17 $defs -c "$REPO/detector/napa/napa_far.cc" -I"$src" -o "$name-far.o"
  timeout 300 g++ -O2 -g -std=c++17 $defs -I"$REPO/detector" -I"$src" -I"$AT" "$REPO/tests/napa-eval/napa_replay.cc" \
    "$name-core.o" "$name-far.o" "$EVAL"/at3/*.o -ljpeg -lpthread -lm -o "$name"
}
"$REPO/scripts/jetson/napa-src.sh" src
build napa_replay "" src
"$REPO/scripts/jetson/napa-src.sh" src-prof "$HERE/napa-profile.patch"
build napa_replay_prof "-DNAPA_PROFILE" src-prof
for e in ${NAPA_EXPERIMENTS:-}; do
  name=${e%%=*}
  IFS=, read -r -a ps <<<"${e#*=}"
  "$REPO/scripts/jetson/napa-src.sh" "src-$name" "${ps[@]}"
  mkdir -p "exp-$name"
  (cd "exp-$name" && build napa_replay "" "../src-$name")
done
echo "built in $WORK"
