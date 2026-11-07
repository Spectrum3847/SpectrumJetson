package frc.spectrumLib.localization;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import frc.spectrumLib.localization.OdometryGuard.HeadingSource;
import frc.spectrumLib.localization.OdometryGuard.Output;
import frc.spectrumLib.localization.OdometryGuard.Sample;
import java.util.Optional;
import java.util.function.UnaryOperator;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.kinematics.ChassisVelocities;
import org.wpilib.math.kinematics.SwerveDriveKinematics;
import org.wpilib.math.kinematics.SwerveDriveOdometry;
import org.wpilib.math.kinematics.SwerveModulePosition;
import org.wpilib.math.kinematics.SwerveModuleVelocity;

class OdometryGuardTest {
    private static final double DT = 0.004;
    private static final Translation2d[] LOCATIONS = {
        new Translation2d(0.3, 0.3),
        new Translation2d(0.3, -0.3),
        new Translation2d(-0.3, 0.3),
        new Translation2d(-0.3, -0.3)
    };

    private final SwerveDriveKinematics kinematics = new SwerveDriveKinematics(LOCATIONS);
    private OdometryGuard guard;

    // The true robot: what perfect sensors would read.
    private double time;
    private double yaw;
    private double imuYaw;
    private double[] distances;
    private double[] angles;
    private SwerveDriveOdometry truth;

    // The guard's output, integrated the way PoseFusion does.
    private SwerveDriveOdometry guarded;
    private Output last;
    private int dropped;

    @BeforeEach
    void setUp() {
        guard = new OdometryGuard(new OdometryGuard.Settings(7.7, 14, LOCATIONS));
        time = 100;
        yaw = 1.0;
        imuYaw = -2.0;
        distances = new double[] {12.0, -3.0, 40.0, 7.5};
        angles = new double[4];
        truth = new SwerveDriveOdometry(kinematics, Rotation2d.fromRadians(yaw), positions());
        guarded = null;
        dropped = 0;
    }

    private SwerveModulePosition[] positions() {
        SwerveModulePosition[] p = new SwerveModulePosition[4];
        for (int m = 0; m < 4; m++) {
            p[m] = new SwerveModulePosition(distances[m], Rotation2d.fromRadians(angles[m]));
        }
        return p;
    }

    /** Drives the true robot for {@code seconds}, feeding the guard what {@code fault} leaves. */
    private void run(
            double seconds, double vx, double vy, double omega, UnaryOperator<Sample> fault) {
        for (int i = 0; i < Math.round(seconds / DT); i++) {
            time += DT;
            yaw += omega * DT;
            imuYaw += omega * DT;
            SwerveModuleVelocity[] v =
                    kinematics.toSwerveModuleVelocities(new ChassisVelocities(vx, vy, omega));
            for (int m = 0; m < 4; m++) {
                distances[m] += v[m].velocity * DT;
                angles[m] = v[m].angle.getRadians();
            }
            truth.update(Rotation2d.fromRadians(yaw), positions());
            Sample s =
                    fault.apply(
                            new Sample(
                                    time,
                                    yaw,
                                    true,
                                    imuYaw,
                                    true,
                                    distances.clone(),
                                    angles.clone(),
                                    new boolean[] {true, true, true, true}));
            Optional<Output> out = guard.update(s);
            if (out.isEmpty()) {
                dropped++;
                continue;
            }
            last = out.get();
            if (guarded == null) {
                guarded =
                        new SwerveDriveOdometry(
                                kinematics, last.heading(), last.positions(), truth.getPose());
            } else {
                guarded.update(last.heading(), last.positions());
            }
        }
    }

    /** The true drive motor 0 restarts its count, as after a power cycle. */
    private void resetModule0() {
        distances[0] = 0;
        truth.resetPosition(Rotation2d.fromRadians(yaw), positions(), truth.getPose());
    }

    private void drive(double seconds, double vx, double vy, double omega) {
        run(seconds, vx, vy, omega, s -> s);
    }

