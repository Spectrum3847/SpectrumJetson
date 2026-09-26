#!/usr/bin/env bash
# Build and install allwpilib natively on the Jetson, for GpuDetectorJNI to link against.
# Run ON THE JETSON, ideally inside tmux (this takes hours):
#   tmux new -s build ~/SpectrumJetson/scripts/jetson/04-build-allwpilib.sh
#
# The tag must match the WPILib version of the PhotonVision build that loads
# lib971apriltag.so. The current FRC-Team-4143 fork uses 2026.2.1. The
# 2027 alpha-7 CUDA port is a separate change and needs a real Jetson build.
# Usage: 04-build-allwpilib.sh [tag]
set -euo pipefail

TAG=${1:-v2026.2.1}
SRC=$HOME/build/allwpilib-$TAG
LOG=$HOME/build/allwpilib-$TAG.log
# More parallelism OOMs on wpimath with 8 GB RAM.
JOBS=4

# JDK 17 for the build. PhotonVision 2027 installs JDK 25 as the default java;
# pin the build to 17 explicitly instead of relying on alternatives.
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH=$PATH:/usr/local/cuda/bin

sudo -v
# Keep sudo fresh so the final install doesn't block on a password hours from now.
( while true; do sudo -n true; sleep 60; done ) 2>/dev/null &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

sudo apt-get install -y openjdk-17-jdk ninja-build protobuf-compiler libxrandr-dev \
  libssh-dev libopencv4.5-java cmake build-essential git

mkdir -p "$HOME/build"
if [[ ! -d $SRC/.git ]]; then
  git clone --depth 1 --branch "$TAG" https://github.com/wpilibsuite/allwpilib.git "$SRC"
fi
cd "$SRC"

exec > >(tee -a "$LOG") 2>&1
echo "==> $(date) building allwpilib $TAG with -j$JOBS (log: $LOG)"

cmake --preset default -DWITH_GUI=OFF -DWITH_JAVA=ON \
  -DWITH_SIMULATION_MODULES=OFF -DWITH_TESTS=OFF \
  -DOPENCV_JAR_FILE=/usr/share/java/opencv.jar

cd build-cmake
time cmake --build . --parallel "$JOBS"
sudo cmake --build . --target install
sudo ldconfig

echo "==> $(date) allwpilib $TAG installed to /usr/local"
