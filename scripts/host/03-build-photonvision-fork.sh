#!/usr/bin/env bash
# Build the FRC-Team-4143 PhotonVision fork (CUDA AprilTag pipeline) as a linuxarm64 jar,
# on the x86-64 host. No sudo: Node 22, pnpm 10 and Temurin 17 go in ~/build/tools,
# matching upstream CI for this commit.
#
# Why a 2026 build against 2027 alpha-6 robot code: the serde message hashes
# (PhotonPipelineResult 4b2ff16a...), NT4 protocol and time-sync packets are identical,
# so stock photonlib v2027.0.0-alpha-2 on the robot accepts it. Robot photonlib must NOT
# move past the alpha-6 era (main after alpha-7 changed the hashes).
set -euo pipefail

FORK_URL=https://github.com/FRC-Team-4143/photonvision.git
FORK_SHA=d8c9e8e1d3d4036f077a92f10f3a513ef4849765   # jetson-orin == main, 2026-01-30
BUILD=$HOME/build
SRC=$BUILD/photonvision-4143
T=$BUILD/tools
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$REPO_ROOT/out

mkdir -p "$T" "$OUT"

if [[ ! -x $T/node/bin/node ]]; then
  echo "==> Installing Node 22 LTS to $T"
  sums=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt)
  tarball=$(grep -oE 'node-v22\.[0-9.]+-linux-x64\.tar\.xz' <<<"$sums" | head -1)
  (cd "$T" && curl -fsSLO "https://nodejs.org/dist/latest-v22.x/$tarball" \
    && grep " $tarball\$" <<<"$sums" | sha256sum -c - \
    && tar xf "$tarball" && ln -sfn "${tarball%.tar.xz}" node)
fi
if [[ ! -x $T/jdk17/bin/java ]]; then
  echo "==> Installing Temurin JDK 17 to $T"
  curl -fsSL -o "$T/jdk17.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
  mkdir -p "$T/jdk17" && tar xf "$T/jdk17.tar.gz" -C "$T/jdk17" --strip-components=1
fi

export PATH=$T/node/bin:$T/jdk17/bin:$PATH
export JAVA_HOME=$T/jdk17
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack enable --install-directory "$T/node/bin"
corepack prepare pnpm@10 --activate
echo "node $(node --version), pnpm $(pnpm --version), $(java -version 2>&1 | head -1)"

if [[ ! -d $SRC/.git ]]; then
  git clone --filter=blob:none "$FORK_URL" "$SRC"
fi
cd "$SRC"
git fetch -q origin
# Reset to the pinned commit, then apply our patches (see patches/).
git checkout -q -f "$FORK_SHA"
git reset -q --hard "$FORK_SHA"
git clean -fdq   # drop files created by earlier patch runs (ignored build caches stay)
for p in "$REPO_ROOT"/patches/photonvision-*.patch; do
  [[ -e $p ]] || continue
  echo "==> Applying $(basename "$p")"
  git apply "$p"
done
# The 3D field models for the Field Calibration page (photonvision-30), from assets/field-models
# (built by tools/fieldmodel from FIRST's field CAD): served by PhotonVision at fieldmodels/.
mkdir -p photon-client/public/fieldmodels
cp "$REPO_ROOT"/assets/field-models/*.glb photon-client/public/fieldmodels/
# The training site (training/) is the sidebar's Documentation page: DocsView frames docs/index.html.
# Upstream CI fills docs/ with its Sphinx manual; we ship our course instead (works offline).
mkdir -p photon-client/public/docs
tar -C "$REPO_ROOT/training" --exclude=tools --exclude=README.md --exclude=.nojekyll -cf - . \
  | tar -C photon-client/public/docs -xf -
# Upstream tags give the jar a sane version string (e.g. v2026.1.1-27-gd8c9e8e1).
git fetch -q --tags https://github.com/PhotonVision/photonvision.git || true

./gradlew installArm64Toolchain
./gradlew photon-targeting:jar photon-server:shadowJar -PArchOverride=linuxarm64

jar=$(ls -t photon-server/build/libs/photonvision-*-linuxarm64.jar | head -1)
cp "$jar" "$OUT/"
echo
echo "Built: $OUT/$(basename "$jar")"
