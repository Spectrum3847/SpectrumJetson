#!/usr/bin/env bash
# ntcore / wpinet / wpiutil / datalog C++ headers and SystemCore libraries from the local WPILib 2027 maven repo,
# for nt_check (build.sh builds it when these are present).
#   tests/systemcore-mjpeg-napa/fetch-ntcore.sh [OUT]      OUT default ~/build/scmn-nt -> OUT/inc, OUT/lib
set -euo pipefail
OUT=${1:-$HOME/build/scmn-nt}
M=${WPILIB_MAVEN:-/c/Users/Public/wpilib/2027_alpha7/maven}
V=${WPI_VER:-2027.0.0-alpha-8}
mkdir -p "$OUT/inc" "$OUT/lib"
for z in ntcore wpinet wpiutil datalog; do
  d="$M/org/wpilib/$z/$z-cpp/$V"
  unzip -q -o "$d/$z-cpp-$V-headers.zip" -d "$OUT/inc"
  rm -rf "$OUT/tmp" && mkdir -p "$OUT/tmp"
  unzip -q -o "$d/$z-cpp-$V-linuxsystemcore.zip" -d "$OUT/tmp"
  find "$OUT/tmp" -name "*.so*" ! -name "*.debug" -exec cp {} "$OUT/lib/" \;
done
rm -rf "$OUT/tmp"
ls "$OUT/lib"
