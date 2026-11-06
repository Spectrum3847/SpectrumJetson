#!/usr/bin/env bash
# Build sc-vision (native/sc-vision) for the SystemCore with WPILib's SystemCore cross toolchain, on the laptop.
#   native/sc-vision/build.sh [OUT]       OUT default ~/builder/sc-vision
# Targets:
#   sc-vision          the app (user-space UVC -> mjdec -> streaming NAPA -> IPPE pose -> publish + CSV)
#   mjdec_bench        decoder identity + speed vs libjpeg-turbo
#   libscvision-dec.so the decoder behind the tester's scmn_dec_* ABI
# NAPA: third_party/napa + patches/napa-*.patch (scripts/jetson/napa-src.sh). -mcpu=cortex-a76: the SystemCore's
# core (Raspberry Pi 5 / CM5). NT=1 links the NetworkTables publisher (needs ntcore headers + libs: NT_INC, NT_LIB).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=${1:-$HOME/builder/sc-vision}
# shellcheck source=scripts/systemcore/toolchain.sh
. "$REPO/scripts/systemcore/toolchain.sh"
mkdir -p "$OUT"
"$REPO/scripts/jetson/napa-src.sh" "$OUT/napa-src"
CF=(-O3 -mcpu=cortex-a76 -fno-plt -Wall -Wextra -fPIC)
"$SC_CC" "${CF[@]}" -std=gnu11 -c "$HERE/src/mjdec.c" -o "$OUT/mjdec.o"
"$SC_CC" "${CF[@]}" -std=gnu11 -c "$HERE/src/uvc_usb.c" -o "$OUT/uvc_usb.o"
"$SC_CC" "${CF[@]}" -std=gnu11 -c "$HERE/src/pose.c" -o "$OUT/pose.o"
"$SC_CC" "${CF[@]}" -Wno-unused-parameter -Wno-sign-compare -std=gnu99 -fvisibility=hidden -fno-wrapv \
  -c "$OUT/napa-src/napa_core.c" -I"$OUT/napa-src" -o "$OUT/napa_core.o"
"$SC_CC" "${CF[@]}" -std=gnu11 "$HERE/tools/mjdec_bench.c" "$OUT/mjdec.o" -o "$OUT/mjdec_bench" -ljpeg
"$SC_CC" "${CF[@]}" -std=gnu11 -shared -Wl,-z,defs "$HERE/tools/scmn_adapter.c" "$OUT/mjdec.o" \
  -o "$OUT/libscvision-dec.so"
PUB=("$HERE/src/nt_pub_stub.cc")
LIBS=()
if [[ ${NT:-0} == 1 ]]; then
  PUB=("$HERE/src/nt_pub.cc" -I"${NT_INC:?NT_INC: ntcore/wpiutil headers}")
  # shellcheck disable=SC2054
  LIBS=(-L"${NT_LIB:?NT_LIB: dir with libntcore.so etc.}" -lntcore -ldatalog -lwpinet -lwpiutil -Wl,-rpath,/opt/sc-vision/lib)
fi
"$SC_CXX" "${CF[@]}" -std=gnu++23 -I"$HERE/src" -I"$OUT/napa-src" "$HERE/src/sc_vision.cc" "${PUB[@]}" \
  "$OUT/mjdec.o" "$OUT/uvc_usb.o" "$OUT/pose.o" "$OUT/napa_core.o" -o "$OUT/sc-vision" -ljpeg -lpthread -lm \
  "${LIBS[@]}"
if [[ ${NT:-0} == 1 ]]; then
  "$SC_CXX" "${CF[@]}" -std=gnu++23 -I"$NT_INC" "$HERE/tools/nt_probe.cc" -o "$OUT/nt_probe" "${LIBS[@]}"
fi
echo "built in $OUT"
