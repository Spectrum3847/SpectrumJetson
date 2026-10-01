// Cost of TagQuality.fill (photonvision-61) per tag, on this machine's CPU: a 1280x800 camera with a
// real-looking lens model (Thriftiest Cam calibration numbers), one tag 3 m away.
//   java -cp /opt/photonvision/photonvision.jar Bench.java
import org.wpilib.vision.apriltag.AprilTagDetection;
import org.wpilib.vision.apriltag.AprilTagPoseEstimate;
import org.wpilib.vision.apriltag.AprilTagPoseEstimator;
import org.wpilib.math.geometry.Transform3d;
import java.util.List;
import org.opencv.core.Size;
import org.photonvision.jni.LibraryLoader;
import org.photonvision.vision.calibration.CameraCalibrationCoefficients;
import org.photonvision.vision.calibration.CameraLensModel;
import org.photonvision.vision.calibration.JsonMatOfDouble;
import org.photonvision.vision.frame.FrameStaticProperties;
import org.photonvision.vision.target.TagQuality;
import org.photonvision.vision.target.TrackedTarget;

public class Bench {
    public static void main(String[] args) throws Exception {
        LibraryLoader.loadWpiLibraries();
        LibraryLoader.loadTargeting();
        org.photonvision.common.LoadJNI.loadLibraries();
        double f = 910;
        var cal =
                new CameraCalibrationCoefficients(
                        new Size(1280, 800),
                        new JsonMatOfDouble(3, 3, new double[] {f, 0, 640, 0, f, 400, 0, 0, 1}),
                        new JsonMatOfDouble(1, 8, new double[] {0.05, -0.08, 0.001, -0.001, 0.02, 0, 0, 0}),
                        new double[0],
                        List.of(),
                        new Size(1, 1),
                        1,
                        CameraLensModel.LENSMODEL_OPENCV);
        var props = new FrameStaticProperties(1280, 800, 70, cal);
        double[] corners = {600, 440, 640, 440, 640, 400, 600, 400};
        // The homography from the tag's -1..1 square to the corners, as the detector gives it.
        var h =
                org.opencv.imgproc.Imgproc.getPerspectiveTransform(
                        new org.opencv.core.MatOfPoint2f(
                                new org.opencv.core.Point(-1, 1),
                                new org.opencv.core.Point(1, 1),
                                new org.opencv.core.Point(1, -1),
                                new org.opencv.core.Point(-1, -1)),
                        new org.opencv.core.MatOfPoint2f(
                                new org.opencv.core.Point(600, 440),
                                new org.opencv.core.Point(640, 440),
                                new org.opencv.core.Point(640, 400),
                                new org.opencv.core.Point(600, 400)));
        double[] hom = new double[9];
        h.get(0, 0, hom);
        var det = new AprilTagDetection("tag36h11", 7, 0, 120, hom, 620, 420, corners);
        var est =
                new AprilTagPoseEstimator(new AprilTagPoseEstimator.Config(0.1651, f, f, 640, 400))
                        .estimateOrthogonalIteration(det, 50);
        var target = new TrackedTarget(List.of());
        for (int i = 0; i < 20000; i++) TagQuality.fill(target, det, est, props, 0.1651); // warm up
        int n = 100000;
        long t0 = System.nanoTime();
        for (int i = 0; i < n; i++) TagQuality.fill(target, det, est, props, 0.1651);
        double us = (System.nanoTime() - t0) / 1e3 / n;
        System.out.printf(
                "TagQuality.fill: %.1f us a tag (edge %.1f px, undistort %.2f px, reproj best %.3f alt %.3f px)%n",
                us, target.getEdgePx(), target.getUndistortPx(), target.getReprojBestPx(), target.getReprojAltPx());
    }
}
