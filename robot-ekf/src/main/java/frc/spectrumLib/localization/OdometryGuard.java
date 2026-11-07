package frc.spectrumLib.localization;

import java.util.Optional;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.kinematics.SwerveModulePosition;
import org.wpilib.math.util.MathUtil;

/**
 * Screens each odometry sample before {@link PoseFusion} sees it, so a device that drops off CAN
 * cannot move the pose. Pure logic on logged inputs, so it replays and is unit tested.
 *
 * <p>When the CANivore's link to SystemCore drops, every device on it reads 0 for up to 1.3 s
 * (TXMAN1 Q34, Q19, r16). Integrated as-is, that moved the fused pose 45 m.
 *
 * <p>Modules: one counts for a sample only when it is connected, did not read a dead 0, and its
 * travel since its last accepted sample fits {@code maxSpeed} over the elapsed time. Its baseline
 * advances only when it is used, so the first good sample after a gap carries the whole gap. The
 * motion is solved by least squares from the modules used (two or more) and handed on as one
 * consistent set of module positions; with fewer, the translation holds and vision holds the pose.
 * A module re-baselines, without integrating, after a reported device reset, or after its readings
 * have been steady but implausible for {@link #REBASELINE_SECONDS} (a reset nobody reported).
 *
 * <p>Heading, in order: the primary gyro (absolute, so after a gap it snaps back to where the gyro,
 * which kept running, says the robot points), the backup gyro's change, the wheels' rotation, else
 * none, and with no heading and no translation the sample is dropped.
 */
public final class OdometryGuard {

    /** Implausible but steady this long means the device reset under us. */
    static final double REBASELINE_SECONDS = 1.0;

    /**
     * Sample times jitter (the sim's gyro steps between samples 3 ms apart), so no check is tighter
     * than this.
     */
    private static final double MIN_ELAPSED_SECONDS = 0.02;

    private static final double DISTANCE_SLACK_METERS = 0.02;
    private static final double YAW_SLACK_RADIANS = 0.02;

    public enum HeadingSource {
        PRIMARY,
        BACKUP,
        WHEELS,
        NONE
    }

    /**
     * Limits and geometry.
     *
     * @param maxSpeed fastest believable wheel travel, m/s (about 1.5x top speed)
     * @param maxTurnRate fastest believable gyro rotation, rad/s
     * @param moduleLocations module positions from the robot centre, kinematics order
     */
    public record Settings(double maxSpeed, double maxTurnRate, Translation2d[] moduleLocations) {}

    /**
     * One odometry sample.
     *
     * @param time seconds
     * @param primaryYaw primary gyro yaw, radians
     * @param primaryOk primary gyro connected and not a dead read
     * @param backupYaw backup gyro yaw, radians
     * @param backupOk backup gyro present and reading
     * @param distances module drive distances, metres
     * @param angles module steer angles, radians
     * @param moduleOk per module: connected and not a dead read
     */
    public record Sample(
            double time,
            double primaryYaw,
            boolean primaryOk,
            double backupYaw,
            boolean backupOk,
            double[] distances,
            double[] angles,
            boolean[] moduleOk) {}

    /**
     * What to hand the estimators.
     *
     * @param heading gyro angle for the estimators
     * @param positions module positions for the estimators
     * @param modulesUsed bit {@code m} set when module {@code m} was used
     * @param headingSource where this sample's heading change came from
     */
    public record Output(
            Rotation2d heading,
            SwerveModulePosition[] positions,
            int modulesUsed,
            HeadingSource headingSource) {}

    /** One sensor's accepted baseline and its plausibility check. */
    private static final class Channel {
        private final boolean angular;
        private boolean haveBaseline = false;
        private double baseline;
        private double baselineTime;
        private boolean resetPending = false;
        private boolean haveLast = false;
        private double lastValue;
        private double lastTime;
        private double implausibleSince = Double.NaN;

        /** Set when {@link #check} re-baselined. */
        private boolean rebased = false;

        Channel(boolean angular) {
            this.angular = angular;
        }

        private double diff(double a, double b) {
            return angular ? MathUtil.angleModulus(a - b) : a - b;
        }

