#!/usr/bin/env bash
# Builds napa_stream_replay (streaming vs whole-frame NAPA, patches/napa-03-streaming.patch) ON THE JETSON or
# any aarch64/x86-64 Linux with gcc and libjpeg-turbo:
#   tests/napa-stream/build.sh [WORK]     WORK default ~/build/napa-stream
# CC/CXX/TARGET_ARCH as scripts/jetson/07-build-napa-detector.sh for a compile-only cross check (no libjpeg:
# builds napa_core.o and napa_far.o only), e.g. WPILib's SystemCore toolchain:
#   CC=aarch64-bookworm-linux-gnu-gcc CXX=aarch64-bookworm-linux-gnu-g++ TARGET_ARCH=aarch64 tests/napa-stream/build.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${1:-$HOME/build/napa-stream}
mkdir -p "$WORK"
N=$WORK/napa-src
"$REPO/scripts/jetson/napa-src.sh" "$N"
CC=${CC:-gcc}
CXX=${CXX:-g++}
ARCH=${TARGET_ARCH:-$(uname -m)}
case $ARCH in
  aarch64) MF="-march=armv8-a+simd" ;;
  x86_64) MF="-msse4.1" ;;
  *) MF="" ;;
esac
CF="-O3 -fno-wrapv $MF"
timeout 300 $CC $CF -std=gnu99 -Wall -Wextra -c "$N/napa_core.c" -I"$N" -o "$WORK/napa_core.o"
timeout 300 $CXX $CF -std=c++17 -Wall -Wextra -c "$REPO/detector/napa/napa_far.cc" -I"$N" -o "$WORK/napa_far.o"
if [[ $ARCH != "$(uname -m)" ]]; then
  echo "cross compile check for $ARCH passed ($WORK/napa_core.o, napa_far.o)"
  exit 0
fi
timeout 300 $CXX -O2 -std=c++17 -Wall -I"$REPO/detector" -I"$N" "$HERE/napa_stream_replay.cc" "$WORK/napa_core.o" \
  "$WORK/napa_far.o" -ljpeg -lpthread -lm -o "$WORK/napa_stream_replay"
timeout 300 $CXX -O2 -std=c++17 -Wall "$REPO/detector/napa/napa_test.cc" "$WORK/napa_far.o" "$WORK/napa_core.o" \
  -I"$N" -I"$REPO/detector/napa" -lm -lpthread -o "$WORK/napa_test"
timeout 60 "$WORK/napa_test" >/dev/null
echo "built $WORK/napa_stream_replay (napa_test passes)"
