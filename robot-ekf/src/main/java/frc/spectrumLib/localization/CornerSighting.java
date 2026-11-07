package frc.spectrumLib.localization;

import org.wpilib.math.geometry.Rotation3d;
import org.wpilib.math.geometry.Transform3d;
import org.wpilib.math.geometry.Translation3d;

/**
 * One AprilTag's four detected corners in one camera frame, raw (distorted) pixels, for {@link
 * TagEkf#addCornerFrame}: eight measurements per tag instead of the one bearing and range of a
 * {@link TagSighting}, and no per-tag PnP in between.
 *
 * @param camera camera name, for per-camera logging
 * @param timestampSeconds capture time
 * @param tagId fiducial id
 * @param fieldCorners the tag's four corners on the field, any order
 * @param pixels detected corners, {u, v} each, any order (matched to the nearest prediction)
 * @param robotToCamera camera mount, robot frame (x forward, y left, z up)
 * @param intrinsics fx, fy, cx, cy
 * @param distortion OpenCV k1, k2, p1, p2, k3[, k4, k5, k6] (rational model); empty for none
 * @param pixelStd corner std-dev, pixels
 */
public record CornerSighting(
        String camera,
        double timestampSeconds,
        int tagId,
        Translation3d[] fieldCorners,
        double[][] pixels,
        Transform3d robotToCamera,
        double[] intrinsics,
        double[] distortion,
        double pixelStd) {

    /** A 6.5 in tag's corners on the field, from its centre pose. */
    public static Translation3d[] tagCorners(org.wpilib.math.geometry.Pose3d tag, double size) {
        double h = size / 2;
        Translation3d[] out = new Translation3d[4];
        double[][] yz = {{-h, -h}, {h, -h}, {h, h}, {-h, h}};
        for (int i = 0; i < 4; i++) {
            out[i] =
                    tag.getTranslation()
                            .plus(
                                    new Translation3d(0, yz[i][0], yz[i][1])
                                            .rotateBy(tag.getRotation()));
        }
        return out;
    }

    /**
     * Projects a field point to raw pixels for a robot at (x, y, theta) on the floor.
     *
     * @return {u, v}, or null behind the camera
     */
    public double[] project(double x, double y, double theta, Translation3d field) {
        // Field -> robot.
        double c = Math.cos(theta);
        double s = Math.sin(theta);
        double dx = field.getX() - x;
        double dy = field.getY() - y;
        Translation3d inRobot = new Translation3d(c * dx + s * dy, -s * dx + c * dy, field.getZ());
        // Robot -> camera (x out of the lens, y left, z up).
        Rotation3d r = robotToCamera.getRotation();
        Translation3d inCam =
                inRobot.minus(robotToCamera.getTranslation())
                        .rotateBy(new Rotation3d(r.getQuaternion().inverse()));
        return projectCamera(inCam);
    }

    /** A point in the camera frame (x out of the lens, y left, z up) to raw pixels, or null. */
    public double[] projectCamera(Translation3d inCam) {
        if (inCam.getX() < 0.05) {
            return null;
        }
        // Normalized image coordinates (OpenCV: x right, y down).
        double xn = -inCam.getY() / inCam.getX();
        double yn = -inCam.getZ() / inCam.getX();
        double[] d = distortion;
        if (d.length >= 5) {
            double r2 = xn * xn + yn * yn;
            double radial = 1 + d[0] * r2 + d[1] * r2 * r2 + d[4] * r2 * r2 * r2;
            if (d.length >= 8) {
                radial /= 1 + d[5] * r2 + d[6] * r2 * r2 + d[7] * r2 * r2 * r2;
            }
            double xd = xn * radial + 2 * d[2] * xn * yn + d[3] * (r2 + 2 * xn * xn);
            double yd = yn * radial + d[2] * (r2 + 2 * yn * yn) + 2 * d[3] * xn * yn;
            xn = xd;
            yn = yd;
        }
        return new double[] {
            intrinsics[0] * xn + intrinsics[2], intrinsics[1] * yn + intrinsics[3]
        };
    }
}