        /** The change since the baseline, or NaN when this sample is not usable. */
        double check(double value, double time, boolean ok, double maxRate, double slack) {
            rebased = false;
            if (!ok) {
                haveLast = false;
                implausibleSince = Double.NaN;
                return Double.NaN;
            }
            boolean steady =
                    haveLast
                            && Math.abs(diff(value, lastValue))
                                    <= maxRate * Math.max(time - lastTime, MIN_ELAPSED_SECONDS)
                                            + slack;
            haveLast = true;
            lastValue = value;
            lastTime = time;
            if (!haveBaseline || resetPending) {
                rebase(value, time);
                return Double.NaN;
            }
            // A reading that only continues an implausible run is held to the time the run began,
            // or a stuck value would turn plausible just by waiting.
            boolean continuesRun = steady && !Double.isNaN(implausibleSince);
            double elapsed = (continuesRun ? implausibleSince : time) - baselineTime;
            double change = diff(value, baseline);
            if (Math.abs(change) <= maxRate * Math.max(elapsed, MIN_ELAPSED_SECONDS) + slack) {
                implausibleSince = Double.NaN;
                return change;
            }
            if (!continuesRun) {
                implausibleSince = time;
            } else if (time - implausibleSince >= REBASELINE_SECONDS) {
                rebase(value, time);
            }
            return Double.NaN;
        }

        void commit(double value, double time) {
            baseline = value;
            baselineTime = time;
        }

        private void rebase(double value, double time) {
            commit(value, time);
            haveBaseline = true;
            resetPending = false;
            implausibleSince = Double.NaN;
            rebased = true;
        }
    }

    private final Settings settings;
    private final int moduleCount;
    private final Channel primary = new Channel(true);
    private final Channel backup = new Channel(true);
    private final Channel[] modules;

    private final double[] outDistances;
    private final Rotation2d[] outAngles;
    private boolean outInitialized = false;

    private boolean headingInitialized = false;
    private double heading = 0;
    private double primaryOffset = 0;

    private boolean backupShadowInitialized = false;
    private double backupShadowOffset = 0;
    private double backupShadowHeading = Double.NaN;

    public OdometryGuard(Settings settings) {
        this.settings = settings;
        this.moduleCount = settings.moduleLocations().length;
        this.modules = new Channel[moduleCount];
        for (int m = 0; m < moduleCount; m++) {
            modules[m] = new Channel(false);
        }
        this.outDistances = new double[moduleCount];
        this.outAngles = new Rotation2d[moduleCount];
    }

    /**
     * Notes device resets reported since the last loop; each takes effect on that device's next
     * reading, which becomes its new baseline.
     */
    public void markResets(boolean primaryReset, boolean[] moduleResets) {
        primary.resetPending |= primaryReset;
        for (int m = 0; m < moduleCount && m < moduleResets.length; m++) {
            modules[m].resetPending |= moduleResets[m];
        }
    }

    /** The heading handed to the estimators, radians. */
    public double getHeading() {
        return heading;
    }

    /** The backup gyro on the primary's heading, aligned once at the first reading of both. */
    public double getBackupShadowHeading() {
        return backupShadowHeading;
    }

