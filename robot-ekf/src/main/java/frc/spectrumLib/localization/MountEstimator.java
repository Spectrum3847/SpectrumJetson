package frc.spectrumLib.localization;

import java.util.LinkedHashMap;
import java.util.Map;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Rotation3d;
import org.wpilib.math.geometry.Transform3d;

/**
 * Estimates each camera's mount yaw and pitch error online from its tag corners, and flags a camera
 * whose mount jumps (knocked).
 *
 * <p>Each frame, before it is used, the tag corners are projected from the current estimate through
 * the camera's corrected mount. A steady horizontal pixel offset is a yaw error, a vertical one a
 * pitch error (1 deg is ~13 px at f = 735). Each camera's correction follows its mean offset with
 * time constant {@code tauSeconds}; frames whose residual RMS is above {@code maxRmsPx} are ignored
 * (a bad estimate or a misread, not the mount).
 *
 * <p>Knocked: after {@link #SETTLE_FRAMES} good frames, a slow baseline ({@link
 * #BASELINE_TAU_SECONDS}) follows the correction; the correction jumping more than {@code knockDeg}
 * away from it means the mount moved (latched, for the pit). Or the residual RMS stays above {@code
 * maxRmsPx} for {@code settleSeconds}. The correction itself keeps tracking, so a knocked camera is
 * usable again once it re-converges; {@link Camera#moving} is true meanwhile. TXMAN1: Orin-Left
 * ~1.5 deg yaw, Orin-Right ~3 deg pitch off their configured mounts.
 */
public final class MountEstimator {

    static final int SETTLE_FRAMES = 200;

    /** Frame gate before settling, pixels. */
    static final double UNSETTLED_MAX_PX = 150;

    static final double BASELINE_TAU_SECONDS = 60;

    /** The jump must last this long: a correction wanders as different tags come into view. */
    static final double KNOCK_HOLD_SECONDS = 1.0;

    /** One camera's state. */
    public static final class Camera {
        double yawDeg;
        double pitchDeg;
        double firstT = Double.NaN;
        double lastT = Double.NaN;
        boolean settled;
        double baseYaw;
        double basePitch;
        boolean moving;
        double movingSince = Double.NaN;
        double badSince = Double.NaN;
        boolean knocked;
        double lastRmsPx = Double.NaN;
        long frames;

        public double yawDeg() {
            return yawDeg;
        }

        public double pitchDeg() {
            return pitchDeg;
        }

        public boolean knocked() {
            return knocked;
        }

        /** The correction is far from its baseline right now: mount just moved, still tracking. */
        public boolean moving() {
            return moving;
        }

        public double lastRmsPx() {
            return lastRmsPx;
        }

        public long frames() {
            return frames;
        }
    }

    private final double tauSeconds;
    private final double maxRmsPx;
    private final double knockDeg;
    private final double settleSeconds;
    private final Map<String, Camera> cameras = new LinkedHashMap<>();

    /**
     * @param tauSeconds how fast a correction follows its offset
     * @param maxRmsPx frames noisier than this don't move the correction
     * @param knockDeg a correction this far from where it settled means knocked
     * @param settleSeconds time to settle before knock checks start
     */
    public MountEstimator(
            double tauSeconds, double maxRmsPx, double knockDeg, double settleSeconds) {
        this.tauSeconds = tauSeconds;
        this.maxRmsPx = maxRmsPx;
        this.knockDeg = knockDeg;
        this.settleSeconds = settleSeconds;
    }

    /** The mount with a camera-local yaw (about z) and pitch (about y) added, degrees. */
    public static Transform3d withFix(Transform3d mount, double yawDeg, double pitchDeg) {
        Rotation3d delta = new Rotation3d(0, Math.toRadians(pitchDeg), Math.toRadians(yawDeg));
        return new Transform3d(
                mount.getTranslation(),
                new Rotation3d(mount.getRotation().getQuaternion().times(delta.getQuaternion())));
    }

    /** The camera's mount with its current correction. */
    public Transform3d corrected(String camera, Transform3d mount) {
        Camera c = cameras.get(camera);
        return c == null ? mount : withFix(mount, c.yawDeg, c.pitchDeg);
    }

