#!/usr/bin/env bash
# NAPA source as SpectrumJetson builds it: third_party/napa (vendored upstream v0.5.1, de613ad, unmodified,
# GPL-3.0-only with the 7(b) credit term) plus patches/napa-*.patch in name order, copied to DIR.
#   scripts/jetson/napa-src.sh DIR [EXTRA.patch...]    (extra patches after ours, e.g. the profile build's)
# Keeps upstream upgrades easy: replace third_party/napa, then re-check each patch applies.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DIR=${1:?usage: napa-src.sh DIR [EXTRA.patch...]}
shift
rm -rf "$DIR"
mkdir -p "$DIR"
cp -r "$REPO/third_party/napa/." "$DIR/"
for p in "$REPO"/patches/napa-*.patch "$@"; do
  [[ -f $p ]] || continue
  patch -s -p3 -d "$DIR" --no-backup-if-mismatch <"$p" || { echo "napa patch failed: $p" >&2; exit 1; }
done
