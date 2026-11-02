package org.photonvision.jni;

// Create/destroy libspectrum-gpu-apriltag detectors far more times than there are slots (10),
// checking handles are reused and never go negative. The unpatched 4143 library
// returns -1 on the 11th create and then indexes detectors[-1].
// Run on the Jetson: tests/gpudetector-handles/run.sh
public class HandleReuseTest {
  public static void main(String[] args) {
    int cycles = args.length > 0 ? Integer.parseInt(args[0]) : 25;
    long[] live = new long[3];
    for (int i = 0; i < cycles; i++) {
      // Hold a few at once so slot reuse isn't just "always slot 0".
      for (int j = 0; j < live.length; j++) {
        live[j] = GpuDetectorJNI.createGpuDetector(1280, 800);
        if (live[j] < 0) {
          System.out.println("FAIL: create returned " + live[j] + " on cycle " + i);
          System.exit(1);
        }
      }
      // Null Mat pointer: must return null, not crash.
      if (GpuDetectorJNI.processimage(live[0], 0) != null) {
        System.out.println("FAIL: processimage(null mat) returned non-null");
        System.exit(1);
      }
      for (long h : live) GpuDetectorJNI.destroyGpuDetector(h);
    }
    // Stale/invalid handles must be rejected, not indexed.
    GpuDetectorJNI.destroyGpuDetector(-1);
    GpuDetectorJNI.destroyGpuDetector(99);
    if (GpuDetectorJNI.processimage(-1, 0) != null || GpuDetectorJNI.processimage(99, 0) != null) {
      System.out.println("FAIL: bad handle returned non-null");
      System.exit(1);
    }
    System.out.println("PASS: " + cycles * live.length + " creates/destroys, handles reused");
  }
}
