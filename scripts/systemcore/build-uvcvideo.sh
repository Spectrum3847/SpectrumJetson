#!/usr/bin/env bash
# Build uvcvideo for the SystemCore's kernel (LimelightOS beta18, 6.12.112-v8-16k) with our urb_packets parameter
# (kernel/uvcvideo-urb-packets.patch), as an out-of-tree module, on the laptop with Docker. The source is
# Limelight's own uvcvideo from their SDK's kbuild tree (it carries their ll_compressed_* bandwidth parameters),
# so the only change from the module the SystemCore runs is urb_packets. STOCK=1 builds it unpatched (its
# srcversion must equal the SystemCore's: `modinfo uvcvideo`).
#   scripts/systemcore/build-uvcvideo.sh [SDK_DIR] [OUT]
#     SDK_DIR  dir with systemcorebetalinux.tar.xz + systemcorebeta-aarch64-toolchain.tar.gz (Limelight beta18 SDK;
#              default ~/systemcore-sdk/beta18)
#     OUT      default ~/builder/uvcvideo-sc  -> uvcvideo.ko
# The SDK is unpacked once into the Docker volume sc-sdk (/opt), as Limelight's crosscomp_examples/kernel does.
# Load on the SystemCore at run time only: scripts/systemcore/uvcvideo-load.sh (no /lib/modules or boot changes).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SDK=${1:-$HOME/systemcore-sdk/beta18}
OUT=${2:-$HOME/builder/uvcvideo-sc}
mkdir -p "$OUT/src"
# Limelight's uvc source from the kbuild tree, plus our patch
tar -C "$OUT/src" -xJf "$SDK/systemcorebetalinux.tar.xz" systemcorebetalinux/drivers/media/usb/uvc/
rm -rf "$OUT/uvc"
mkdir -p "$OUT/uvc"
cp "$OUT"/src/systemcorebetalinux/drivers/media/usb/uvc/*.[ch] "$OUT"/src/systemcorebetalinux/drivers/media/usb/uvc/Makefile "$OUT/uvc/"
if [[ ${STOCK:-0} != 1 ]]; then
  tr -d '\r' < "$REPO/kernel/uvcvideo-urb-packets.patch" | patch -d "$OUT/uvc" -p5 --no-backup-if-mismatch
  grep -q uvc_urb_packets "$OUT/uvc/uvc_video.c"
fi
# Docker paths: on Windows Git Bash, /c/... -> C:/...
dpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export MSYS_NO_PATHCONV=1
docker volume create sc-sdk >/dev/null
docker run --rm -v sc-sdk:/opt -v "$(dpath "$SDK"):/sdk:ro" ubuntu:24.04 bash -c '
  set -e
  if [ ! -f /opt/.unpacked ]; then
    apt-get update -qq && apt-get install -y -qq xz-utils >/dev/null
    tar -C /opt -xJf /sdk/systemcorebetalinux.tar.xz
    tar -C /opt -xzf /sdk/systemcorebeta-aarch64-toolchain.tar.gz
    touch /opt/.unpacked
  fi'
docker run --rm -v sc-sdk:/opt -v "$(dpath "$OUT/uvc"):/m" ubuntu:24.04 bash -c '
  set -e
  apt-get update -qq && apt-get install -y -qq make gcc bc flex bison libelf-dev kmod >/dev/null 2>&1
  TC=$(ls -d /opt/*toolchain* /opt/aarch64-* 2>/dev/null | head -1)
  [ -x "$TC/relocate-sdk.sh" ] && [ ! -f "$TC/.relocated" ] && (cd "$TC" && ./relocate-sdk.sh >/dev/null && touch .relocated)
  CC=$(ls "$TC"/bin/aarch64-*linux-gnu-gcc | head -1)
  make -s -C /opt/systemcorebetalinux M=/m ARCH=arm64 CROSS_COMPILE=${CC%gcc} modules
  modinfo /m/uvcvideo.ko | grep -E "vermagic|srcversion|parm:.*urb_packets" || true'
cp "$OUT/uvc/uvcvideo.ko" "$OUT/uvcvideo.ko"
echo "built $OUT/uvcvideo.ko"
