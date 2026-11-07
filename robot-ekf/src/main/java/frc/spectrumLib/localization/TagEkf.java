package frc.spectrumLib.localization;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.geometry.Translation3d;
import org.wpilib.math.kinematics.SwerveModulePosition;
import org.wpilib.math.util.MathUtil;

/**
 * An extended Kalman filter over (x, y, heading) that takes every camera's tags one at a time, in
 * the style of 971's AOS localizer: each tag is a bearing and a distance from its camera, so a
 * single or far tag still corrects the pose at a low weight instead of being thrown away, and every
 * camera feeds the same estimate.
 *
 * <ul>
 *   <li><b>Predict</b> on every odometry sample: wheel translation, gyro heading change. Variance
 *       grows with distance driven, and more when the modules disagree with each other or with the
 *       gyro (slip). Heading gets very little.
 *   <li><b>Correct</b> per tag, at the frame's capture time. About {@link #HISTORY_SECONDS} of
 *       states are kept; a frame is inserted at its time and odometry and later frames are replayed
 *       over it, so the result does not depend on arrival order.
 *   <li><b>Reject</b> a tag whose innovation fails a chi-squared test. If tags keep failing for
 *       {@link #RELOCALIZE_SECONDS}, the covariance is widened so the cameras can pull it back.
 * </ul>
 *
 * <p>Noise values are starting points to tune against logs, not measured.
 */
public class TagEkf {

    static final double HISTORY_SECONDS = 1.5;
    private static final int CAPACITY = 1024;

    /**
     * Translation variance per metre driven (m²/m): ~4 cm after 1 m. Odometry, heading, bearing,
     * range and timing values re-tuned in TagEkfTuner on 9 TXMAN1 logs with MountEstimator on:
     * held-out p90 0.138 -> 0.122 m, NIS 0.75 -> 1.9 (docs/pose-improvements.md).
     */
    static final double ODOM_VAR_PER_METER = 0.0018;

    /** Translation variance per metre of slip (m²/m). */
    static final double SLIP_VAR_PER_METER = 0.05;

    /** Heading random walk (rad²/s). */
    static final double HEADING_VAR_PER_SECOND = 1.3e-5;

    /** Heading variance per radian turned (rad²/rad). */
    static final double HEADING_VAR_PER_RADIAN = 9.6e-4;

    /**
     * Bearing std-dev on the optical axis. Was 1 deg, mostly covering mount-yaw error; with
     * MountEstimator correcting the mounts the tags are good to ~0.25 deg.
     */
    static final double BEARING_STD_RAD = Math.toRadians(0.25);

    static final double RANGE_STD_BASE_M = 0.005;
    static final double RANGE_STD_PER_M2 = 0.005;

    /** Std-devs scale by 1 + (angle off the optical axis / this)². */
    static final double OFF_AXIS_REF_RAD = Math.toRadians(35);

    /** Capture-time error, turned into noise by the robot's speed. */
    static final double TIMING_STD_SECONDS = 0.000625;

    static final double MIN_RANGE_M = 0.2;
    static final double MAX_RANGE_M = 8.0;

    /** Chi-squared, 2 degrees of freedom, 99.9%. */
    static final double GATE_CHI2 = 13.8;

    static final double RELOCALIZE_SECONDS = 1.0;
    static final int RELOCALIZE_MIN_REJECTS = 20;
    static final double RELOCALIZE_XY_STD_M = 0.5;
    static final double RELOCALIZE_THETA_STD_RAD = Math.toRadians(5);

    static final double RESET_XY_STD_M = 0.05;
    static final double RESET_THETA_STD_RAD = Math.toRadians(1);

    private static final double UNSEEDED_VAR = 1e4;

    /**
     * The noise model, so replay (TagEkfTuner) can sweep it. {@link #DEFAULT} is the constants
     * above.
     *
     * @param slipYawWeight weight of the wheel-vs-gyro rotation gap in the slip term (1 = as built)
     */
    public record Noise(
            double odomVarPerMeter,
            double slipVarPerMeter,
            double slipYawWeight,
            double headingVarPerSecond,
            double headingVarPerRadian,
            double bearingStdRad,
            double rangeStdBaseM,
            double rangeStdPerM2,
            double timingStdSeconds,
            double gateChi2) {
        public static final Noise DEFAULT =
                new Noise(
                        ODOM_VAR_PER_METER,
                        SLIP_VAR_PER_METER,
                        1.0,
                        HEADING_VAR_PER_SECOND,
                        HEADING_VAR_PER_RADIAN,
                        BEARING_STD_RAD,
                        RANGE_STD_BASE_M,
                        RANGE_STD_PER_M2,
                        TIMING_STD_SECONDS,
                        GATE_CHI2);
    }

    private final Noise noise;

    /** Per-camera tag counts, and this loop's residuals of the tags that passed. */
    public static final class CameraStats {
        public long accepted;
        public long rejected;

        /** Whether the residual arrays were last logged non-empty, so they're cleared once. */
        boolean loggedResiduals;

        private double[] bearingResidualsDeg = new double[8];
        private double[] rangeResidualsM = new double[8];
        private int loopCount;

        private void add(double bearingDeg, double rangeM) {
            if (loopCount == bearingResidualsDeg.length) {
                bearingResidualsDeg = java.util.Arrays.copyOf(bearingResidualsDeg, loopCount * 2);
                rangeResidualsM = java.util.Arrays.copyOf(rangeResidualsM, loopCount * 2);
            }
            bearingResidualsDeg[loopCount] = bearingDeg;
            rangeResidualsM[loopCount] = rangeM;
            loopCount++;
        }

