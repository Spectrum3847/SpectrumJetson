package frc.spectrumLib.localization;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Pose3d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Rotation3d;
import org.wpilib.math.geometry.Transform3d;
import org.wpilib.math.geometry.Translation3d;

/** MountEstimator converges to a mount error from corners alone, and flags a later knock. */
class MountEstimatorTest {

    static final double[] K = {735, 735, 640, 400};
    static final Transform3d CONFIGURED =
            new Transform3d(
                    new Translation3d(0.1, 0, 0.5), new Rotation3d(0, Math.toRadians(-15), 0));
    static final Pose3d TAG =
            new Pose3d(new Translation3d(3, 0.2, 0.8), new Rotation3d(0, 0, Math.PI));

    /** Corners as a camera actually mounted at {@code truth} sees them, robot at the origin. */
    static CornerSighting seen(double t, Transform3d truth, Transform3d assumed) {
        Translation3d[] corners = CornerSighting.tagCorners(TAG, 0.1651);
        CornerSighting real =
                new CornerSighting("cam", t, 1, corners, null, truth, K, new double[0], 1);
        double[][] px = new double[4][];
        for (int i = 0; i < 4; i++) {
            px[i] = real.project(0, 0, 0, corners[i]);
        }
        return new CornerSighting("cam", t, 1, corners, px, assumed, K, new double[0], 1);
    }

    @Test
    void convergesAndFlagsKnock() {
        MountEstimator est = new MountEstimator(2, 40, 1.5, 20);
        Transform3d truth = MountEstimator.withFix(CONFIGURED, 1.0, -2.0);
        Pose2d robot = new Pose2d(0, 0, new Rotation2d());
        double t = 0;
        for (; t < 40; t += 0.02) {
            est.update(robot, List.of(seen(t, truth, est.corrected("cam", CONFIGURED))));
        }
        MountEstimator.Camera c = est.cameras().get("cam");
        assertEquals(1.0, c.yawDeg(), 0.1);
        assertEquals(-2.0, c.pitchDeg(), 0.1);
        assertFalse(c.knocked());

        Transform3d knocked = MountEstimator.withFix(truth, 3.0, 0);
        for (; t < 50; t += 0.02) {
            est.update(robot, List.of(seen(t, knocked, est.corrected("cam", CONFIGURED))));
        }
        assertTrue(est.cameras().get("cam").knocked());
    }
}
