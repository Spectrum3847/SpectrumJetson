#!/bin/sh
# PhotonVision's ExecStart on the SystemCore (installed as /opt/photonvision/run.sh by install-photonvision.sh).
# Starts the JVM with the Java 25 AOT cache (JEP 483/514/515: classes loaded and linked ahead of time, plus method
# profiles) when /opt/photonvision/photonvision.aot was built for this jar and this JVM, else without it, and says
# which in the journal. Measured (docs/PHOTONVISION-PERF.md): start-up 2.8 -> 1.6 s to the web server, 2.7 -> 2.0 s
# to the first frame, first 25 s 40 -> 30% of a core. The JVM checks the cache itself too: a cache that doesn't
# match is ignored with a warning (never a failed start), so this check only keeps the journal honest.
#   run.sh            start PhotonVision
#   run.sh --stamp    print what the cache must match (the jar's size and time, the JVM's version)
D=${PV_DIR:-/opt/photonvision}  # PV_DIR: tests only
JAR=$D/photonvision.jar
CACHE=$D/photonvision.aot
JAVA=/usr/bin/java
stamp() {
  home=$(dirname "$(dirname "$(readlink -f "$JAVA")")")
  ver=$(sed -n 's/^JAVA_RUNTIME_VERSION="\(.*\)"/\1/p' "$home/release" 2>/dev/null)
  # (no stat(1) on LimelightOS: wc and date -r)
  echo "jar $(wc -c < "$JAR") $(date -r "$JAR" +%s) jvm ${ver:-unknown} $(wc -c < "$home/lib/server/libjvm.so" 2>/dev/null)"
}
if [ "${1:-}" = "--stamp" ]; then
  stamp
  exit 0
fi
AOT=""
if [ "${SPECTRUM_AOT_CACHE:-1}" = "0" ]; then
  echo "AOT cache: off (SPECTRUM_AOT_CACHE=0)"
elif [ ! -f "$CACHE" ]; then
  echo "AOT cache: none ($CACHE missing; install-photonvision.sh builds it); starting without"
elif [ "$(cat "$CACHE.stamp" 2>/dev/null)" != "$(stamp)" ]; then
  echo "AOT cache: stale (built for another jar or JVM: rerun install-photonvision.sh); starting without"
else
  echo "AOT cache: using $CACHE"
  AOT="-XX:AOTCache=$CACHE"
fi
# shellcheck disable=SC2086
exec "$JAVA" -Xmx512m $AOT -XX:-CreateCoredumpOnCrash -Djava.library.path="$D/lib" -jar "$JAR" -n