    private void assertTracksTruth(double tolerance) {
        Pose2d g = guarded.getPose();
        Pose2d t = truth.getPose();
        assertEquals(0, g.getTranslation().getDistance(t.getTranslation()), tolerance, "xy");
        assertEquals(0, g.getRotation().minus(t.getRotation()).getRadians(), tolerance, "heading");
    }

    /** A CANivore drop as logged: every reading 0, and the flags say so. */
    private static Sample dropped(Sample s) {
        return new Sample(
                s.time(),
                0,
                false,
                s.backupYaw(),
                false,
                new double[4],
                new double[4],
                new boolean[4]);
    }

    private static Sample module(Sample s, int m, double distance, boolean ok) {
        double[] d = s.distances().clone();
        boolean[] okFlags = s.moduleOk().clone();
        d[m] = distance;
        okFlags[m] = ok;
        return new Sample(
                s.time(),
                s.primaryYaw(),
                s.primaryOk(),
                s.backupYaw(),
                s.backupOk(),
                d,
                s.angles(),
                okFlags);
    }

    private static Sample noPrimary(Sample s) {
        return new Sample(
                s.time(),
                0,
                false,
                s.backupYaw(),
                s.backupOk(),
                s.distances(),
                s.angles(),
                s.moduleOk());
    }

    private static Sample noGyros(Sample s) {
        return new Sample(s.time(), 0, false, 0, false, s.distances(), s.angles(), s.moduleOk());
    }

    @Test
    void passesGoodSamplesThrough() {
        drive(1, 2, 1, 0.5);
        assertEquals(0b1111, last.modulesUsed());
        assertEquals(HeadingSource.PRIMARY, last.headingSource());
        assertEquals(yaw, last.heading().getRadians(), 1e-9);
        for (int m = 0; m < 4; m++) {
            assertEquals(distances[m], last.positions()[m].distance, 1e-9);
        }
        assertTracksTruth(1e-6);
    }

    @Test
    void canivoreDropFreezesThenResumes() {
        drive(0.5, 2, 0, 0);
        Pose2d before = guarded.getPose();
        run(0.6, 2, 0, 0.5, OdometryGuardTest::dropped);
        assertEquals(150, dropped);
        assertEquals(before, guarded.getPose());

        drive(0.5, 2, 0, 0);
        assertEquals(0b1111, last.modulesUsed());
        // The gap's travel arrives in one sample, along the end angles: a few cm off at most.
        assertTracksTruth(0.1);
    }

    @Test
    void zerosWithConnectedFlagsAreRejectedAsTooFast() {
        drive(0.5, 2, 0, 0);
        Pose2d before = guarded.getPose();
        run(
                0.6,
                0,
                0,
                0,
                s ->
                        new Sample(
                                s.time(),
                                0,
                                true,
                                s.backupYaw(),
                                true,
                                new double[4],
                                new double[4],
                                s.moduleOk()));
        assertTrue(guarded.getPose().getTranslation().getDistance(before.getTranslation()) < 1e-9);
        drive(0.5, 1, 0, 0);
        assertTracksTruth(0.02);
    }

    @Test
    void oneModuleOutSolvesFromTheOtherThree() {
        drive(0.2, 1, 0, 0);
        run(1, 1.5, -0.5, 1.2, s -> module(s, 2, 0, false));
        assertEquals(0b1011, last.modulesUsed());
        assertTracksTruth(1e-3);
    }

    @Test
    void twoModulesAreEnough() {
        drive(0.2, 1, 0, 0);
        run(1, 1.5, -0.5, 1.2, s -> module(module(s, 2, 0, false), 3, 0, false));
        assertEquals(0b0011, last.modulesUsed());
        assertTracksTruth(1e-3);
    }

    @Test
    void aCreepTooSmallForRotation2dKeepsTheOutModulesAngle() {
        drive(0.2, 0, 1, 0); // every module at +90 deg
        // Module 2 out while the robot creeps the other way at 0.1 mm/s: 0.4 um a sample, too
        // short for Rotation2d, which would report an error and point the module at 0 rad.
        run(0.1, 0, -1e-4, 0, s -> module(s, 2, 0, false));
        assertEquals(0b1011, last.modulesUsed());
        assertEquals(Math.PI / 2, last.positions()[2].angle.getRadians(), 1e-9);
    }

