#!/bin/bash
# The installer's AOT-cache path (scripts/systemcore/install-photonvision.sh + photonvision-run.sh), tried in RAM
# without touching /opt/photonvision, ON THE SYSTEMCORE: the installed jar and libraries are copied to /dev/shm/pvaot,
# a training run records, the cache is built and stamped as the installer does, then PhotonVision runs through
# run.sh (PV_DIR=/dev/shm/pvaot) with the cache and with SPECTRUM_AOT_CACHE=0, after a WARM s warm-up (steady
# state), and run.sh's stamp check is shown to catch a changed jar.
#   [WARM=60] [SECS=20] [TRAIN=45] [CAM= NICK=] aot-install-test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
P=/dev/shm/pvaot
export OUT=${OUT:-/dev/shm/pvperf-out}
mkdir -p "$OUT" "$P/lib"
trap 'rm -rf "$P"' EXIT
cp /opt/photonvision/photonvision.jar "$P/" && cp /opt/photonvision/lib/*.so "$P/lib/"
cp "$REPO/scripts/systemcore/photonvision-run.sh" "$P/run.sh" && chmod +x "$P/run.sh"
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1"
S="$S SPECTRUM_STREAM_DECODER=mjdec SPECTRUM_NATIVE_PUBLISH=1 SPECTRUM_WEBPORT=${PORT:-5881} PV_DIR=$P"
export PVPERF_LIB=$P/lib NOJFR=1 LOCK_WAIT=900
# training run, as the installer's (configuration written at JVM exit)
# shellcheck disable=SC2086
PVPERF_JAR=$P/photonvision.jar PVPERF_JVM="-Xmx512m -XX:AOTMode=record -XX:AOTConfiguration=$P/pv.aotconf" WARM=1 \
  "$HERE/measure.sh" aotinst-train "${TRAIN:-45}" $S > "$OUT/aotinst-train.log" 2>&1
sudo -n /usr/bin/java -Xmx512m -XX:AOTMode=create -XX:AOTConfiguration="$P/pv.aotconf" \
  -XX:AOTCache="$P/photonvision.aot" -cp "$P/photonvision.jar" > "$OUT/aotinst-create.log" 2>&1
PV_DIR=$P "$P/run.sh" --stamp > "$P/photonvision.aot.stamp"
echo "cache $(du -h "$P/photonvision.aot" | cut -f1), stamp: $(cat "$P/photonvision.aot.stamp")"
for m in off on; do
  e=""
  [[ $m == off ]] && e="SPECTRUM_AOT_CACHE=0"
  # shellcheck disable=SC2086
  PVPERF_EXEC=$P/run.sh WARM=${WARM:-60} "$HERE/measure.sh" "aotinst-$m" "${SECS:-20}" $S $e \
    > "$OUT/aotinst-$m.log" 2>&1
  { head -8 "$OUT/aotinst-$m.tcpu"; grep -E "^rawBytes" "$OUT/aotinst-$m.probe"; grep -ohE "AOT cache: [^\"]*" \
    "$OUT/aotinst-$m.journal" | head -1; } | sed "s/^/aotinst-$m /"
done
touch "$P/photonvision.jar"
[[ $(PV_DIR=$P "$P/run.sh" --stamp) != "$(cat "$P/photonvision.aot.stamp")" ]] &&
  echo "stamp check: a changed jar is seen as stale (run.sh starts without the cache)"