    /**
     * One frame's corners, already built with {@link #corrected} mounts, against the estimate.
     *
     * @param est the filter's pose at the frame's capture time
     * @param frame the frame's tags (one camera)
     */
    public void update(Pose2d est, java.util.List<CornerSighting> frame) {
        if (frame.isEmpty()) {
            return;
        }
        CornerSighting first = frame.get(0);
        Camera c = cameras.computeIfAbsent(first.camera(), k -> new Camera());
        double t = first.timestampSeconds();
        double su = 0;
        double sv = 0;
        double s2 = 0;
        int n = 0;
        for (CornerSighting cs : frame) {
            // Tag centres, not corners: a mount error bigger than half the tag's size in pixels
            // pairs corners with the wrong neighbour, but the centre offset is unambiguous.
            double pu = 0;
            double pv = 0;
            double du = 0;
            double dv = 0;
            int k = cs.fieldCorners().length;
            for (int i = 0; i < k; i++) {
                double[] q =
                        cs.project(
                                est.getX(),
                                est.getY(),
                                est.getRotation().getRadians(),
                                cs.fieldCorners()[i]);
                if (q == null) {
                    return;
                }
                pu += q[0] / k;
                pv += q[1] / k;
                du += cs.pixels()[i][0] / k;
                dv += cs.pixels()[i][1] / k;
            }
            su += du - pu;
            sv += dv - pv;
            s2 += (du - pu) * (du - pu) + (dv - pv) * (dv - pv);
            n++;
        }
        if (n == 0) {
            return;
        }
        double rms = Math.sqrt(s2 / n);
        c.lastRmsPx = rms;
        if (Double.isNaN(c.firstT)) {
            c.firstT = t;
        }
        double dt = Double.isNaN(c.lastT) ? 0 : Math.max(0, t - c.lastT);
        c.lastT = t;
        boolean old = c.settled;
        // Before settling the offset IS the mount error (TXMAN1 Orin-Left ~5 deg = ~64 px), so only
        // wild frames are dropped; after, a large offset is a bad estimate or a knock.
        if (rms > (old ? maxRmsPx : UNSETTLED_MAX_PX)) {
            if (Double.isNaN(c.badSince)) {
                c.badSince = t;
            }
            if (old && t - c.badSince >= settleSeconds) {
                // Offsets stayed large: the mount moved too far to track. Re-learn it.
                c.knocked = true;
                c.settled = false;
                c.frames = 0;
                c.badSince = Double.NaN;
            }
            return;
        }
        c.badSince = Double.NaN;
        c.frames++;
        // Signs from TXMAN1 replay: a negative u offset wants a negative yaw fix, a positive v
        // offset a negative pitch fix.
        double fx = first.intrinsics()[0];
        double fy = first.intrinsics()[1];
        double k = Math.min(1, dt / tauSeconds);
        c.yawDeg += k * Math.toDegrees(su / n / fx);
        c.pitchDeg -= k * Math.toDegrees(sv / n / fy);
        if (!c.settled) {
            // Until settled the baseline is the correction itself: initial convergence isn't a
            // knock.
            c.baseYaw = c.yawDeg;
            c.basePitch = c.pitchDeg;
            c.settled = c.frames >= SETTLE_FRAMES;
            return;
        }
        double kb = Math.min(1, dt / BASELINE_TAU_SECONDS);
        c.baseYaw += kb * (c.yawDeg - c.baseYaw);
        c.basePitch += kb * (c.pitchDeg - c.basePitch);
        c.moving = Math.hypot(c.yawDeg - c.baseYaw, c.pitchDeg - c.basePitch) > knockDeg;
        if (!c.moving) {
            c.movingSince = Double.NaN;
        } else if (Double.isNaN(c.movingSince)) {
            c.movingSince = t;
        } else if (t - c.movingSince >= KNOCK_HOLD_SECONDS) {
            c.knocked = true;
        }
    }

    public Map<String, Camera> cameras() {
        return cameras;
    }
}
