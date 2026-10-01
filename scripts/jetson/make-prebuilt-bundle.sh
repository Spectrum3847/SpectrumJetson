#!/usr/bin/env bash
# Packs what a Jetson built from source has compiled into one archive, so another Jetson can skip
# the builds (install.sh --prebuilt). Run ON THE JETSON after install.sh has finished from source.
#
#   scripts/jetson/make-prebuilt-bundle.sh [--jar PATH]   ->  ~/release/spectrum-jetson-prebuilt-<tag>.tar.gz
#
# What's in it (each where install.sh expects it):
#   build/bos-detector/  lib971apriltag.so libspectrumnvjpg.so libspectrumtrt.so
#   build/fieldcal-detect/fieldcal_detect
#   build/bos-detector/far_search_test   (the synthetic-tag generator fake-cameras.sh uses)
#   photonvision-spectrum-<tag>-linuxarm64.jar   (default: the jar PhotonVision is running)
#   MANIFEST  repo commit, L4T and CUDA versions, the patch list, and every file's SHA-256
#   NOTICES.md and the license texts (release/): where each file comes from, and its license
#
# It refuses if this repo copy has uncommitted changes: a bundle must match a commit. It also
# refuses if the detector regression check (tests/regression) finds any detection changed since
# the goldens were accepted; SKIP_REGRESSION=1 skips that, for a bundle you know differs.
# The camera driver isn't in it: it's built for the exact kernel, in 41 s, by install.sh.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
JAR=/opt/photonvision/photonvision.jar
while [[ $# -gt 0 ]]; do
  case $1 in --jar) JAR=$2; shift 2 ;; *) sed -n '2,19p' "$0"; exit 2 ;; esac
done

# The repo copy on the Jetson is an rsync of the laptop's, without .git: the laptop passes the
# commit it was synced from (setup-jetson.sh writes .spectrum-commit), with "-dirty" if it wasn't clean.
commit=$(cat "$REPO/.spectrum-commit" 2>/dev/null || true)
[[ -n $commit ]] || { echo "No $REPO/.spectrum-commit: sync this repo with scripts/host/setup-jetson.sh" >&2; exit 1; }
[[ $commit != *-dirty ]] || { echo "STOP: the repo was synced with uncommitted changes ($commit): commit, sync, then bundle" >&2; exit 1; }
if [[ ${SKIP_REGRESSION:-0} != 1 ]]; then
  echo "==> Detector regression check (tests/regression)"
  "$REPO/tests/regression/run.sh" || {
    echo "STOP: detections changed against the goldens. Bless them if intended (tests/regression/run.sh --bless), commit, sync, then bundle; or SKIP_REGRESSION=1." >&2
    exit 1
  }
fi
l4t=$(head -1 /etc/nv_tegra_release | sed -E 's/.*R([0-9]+).*REVISION: ([0-9.]+).*/\1.\2/')
cuda=$(/usr/local/cuda/bin/nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')
tag=v$(date +%Y.%m.%d)-${commit:0:7}
name=spectrum-jetson-prebuilt-$tag
OUT=$HOME/release
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

files=(
  "$HOME/build/bos-detector/lib971apriltag.so:build/bos-detector/lib971apriltag.so"
  "$HOME/build/bos-detector/libspectrumnvjpg.so:build/bos-detector/libspectrumnvjpg.so"
  "$HOME/build/bos-detector/libspectrumtrt.so:build/bos-detector/libspectrumtrt.so"
  "$HOME/build/fieldcal-detect/fieldcal_detect:build/fieldcal-detect/fieldcal_detect"
  "$HOME/build/bos-detector/far_search_test:build/bos-detector/far_search_test"
  "$JAR:photonvision-spectrum-$tag-linuxarm64.jar"
)
for f in "${files[@]}"; do
  src=${f%%:*} dst=${f#*:}
  [[ -f $src ]] || { echo "Missing $src: run install.sh from source first" >&2; exit 1; }
  install -D -m "$([[ -x $src ]] && echo 755 || echo 644)" "$src" "$STAGE/$dst"
done
# Licenses and attribution for everything in the bundle (release/NOTICES.md).
install -m 644 "$REPO"/release/NOTICES.md "$REPO"/release/LICENSE-*.* "$STAGE/"
unzip -tq "$STAGE/photonvision-spectrum-$tag-linuxarm64.jar" >/dev/null || { echo "STOP: $JAR isn't a valid jar" >&2; exit 1; }

{
  echo "bundle: $name"
  echo "commit: $commit"
  echo "built: $(date -u +%Y-%m-%dT%H:%MZ) on $(hostname)"
  echo "l4t: $l4t"
  echo "cuda: $cuda"
  echo "kernel: $(uname -r)"
  echo "patches: $(cd "$REPO/patches" && ls *.patch | tr '\n' ' ')"
  echo "sha256:"
  (cd "$STAGE" && find . -type f ! -name MANIFEST | sort | xargs sha256sum | sed 's/^/  /')
} > "$STAGE/MANIFEST"

mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/$name.tar.gz" .
(cd "$OUT" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
echo "Built $OUT/$name.tar.gz ($(du -h "$OUT/$name.tar.gz" | cut -f1))"
cat "$STAGE/MANIFEST"
