#!/usr/bin/env bash
# Unpack WPILib's ntcore/wpinet/wpiutil C++ headers and SystemCore (linuxsystemcore) libraries from the local WPILib
# 2027 install's maven repo, for sc-vision's NetworkTables publisher (build.sh with NT=1).
#   native/sc-vision/fetch-ntcore.sh [OUT]     OUT default ~/builder/ntcore  -> OUT/inc, OUT/lib
# WPILIB_MAVEN (default: the newest ~/wpilib or C:/Users/Public/wpilib 2027 maven) and WPI_VER (2027.0.0-alpha-8).
set -euo pipefail
OUT=${1:-$HOME/builder/ntcore}
M=${WPILIB_MAVEN:-$(ls -d /c/Users/Public/wpilib/2027*/maven "$HOME"/wpilib/2027*/maven 2>/dev/null | tail -1 || true)}
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
