package frc.spectrumLib.localization;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Pose3d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Rotation3d;
import org.wpilib.math.geometry.Transform3d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.geometry.Translation3d;
import org.wpilib.math.kinematics.SwerveModulePosition;

class TagEkfTest {

    private static final Translation2d[] MODULES = {
        new Translation2d(0.3, 0.3),
        new Translation2d(0.3, -0.3),
        new Translation2d(-0.3, 0.3),
        new Translation2d(-0.3, -0.3)
    };

    private static final Transform3d FRONT =
            new Transform3d(
                    new Translation3d(0.2, 0.1, 0.5),
                    new Rotation3d(0, Math.toRadians(-15), Math.toRadians(10)));

    private static final Transform3d LEFT =
            new Transform3d(
                    new Translation3d(0.0, 0.3, 0.5),
                    new Rotation3d(0, Math.toRadians(-20), Math.toRadians(80)));

    private static final Translation3d[] TAGS = {
        new Translation3d(5.0, 1.0, 1.1),
        new Translation3d(5.0, 2.5, 0.8),
        new Translation3d(2.0, 5.0, 1.1)
    };

    /** Every module pointing forward, having rolled {@code distance}. */
    private static SwerveModulePosition[] rolled(double distance) {
        SwerveModulePosition[] p = new SwerveModulePosition[4];
        for (int i = 0; i < 4; i++) {
            p[i] = new SwerveModulePosition(distance, Rotation2d.ZERO);
        }
        return p;
    }

    /** What a perfect camera on a robot at {@code robot} sees of {@code tag}. */
    private static TagSighting see(
            String camera, double t, Pose2d robot, Transform3d mount, Translation3d tag) {
        Pose3d cameraPose = new Pose3d(robot).transformBy(mount);
        Translation3d inCamera =
                new Pose3d(tag, Rotation3d.ZERO).relativeTo(cameraPose).getTranslation();
        return new TagSighting(camera, t, 0, tag, mount, inCamera, 1.0);
    }

    /** The front camera sees the two tags ahead, the left camera the one to the left. */
    private static List<TagSighting> frame(double t, Pose2d robot) {
        return List.of(
                see("Front", t, robot, FRONT, TAGS[0]),
                see("Front", t, robot, FRONT, TAGS[1]),
                see("Left", t, robot, LEFT, TAGS[2]));
    }

    @Test
    void odometryAloneDeadReckons() {
        TagEkf ekf = new TagEkf(MODULES);
        ekf.reset(new Pose2d(1, 2, Rotation2d.CCW_PI_2));
        Rotation2d gyro = Rotation2d.fromDegrees(30); // any boot angle
        for (int i = 0; i <= 250; i++) {
            ekf.addOdometry(i * 0.004, gyro, rolled(i * 0.004));
        }
        Pose2d p = ekf.getPose();
        assertEquals(1.0, p.getX(), 1e-9);
        assertEquals(3.0, p.getY(), 1e-9);
        assertEquals(90.0, p.getRotation().getDegrees(), 1e-9);
        assertTrue(ekf.getStdDevs()[0] > 0.05, "variance grows with distance driven");
    }

    @Test
    void tagsPullASmallOffsetIn() {
        Pose2d truth = new Pose2d(2, 1.5, Rotation2d.fromDegrees(5));
        TagEkf ekf = new TagEkf(MODULES);
        ekf.addOdometry(0, Rotation2d.ZERO, rolled(0));
        ekf.reset(new Pose2d(2.05, 1.46, Rotation2d.fromDegrees(5.3)));
        for (int i = 1; i <= 100; i++) {
            double t = i * 0.02;
            ekf.addOdometry(t, Rotation2d.ZERO, rolled(0));
            if (i > 1) {
                ekf.addFrame(frame(t - 0.03, truth));
            }
        }
        assertEquals(0, ekf.getRelocalizations());
        assertEquals(0, ekf.getRejectedCount());
        assertEquals(0, ekf.getPose().getTranslation().getDistance(truth.getTranslation()), 0.01);
        assertEquals(5.0, ekf.getPose().getRotation().getDegrees(), 0.1);
    }

