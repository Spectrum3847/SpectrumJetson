#!/usr/bin/env bash
# Run ON THE JETSON. Compiles the fork's GpuDetectorJNI.java plus HandleReuseTest and
# runs it against /usr/lib/libspectrum-gpu-apriltag.so, or the one in $LIBDIR if set
# (e.g. LIBDIR=~/build/gpu-detector to test a build before installing it). Needs allwpilib's apriltag.jar (for the
# AprilTagDetection class the JNI looks up on load).
set -euo pipefail
cd "$(dirname "$0")"
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
CP=$(ls /usr/local/java/apriltag*.jar /usr/local/java/wpimath*.jar /usr/local/java/wpiutil*.jar 2>/dev/null | tr '\n' ':')
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src/org/photonvision/jni"
cat > "$tmp/src/org/photonvision/jni/GpuDetectorJNI.java" <<'J'
package org.photonvision.jni;
import edu.wpi.first.apriltag.AprilTagDetection;
public class GpuDetectorJNI {
  static {  // the old name (lib971apriltag) for builds from before 2026-10-31
    try { System.loadLibrary("spectrum-gpu-apriltag"); }
    catch (UnsatisfiedLinkError e) { System.loadLibrary("971apriltag"); }
  }
  public static native long createGpuDetector(int width, int height);
  public static native void destroyGpuDetector(long handle);
  public static native void setparams(long handle, double fx, double cx, double fy, double cy,
      double k1, double k2, double p1, double p2, double k3);
  public static native AprilTagDetection[] processimage(long handle, long p);
}
J
"$JAVA_HOME/bin/javac" -cp "$CP" -d "$tmp/classes" "$tmp/src/org/photonvision/jni/GpuDetectorJNI.java" org/photonvision/jni/HandleReuseTest.java
free -m | awk '/Mem/{print "mem used before: " $3 " MB"}'
"$JAVA_HOME/bin/java" ${LIBDIR:+-Djava.library.path=$LIBDIR} -cp "$tmp/classes:$CP" org.photonvision.jni.HandleReuseTest "${1:-25}" | grep -vE "^(creategpudetector|destroygpudetector)"
free -m | awk '/Mem/{print "mem used after:  " $3 " MB"}'