        public double[] bearingResidualsDeg() {
            return java.util.Arrays.copyOf(bearingResidualsDeg, loopCount);
        }

        public double[] rangeResidualsM() {
            return java.util.Arrays.copyOf(rangeResidualsM, loopCount);
        }

        public int loopCount() {
            return loopCount;
        }
    }

    /** A tag reduced to what the update needs. Robot frame, camera at (cx, cy). */
    private record Measured(
            String camera,
            double bearing,
            double range,
            double cx,
            double cy,
            double tagX,
            double tagY,
            double noiseScale) {}

    private static final class Correction {
        final double time;
        final Measured[] tags;
        final double px;
        final double py;
        final double ptheta;
        final double varXy;
        final double varTheta;
        boolean inflate;

        /** A one-axis position measurement: px, py the unit normal, ptheta the value, varXy. */
        boolean axis;

        /** A frame of tag corners instead of tags. */
        CornerSighting[] corners;

        Correction(double time, Measured[] tags) {
            this(time, tags, 0, 0, 0, 0, 0);
        }

        Correction(
                double time,
                Measured[] tags,
                double px,
                double py,
                double ptheta,
                double varXy,
                double varTheta) {
            this.time = time;
            this.tags = tags;
            this.px = px;
            this.py = py;
            this.ptheta = ptheta;
            this.varXy = varXy;
            this.varTheta = varTheta;
        }
    }

    private final int modules;
    private final double[] moduleX;
    private final double[] moduleY;
    private final double meanModuleRadius;

    /** (AᵀA)⁻¹ for the least-squares chassis twist from module displacements. */
    private final double[] twistNormalInv;

    private final double[] sampleTime = new double[CAPACITY];
    private final double[] sampleDx = new double[CAPACITY];
    private final double[] sampleDy = new double[CAPACITY];
    private final double[] sampleDtheta = new double[CAPACITY];
    private final double[] sampleDt = new double[CAPACITY];
    private final double[] sampleVarXy = new double[CAPACITY];
    private final double[] sampleVarTheta = new double[CAPACITY];

    /** State and covariance after each sample's prediction, before its corrections. */
    private final double[] preState = new double[CAPACITY * 3];

    private final double[] preCov = new double[CAPACITY * 9];

    /** State and covariance after each sample's corrections, before the next prediction. */
    private final double[] postState = new double[CAPACITY * 3];

    private final double[] postCov = new double[CAPACITY * 9];

    /** Self-checking uncertainty: mean frame NIS above this widens P first. 0 = off. */
    private double adaptiveNis = 0;

    private double adaptiveGain = 0;
    private int oldest = 0;
    private int size = 0;

    /** Corrections still inside the history, in time order. */
    private final List<Correction> corrections = new ArrayList<>();

    private final double[] s = new double[3];
    private final double[] p = new double[9];

    private boolean haveOdometry = false;
    private double lastGyro;
    private final double[] lastDistances;
    private double odometryNoiseScale = 1.0;

    private boolean seeded = false;

    /** A good frame had at least half its tags pass the gate. */
    private double lastGoodFrameTime = Double.NaN;

    private int rejectsSinceGoodFrame = 0;
    private Correction recording;

    private long acceptedCount = 0;
    private long rejectedCount = 0;
    private long relocalizations = 0;
    private final Map<String, Long> rejectionCounts = new LinkedHashMap<>();
    private final Map<String, CameraStats> cameraStats = new LinkedHashMap<>();

    private final double[] moduleDx;
    private final double[] moduleDy;

    /**
     * @param moduleLocations module positions from the robot centre, robot frame
     */
    public TagEkf(Translation2d[] moduleLocations) {
        this(moduleLocations, Noise.DEFAULT);
    }

    /**
     * @param moduleLocations module positions from the robot centre, robot frame
     * @param noise the noise model
     */
    public TagEkf(Translation2d[] moduleLocations, Noise noise) {
        this.noise = noise;
        modules = moduleLocations.length;
        moduleX = new double[modules];
        moduleY = new double[modules];
        lastDistances = new double[modules];
        moduleDx = new double[modules];
        moduleDy = new double[modules];
        double sx = 0;
        double sy = 0;
        double sr2 = 0;
        double radius = 0;
        for (int i = 0; i < modules; i++) {
            moduleX[i] = moduleLocations[i].getX();
            moduleY[i] = moduleLocations[i].getY();
            sx += moduleX[i];
            sy += moduleY[i];
            sr2 += sq(moduleX[i]) + sq(moduleY[i]);
            radius += moduleLocations[i].getNorm();
        }
        meanModuleRadius = radius / modules;
        twistNormalInv = inverse3(new double[] {modules, 0, -sy, 0, modules, sx, -sy, sx, sr2});
        p[0] = UNSEEDED_VAR;
        p[4] = UNSEEDED_VAR;
        p[8] = UNSEEDED_VAR;
    }

    /**
     * Multiplies odometry translation variance, e.g. while the robot is tilted on a bump.
     *
     * @param scale 1 for normal driving
     */
    public void setOdometryNoiseScale(double scale) {
        odometryNoiseScale = scale;
    }