    @Test
    void relocalizesAfterAGrossError() {
        Pose2d truth = new Pose2d(2, 1.5, Rotation2d.ZERO);
        TagEkf ekf = new TagEkf(MODULES);
        ekf.addOdometry(0, Rotation2d.ZERO, rolled(0));
        ekf.reset(new Pose2d(3.2, 0.7, Rotation2d.ZERO));
        for (int i = 1; i <= 200; i++) {
            double t = i * 0.02;
            ekf.addOdometry(t, Rotation2d.ZERO, rolled(0));
            ekf.addFrame(frame(t - 0.03, truth));
        }
        assertTrue(ekf.getRelocalizations() >= 1);
        assertTrue(ekf.getRejectionCounts().get("Innovation") > 0);
        assertEquals(0, ekf.getPose().getTranslation().getDistance(truth.getTranslation()), 0.01);
    }

    @Test
    void outlierIsRejected() {
        Pose2d truth = new Pose2d(2, 1.5, Rotation2d.ZERO);
        TagEkf ekf = new TagEkf(MODULES);
        ekf.addOdometry(0, Rotation2d.ZERO, rolled(0));
        ekf.reset(truth);
        ekf.addOdometry(0.02, Rotation2d.ZERO, rolled(0));
        TagSighting good = see("Front", 0.01, truth, FRONT, TAGS[0]);
        Translation3d far = good.cameraToTag().times(1.6);
        ekf.addFrame(List.of(new TagSighting("Front", 0.01, 0, good.tagField(), FRONT, far, 1.0)));
        assertEquals(1, ekf.getRejectionCounts().get("Innovation"));
        assertEquals(0, ekf.getPose().getTranslation().getDistance(truth.getTranslation()), 1e-9);
    }

    /** Same frames, delivered in a different order: same result. */
    @Test
    void resultDoesNotDependOnArrivalOrder() {
        TagEkf inOrder = new TagEkf(MODULES);
        TagEkf late = new TagEkf(MODULES);
        Pose2d start = new Pose2d(1, 1, Rotation2d.ZERO);
        for (TagEkf e : List.of(inOrder, late)) {
            e.addOdometry(0, Rotation2d.ZERO, rolled(0));
            e.reset(
                    start.plus(
                            new org.wpilib.math.geometry.Transform2d(
                                    0.04, -0.03, Rotation2d.ZERO)));
        }
        List<List<TagSighting>> held = new ArrayList<>();
        for (int i = 1; i <= 100; i++) {
            double t = i * 0.004;
            double x = 0.5 * t; // 0.5 m/s forward
            for (TagEkf e : List.of(inOrder, late)) {
                e.addOdometry(t, Rotation2d.ZERO, rolled(x));
            }
            if (i % 5 == 0) {
                Pose2d truth = new Pose2d(1 + x - 0.5 * 0.03, 1, Rotation2d.ZERO);
                List<TagSighting> front = frame(t - 0.03, truth);
                List<TagSighting> left = List.of(see("Left", t - 0.025, truth, LEFT, TAGS[2]));
                inOrder.addFrame(front);
                inOrder.addFrame(left);
                // The late filter gets the left camera first and the front one a loop later.
                late.addFrame(left);
                held.add(front);
            }
            if (i % 5 == 2 && !held.isEmpty()) {
                late.addFrame(held.remove(0));
            }
        }
        for (List<TagSighting> f : held) {
            late.addFrame(f);
        }
        Pose2d a = inOrder.getPose();
        Pose2d b = late.getPose();
        assertEquals(a.getX(), b.getX(), 1e-9);
        assertEquals(a.getY(), b.getY(), 1e-9);
        assertEquals(a.getRotation().getRadians(), b.getRotation().getRadians(), 1e-9);
    }

    @Test
    void framesBeforeAResetAreDropped() {
        TagEkf ekf = new TagEkf(MODULES);
        ekf.addOdometry(0, Rotation2d.ZERO, rolled(0));
        ekf.addOdometry(0.02, Rotation2d.ZERO, rolled(0));
        Pose2d pose = new Pose2d(3, 3, Rotation2d.ZERO);
        ekf.reset(pose);
        ekf.addFrame(frame(0.01, new Pose2d(2, 1.5, Rotation2d.ZERO)));
        assertEquals(TAGS.length, ekf.getRejectionCounts().get("Too Old"));
        assertEquals(pose, ekf.getPose());
    }

    @Test
    void limelightAnglesRoundTrip() {
        Translation3d v = new Translation3d(3.0, -0.8, 0.6);
        double tx = Math.toDegrees(Math.atan2(-v.getY(), v.getX()));
        double ty = Math.toDegrees(Math.atan2(v.getZ(), v.getX()));
        Translation3d back = TagSighting.fromAngles(tx, ty, v.getNorm());
        assertEquals(0, back.getDistance(v), 1e-9);
    }
}
