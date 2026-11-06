#!/bin/bash
# Java 25 AOT cache (JEP 483/514/515) for PhotonVision on the SystemCore (docs/PHOTONVISION-PERF.md), ON THE
# SYSTEMCORE: a training run records which classes PhotonVision loads and links and its method profiles
# (-XX:AOTMode=record), the cache is assembled from that (-XX:AOTMode=create, no camera), then start-up is
# compared with and without -XX:AOTCache: CPU in the first SECS seconds by thread (the JIT compilers), the time to
# the web server and to the first decoded frame. The cache belongs to one jar + JVM: rebuild it for every jar.
#   JAR=/dev/shm/pvperf/pv-NAME.jar [LIB=dir] [CAM= NICK=] [SECS=25] [TRAIN=40] [RUNS="off on off on"] aot.sh
HERE=$(cd "$(dirname "$0")" && pwd)
JAR=${JAR:?jar}
export OUT=${OUT:-/dev/shm/pvperf-out}
mkdir -p "$OUT"
D=$(dirname "$JAR")
CONF=$D/pv.aotconf
CACHE=$D/pv.aot
JVM="-Xmx512m"
export PVPERF_JAR=$JAR PVPERF_LIB=${LIB:-} NOJFR=1
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1"
S="$S SPECTRUM_STREAM_DECODER=mjdec SPECTRUM_NATIVE_PUBLISH=1 SPECTRUM_WEBPORT=${PORT:-5881}"
if [[ ! -f $CACHE ]]; then
  # 1. training run (the configuration is written when the JVM exits)
  # shellcheck disable=SC2086
  PVPERF_JVM="$JVM -XX:AOTMode=record -XX:AOTConfiguration=$CONF" LOCK_WAIT=900 WARM=1 \
    "$HERE/measure.sh" aot-train "${TRAIN:-40}" $S > "$OUT/aot-train.log" 2>&1
  sudo -n test -f "$CONF" || { echo "no AOT configuration written ($CONF)"; exit 1; }
  # 2. assemble the cache (no camera, no PhotonVision run)
  t0=$(python3 -c "import time; print(time.time())")
  sudo -n /usr/bin/java $JVM -XX:AOTMode=create -XX:AOTConfiguration="$CONF" -XX:AOTCache="$CACHE" \
    -Djava.library.path=/opt/photonvision/lib -cp "$JAR" > "$OUT/aot-create.log" 2>&1
  echo "AOT cache: $(du -h "$CACHE" | cut -f1) in $(python3 -c "import time; print(round(time.time() - $t0, 1))") s"
fi
# 3. start-up with and without the cache
i=0
for m in ${RUNS:-off on off on}; do
  i=$((i + 1))
  j=$JVM
  [[ $m == on ]] && j="$JVM -XX:AOTCache=$CACHE"
  # shellcheck disable=SC2086
  PVPERF_JVM=$j LOCK_WAIT=900 WARM=1 "$HERE/measure.sh" "aot-$m-$i" "${SECS:-25}" $S > "$OUT/aot-$m-$i.log" 2>&1
  { head -8 "$OUT/aot-$m-$i.tcpu"; cat "$OUT/aot-$m-$i.startup"; } | sed "s/^/aot-$m-$i /"
done