    /**
     * Predicts with one odometry sample.
     *
     * @param timestampSeconds sample time
     * @param gyro gyro yaw
     * @param positions module positions, same order as the locations
     */
    public void addOdometry(
            double timestampSeconds, Rotation2d gyro, SwerveModulePosition[] positions) {
        double g = gyro.getRadians();
        if (!haveOdometry) {
            haveOdometry = true;
            lastGyro = g;
            for (int i = 0; i < modules; i++) {
                lastDistances[i] = positions[i].distance;
            }
            size = 0;
            pushSample(timestampSeconds, 0, 0, 0, 0, 0, 0);
            return;
        }
        double bx = 0;
        double by = 0;
        double bw = 0;
        double[] dxs = moduleDx;
        double[] dys = moduleDy;
        for (int i = 0; i < modules; i++) {
            double d = positions[i].distance - lastDistances[i];
            lastDistances[i] = positions[i].distance;
            double a = positions[i].angle.getRadians();
            dxs[i] = d * Math.cos(a);
            dys[i] = d * Math.sin(a);
            bx += dxs[i];
            by += dys[i];
            bw += -moduleY[i] * dxs[i] + moduleX[i] * dys[i];
        }
        double[] n = twistNormalInv;
        double vx = n[0] * bx + n[1] * by + n[2] * bw;
        double vy = n[3] * bx + n[4] * by + n[5] * bw;
        double w = n[6] * bx + n[7] * by + n[8] * bw;
        double residual = 0;
        for (int i = 0; i < modules; i++) {
            residual += sq(dxs[i] - (vx - w * moduleY[i])) + sq(dys[i] - (vy + w * moduleX[i]));
        }
        double dGyro = MathUtil.angleModulus(g - lastGyro);
        lastGyro = g;
        double slip =
                Math.sqrt(residual / modules)
                        + noise.slipYawWeight() * Math.abs(w - dGyro) * meanModuleRadius;

        // Pose exponential with the gyro's heading change, as WPILib's odometry does.
        double sinTerm;
        double cosTerm;
        if (Math.abs(dGyro) < 1e-9) {
            sinTerm = 1.0 - dGyro * dGyro / 6.0;
            cosTerm = 0.5 * dGyro;
        } else {
            sinTerm = Math.sin(dGyro) / dGyro;
            cosTerm = (1 - Math.cos(dGyro)) / dGyro;
        }
        double lx = vx * sinTerm - vy * cosTerm;
        double ly = vx * cosTerm + vy * sinTerm;

        double dt = Math.max(0, timestampSeconds - newestTime());
        double varXy =
                (noise.odomVarPerMeter() * Math.hypot(lx, ly) + noise.slipVarPerMeter() * slip)
                        * odometryNoiseScale;
        double varTheta =
                noise.headingVarPerSecond() * dt + noise.headingVarPerRadian() * Math.abs(dGyro);
        if (size > 0) {
            storePost(index(size - 1));
        }
        predict(s, p, lx, ly, dGyro, varXy, varTheta);
        while (size > 0 && sampleTime[oldest] < timestampSeconds - HISTORY_SECONDS) {
            dropOldest();
        }
        if (size == CAPACITY) {
            dropOldest();
        }
        pushSample(timestampSeconds, lx, ly, dGyro, dt, varXy, varTheta);
    }

    /**
     * Hard-resets the pose (auto start, driver reorient). Frames captured before it are dropped.
     *
     * @param pose the new pose
     */
    public void reset(Pose2d pose) {
        s[0] = pose.getX();
        s[1] = pose.getY();
        s[2] = pose.getRotation().getRadians();
        java.util.Arrays.fill(p, 0);
        p[0] = sq(RESET_XY_STD_M);
        p[4] = sq(RESET_XY_STD_M);
        p[8] = sq(RESET_THETA_STD_RAD);
        corrections.clear();
        if (size > 0) {
            int newest = index(size - 1);
            oldest = newest;
            size = 1;
            storePre(newest);
            lastGoodFrameTime = sampleTime[newest];
        }
        seeded = true;
        rejectsSinceGoodFrame = 0;
    }

    /**
     * Applies a one-axis position measurement: {@code nx * x + ny * y = value}, for field knowledge
     * such as a bump crossing or a wall the robot can't be past. Needs a seeded filter.
     *
     * @param timestampSeconds when it held
     * @param nx unit normal, x
     * @param ny unit normal, y
     * @param value the measured projection, metres
     * @param std its std-dev, metres
     * @return false if it fell outside the history or the filter isn't seeded
     */
    public boolean addAxis(
            double timestampSeconds, double nx, double ny, double value, double std) {
        if (!seeded) {
            return false;
        }
        Correction c = new Correction(clampTime(timestampSeconds), null, nx, ny, value, sq(std), 0);
        c.axis = true;
        return insert(c, "Axis");
    }

    /**
     * Applies a whole-pose measurement at its capture time (the seed every track shares).
     *
     * @param pose measured pose
     * @param timestampSeconds capture time
     * @param xyStd translation std-dev, metres
     * @param thetaStd heading std-dev, radians
     */
    public void addPose(Pose2d pose, double timestampSeconds, double xyStd, double thetaStd) {
        Correction c =
                new Correction(
                        clampTime(timestampSeconds),
                        null,
                        pose.getX(),
                        pose.getY(),
                        pose.getRotation().getRadians(),
                        sq(xyStd),
                        sq(thetaStd));
        if (insert(c, "Pose")) {
            if (!seeded) {
                lastGoodFrameTime = c.time;
            }
            seeded = true;
        }
    }

