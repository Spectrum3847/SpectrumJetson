package org.spectrum3847.vision;

import static org.junit.jupiter.api.Assertions.*;

import edu.wpi.first.apriltag.AprilTagFieldLayout;
import edu.wpi.first.apriltag.AprilTagFields;
import edu.wpi.first.math.geometry.Pose2d;
import edu.wpi.first.math.geometry.Pose3d;
import edu.wpi.first.math.geometry.Rotation2d;
import edu.wpi.first.math.geometry.Rotation3d;
import edu.wpi.first.math.geometry.Transform3d;
import edu.wpi.first.math.geometry.Translation3d;
import org.junit.jupiter.api.Test;
import org.spectrum3847.vision.health.MountCheck;
import org.spectrum3847.vision.io.TagQualityEstimator;
import org.spectrum3847.vision.health.MountCheck.Status;
import org.spectrum3847.vision.testing.SyntheticCamera;
import org.spectrum3847.vision.testing.VisionScenario;

/**
 * The mount check on synthetic frames from the 2026 field: one camera's real mount differs from
 * robot code's (yaw +5°, pitch −3°, x +4 cm), a slow drive with 1 px corner noise.
 */
class MountCheckTest {
    static final AprilTagFieldLayout FIELD = AprilTagFieldLayout.loadField(AprilTagFields.kDefaultField);
    static final Transform3d[] MOUNTS = {
        new Transform3d(0.30, 0.30, 0.25, new Rotation3d(0, Math.toRadians(-15), Math.toRadians(20))),
        new Transform3d(0.30, -0.30, 0.25, new Rotation3d(0, Math.toRadians(-15), Math.toRadians(-20))),
        new Transform3d(0.25, 0.0, 0.45, new Rotation3d(0, Math.toRadians(-12), 0)),
    };

    static Transform3d perturbed(Transform3d m) {
        var r = m.getRotation();
        return new Transform3d(m.getX() + 0.04, m.getY(), m.getZ(),
                new Rotation3d(r.getX(), r.getY() + Math.toRadians(-3), r.getZ() + Math.toRadians(5)));
    }

    /** 3 m from the red alliance wall's tags, facing them, driving slowly side to side and turning a little. */
    static MountCheck drive(int cameras, int bad, boolean independentEstimator) {
        var s = new VisionScenario(FIELD);
        for (int i = 0; i < cameras; i++) {
            var c = SyntheticCamera.typical("cam" + i, 100 + i);
            c.pixelNoise = 1.0;
            c.maxRange = 6;
            s.camera(c, MOUNTS[i], i == bad ? perturbed(MOUNTS[i]) : MOUNTS[i]);
        }
        // The scenario's estimator is the truth. Independent: the check may use it even for a camera
        // that gave most of its measurements (as if it were field-calibrated odometry).
        if (independentEstimator) s.vision().mountCheck().config.maxSelfShare = 1.1;
        for (double t = 0; t <= 20; t += 0.02) {
            double x = 13.5 + 0.8 * Math.sin(0.15 * t), y = 4.0 + 1.2 * Math.sin(0.25 * t);
            double th = Math.toRadians(10 * Math.sin(0.2 * t));
            s.step(t, new Pose2d(x, y, new Rotation2d(th)), 0.03, 0.4, 0.03);
        }
        var mc = s.vision().mountCheck();
        for (var r : mc.reports()) System.out.println(r.camera() + " " + r.status() + " n=" + r.samples() + "/" + r.refSamples()
                + " ref=" + r.reference() + " err=" + java.util.Arrays.toString(r.error()) + " | " + r.message());
        return mc;
    }

    @Test
    void correctMountsNoAlarm() {
        var mc = drive(3, -1, false);
        assertEquals(3, mc.reports().size());
        for (var r : mc.reports()) {
            assertEquals(Status.OK, r.status(), r.message());
            assertTrue(r.reference().startsWith("cameras:"), r.reference());
        }
    }

    @Test
    void oneBadCameraOfThree() {
        var mc = drive(3, 0, false);
        var bad = mc.report("cam0");
        assertTrue(bad.status() == Status.BAD, bad.message());
        assertEquals(Status.OK, mc.report("cam1").status(), mc.report("cam1").message());
        assertEquals(Status.OK, mc.report("cam2").status(), mc.report("cam2").message());
        assertEquals("cameras:cam1+cam2", bad.reference());
        var truth = MountCheck.Mount.of(perturbed(MOUNTS[0]));
        var est = bad.estimated();
        assertEquals(truth.x(), est.x(), 0.03);
        assertEquals(truth.y(), est.y(), 0.03);
        assertEquals(truth.z(), est.z(), 0.02);
        assertEquals(truth.pitchDeg(), est.pitchDeg(), 0.5);
        assertEquals(truth.yawDeg(), est.yawDeg(), 1.0);
        assertEquals(truth.rollDeg(), est.rollDeg(), 0.5);
    }

    @Test
    void twoCamerasBlameTheRightOne() {
        var mc = drive(2, 1, false);
        assertTrue(mc.report("cam1").status().compareTo(Status.SUSPECT) >= 0, mc.report("cam1").message());
        assertEquals(Status.OK, mc.report("cam0").status(), mc.report("cam0").message());
    }

    @Test
    void singleCameraAgainstTheEstimator() {
        var mc = drive(1, 0, true);
        var r = mc.report("cam0");
        assertTrue(r.status() == Status.BAD, r.message());
        assertEquals("estimator", r.reference());
        assertEquals(-15 - 3, r.estimated().pitchDeg(), 0.5);
    }

    @Test
    void singleCameraOwnEstimatorOnlyHeightRollPitch() {
        // The estimator's pose came from this camera: x/y/yaw can't be checked, pitch still is.
        var r = drive(1, 0, false).report("cam0");
        assertEquals("none", r.reference());
        assertTrue(Double.isNaN(r.error()[5]));
        assertEquals(-3, r.error()[4], 0.5);
        assertEquals(Status.SUSPECT, r.status(), r.message());
    }

    @Test
    void singleCorrectCameraNoAlarm() {
        var mc = drive(1, -1, true);
        assertEquals(Status.OK, mc.report("cam0").status(), mc.report("cam0").message());
    }
}