    @Test
    void oneModuleHoldsTheTranslation() {
        drive(0.2, 1, 0, 0);
        Pose2d before = guarded.getPose();
        run(0.2, 1, 0, 0, s -> module(module(module(s, 1, 0, false), 2, 0, false), 3, 0, false));
        assertEquals(0, last.modulesUsed());
        assertEquals(
                0, guarded.getPose().getTranslation().getDistance(before.getTranslation()), 1e-9);
    }

    @Test
    void implausibleModuleStepIsIgnored() {
        drive(0.2, 1, 0, 0);
        run(0.004, 1, 0, 0, s -> module(s, 0, s.distances()[0] + 1.0, true));
        assertEquals(0b1110, last.modulesUsed());
        drive(0.5, 1, 0, 0);
        assertTracksTruth(1e-3);
    }

    @Test
    void reportedModuleResetRebaselines() {
        drive(0.2, 1, 0, 0);
        resetModule0();
        guard.markResets(false, new boolean[] {true, false, false, false});
        drive(0.5, 1, 0, 0.3);
        assertEquals(0b1111, last.modulesUsed());
        assertTracksTruth(1e-3);
    }

    @Test
    void unreportedResetRebaselinesAfterASecond() {
        drive(0.2, 1, 0, 0);
        resetModule0();
        drive(OdometryGuard.REBASELINE_SECONDS - 0.1, 1, 0, 0);
        assertEquals(0b1110, last.modulesUsed());
        drive(0.2, 1, 0, 0);
        assertEquals(0b1111, last.modulesUsed());
        assertTracksTruth(1e-3);
    }

    @Test
    void backupGyroCarriesTheHeadingAndPrimarySnapsBack() {
        drive(0.2, 0, 0, 1);
        run(0.5, 0, 0, 1, OdometryGuardTest::noPrimary);
        assertEquals(HeadingSource.BACKUP, last.headingSource());
        assertTracksTruth(1e-6);

        double offBy = 0.3;
        run(0.5, 0, 0, 1, s -> noPrimary(withBackupYaw(s, s.backupYaw() + offBy)));
        drive(0.1, 0, 0, 1);
        // The primary kept counting through the gap, so its heading wins over the drifted backup.
        assertEquals(HeadingSource.PRIMARY, last.headingSource());
        assertEquals(0, last.heading().minus(Rotation2d.fromRadians(yaw)).getRadians(), 1e-9);
    }

    private static Sample withBackupYaw(Sample s, double backupYaw) {
        return new Sample(
                s.time(),
                s.primaryYaw(),
                s.primaryOk(),
                backupYaw,
                s.backupOk(),
                s.distances(),
                s.angles(),
                s.moduleOk());
    }

    @Test
    void wheelsCarryTheHeadingWithBothGyrosOut() {
        drive(0.2, 0, 0, 0);
        run(1, 1, 0, 1, OdometryGuardTest::noGyros);
        assertEquals(HeadingSource.WHEELS, last.headingSource());
        assertTracksTruth(1e-3);
    }

    @Test
    void reportedGyroResetReoffsetsInsteadOfJumping() {
        drive(0.2, 0, 0, 1);
        double headingBefore = last.heading().getRadians();
        yaw = 0;
        guard.markResets(true, new boolean[4]);
        run(0.004, 0, 0, 0, s -> s);
        assertEquals(headingBefore, last.heading().getRadians(), 1e-9);
    }

    @Test
    void backupShadowFollowsTheBackupAlignedToThePrimary() {
        drive(1, 0, 0, 1);
        assertEquals(
                0,
                Rotation2d.fromRadians(guard.getBackupShadowHeading())
                        .minus(Rotation2d.fromRadians(yaw))
                        .getRadians(),
                1e-9);
    }
}