    /**
     * Applies one camera frame's tags. They must share one capture time.
     *
     * @param frame the frame's tags
     */
    public void addFrame(List<TagSighting> frame) {
        if (frame.isEmpty()) {
            return;
        }
        if (!seeded) {
            for (TagSighting t : frame) {
                reject(t.camera(), "Not Seeded");
            }
            return;
        }
        List<Measured> kept = new ArrayList<>(frame.size());
        for (TagSighting t : frame) {
            Measured m = measure(t);
            if (m == null) {
                reject(t.camera(), "Range");
            } else {
                kept.add(m);
            }
        }
        if (kept.isEmpty()) {
            return;
        }
        Correction c =
                new Correction(
                        clampTime(frame.get(0).timestampSeconds()), kept.toArray(new Measured[0]));
        if (rejectsSinceGoodFrame >= RELOCALIZE_MIN_REJECTS
                && c.time - lastGoodFrameTime >= RELOCALIZE_SECONDS) {
            c.inflate = true;
            relocalizations++;
            rejectsSinceGoodFrame = 0;
            lastGoodFrameTime = c.time;
        }
        if (!insert(c, null)) {
            for (Measured m : c.tags) {
                reject(m.camera(), size == 0 ? "No Odometry" : "Too Old");
            }
        }
    }

    /**
     * Applies one camera frame's tags as corner pixels (eight measurements per tag), gated per tag
     * at the 8-dof equivalent of {@code gateChi2}. They must share one capture time.
     *
     * @param frame the frame's tags
     */
    public void addCornerFrame(List<CornerSighting> frame) {
        if (frame.isEmpty()) {
            return;
        }
        if (!seeded) {
            for (CornerSighting t : frame) {
                reject(t.camera(), "Not Seeded");
            }
            return;
        }
        Correction c = new Correction(clampTime(frame.get(0).timestampSeconds()), null);
        c.corners = frame.toArray(new CornerSighting[0]);
        if (rejectsSinceGoodFrame >= RELOCALIZE_MIN_REJECTS
                && c.time - lastGoodFrameTime >= RELOCALIZE_SECONDS) {
            c.inflate = true;
            relocalizations++;
            rejectsSinceGoodFrame = 0;
            lastGoodFrameTime = c.time;
        }
        if (!insert(c, null)) {
            for (CornerSighting t : frame) {
                reject(t.camera(), size == 0 ? "No Odometry" : "Too Old");
            }
        }
    }

    private static Measured measure(TagSighting t) {
        Translation3d inCamera = t.cameraToTag();
        double norm = inCamera.getNorm();
        if (!(norm > 0)) {
            return null;
        }
        Translation3d inRobot = inCamera.rotateBy(t.robotToCamera().getRotation());
        double range = Math.hypot(inRobot.getX(), inRobot.getY());
        if (range < MIN_RANGE_M || range > MAX_RANGE_M) {
            return null;
        }
        double offAxis = Math.acos(Math.clamp(inCamera.getX() / norm, -1.0, 1.0));
        return new Measured(
                t.camera(),
                Math.atan2(inRobot.getY(), inRobot.getX()),
                range,
                t.robotToCamera().getX(),
                t.robotToCamera().getY(),
                t.tagField().getX(),
                t.tagField().getY(),
                t.noiseScale() * (1 + sq(offAxis / OFF_AXIS_REF_RAD)));
    }

    /** Inserts a correction in time order and replays from it; false if outside the history. */
    private boolean insert(Correction c, String rejectAs) {
        if (size == 0 || c.time < sampleTime[oldest]) {
            if (rejectAs != null) {
                countRejection(rejectAs + (size == 0 ? " (No Odometry)" : " (Too Old)"));
            }
            return false;
        }
        int at = corrections.size();
        while (at > 0 && corrections.get(at - 1).time > c.time) {
            at--;
        }
        corrections.add(at, c);
        int k = size - 1;
        while (k > 0 && sampleTime[index(k)] > c.time) {
            k--;
        }
        recording = c;
        replayFrom(k);
        recording = null;
        return true;
    }

    /** Restores sample {@code k}'s pre-correction state and replays every later event. */
    private void replayFrom(int k) {
        int ik = index(k);
        System.arraycopy(preState, ik * 3, s, 0, 3);
        System.arraycopy(preCov, ik * 9, p, 0, 9);
        int ci = 0;
        while (ci < corrections.size() && corrections.get(ci).time < sampleTime[ik]) {
            ci++;
        }
        for (int j = k; j < size; j++) {
            int ij = index(j);
            if (j > k) {
                storePost(index(j - 1));
                predict(
                        s,
                        p,
                        sampleDx[ij],
                        sampleDy[ij],
                        sampleDtheta[ij],
                        sampleVarXy[ij],
                        sampleVarTheta[ij]);
                storePre(ij);
            }
            double next = j + 1 < size ? sampleTime[index(j + 1)] : Double.POSITIVE_INFINITY;
            while (ci < corrections.size() && corrections.get(ci).time < next) {
                apply(corrections.get(ci), ij);
                ci++;
            }
        }
    }

