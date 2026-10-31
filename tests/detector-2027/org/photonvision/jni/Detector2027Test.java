package org.photonvision.jni;

import org.opencv.core.Core;
import org.opencv.core.CvType;
import org.opencv.core.Mat;
import org.opencv.core.MatOfPoint2f;
import org.opencv.core.Point;
import org.opencv.core.Scalar;
import org.opencv.core.Size;
import org.opencv.imgproc.Imgproc;
import org.opencv.objdetect.ArucoDetector;
import org.opencv.objdetect.Objdetect;
import org.wpilib.vision.apriltag.AprilTagDetection;
import org.wpilib.vision.apriltag.AprilTagDetector;

// tests/detector-2027/run.sh: libspectrum-gpu-apriltag.so in a JVM with WPILib 2027's own natives (from
// PhotonVision's jar), as PhotonVision runs it. One synthetic tag, detected by WPILib's CPU
// detector and by ours; ours must report corners 0.5 px up-left of WPILib's (OpenCV's pixel
// convention vs AprilTag's), and agree otherwise.
public class Detector2027Test {
  public static void main(String[] args) {
    System.loadLibrary("opencv_java4130");
    int fails = 0;

    // A 36h11 tag (OpenCV's image is the real tag rotated 180 deg; either decodes), 10-cell
    // pattern with a white quiet zone, warped in perspective onto a mid-grey 1280x800 frame.
    Mat marker = new Mat();
    Objdetect.generateImageMarker(Objdetect.getPredefinedDictionary(Objdetect.DICT_APRILTAG_36h11), 7, 400, marker, 1);
    Mat tag = new Mat(500, 500, CvType.CV_8UC1, new Scalar(255));
    marker.copyTo(tag.submat(50, 450, 50, 450));
    Mat frame = new Mat(800, 1280, CvType.CV_8UC1, new Scalar(128));
    MatOfPoint2f src = new MatOfPoint2f(new Point(0, 0), new Point(500, 0), new Point(500, 500), new Point(0, 500));
    MatOfPoint2f dst = new MatOfPoint2f(new Point(430.3, 180.7), new Point(820.1, 210.2), new Point(790.6, 620.4), new Point(400.2, 590.9));
    Imgproc.warpPerspective(tag, frame, Imgproc.getPerspectiveTransform(src, dst), new Size(1280, 800),
        Imgproc.INTER_LINEAR, Core.BORDER_TRANSPARENT);

    AprilTagDetector cpu = new AprilTagDetector();
    cpu.addFamily("tag36h11");
    AprilTagDetection[] c = cpu.detect(frame);

    long h = GpuDetectorJNI.createGpuDetector(1280, 800);
    GpuDetectorJNI.setparams(h, 900, 640, 900, 400, 0, 0, 0, 0, 0);
    AprilTagDetection[] g = null;
    for (int i = 0; i < 5; i++) g = GpuDetectorJNI.processimage(h, frame.getNativeObjAddr());  // warm up
    GpuDetectorJNI.destroyGpuDetector(h);

    System.out.println("WPILib CPU: " + c.length + " tag(s); 971 GPU: " + (g == null ? "null" : g.length + " tag(s)"));
    if (c.length != 1 || g == null || g.length != 1 || c[0].getId() != g[0].getId()) {
      System.out.println("FAIL: expected the same single tag from both");
      System.exit(1);
    }
    double sx = 0, sy = 0, worst = 0;
    for (int k = 0; k < 4; k++) {
      double dx = g[0].getCornerX(k) - c[0].getCornerX(k), dy = g[0].getCornerY(k) - c[0].getCornerY(k);
      System.out.printf("  corner %d: CPU (%.3f, %.3f)  GPU (%.3f, %.3f)  GPU-CPU (%+.3f, %+.3f)%n", k,
          c[0].getCornerX(k), c[0].getCornerY(k), g[0].getCornerX(k), g[0].getCornerY(k), dx, dy);
      sx += dx; sy += dy;
      worst = Math.max(worst, Math.hypot(dx + 0.5, dy + 0.5));
    }
    sx /= 4; sy /= 4;
    double dcx = g[0].getCenterX() - c[0].getCenterX(), dcy = g[0].getCenterY() - c[0].getCenterY();
    // Homography: the tag's centre (0,0) must map to the reported centre in both.
    double[] H = g[0].getHomography();
    double hx = H[2] / H[8], hy = H[5] / H[8];
    System.out.printf("  mean GPU-CPU (%+.3f, %+.3f) px; centre (%+.3f, %+.3f); homography centre off by (%.4f, %.4f)%n",
        sx, sy, dcx, dcy, hx - g[0].getCenterX(), hy - g[0].getCenterY());
    if (Math.abs(sx + 0.5) > 0.15 || Math.abs(sy + 0.5) > 0.15) { System.out.println("FAIL: mean offset isn't -0.5 px"); fails++; }
    if (worst > 0.3) { System.out.println("FAIL: a corner disagrees by more than 0.3 px beyond the -0.5 shift"); fails++; }
    if (Math.abs(hx - g[0].getCenterX()) > 1e-6 || Math.abs(hy - g[0].getCenterY()) > 1e-6) { System.out.println("FAIL: homography not shifted with the corners"); fails++; }
    System.out.println(fails == 0 ? "PASS" : "FAIL: " + fails);
    System.exit(fails == 0 ? 0 : 1);
  }
}
