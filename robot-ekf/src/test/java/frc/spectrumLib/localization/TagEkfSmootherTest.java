package frc.spectrumLib.localization;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.kinematics.SwerveModulePosition;

/** TagEkf's RTS smoother and self-checking uncertainty. */
class TagEkfSmootherTest {

    private static TagEkf driving(double[] distance, int samples) {
        TagEkf e =
                new TagEkf(
                        new Translation2d[] {
                            new Translation2d(0.3, 0.3),
                            new Translation2d(0.3, -0.3),
                            new Translation2d(-0.3, 0.3),
                            new Translation2d(-0.3, -0.3)
                        });
        for (int i = 0; i < samples; i++) {
            SwerveModulePosition[] m = new SwerveModulePosition[4];
            for (int k = 0; k < 4; k++) {
                m[k] = new SwerveModulePosition(distance[0] * i, new Rotation2d());
            }
            e.addOdometry(i * 0.01, new Rotation2d(), m);
            if (i == 1) {
                e.reset(new Pose2d());
            }
        }
        return e;
    }

    @Test
    void smootherMatchesFilterAtNewestSample() {
        TagEkf e = driving(new double[] {0.01}, 50);
        double[] sm = e.smoothedAt(0.49);
        assertNotNull(sm);
        assertEquals(e.getPose().getX(), sm[0], 1e-9);
    }

    @Test
    void laterPoseFixPullsEarlierSmoothedPose() {
        TagEkf e = driving(new double[] {0.01}, 100); // odometry says x = 0.98 m at 0.99 s
        double before = e.smoothedAt(0.5)[0];
        // A confident fix at the newest time: the robot is really 0.2 m further on.
        e.addPose(new Pose2d(e.getPose().getX() + 0.2, 0, new Rotation2d()), 0.99, 0.01, 0.01);
        double after = e.smoothedAt(0.5)[0];
        assertTrue(after > before + 0.02, "before " + before + " after " + after);
        assertTrue(after < before + 0.2, "after " + after);
    }

    @Test
    void outsideHistoryIsNull() {
        TagEkf e = driving(new double[] {0.01}, 10);
        assertEquals(null, e.smoothedAt(-1));
    }
}
