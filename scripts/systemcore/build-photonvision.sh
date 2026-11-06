#!/usr/bin/env bash
# Build the Spectrum PhotonVision fork as a linuxarm64 jar for the SystemCore, on the laptop (Windows Git Bash
# or Linux). Needs git, node + pnpm, and a JDK 25 (WPILib 2027's).
#   scripts/systemcore/build-photonvision.sh [SRC] [BRANCH]
#     SRC     clone of Spectrum3847/photonvision (default ~/builder/pv; cloned if missing)
#     BRANCH  default sc/mjpeg-napa (spectrum-2027 + the SystemCore changes)
# installArm64Toolchain is needed once: without it the jar silently lacks libphotontargetingJNI.so for arm64
# and PhotonVision exits with "Could not find library photontargetingJNI".
set -euo pipefail
SRC=${1:-$HOME/builder/pv}
BRANCH=${2:-sc/mjpeg-napa}
JAVA_HOME=${JAVA_HOME:-$(ls -d /c/Users/Public/wpilib/2027*/jdk "$HOME"/wpilib/2027*/jdk 2>/dev/null | tail -1 || true)}
export JAVA_HOME
[[ -d $SRC/.git ]] || git clone --filter=blob:none -b "$BRANCH" https://github.com/Spectrum3847/photonvision.git "$SRC"
cd "$SRC"
./gradlew installArm64Toolchain -q
./gradlew photon-targeting:jar photon-server:shadowJar -PArchOverride=linuxarm64 -q
jar=$(ls -t photon-server/build/libs/photonvision-*-linuxarm64.jar | head -1)
python3 -c "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); z.getinfo('linux/arm64/shared/libphotontargetingJNI.so')" "$jar"
echo "$SRC/$jar"
