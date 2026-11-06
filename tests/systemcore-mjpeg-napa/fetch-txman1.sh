#!/usr/bin/env bash
# Download a few TXMAN1 Jetson Rewind segments (original camera MJPEG + frame index) from the team's Spectrum Log
# Analyzer (read-only GETs; nothing is uploaded), laid out as Rewind sessions: OUT/<match>/<camera>/<files>.
#   fetch-txman1.sh OUT FILE_ID:MATCH:CAMERA:NAME ...
# File ids come from https://robotlog.spectrum3847.org/api/matches/<match id> ("files"); raw bytes from
# /api/files/<id>/raw.
set -euo pipefail
OUT=${1:?OUT}
shift
for spec in "$@"; do
  IFS=: read -r id match cam name <<<"$spec"
  mkdir -p "$OUT/$match/$cam"
  [[ -s $OUT/$match/$cam/$name ]] && continue
  curl -sf -m 600 -o "$OUT/$match/$cam/$name" "https://robotlog.spectrum3847.org/api/files/$id/raw"
  echo "$match/$cam/$name $(wc -c <"$OUT/$match/$cam/$name")"
done