    private void apply(Correction c, int sample) {
        if (c.inflate) {
            p[0] += sq(RELOCALIZE_XY_STD_M);
            p[4] += sq(RELOCALIZE_XY_STD_M);
            p[8] += sq(RELOCALIZE_THETA_STD_RAD);
        }
        if (c.axis) {
            correctAxis(c);
            return;
        }
        if (c.corners != null) {
            boolean rec = c == recording;
            int ok = 0;
            for (CornerSighting t : c.corners) {
                if (correctCorners(t, rec)) {
                    ok++;
                }
            }
            if (rec) {
                if (2 * ok >= c.corners.length) {
                    rejectsSinceGoodFrame = 0;
                    lastGoodFrameTime = c.time;
                } else {
                    rejectsSinceGoodFrame += c.corners.length - ok;
                }
            }
            return;
        }
        if (c.tags == null) {
            correctPose(c);
            return;
        }
        double dt = sampleDt[sample];
        double speed = dt > 0 ? Math.hypot(sampleDx[sample], sampleDy[sample]) / dt : 0;
        double omega = dt > 0 ? Math.abs(sampleDtheta[sample]) / dt : 0;
        boolean record = c == recording;
        if (adaptiveNis > 0) {
            // Self-checking uncertainty: if this frame's tags sit, on average, further from the
            // estimate than its covariance allows, the covariance is too small: widen it in
            // proportion before using them. Deterministic, so replay reproduces it.
            double sum = 0;
            int n = 0;
            double[] out = new double[3];
            for (Measured m : c.tags) {
                correctTag(m, speed, omega, false, out);
                if (out[2] > 0) {
                    sum += Math.min(out[2], 100);
                    n++;
                }
            }
            double excess = n > 0 ? sum / n - adaptiveNis : 0;
            if (excess > 0) {
                p[0] += adaptiveGain * excess * sq(0.05);
                p[4] += adaptiveGain * excess * sq(0.05);
                p[8] += adaptiveGain * excess * sq(Math.toRadians(1));
            }
        }
        int accepted = 0;
        for (Measured m : c.tags) {
            if (correctTag(m, speed, omega, record)) {
                accepted++;
            }
        }
        if (record) {
            if (2 * accepted >= c.tags.length) {
                rejectsSinceGoodFrame = 0;
                lastGoodFrameTime = c.time;
            } else {
                rejectsSinceGoodFrame += c.tags.length - accepted;
            }
        }
    }

    /** 8-dof chi-squared at the same tail as the 2-dof {@link #GATE_CHI2} (99.9%). */
    static final double GATE_CHI2_8 = 26.12;

    /**
     * One tag's four corners: pixels matched to the nearest predicted corner, numeric Jacobian,
     * information-form update (only 3x3 inverses: R is diagonal). False if gated out.
     */
    private boolean correctCorners(CornerSighting t, boolean record) {
        int n = t.pixels().length;
        double[][] pred = new double[n][];
        for (int i = 0; i < n; i++) {
            pred[i] = t.project(s[0], s[1], s[2], t.fieldCorners()[i]);
            if (pred[i] == null) {
                return false;
            }
        }
        // Match each detected corner to a predicted one by shape about each set's centre (orders
        // differ by convention, and an offset bigger than half the tag would pair neighbours).
        double pcu = 0;
        double pcv = 0;
        double dcu = 0;
        double dcv = 0;
        for (int i = 0; i < n; i++) {
            pcu += pred[i][0] / n;
            pcv += pred[i][1] / n;
            dcu += t.pixels()[i][0] / n;
            dcv += t.pixels()[i][1] / n;
        }
        int[] match = new int[n];
        boolean[] used = new boolean[n];
        for (int i = 0; i < n; i++) {
            int best = -1;
            double bestD = Double.POSITIVE_INFINITY;
            for (int j = 0; j < n; j++) {
                double d =
                        sq((t.pixels()[i][0] - dcu) - (pred[j][0] - pcu))
                                + sq((t.pixels()[i][1] - dcv) - (pred[j][1] - pcv));
                if (!used[j] && d < bestD) {
                    bestD = d;
                    best = j;
                }
            }
            used[best] = true;
            match[i] = best;
        }
        int m = 2 * n;
        double[] nu = new double[m];
        double[][] h = new double[m][3];
        double[] eps = {1e-4, 1e-4, 1e-5};
        for (int i = 0; i < n; i++) {
            double[] pr = pred[match[i]];
            nu[2 * i] = t.pixels()[i][0] - pr[0];
            nu[2 * i + 1] = t.pixels()[i][1] - pr[1];
            for (int k = 0; k < 3; k++) {
                double[] st = {s[0], s[1], s[2]};
                st[k] += eps[k];
                double[] q = t.project(st[0], st[1], st[2], t.fieldCorners()[match[i]]);
                if (q == null) {
                    return false;
                }
                h[2 * i][k] = (q[0] - pr[0]) / eps[k];
                h[2 * i + 1][k] = (q[1] - pr[1]) / eps[k];
            }
        }
        double rInv = 1 / sq(t.pixelStd());
        // Information form: P+ = (P^-1 + Hᵀ R^-1 H)^-1, x+ = x + P+ Hᵀ R^-1 ν.
        double[] info = inverse3(p);
        double[] htrnu = new double[3];
        for (int r = 0; r < m; r++) {
            for (int a = 0; a < 3; a++) {
                htrnu[a] += h[r][a] * rInv * nu[r];
                for (int b = 0; b < 3; b++) {
                    info[a * 3 + b] += h[r][a] * rInv * h[r][b];
                }
            }
        }
        double[] post = inverse3(info);
        // NIS by Woodbury: νᵀ S^-1 ν = νᵀR^-1ν - (HᵀR^-1ν)ᵀ P+ (HᵀR^-1ν).
        double nis = 0;
        for (double v : nu) {
            nis += v * v * rInv;
        }
        nis -= dot3(htrnu, mulVec3(post, htrnu));
        if (!(nis <= GATE_CHI2_8 * noise.gateChi2() / GATE_CHI2)) {
            if (record) {
                reject(t.camera(), "Innovation");
            }
            return false;
        }
        double[] dx = mulVec3(post, htrnu);
        s[0] += dx[0];
        s[1] += dx[1];
        s[2] = MathUtil.angleModulus(s[2] + dx[2]);
        System.arraycopy(post, 0, p, 0, 9);
        if (record) {
            acceptedCount++;
            statsFor(t.camera()).accepted++;
        }
        return true;
    }

