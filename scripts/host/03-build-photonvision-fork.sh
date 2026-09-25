#!/usr/bin/env bash
# Build the SpectrumJetson PhotonVision source migration as a linuxarm64 jar.
# The base is an exact upstream commit that targets WPILib 2027.0.0-alpha-7.
# No sudo: Node, pnpm, and Temurin JDK 25 stay under ~/build/tools.
set -euo pipefail

UPSTREAM_URL=https://github.com/PhotonVision/photonvision.git
UPSTREAM_SHA=1f419c9de3a6a0787571648d18211537a83fdca9
BUILD=$HOME/build
SRC=$BUILD/photonvision-2027
T=$BUILD/tools
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$REPO_ROOT/out
MIGRATION_PATCH=$REPO_ROOT/patches/photonvision-2027-alpha7-migration.patch

mkdir -p "$T" "$OUT"
[[ -f $MIGRATION_PATCH ]] || { echo "Missing $MIGRATION_PATCH" >&2; exit 1; }

if [[ ! -x $T/node/bin/node ]]; then
  echo "==> Installing Node 24 LTS to $T"
  sums=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt)
  tarball=$(grep -oE 'node-v24\.[0-9.]+-linux-x64\.tar\.xz' <<<"$sums" | head -1)
  (cd "$T" && curl -fsSLO "https://nodejs.org/dist/latest-v24.x/$tarball" \
    && grep " $tarball\$" <<<"$sums" | sha256sum -c - \
    && tar xf "$tarball" && ln -sfn "${tarball%.tar.xz}" node)
fi
if [[ ! -x $T/jdk25/bin/java ]]; then
  echo "==> Installing Temurin JDK 25 to $T"
  curl -fsSL -o "$T/jdk25.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse"
  mkdir -p "$T/jdk25" && tar xf "$T/jdk25.tar.gz" -C "$T/jdk25" --strip-components=1
fi

export PATH=$T/node/bin:$T/jdk25/bin:$PATH
export JAVA_HOME=$T/jdk25
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export GRADLE_OPTS=${GRADLE_OPTS:--Xmx768m -Dfile.encoding=UTF-8}
corepack enable --install-directory "$T/node/bin"
corepack prepare pnpm@11 --activate
java_line=$("$JAVA_HOME/bin/java" -version 2>&1)
echo "node $(node --version), pnpm $(pnpm --version), ${java_line%%$'\n'*}"

if [[ ! -d $SRC/.git ]]; then
  git clone --filter=blob:none "$UPSTREAM_URL" "$SRC"
fi
cd "$SRC"
git remote set-url origin "$UPSTREAM_URL"
git fetch -q origin
git checkout -q -f "$UPSTREAM_SHA"
git reset -q --hard "$UPSTREAM_SHA"
git clean -fdq
git apply --check "$MIGRATION_PATCH"
git apply "$MIGRATION_PATCH"

# The 3D field models come from SpectrumJetson's asset snapshot.
mkdir -p photon-client/public/fieldmodels
cp "$REPO_ROOT"/assets/field-models/*.glb photon-client/public/fieldmodels/
git fetch -q --tags "$UPSTREAM_URL" || true

./gradlew --no-daemon --max-workers=1 installArm64Toolchain
./gradlew --no-daemon --max-workers=1 photon-targeting:jar photon-server:shadowJar -PArchOverride=linuxarm64

jar=$(python3 - "$SRC" <<'PY'
import glob
import os
import sys
jars = glob.glob(os.path.join(sys.argv[1], "photon-server/build/libs/photonvision-*-linuxarm64.jar"))
if len(jars) != 1:
    raise SystemExit(f"expected one linuxarm64 jar, found {len(jars)}")
print(max(jars, key=os.path.getmtime))
PY
)
cp "$jar" "$OUT/"
echo
echo "Built: $OUT/$(basename "$jar")"
echo "This jar needs the matching alpha-7 native libraries. Jetson and robot-network tests are still required."
