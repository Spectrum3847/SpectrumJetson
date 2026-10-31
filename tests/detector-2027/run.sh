#!/usr/bin/env bash
# libspectrum-gpu-apriltag.so inside a JVM holding WPILib 2027's natives, as PhotonVision 2027 runs it: loads
# beside WPILib's libapriltag/libwpiutil (no symbol clash), finds the 2027 AprilTagDetection, and
# reports corners in OpenCV's pixel convention: 0.5 px up-left of WPILib's CPU detector on the same
# synthetic tag. Run ON THE JETSON. No camera; PhotonVision can keep running.
# Usage: tests/detector-2027/run.sh [photonvision jar]   (LIBDIR: the detector to test,
#   default ~/build/gpu-detector; the jar supplies WPILib 2027, OpenCV and their natives)
set -euo pipefail
cd "$(dirname "$0")"
JAR=${1:-/opt/photonvision/photonvision.jar}
LIBDIR=${LIBDIR:-$HOME/build/gpu-detector}
JAVA=/usr/lib/jvm/java-25-openjdk-arm64/bin/java
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# The jar's linux/arm64 natives, as PhotonVision extracts them. (Python: Ubuntu 24.04's unzip
# rejects these jars' repeated LICENSE entries.)
python3 - "$JAR" "$tmp/lib" <<'PY'
import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); os.makedirs(sys.argv[2])
for n in z.namelist():
    if n.startswith("linux/arm64/shared/") and not n.endswith("/"):
        open(os.path.join(sys.argv[2], os.path.basename(n)), "wb").write(z.read(n))
PY
mkdir -p "$tmp/src/org/photonvision/jni"
cat > "$tmp/src/org/photonvision/jni/GpuDetectorJNI.java" <<'J'
package org.photonvision.jni;
import org.wpilib.vision.apriltag.AprilTagDetection;
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
"${JAVA%java}javac" -cp "$JAR" -d "$tmp/classes" "$tmp/src/org/photonvision/jni/GpuDetectorJNI.java" \
  org/photonvision/jni/Detector2027Test.java
LD_LIBRARY_PATH=$tmp/lib timeout 120 "$JAVA" --enable-native-access=ALL-UNNAMED -Djava.library.path="$LIBDIR:$tmp/lib" \
  -cp "$tmp/classes:$JAR" org.photonvision.jni.Detector2027Test