    /** Scalar update, H = [nx, ny, 0]. */
    private void correctAxis(Correction c) {
        double[] h = {c.px, c.py, 0};
        double[] ph = mulVec3(p, h);
        double sv = dot3(h, ph) + c.varXy;
        double v = c.ptheta - (c.px * s[0] + c.py * s[1]);
        double[] k = {ph[0] / sv, ph[1] / sv, ph[2] / sv};
        s[0] += k[0] * v;
        s[1] += k[1] * v;
        s[2] = MathUtil.angleModulus(s[2] + k[2] * v);
        // Joseph form: (I-KH)P(I-KH)ᵀ + K r Kᵀ.
        double[] ikh = new double[9];
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                ikh[i * 3 + j] = (i == j ? 1 : 0) - k[i] * h[j];
            }
        }
        double[] joseph = mul3(mul3(ikh, p), transpose3(ikh));
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                p[i * 3 + j] = joseph[i * 3 + j] + k[i] * c.varXy * k[j];
            }
        }
    }

    private void correctPose(Correction c) {
        double[] r = {c.varXy, 0, 0, 0, c.varXy, 0, 0, 0, c.varTheta};
        double[] sInv = inverse3(add3(p, r));
        double[] k = mul3(p, sInv);
        double v0 = c.px - s[0];
        double v1 = c.py - s[1];
        double v2 = MathUtil.angleModulus(c.ptheta - s[2]);
        s[0] += k[0] * v0 + k[1] * v1 + k[2] * v2;
        s[1] += k[3] * v0 + k[4] * v1 + k[5] * v2;
        s[2] = MathUtil.angleModulus(s[2] + k[6] * v0 + k[7] * v1 + k[8] * v2);
        // Joseph form: (I-K)P(I-K)ᵀ + KRKᵀ.
        double[] ik = {1 - k[0], -k[1], -k[2], -k[3], 1 - k[4], -k[5], -k[6], -k[7], 1 - k[8]};
        double[] a = mul3(mul3(ik, p), transpose3(ik));
        double[] b = mul3(mul3(k, r), transpose3(k));
        for (int i = 0; i < 9; i++) {
            p[i] = a[i] + b[i];
        }
    }

    /**
     * Turns on self-checking uncertainty: before each frame, if its tags' mean NIS is above {@code
     * nis}, P grows by {@code gain} x the excess x (5 cm, 5 cm, 1 deg)². 0 turns it off.
     */
    public void setAdaptive(double nis, double gain) {
        adaptiveNis = nis;
        adaptiveGain = gain;
    }

    /**
     * Fixed-lag smoothed state and covariance at {@code t}: an RTS backward pass over the history,
     * so tags seen after {@code t} also correct it. Within the last {@link #HISTORY_SECONDS}.
     *
     * @return {x, y, theta, P (9)}, or null outside the history
     */
    public double[] smoothedAt(double t) {
        if (size == 0 || t < sampleTime[oldest]) {
            return null;
        }
        double[] xs = s.clone(); // the newest sample's posterior is the current state
        double[] ps = p.clone();
        int j = size - 1;
        while (j > 0 && sampleTime[index(j)] > t) {
            int i = index(j - 1);
            int i1 = index(j);
            double[] xf = java.util.Arrays.copyOfRange(postState, i * 3, i * 3 + 3);
            double[] pf = java.util.Arrays.copyOfRange(postCov, i * 9, i * 9 + 9);
            double[] xp = java.util.Arrays.copyOfRange(preState, i1 * 3, i1 * 3 + 3);
            double[] pp = java.util.Arrays.copyOfRange(preCov, i1 * 9, i1 * 9 + 9);
            // F at sample j (predict's Jacobian about the posterior of j-1).
            double c = Math.cos(xf[2]);
            double sn = Math.sin(xf[2]);
            double gx = c * sampleDx[i1] - sn * sampleDy[i1];
            double gy = sn * sampleDx[i1] + c * sampleDy[i1];
            double[] f = {1, 0, -gy, 0, 1, gx, 0, 0, 1};
            double[] g = mul3(mul3(pf, transpose3(f)), inverse3(pp));
            double[] dx = {xs[0] - xp[0], xs[1] - xp[1], MathUtil.angleModulus(xs[2] - xp[2])};
            double[] corr = mulVec3(g, dx);
            double[] dp = new double[9];
            for (int k = 0; k < 9; k++) {
                dp[k] = ps[k] - pp[k];
            }
            double[] pcorr = mul3(mul3(g, dp), transpose3(g));
            for (int k = 0; k < 3; k++) {
                xs[k] = xf[k] + corr[k];
            }
            xs[2] = MathUtil.angleModulus(xs[2]);
            for (int k = 0; k < 9; k++) {
                ps[k] = pf[k] + pcorr[k];
            }
            j--;
        }
        double[] out = new double[12];
        System.arraycopy(xs, 0, out, 0, 3);
        System.arraycopy(ps, 0, out, 3, 9);
        return out;
    }

    /** Like {@link #innovation}, against the smoothed state at the tag's capture time. */
    public double[] innovationSmoothed(TagSighting t) {
        Measured m = measure(t);
        double[] sm = seeded ? smoothedAt(t.timestampSeconds()) : null;
        if (m == null || sm == null) {
            return null;
        }
        double[] state = s.clone();
        double[] cov = p.clone();
        System.arraycopy(sm, 0, s, 0, 3);
        System.arraycopy(sm, 3, p, 0, 9);
        double[] out = new double[3];
        boolean ok = correctTag(m, 0, 0, false, out);
        System.arraycopy(state, 0, s, 0, 3);
        System.arraycopy(cov, 0, p, 0, 9);
        return ok || out[2] > 0 ? out : null;
    }

    /**
     * A tag's innovation against the current estimate, without applying it: for scoring held-out
     * tags in replay. Call with the filter advanced to the tag's capture time.
     *
     * @param t the tag
     * @return {bearing residual rad, range residual m, Mahalanobis² with the robot at rest}, or
     *     null
     */
    public double[] innovation(TagSighting t) {
        Measured m = measure(t);
        if (m == null || !seeded) {
            return null;
        }
        double[] state = s.clone();
        double[] cov = p.clone();
        double[] out = new double[3];
        boolean ok = correctTag(m, 0, 0, false, out);
        System.arraycopy(state, 0, s, 0, 3);
        System.arraycopy(cov, 0, p, 0, 9);
        return ok || out[2] > 0 ? out : null;
    }

    private boolean correctTag(Measured m, double speed, double omega, boolean record) {
        return correctTag(m, speed, omega, record, null);
    }

    /** One tag's bearing-and-distance update; false if it failed the gate. */
    private boolean correctTag(
            Measured m, double speed, double omega, boolean record, double[] innovationOut) {
        double c = Math.cos(s[2]);
        double sn = Math.sin(s[2]);
        double wx = m.tagX() - s[0];
        double wy = m.tagY() - s[1];
        double a = c * wx + sn * wy;
        double b = -sn * wx + c * wy;
        double ux = a - m.cx();
        double uy = b - m.cy();
        double rho2 = ux * ux + uy * uy;
        double rho = Math.sqrt(rho2);
        if (rho < 1e-6) {
            return false;
        }
        // du/d(x, y, theta): columns (-c, sn), (-sn, -c), (b, -a).
        double[] dux = {-c, -sn, b};
        double[] duy = {sn, -c, -a};
        double[] hb = new double[3];
        double[] hr = new double[3];
        for (int i = 0; i < 3; i++) {
            hb[i] = (-uy * dux[i] + ux * duy[i]) / rho2;
            hr[i] = (ux * dux[i] + uy * duy[i]) / rho;
        }
        double nb = MathUtil.angleModulus(m.bearing() - Math.atan2(uy, ux));
        double nr = m.range() - rho;

        double stdB =
                Math.hypot(
                        noise.bearingStdRad() * m.noiseScale(),
                        (omega + speed / m.range()) * noise.timingStdSeconds());
        double stdR =
                Math.hypot(
                        (noise.rangeStdBaseM() + noise.rangeStdPerM2() * m.range() * m.range())
                                * m.noiseScale(),
                        speed * noise.timingStdSeconds());
        double rb = stdB * stdB;
        double rr = stdR * stdR;

        double[] phb = mulVec3(p, hb);
        double[] phr = mulVec3(p, hr);
        double s00 = dot3(hb, phb) + rb;
        double s01 = dot3(hb, phr);
        double s11 = dot3(hr, phr) + rr;
        double det = s00 * s11 - s01 * s01;
        if (!(det > 0)) {
            return false;
        }
        double i00 = s11 / det;
        double i01 = -s01 / det;
        double i11 = s00 / det;
        double d2 = nb * (i00 * nb + i01 * nr) + nr * (i01 * nb + i11 * nr);
        if (innovationOut != null) {
            innovationOut[0] = nb;
            innovationOut[1] = nr;
            innovationOut[2] = d2;
            return d2 <= noise.gateChi2();
        }
        if (d2 > noise.gateChi2()) {
            if (record) {
                reject(m.camera(), "Innovation");
            }
            return false;
        }
        // K = P Hᵀ S⁻¹, 3x2.
        double[] kb = new double[3];
        double[] kr = new double[3];
        for (int i = 0; i < 3; i++) {
            kb[i] = phb[i] * i00 + phr[i] * i01;
            kr[i] = phb[i] * i01 + phr[i] * i11;
        }
        s[0] += kb[0] * nb + kr[0] * nr;
        s[1] += kb[1] * nb + kr[1] * nr;
        s[2] = MathUtil.angleModulus(s[2] + kb[2] * nb + kr[2] * nr);
        double[] ikh = new double[9];
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                ikh[i * 3 + j] = (i == j ? 1 : 0) - kb[i] * hb[j] - kr[i] * hr[j];
            }
        }
        double[] joseph = mul3(mul3(ikh, p), transpose3(ikh));
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                p[i * 3 + j] = joseph[i * 3 + j] + kb[i] * rb * kb[j] + kr[i] * rr * kr[j];
            }
        }
        if (record) {
            acceptedCount++;
            CameraStats st = statsFor(m.camera());
            st.accepted++;
            st.add(Math.toDegrees(nb), nr);
        }
        return true;
    }

    private static void predict(
            double[] s,
            double[] p,
            double lx,
            double ly,
            double dtheta,
            double varXy,
            double varTheta) {
        double c = Math.cos(s[2]);
        double sn = Math.sin(s[2]);
        double gx = c * lx - sn * ly;
        double gy = sn * lx + c * ly;
        s[0] += gx;
        s[1] += gy;
        s[2] = MathUtil.angleModulus(s[2] + dtheta);
        // F = [[1, 0, -gy], [0, 1, gx], [0, 0, 1]]; P = F P Fᵀ + Q.
        double p02 = p[2] - gy * p[8];
        double p12 = p[5] + gx * p[8];
        double p00 = p[0] - 2 * gy * p[2] + gy * gy * p[8];
        double p11 = p[4] + 2 * gx * p[5] + gx * gx * p[8];
        double p01 = p[1] + gx * p[2] - gy * p[5] - gx * gy * p[8];
        p[0] = p00 + varXy;
        p[1] = p01;
        p[2] = p02;
        p[3] = p01;
        p[4] = p11 + varXy;
        p[5] = p12;
        p[6] = p02;
        p[7] = p12;
        p[8] += varTheta;
    }

    /**
     * Counts a tag the caller chose not to apply.
     *
     * @param camera the tag's camera
     * @param reason why, for {@code RejectionCounts}
     */
    public void skip(String camera, String reason) {
        reject(camera, reason);
    }

    private void reject(String camera, String reason) {
        rejectedCount++;
        statsFor(camera).rejected++;
        countRejection(reason);
    }

    private void countRejection(String reason) {
        rejectionCounts.merge(reason, 1L, Long::sum);
    }

    private CameraStats statsFor(String camera) {
        return cameraStats.computeIfAbsent(camera, n -> new CameraStats());
    }

    private double clampTime(double t) {
        return size == 0 ? t : Math.min(t, newestTime());
    }

    private double newestTime() {
        return size == 0 ? Double.NEGATIVE_INFINITY : sampleTime[index(size - 1)];
    }

    private int index(int logical) {
        return (oldest + logical) % CAPACITY;
    }

    private void pushSample(
            double t,
            double dx,
            double dy,
            double dtheta,
            double dt,
            double varXy,
            double varTheta) {
        int i = index(size);
        size++;
        sampleTime[i] = t;
        sampleDx[i] = dx;
        sampleDy[i] = dy;
        sampleDtheta[i] = dtheta;
        sampleDt[i] = dt;
        sampleVarXy[i] = varXy;
        sampleVarTheta[i] = varTheta;
        storePre(i);
    }

    private void storePost(int i) {
        System.arraycopy(s, 0, postState, i * 3, 3);
        System.arraycopy(p, 0, postCov, i * 9, 9);
    }

    private void storePre(int i) {
        System.arraycopy(s, 0, preState, i * 3, 3);
        System.arraycopy(p, 0, preCov, i * 9, 9);
    }

    /** Drops the oldest sample; corrections in its interval are already in later states. */
    private void dropOldest() {
        oldest = (oldest + 1) % CAPACITY;
        size--;
        double first = size > 0 ? sampleTime[oldest] : Double.POSITIVE_INFINITY;
        while (!corrections.isEmpty() && corrections.get(0).time < first) {
            corrections.remove(0);
        }
    }

    /** Clears this loop's residuals; call after logging. */
    public void clearLoopStats() {
        for (CameraStats st : cameraStats.values()) {
            st.loopCount = 0;
        }
    }

    public Pose2d getPose() {
        return new Pose2d(s[0], s[1], Rotation2d.fromRadians(s[2]));
    }

    /** Std-devs [x m, y m, heading rad]. */
    public double[] getStdDevs() {
        return new double[] {Math.sqrt(p[0]), Math.sqrt(p[4]), Math.sqrt(p[8])};
    }

    public boolean isSeeded() {
        return seeded;
    }

    public long getAcceptedCount() {
        return acceptedCount;
    }

    public long getRejectedCount() {
        return rejectedCount;
    }

    public long getRelocalizations() {
        return relocalizations;
    }

    public Map<String, Long> getRejectionCounts() {
        return rejectionCounts;
    }

    public Map<String, CameraStats> getCameraStats() {
        return cameraStats;
    }

    // -- 3x3 helpers, row-major --

    private static double sq(double v) {
        return v * v;
    }

    private static double dot3(double[] a, double[] b) {
        return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    }

    private static double[] mulVec3(double[] m, double[] v) {
        return new double[] {
            m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
            m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
            m[6] * v[0] + m[7] * v[1] + m[8] * v[2]
        };
    }

    private static double[] mul3(double[] a, double[] b) {
        double[] out = new double[9];
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                out[i * 3 + j] =
                        a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
            }
        }
        return out;
    }

    private static double[] add3(double[] a, double[] b) {
        double[] out = new double[9];
        for (int i = 0; i < 9; i++) {
            out[i] = a[i] + b[i];
        }
        return out;
    }

    private static double[] transpose3(double[] a) {
        return new double[] {a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]};
    }

    private static double[] inverse3(double[] m) {
        double c00 = m[4] * m[8] - m[5] * m[7];
        double c01 = m[5] * m[6] - m[3] * m[8];
        double c02 = m[3] * m[7] - m[4] * m[6];
        double det = m[0] * c00 + m[1] * c01 + m[2] * c02;
        return new double[] {
            c00 / det,
            (m[2] * m[7] - m[1] * m[8]) / det,
            (m[1] * m[5] - m[2] * m[4]) / det,
            c01 / det,
            (m[0] * m[8] - m[2] * m[6]) / det,
            (m[2] * m[3] - m[0] * m[5]) / det,
            c02 / det,
            (m[1] * m[6] - m[0] * m[7]) / det,
            (m[0] * m[4] - m[1] * m[3]) / det
        };
    }
}
