#!/usr/bin/env bash
# Builds napa_replay ON THE JETSON (or any aarch64/x86-64 Linux with libjpeg-turbo): fetches NAPA (GPLv3,
# github.com/zwatx/NAPA, pinned commit) and uses AprilTag 3 from ~/build/apriltag-src/apriltag (or fetches it).
#   tests/napa-eval/build.sh [WORK]    WORK default ~/build/napa-eval
# Makes WORK/napa_replay (stock NAPA) and WORK/napa_replay_stats (NAPA with tile counters, --tile-stats).
# Neither changes the installed detector or PhotonVision.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${1:-$HOME/build/napa-eval}
NAPA_COMMIT=de613ad
mkdir -p "$WORK"
cd "$WORK"
[[ -d napa ]] || timeout 300 git clone -q https://github.com/zwatx/NAPA napa
git -C napa checkout -q "$NAPA_COMMIT"
AT=${AT:-$HOME/build/apriltag-src/apriltag}
if [[ ! -f $AT/apriltag.c ]]; then
  [[ -d apriltag ]] || timeout 300 git clone -q https://github.com/AprilRobotics/apriltag apriltag
  AT=$WORK/apriltag
fi
N=napa/src/napa_vision/_native
# Tile counters for --tile-stats: per pyramid level, tiles tested and tiles not flat (threshold != 0).
sed -e 's|^/\* -* threshold \*/|__thread long napa_stat_tot[8], napa_stat_act[8];\nstatic __thread int napa_stat_lvl;\n&|' \
    -e 's/^static int threshold_level(napa_detector \*det, int lw, int lh, int factor) {/&\n    int napa_lvl_ = napa_stat_lvl++ \& 7;/' \
    -e 's/^            tt\[tx\] = t;/&\n            napa_stat_tot[napa_lvl_]++, napa_stat_act[napa_lvl_] += t != 0;/' \
    -e 's/^    det->failed_n = 0;/&\n    napa_stat_lvl = 0;/' "$N/napa_core.c" > napa_core_stats.c
grep -q napa_lvl_ napa_core_stats.c || { echo "stats patch failed" >&2; exit 1; }
CF="-O3 -fno-wrapv"
gcc $CF -c "$N/napa_core.c" -I"$N" -o napa_core.o
gcc $CF -DNAPA_STATS -c napa_core_stats.c -I"$N" -o napa_core_stats.o
AT_SRC=("$AT"/apriltag.c "$AT"/apriltag_quad_thresh.c "$AT"/tag36h11.c "$AT"/common/*.c)
mkdir -p at3
for f in "${AT_SRC[@]}"; do
  o=at3/$(basename "${f%.c}").o
  [[ $o -nt $f ]] || gcc -O3 -std=gnu99 -fPIC -I"$AT" -c "$f" -o "$o"
done
for v in "" _stats; do
  def=""; [[ $v == _stats ]] && def="-DNAPA_STATS"
  g++ -O2 -std=c++17 $def -I"$REPO/detector" -I"$N" -I"$AT" "$HERE/napa_replay.cc" "napa_core$v.o" at3/*.o \
      -ljpeg -lpthread -lm -o "napa_replay$v"
done
echo "built $WORK/napa_replay and $WORK/napa_replay_stats"