    /** Screens one sample. Empty when it can move nothing. */
    public Optional<Output> update(Sample s) {
        double t = s.time();

        double[] change = new double[moduleCount];
        int used = 0;
        int usedCount = 0;
        for (int m = 0; m < moduleCount; m++) {
            boolean ok = m < s.moduleOk().length && s.moduleOk()[m];
            change[m] =
                    modules[m].check(
                            s.distances()[m], t, ok, settings.maxSpeed(), DISTANCE_SLACK_METERS);
            if (!Double.isNaN(change[m])) {
                used |= 1 << m;
                usedCount++;
            }
        }
        if (!outInitialized) {
            for (int m = 0; m < moduleCount; m++) {
                outDistances[m] = s.distances()[m];
                outAngles[m] = Rotation2d.fromRadians(s.angles()[m]);
            }
            outInitialized = true;
        }
        // One module cannot separate translation from rotation.
        if (usedCount < 2) {
            used = 0;
        }

        double[] twist = used != 0 ? solve(change, s.angles(), used) : new double[3];

        double primaryChange =
                primary.check(
                        s.primaryYaw(),
                        t,
                        s.primaryOk(),
                        settings.maxTurnRate(),
                        YAW_SLACK_RADIANS);
        double backupChange =
                backup.check(
                        s.backupYaw(), t, s.backupOk(), settings.maxTurnRate(), YAW_SLACK_RADIANS);
        if (!Double.isNaN(backupChange)) {
            backup.commit(s.backupYaw(), t);
        }

        HeadingSource source;
        if (primary.rebased) {
            if (!headingInitialized) {
                heading = s.primaryYaw();
            }
            primaryOffset = heading - s.primaryYaw();
            source = HeadingSource.PRIMARY;
        } else if (!Double.isNaN(primaryChange)) {
            primary.commit(s.primaryYaw(), t);
            heading = s.primaryYaw() + primaryOffset;
            source = HeadingSource.PRIMARY;
        } else if (!Double.isNaN(backupChange)) {
            heading += backupChange;
            source = HeadingSource.BACKUP;
        } else if (used != 0) {
            heading += twist[2];
            source = HeadingSource.WHEELS;
        } else {
            source = HeadingSource.NONE;
        }
        headingInitialized |= source != HeadingSource.NONE;

        if (source == HeadingSource.PRIMARY && s.backupOk() && !backupShadowInitialized) {
            backupShadowOffset = heading - s.backupYaw();
            backupShadowInitialized = true;
        }
        if (backupShadowInitialized && s.backupOk()) {
            backupShadowHeading = s.backupYaw() + backupShadowOffset;
        }

        if (used == 0 && source == HeadingSource.NONE) {
            return Optional.empty();
        }

        SwerveModulePosition[] positions = new SwerveModulePosition[moduleCount];
        for (int m = 0; m < moduleCount; m++) {
            if ((used & (1 << m)) != 0) {
                modules[m].commit(s.distances()[m], t);
                outDistances[m] += change[m];
                outAngles[m] = Rotation2d.fromRadians(s.angles()[m]);
            } else if (used != 0) {
                Translation2d loc = settings.moduleLocations()[m];
                double vx = twist[0] - twist[2] * loc.getY();
                double vy = twist[1] + twist[2] * loc.getX();
                double d = Math.hypot(vx, vy);
                // Rotation2d reports an error (with a stack trace) and points at 0 rad for a vector
                // of 1e-6 or less; under that the module keeps its last angle.
                if (d > 1e-6) {
                    outDistances[m] += d;
                    outAngles[m] = new Rotation2d(vx, vy);
                }
            }
            positions[m] = new SwerveModulePosition(outDistances[m], outAngles[m]);
        }
        return Optional.of(new Output(Rotation2d.fromRadians(heading), positions, used, source));
    }

    /**
     * Least-squares (dx, dy, dtheta) from the used modules: each module moved {@code change} metres
     * toward its end angle, and a twist moves module (x, y) by (dx - w y, dy + w x).
     */
    private double[] solve(double[] change, double[] angles, int used) {
        double n = 0, sx = 0, sy = 0, sr = 0, bx = 0, by = 0, bw = 0;
        for (int m = 0; m < moduleCount; m++) {
            if ((used & (1 << m)) == 0) {
                continue;
            }
            double x = settings.moduleLocations()[m].getX();
            double y = settings.moduleLocations()[m].getY();
            double vx = change[m] * Math.cos(angles[m]);
            double vy = change[m] * Math.sin(angles[m]);
            n++;
            sx += x;
            sy += y;
            sr += x * x + y * y;
            bx += vx;
            by += vy;
            bw += x * vy - y * vx;
        }
        // Normal equations [[n, 0, -sy], [0, n, sx], [-sy, sx, sr]] u = [bx, by, bw].
        double det = n * sr - sx * sx - sy * sy;
        if (Math.abs(det) < 1e-12) {
            return new double[3];
        }
        double w = (n * bw + sy * bx - sx * by) / det;
        return new double[] {(bx + sy * w) / n, (by - sx * w) / n, w};
    }
}
