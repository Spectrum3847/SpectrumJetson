package frc.spectrumLib.localization;

import org.wpilib.math.geometry.Transform3d;
import org.wpilib.math.geometry.Translation3d;

/**
 * One AprilTag seen by one camera in one frame: where the tag's centre was, relative to the camera.
 * {@link TagEkf} turns it into a bearing and a distance from the camera.
 *
 * @param camera camera name, for per-camera logging
 * @param timestampSeconds capture time, {@code Timer.getTimestamp()} base
 * @param tagId fiducial id
 * @param tagField the tag's centre on the field
 * @param robotToCamera camera mount, robot frame (x forward, y left, z up)
 * @param cameraToTag the tag's centre in the camera frame (x out of the lens, y left, z up)
 * @param noiseScale the camera's std-dev multiplier; 1 for none
 */
public record TagSighting(
        String camera,
        double timestampSeconds,
        int tagId,
        Translation3d tagField,
        Transform3d robotToCamera,
        Translation3d cameraToTag,
        double noiseScale) {

    /**
     * The tag's centre in the camera frame from a Limelight raw fiducial: its angles from the
     * principal point ({@code txnc} positive right, {@code tync} positive up) and its distance.
     */
    public static Translation3d fromAngles(
            double txncDegrees, double tyncDegrees, double distanceMeters) {
        double y = -Math.tan(Math.toRadians(txncDegrees));
        double z = Math.tan(Math.toRadians(tyncDegrees));
        double scale = distanceMeters / Math.sqrt(1 + y * y + z * z);
        return new Translation3d(scale, y * scale, z * scale);
    }
}
