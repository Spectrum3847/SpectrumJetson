#!/bin/bash
# A/B of PhotonVision jars on the SystemCore's fast path (docs/PHOTONVISION-PERF.md), Thriftiest, PhotonVision's UI on
# port PORT (default 5881) so a browser left open on 5880 doesn't attach. Each run is tests/pv-perf/measure.sh.
#   RUNS="base perf base perf" JARS=~/pvperf MODE=native|java [TAG=n] [VIEWER=...] [EXTRA="ENV=VAL ..."] ab.sh
# jar NAME = $JARS/pv-NAME.jar
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HOME/pvperf/out}
export OUT
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1"
S="$S SPECTRUM_STREAM_DECODER=mjdec SPECTRUM_WEBPORT=${PORT:-5881}"
[[ ${MODE:-native} == native ]] && S="$S SPECTRUM_NATIVE_PUBLISH=1"
i=0
for r in ${RUNS:-base perf base perf}; do
  i=$((i + 1))
  n=${TAG:-n}-$r-$i
  # shellcheck disable=SC2086
  LOCK_WAIT=900 WARM=${WARM:-45} PVPERF_JAR=${JARS:-$HOME/pvperf}/pv-$r.jar "$HERE/measure.sh" "$n" "${SECS:-30}" \
    $S ${EXTRA:-} > "$OUT/$n.log" 2>&1
  { head -16 "$OUT/$n.tcpu"; grep -E "^rawBytes" "$OUT/$n.probe"; } | sed "s/^/$n /"
done
