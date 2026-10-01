import org.opencv.core.Core;
import org.opencv.core.CvType;
import org.opencv.core.Mat;
import org.opencv.core.MatOfDouble;
import org.photonvision.jni.GpuDetectorJNI;
import org.photonvision.jni.LibraryLoader;

// Feed lib971apriltag synthetic frames at several resolutions, the way PhotonVision does
// (one detector, resized when the frame size changes). The JNI prints "971 detector hN
// failure" lines for failed frames; run.sh counts them per resolution.
public class FrameSizeTest {
  public static void main(String[] args) throws Exception {
    if (!LibraryLoader.loadWpiLibraries()) {
      throw new IllegalStateException("PhotonVision could not load its WPILib and OpenCV natives");
    }
    int[][] sizes = {{1280, 800}, {640, 480}, {320, 240}, {800, 600}, {1280, 720}, {1280, 800}};
    long h = GpuDetectorJNI.createGpuDetector(640, 480);
    for (int[] s : sizes) {
      for (String kind : new String[] {"blank", "noise"}) {
        Mat m = new Mat(s[1], s[0], CvType.CV_8UC1);
        if (kind.equals("blank")) m.setTo(new org.opencv.core.Scalar(128));
        else Core.randu(m, 0, 256);
        System.out.println("=== " + s[0] + "x" + s[1] + " " + kind);
        System.out.flush();
        for (int i = 0; i < 20; i++) {
          GpuDetectorJNI.processimage(h, m.getNativeObjAddr());
          Thread.sleep(10);
        }
        m.release();
      }
    }
    GpuDetectorJNI.destroyGpuDetector(h);
    System.out.println("=== done");
  }
}
