#!/usr/bin/env bash
# Cross-build uvc_timing for the SystemCore (Raspberry Pi 5) with WPILib's SystemCore toolchain, on the laptop.
#   tests/camera-timing/build.sh [OUT]     OUT default tests/camera-timing/out
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/out}
WPI=${WPI:-$(ls -d /c/Users/Public/wpilib/2027*/systemcore "$HOME"/wpilib/2027*/systemcore 2>/dev/null | tail -1 || true)}
[[ -d $WPI/bin ]] || { echo "no WPILib SystemCore toolchain (set WPI=.../wpilib/2027_xxx/systemcore)" >&2; exit 1; }
CC=$WPI/bin/aarch64-systemcore2027-linux-gnu-gcc
[[ -f $CC.exe ]] && CC=$CC.exe
mkdir -p "$OUT"
"$CC" -O2 -mcpu=cortex-a76 -Wall -Wextra -std=gnu11 "$HERE/uvc_timing.c" "$HERE/uvc_usb.c" -o "$OUT/uvc_timing"
echo "built $OUT/uvc_timing"
