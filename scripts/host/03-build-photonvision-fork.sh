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

# Pinned, with their published SHA-256s, so a rebuild months later gets the same tools: the
# versions that built the 2026-10-12 alpha-7 jar. (Moving one: change the version and the hash together.)
NODE_VERSION=v24.21.0
NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
JDK_VERSION=25.0.4.1+1
JDK_SHA256=dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e
PNPM_VERSION=11.28.2
if [[ ! -x $T/node/bin/node ]]; then
  echo "==> Installing Node $NODE_VERSION to $T"
  tarball=node-$NODE_VERSION-linux-x64.tar.xz
  (cd "$T" && curl -fsSLO "https://nodejs.org/dist/$NODE_VERSION/$tarball" \
    && echo "$NODE_SHA256  $tarball" | sha256sum -c - \
    && tar xf "$tarball" && ln -sfn "${tarball%.tar.xz}" node)
fi
if [[ ! -x $T/jdk25/bin/java ]]; then
  echo "==> Installing Temurin JDK $JDK_VERSION to $T"
  curl -fsSL -o "$T/jdk25.tar.gz" \
    "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-${JDK_VERSION/+/%2B}/OpenJDK25U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz"
  echo "$JDK_SHA256  $T/jdk25.tar.gz" | sha256sum -c -
  mkdir -p "$T/jdk25" && tar xf "$T/jdk25.tar.gz" -C "$T/jdk25" --strip-components=1
fi

export PATH=$T/node/bin:$T/jdk25/bin:$PATH
export JAVA_HOME=$T/jdk25
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export GRADLE_OPTS=${GRADLE_OPTS:--Xmx768m -Dfile.encoding=UTF-8}
corepack enable --install-directory "$T/node/bin"
corepack prepare "pnpm@$PNPM_VERSION" --activate
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
# The training site (training/) is the sidebar's Documentation page: DocsView frames docs/index.html.
# Upstream CI fills docs/ with its Sphinx manual; we ship our course instead (works offline).
mkdir -p photon-client/public/docs
tar -C "$REPO_ROOT/training" --exclude=tools --exclude=README.md --exclude=.nojekyll -cf - . \
  | tar -C photon-client/public/docs -xf -
# Upstream tags give the jar a sane version string (e.g. v2026.1.1-27-gd8c9e8e1).
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
