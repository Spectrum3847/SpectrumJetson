#!/usr/bin/env bash
# Builds the SystemCore MJPEG + NAPA bench for the Pi (aarch64, LimelightOS SystemCore has no compiler):
# cross with WPILib's SystemCore toolchain from Git Bash on Windows (default) or any Linux with one.
#   tests/systemcore-mjpeg-napa/build.sh [WORK]          WORK default ~/build/scmn
#   CXX=... CC=... to use another toolchain; CFLAGS_EXTRA="-mcpu=cortex-a76" to try tuning.
# Builds: scmn_bench (bench.cc), napa_stream_replay (tests/napa-stream), napa_test, scmn_live (live.c),
# scmn_prof (prof.c). NAPA is built exactly as scripts/jetson/07-build-napa-detector.sh does
# (napa-src.sh: third_party/napa + patches/napa-*.patch, -O3 -fno-wrapv -march=armv8-a+simd).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${1:-$HOME/build/scmn}
TC=${SCMN_TOOLCHAIN:-/c/Users/Public/wpilib/2027_alpha7/systemcore/bin/aarch64-systemcore2027-linux-gnu}
CC=${CC:-$TC-gcc}
CXX=${CXX:-$TC-g++}
mkdir -p "$WORK"
N=$WORK/napa-src
# SCMN_NAPA_EXTRA: extra patches after ours (e.g. prototypes/napa-04-stream-readahead.patch)
# shellcheck disable=SC2086
"$REPO/scripts/jetson/napa-src.sh" "$N" ${SCMN_NAPA_EXTRA:-}
MF="-march=armv8-a+simd ${CFLAGS_EXTRA:-}"
CF="-O3 -g -fno-wrapv $MF"
"$CC" $CF -std=gnu99 -Wall -Wextra -c "$N/napa_core.c" -I"$N" -o "$WORK/napa_core.o"
"$CXX" $CF -std=c++17 -Wall -Wextra -c "$REPO/detector/napa/napa_far.cc" -I"$N" -o "$WORK/napa_far.o"
"$CXX" -O2 -g -std=c++17 -Wall -Wextra -I"$REPO/detector" -I"$N" "$HERE/bench.cc" "$WORK/napa_core.o" "$WORK/napa_far.o" \
  -ljpeg -lturbojpeg -ldl -lpthread -lm -o "$WORK/scmn_bench"
"$CXX" -O2 -g -std=c++17 -Wall -I"$REPO/detector" -I"$N" "$REPO/tests/napa-stream/napa_stream_replay.cc" \
  "$WORK/napa_core.o" "$WORK/napa_far.o" -ljpeg -lpthread -lm -o "$WORK/napa_stream_replay"
"$CXX" -O2 -std=c++17 -Wall "$REPO/detector/napa/napa_test.cc" "$WORK/napa_far.o" "$WORK/napa_core.o" \
  -I"$N" -I"$REPO/detector/napa" -lm -lpthread -o "$WORK/napa_test"
"$CXX" -O2 -g -std=c++17 -Wall -Wextra -I"$REPO/detector" -I"$N" "$HERE/live.cc" "$WORK/napa_core.o" "$WORK/napa_far.o" \
  -ljpeg -lpthread -lm -o "$WORK/scmn_live"
[[ -f $HERE/prof.c ]] && "$CC" -O2 -g -std=gnu11 -Wall -Wextra "$HERE/prof.c" -o "$WORK/scmn_prof"
echo "built in $WORK: $(cd "$WORK" && ls scmn_* napa_stream_replay napa_test | tr '\n' ' ')"
