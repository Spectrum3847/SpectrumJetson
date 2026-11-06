#!/bin/bash
# A/B of PhotonVision builds/settings on the SystemCore's fast path (docs/PHOTONVISION-PERF.md), one camera (CAM,
# NICK; default the Thriftiest), PhotonVision's UI on port PORT (default 5881) so a browser left open on 5880 doesn't
# attach. Each run is tests/pv-perf/measure.sh, ON THE SYSTEMCORE.
#   RUNS="base perf base perf" JARS=~/pvperf MODE=native|java [TAG=n] [VIEWER=...] [EXTRA="ENV=VAL ..."] ab.sh
# A run is NAME or NAME:ENV=VAL,ENV=VAL (extra environment for that run only). NAME picks $JARS/pv-NAME.jar (the
# installed jar if there is none) and $JARS/lib-NAME/ (our own streaming/NAPA libraries; the installed ones if none).
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HOME/pvperf/out}
JARS=${JARS:-$HOME/pvperf}
export OUT
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1"
S="$S SPECTRUM_STREAM_DECODER=mjdec SPECTRUM_WEBPORT=${PORT:-5881}"
[[ ${MODE:-native} == native ]] && S="$S SPECTRUM_NATIVE_PUBLISH=1"
i=0
for spec in ${RUNS:-base perf base perf}; do
  i=$((i + 1))
  r=${spec%%:*}
  env=""
  [[ $spec == *:* ]] && env=${spec#*:}
  n=${TAG:-n}-$r-$i
  jar=""; lib=""
  [[ -f $JARS/pv-$r.jar ]] && jar=$JARS/pv-$r.jar
  [[ -d $JARS/lib-$r ]] && lib=$JARS/lib-$r
  # shellcheck disable=SC2086
  LOCK_WAIT=900 WARM=${WARM:-45} PVPERF_JAR=$jar PVPERF_LIB=$lib "$HERE/measure.sh" "$n" "${SECS:-30}" \
    $S ${EXTRA:-} ${env//,/ } > "$OUT/$n.log" 2>&1
  { echo "$spec"; head -16 "$OUT/$n.tcpu"; grep -E "^rawBytes" "$OUT/$n.probe"; cat "$OUT/$n.wchar" 2>/dev/null; } |
    sed "s/^/$n /"
done
