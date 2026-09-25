#!/usr/bin/env bash
# Run ON THE JETSON: feed the detector library synthetic frames at several resolutions and
# count failed frames per resolution. LIBDIR=<dir> tests an uninstalled lib971apriltag.so.
set -uo pipefail
cd "$(dirname "$0")"
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-arm64}
CP=/opt/photonvision/photonvision.jar
[[ -x $JAVA_HOME/bin/javac && -f $CP ]] || {
  echo "Install PhotonVision's alpha-7 jar and openjdk-25-jdk first." >&2
  exit 1
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src/org/photonvision/jni"
cat > "$tmp/src/org/photonvision/jni/GpuDetectorJNI.java" <<'J'
package org.photonvision.jni;
import org.wpilib.vision.apriltag.AprilTagDetection;
public class GpuDetectorJNI {
  static { System.loadLibrary("971apriltag"); }
  public static native long createGpuDetector(int width, int height);
  public static native void destroyGpuDetector(long handle);
  public static native AprilTagDetection[] processimage(long handle, long p);
}
J
"$JAVA_HOME/bin/javac" -cp "$CP" -d "$tmp/classes" "$tmp/src/org/photonvision/jni/GpuDetectorJNI.java" FrameSizeTest.java
"$JAVA_HOME/bin/java" -Djava.library.path="${LIBDIR:+$LIBDIR:}/usr/lib/jni:/usr/lib" -cp "$tmp/classes:$CP" FrameSizeTest > "$tmp/out.txt" 2>&1
rc=$?
awk '/^=== /{label=$0; sub(/^=== /,"",label); order[++n]=label; fails[label]=0; next}
     /971 detector h[0-9]+ failure/{fails[label]++}
     /exiting so systemd restarts/{exited=label}
     END {for (i=1;i<=n;i++) if (order[i]!="done") printf "%-18s %s\n", order[i], (fails[order[i]] ? fails[order[i]] " FAILED frames (logged, max 5 + every 30th)" : "ok");
          if (exited) print "watchdog exited the process during: " exited}' "$tmp/out.txt"
grep -m3 -E "Received cuda status|failure 1:" "$tmp/out.txt"
echo "exit code $rc"
