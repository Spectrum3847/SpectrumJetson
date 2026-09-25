#!/usr/bin/env bash
# Fetch the exact AllWPILib alpha-7 headers used by the SpectrumJetson native bridge.
# Run ON THE JETSON before 05-build-gpudetector.sh, 07-build-bos-detector.sh,
# or 13-build-fieldcal-detect.sh.
set -euo pipefail

TAG=v2027.0.0-alpha-7
TAG_OBJECT=b3232873240d60fe9f3d8ed6587e2770392f206c
COMMIT=83df3ee3ce1e892f76970ec21c8efdc00a104d4a
SRC=${ALLWPILIB_DIR:-$HOME/build/allwpilib-$TAG}
URL=https://github.com/wpilibsuite/allwpilib.git
INCLUDE=$SRC/wpiutil/src/main/native/include

if [[ ! -d $SRC/.git ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$URL"
fi
git -C "$SRC" remote set-url origin "$URL"
git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
[[ $(git -C "$SRC" rev-parse "refs/tags/$TAG") == "$TAG_OBJECT" ]] || {
  echo "Unexpected $TAG tag object. Refusing the headers." >&2
  exit 1
}
[[ $(git -C "$SRC" rev-parse "refs/tags/$TAG^{commit}") == "$COMMIT" ]] || {
  echo "Unexpected $TAG commit. Refusing the headers." >&2
  exit 1
}
git -C "$SRC" checkout -q --detach "$COMMIT"
git -C "$SRC" reset -q --hard "$COMMIT"

for header in "$INCLUDE/wpi/util/RawFrame.h" "$INCLUDE/wpi/util/PixelFormat.h"; do
  [[ -f $header ]] || { echo "Missing alpha-7 header: $header" >&2; exit 1; }
done

echo "AllWPILib $TAG headers ready: $INCLUDE"
echo "The CUDA bridge compiles as C++20 and does not link libwpiutil."
echo "Run 05, 07, and 13 on the Jetson. Static checks are not hardware validation."
