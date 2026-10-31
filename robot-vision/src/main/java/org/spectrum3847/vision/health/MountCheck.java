package org.spectrum3847.vision.health;

import edu.wpi.first.apriltag.AprilTagFieldLayout;
import edu.wpi.first.math.MathUtil;
import edu.wpi.first.math.Matrix;
import edu.wpi.first.math.Nat;
import edu.wpi.first.math.VecBuilder;
import edu.wpi.first.math.geometry.Pose2d;
import edu.wpi.first.math.geometry.Pose3d;
import edu.wpi.first.math.geometry.Rotation2d;
import edu.wpi.first.math.geometry.Rotation3d;
import edu.wpi.first.math.geometry.Transform2d;
import edu.wpi.first.math.geometry.Transform3d;
import edu.wpi.first.math.geometry.Translation3d;
import edu.wpi.first.math.interpolation.TimeInterpolatableBuffer;
import edu.wpi.first.math.util.Units;
import edu.wpi.first.networktables.DoubleArrayPublisher;
import edu.wpi.first.networktables.IntegerPublisher;
import edu.wpi.first.networktables.NetworkTable;
import edu.wpi.first.networktables.NetworkTableInstance;
import edu.wpi.first.networktables.StringPublisher;
import edu.wpi.first.networktables.StructPublisher;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import org.spectrum3847.vision.compat.VisionAlert;
import org.spectrum3847.vision.compat.VisionAlert.Level;
import org.spectrum3847.vision.heading.RobotMotionHistory;
import org.spectrum3847.vision.io.TagQualityEstimator;
import org.spectrum3847.vision.observation.FrameObservation;
import org.spectrum3847.vision.observation.TagObservation;

/**
 * Notices a camera mount in robot code that doesn't match the robot: a camera knocked, re-aimed,
 * or measured wrong. A wrong mount moves every pose from that camera while each tag detection
 * still looks fine, so no gate catches it.
 *
 * <p><b>How.</b> Each frame (at most {@link Config#maxSampleHz} per camera) the camera's own field
 * pose is solved from vision alone: a 6-DoF PnP on the tag corners when the calibration is known
 * (PhotonLib's camera matrix), otherwise PhotonVision's multi-tag or single-tag solve. That
 * implies a mount, compared with the configured one:
 *
 * <ul>
 *   <li><b>Height, roll and pitch</b> need no reference at all: the robot is flat on the floor, so
 *       they are the camera's own field z, roll and pitch. Every usable frame gives them.
 *   <li><b>x, y and yaw</b> need the robot's pose from something other than this camera:
 *       <ol>
 *         <li>other cameras seeing tags at the same time (moved to one time with the estimator's
 *             motion). For every pair of cameras the median difference is kept; the largest group
 *             of cameras that agree with each other is the reference for all of them, so one bad
 *             camera among three or more is the odd one out;
 *         <li>2 cameras that disagree: one of them is wrong, and it's the one whose poses disagree
 *             more with the pose estimator (and whose height, roll or pitch are off);
 *         <li>otherwise the pose estimator, unless this camera fed it most of the recent
 *             measurements ({@link Config#maxSelfShare}): then its pose is mostly this camera's
 *             own, and agreeing with it proves nothing.
 *       </ol>
 * </ul>
 *
 * Samples are only taken with the robot slow ({@link Config#maxSpeed}, {@link Config#maxYawRate}),
 * where frame timing barely matters. Each camera keeps its last {@link Config#window} samples; the
 * estimate is their median. A dimension is off when its median differs from the configured mount
 * by more than {@link Config#maxAngleDeg} / {@link Config#maxOffsetMeters} plus two standard
 * errors: SUSPECT, and BAD at {@link Config#badFactor} times that.
 *
 * <p>Results: {@link #reports()}, NetworkTables under {@code /SpectrumVision/mountCheck/<camera>/},
 * and a dashboard alert per camera (kept up until {@link #reset()} so the pit sees it after a
 * match). The estimate is printed as Java to paste into robot code ({@link Mount#code()}).
 */
public class MountCheck {
    public enum Status {
        /** Not enough samples yet (needs tags in view, robot slow). */
        NO_DATA,
        OK,
        SUSPECT,
        BAD
    }

    /** Settings. Public fields. */
    public static final class Config {
        /** An angle further off than this (degrees) is SUSPECT. */
        public double maxAngleDeg = 2;
        /** A position further off than this (metres) is SUSPECT. */
        public double maxOffsetMeters = 0.04;
        /** BAD at this many times the SUSPECT limit. */
        public double badFactor = 2;
        /** Samples needed before a dimension is judged. */
        public int minSamples = 40;
        /** Samples kept per camera (the newest). */
        public int window = 400;
        /** At most this many samples a second per camera. */
        public double maxSampleHz = 25;
        /** Only sample with the robot slower than this (m/s) ... */
        public double maxSpeed = 1.0;
        /** ... and turning slower than this (rad/s). */
        public double maxYawRate = 0.75;
        /** A PnP solution fitting the corners worse than this (RMS px) is dropped. */
        public double maxReprojPx = 3;
        /**
         * A frame whose solve is this uncertain (camera position σ in metres, from the corners'
         * fit and geometry, at 1 px corner noise) is left out: far or bunched-up tags.
         */
        public double maxPositionSigma = 0.25;
        /** ... or whose orientation σ is above this (degrees). */
        public double maxAngleSigmaDeg = 3;
        /** One tag alone is used only when its side is at least this many pixels. */
        public double minSingleTagSidePx = 45;
        /** Without the calibration: PhotonVision's single-tag solve only below this ambiguity. */
        public double maxAmbiguity = 0.15;
        /** Tags farther than this (m) are left out. */
        public double maxTagDistance = 6;
        /** Frames of different cameras within this (s) are compared (moved to one time by odometry). */
        public double pairWindowSeconds = 0.06;
        /** The estimator is a reference for a camera only if the camera gave less than this share. */
        public double maxSelfShare = 0.6;
        /** How long the share is measured over (s). */
        public double shareSeconds = 3;
        public double tagSizeMeters = Units.inchesToMeters(6.5);
        /**
         * A sample implying a mount further off than this (metres, or 10x in degrees) is a wrong
         * pose or a flipped tag, not a mount: dropped.
         */
        public double maxPlausibleOffset = 0.5;
        public double maxPlausibleAngleDeg = 20;
    }

    /** A mount as numbers: metres and degrees (WPILib's Rotation3d(roll, pitch, yaw)). */
    public record Mount(double x, double y, double z, double rollDeg, double pitchDeg, double yawDeg) {
        public static Mount of(Transform3d t) {
            var r = t.getRotation();
            return new Mount(t.getX(), t.getY(), t.getZ(),
                    Math.toDegrees(r.getX()), Math.toDegrees(r.getY()), Math.toDegrees(r.getZ()));
        }

        public Transform3d toTransform() {
            return new Transform3d(x, y, z, new Rotation3d(
                    Math.toRadians(rollDeg), Math.toRadians(pitchDeg), Math.toRadians(yawDeg)));
        }

        public double[] toArray() {
            return new double[] {x, y, z, rollDeg, pitchDeg, yawDeg};
        }

        /** Java to paste into robot code. */
        public String code() {
            return String.format(
                    "new Transform3d(%.3f, %.3f, %.3f, new Rotation3d(Math.toRadians(%.1f), Math.toRadians(%.1f), Math.toRadians(%.1f)))",
                    x, y, z, rollDeg, pitchDeg, yawDeg);
        }

        @Override
        public String toString() {
            return String.format("x %.3f y %.3f z %.3f m, roll %.1f pitch %.1f yaw %.1f deg", x, y, z, rollDeg, pitchDeg, yawDeg);
        }
    }

    /**
     * One camera's result.
     *
     * @param status the worst dimension's
     * @param samples height/roll/pitch samples; @param refSamples x/y/yaw samples
     * @param reference where x/y/yaw's reference came from: "cameras:&lt;a&gt;+&lt;b&gt;" (the
     *     cameras that agree), "pair:&lt;other&gt;" (two that disagree), "estimator", or "none"
     * @param configured the mount in robot code; @param estimated what the data says (configured
     *     values where there's no data)
     * @param error estimated minus configured: x, y, z (m), roll, pitch, yaw (deg); NaN where unjudged
     * @param disagreementMeters / disagreementDeg median distance and heading difference of this
     *     camera's robot poses from the other cameras' (NaN: never seen together)
     * @param message one line for the dashboard
     */
    public record CameraReport(
            String camera,
            Status status,
            int samples,
            int refSamples,
            String reference,
            Mount configured,
            Mount estimated,
            double[] error,
            double disagreementMeters,
            double disagreementDeg,
            String message) {}

    private static final class Samples {
        final ArrayDeque<double[]> zrp = new ArrayDeque<>(); // z, roll, pitch (rad)
        // x, y, yaw implied with another camera's robot pose as the reference, by that camera.
        final LinkedHashMap<String, ArrayDeque<double[]>> partner = new LinkedHashMap<>();
        final ArrayDeque<double[]> est = new ArrayDeque<>(); // x, y, yaw from the estimator
        final ArrayDeque<double[]> disagree = new ArrayDeque<>(); // m, rad vs other cameras
        final ArrayDeque<double[]> estDev = new ArrayDeque<>(); // m, rad vs the estimator
        double lastSample = Double.NEGATIVE_INFINITY;
        Transform3d mountSeen;
        VisionAlert alert;
        Status latched = Status.NO_DATA;
        CameraReport report;

        void clear() {
            zrp.clear();
            partner.clear();
            est.clear();
            disagree.clear();
            estDev.clear();
            latched = Status.NO_DATA;
            report = null;
        }
    }

    private record Seen(String camera, double t, Pose2d robot) {}

    public final Config config = new Config();
    private final AprilTagFieldLayout field;
    private final Map<String, TagQualityEstimator> lenses = new LinkedHashMap<>();
    private final Map<String, Samples> cameras = new LinkedHashMap<>();
    private final Set<String> ignored = new HashSet<>();
    private final ArrayDeque<Seen> recent = new ArrayDeque<>();
    private final ArrayDeque<double[]> accepted = new ArrayDeque<>(); // t, camera index
    private final List<String> cameraIndex = new ArrayList<>();
    private final TimeInterpolatableBuffer<Pose2d> estimator = TimeInterpolatableBuffer.createBuffer(2.0);
    private final boolean publish;
    private NetworkTable table;
    private final Map<String, Object[]> pubs = new LinkedHashMap<>();
    private StringPublisher summaryPub;
    private double lastReport = Double.NEGATIVE_INFINITY;

    /** @param publish NetworkTables values and dashboard alerts (off for tests and replays) */
    public MountCheck(AprilTagFieldLayout field, boolean publish) {
        this.field = field;
        this.publish = publish;
    }

    /** A camera's calibration (PhotonLib's camera matrix, row-major, and distortion): enables PnP. */
    public void intrinsics(String camera, double[] cameraMatrix, double[] distCoeffs) {
        lenses.put(camera, new TagQualityEstimator(cameraMatrix, distCoeffs, config.tagSizeMeters));
    }

    public boolean hasIntrinsics(String camera) {
        return lenses.containsKey(camera);
    }

    /** Leave a camera out (a turret camera, whose mount moves). */
    public void ignore(String camera) {
        ignored.add(camera);
    }

    /** Forget every sample and clear the alerts (after fixing a mount, or between checks). */
    public void reset() {
        for (var s : cameras.values()) {
            s.clear();
            if (s.alert != null) s.alert.set(false);
        }
        recent.clear();
        lastReport = Double.NEGATIVE_INFINITY;
    }

    /** The pose estimator's pose now (once a loop; null: none). Used as a reference and to move frames in time. */
    public void addEstimatorPose(double t, Pose2d pose) {
        if (pose != null) estimator.addSample(t, pose);
    }

    /** A measurement sent to the estimator, to know which cameras its pose came from. */
    public void addAccepted(double t, String camera) {
        int i = cameraIndex.indexOf(camera);
        if (i < 0) {
            cameraIndex.add(camera);
            i = cameraIndex.size() - 1;
        }
        accepted.add(new double[] {t, i});
    }

    /**
     * One loop's new frames.
     *
     * @param now robot time
     * @param frames every camera's new frames
     * @param mounts each camera's configured robot-to-camera
     * @param motion speed and turn rate by time (may be null: no motion gate)
     */
    public void update(double now, List<FrameObservation> frames, Map<String, Transform3d> mounts, RobotMotionHistory motion) {
        while (!accepted.isEmpty() && accepted.peekFirst()[0] < now - config.shareSeconds) accepted.removeFirst();
        while (!recent.isEmpty() && recent.peekFirst().t() < now - 0.5) recent.removeFirst();
        // Solve every usable frame first, so each camera can be compared with the others'.
        var solved = new ArrayList<Object[]>();
        for (var f : frames) {
            if (ignored.contains(f.camera())) continue;
            var mount = mounts.get(f.camera());
            if (mount == null) continue;
            var s = cameras.computeIfAbsent(f.camera(), n -> new Samples());
            if (s.mountSeen != null && !s.mountSeen.equals(mount)) s.clear();
            s.mountSeen = mount;
            if (f.timestampSeconds() - s.lastSample < 1.0 / config.maxSampleHz) continue;
            if (!slow(motion, f.timestampSeconds())) continue;
            Pose3d cam = cameraPose(f, mount);
            if (cam == null) continue;
            s.lastSample = f.timestampSeconds();
            Pose2d robot = cam.transformBy(mount.inverse()).toPose2d();
            recent.add(new Seen(f.camera(), f.timestampSeconds(), robot));
            solved.add(new Object[] {f, cam, robot});
        }
        for (var o : solved) addSample((FrameObservation) o[0], (Pose3d) o[1], (Pose2d) o[2], mounts);
        if (now - lastReport >= 0.5) {
            lastReport = now;
            var trusted = trustedSet(mounts);
            for (var e : cameras.entrySet()) {
                var m = mounts.get(e.getKey());
                if (m != null) e.getValue().report = judge(e.getKey(), e.getValue(), m, trusted);
            }
            resolvePairs();
            if (publish) publishAll();
        }
    }

    private boolean slow(RobotMotionHistory motion, double t) {
        if (motion == null) return true;
        var v = motion.speedAt(t);
        var w = motion.yawRateAt(t);
        return (v.isEmpty() || Math.abs(v.get()) <= config.maxSpeed) && (w.isEmpty() || Math.abs(w.get()) <= config.maxYawRate);
    }

    private void addSample(FrameObservation f, Pose3d cam, Pose2d robot, Map<String, Transform3d> mounts) {
        var s = cameras.get(f.camera());
        var cfg = mounts.get(f.camera());
        double t = f.timestampSeconds();
        var r = cam.getRotation();
        double maxAng = Math.toRadians(config.maxPlausibleAngleDeg);
        if (Math.abs(cam.getZ() - cfg.getZ()) > config.maxPlausibleOffset
                || Math.abs(MathUtil.angleModulus(r.getX() - cfg.getRotation().getX())) > maxAng
                || Math.abs(MathUtil.angleModulus(r.getY() - cfg.getRotation().getY())) > maxAng) {
            return;
        }
        push(s.zrp, new double[] {cam.getZ(), r.getX(), r.getY()});
        // Other cameras' robot poses near this time, moved to it.
        var others = new LinkedHashMap<String, Pose2d>();
        var dts = new LinkedHashMap<String, Double>();
        for (var o : recent) {
            if (o.camera().equals(f.camera())) continue;
            double dt = Math.abs(o.t() - t);
            if (dt > config.pairWindowSeconds) continue;
            if (dts.containsKey(o.camera()) && dts.get(o.camera()) <= dt) continue;
            var moved = moveTo(o.robot(), o.t(), t);
            if (moved == null) continue;
            others.put(o.camera(), moved);
            dts.put(o.camera(), dt);
        }
        for (var e : others.entrySet()) {
            var v = implied(e.getValue(), cam);
            if (plausible(v, cfg)) push(s.partner.computeIfAbsent(e.getKey(), k -> new ArrayDeque<>()), v);
        }
        Pose2d ref = null;
        if (others.size() >= 2) {
            var all = new ArrayList<>(others.values());
            all.add(robot);
            ref = median(all, robot);
        } else if (others.size() == 1) {
            ref = others.values().iterator().next();
        }
        if (ref != null) {
            push(s.disagree, new double[] {
                robot.getTranslation().getDistance(ref.getTranslation()),
                Math.abs(robot.getRotation().minus(ref.getRotation()).getRadians())
            });
        }
        var est = estimator.getInternalBuffer().isEmpty() ? Optional.<Pose2d>empty() : estimatorAt(t);
        if (est.isPresent()) {
            push(s.estDev, new double[] {
                robot.getTranslation().getDistance(est.get().getTranslation()),
                Math.abs(robot.getRotation().minus(est.get().getRotation()).getRadians())
            });
            var v = implied(est.get(), cam);
            if (selfShare(f.camera()) < config.maxSelfShare && plausible(v, cfg)) push(s.est, v);
        }
    }

    private Optional<Pose2d> estimatorAt(double t) {
        var b = estimator.getInternalBuffer();
        if (t < b.firstKey() - 0.05 || t > b.lastKey() + 0.1) return Optional.empty();
        return estimator.getSample(t);
    }

    /** {@code pose} seen at {@code from}, moved to {@code to} with the estimator's motion (or as is, if close). */
    private Pose2d moveTo(Pose2d pose, double from, double to) {
        if (Math.abs(from - to) < 1e-4) return pose;
        if (estimator.getInternalBuffer().isEmpty()) return Math.abs(from - to) <= 0.02 ? pose : null;
        var a = estimatorAt(from);
        var b = estimatorAt(to);
        if (a.isEmpty() || b.isEmpty()) return Math.abs(from - to) <= 0.02 ? pose : null;
        return pose.plus(new Transform2d(a.get(), b.get()));
    }

    private boolean plausible(double[] xyYaw, Transform3d cfg) {
        return Math.hypot(xyYaw[0] - cfg.getX(), xyYaw[1] - cfg.getY()) <= config.maxPlausibleOffset
                && Math.abs(MathUtil.angleModulus(xyYaw[2] - cfg.getRotation().getZ())) <= Math.toRadians(config.maxPlausibleAngleDeg);
    }

    private double selfShare(String camera) {
        if (accepted.isEmpty()) return 0;
        int i = cameraIndex.indexOf(camera), n = 0;
        for (var a : accepted) if ((int) a[1] == i) n++;
        return (double) n / accepted.size();
    }

    private static double[] implied(Pose2d robot, Pose3d cam) {
        var m = new Transform3d(new Pose3d(robot), cam);
        return new double[] {m.getX(), m.getY(), m.getRotation().getZ()};
    }

    private static Pose2d median(List<Pose2d> poses, Pose2d about) {
        int n = poses.size();
        double[] x = new double[n], y = new double[n], th = new double[n];
        for (int i = 0; i < n; i++) {
            x[i] = poses.get(i).getX();
            y[i] = poses.get(i).getY();
            th[i] = poses.get(i).getRotation().minus(about.getRotation()).getRadians();
        }
        return new Pose2d(median(x), median(y), about.getRotation().plus(new Rotation2d(median(th))));
    }

    private void push(ArrayDeque<double[]> q, double[] v) {
        q.add(v);
        while (q.size() > config.window) q.removeFirst();
    }

    // ---- The camera's field pose from vision alone ----

    /** The camera's field pose from this frame alone, or null if the frame isn't good enough. */
    Pose3d cameraPose(FrameObservation f, Transform3d mount) {
        var tags = new ArrayList<TagObservation>();
        for (var t : f.tags()) {
            if (field.getTagPose(t.id()).isEmpty()) continue;
            if (t.bestCameraToTag() != null && t.distanceMeters() > config.maxTagDistance) continue;
            tags.add(t);
        }
        if (tags.isEmpty()) return null;
        var lens = lenses.get(f.camera());
        if (lens != null && allCorners(tags)) return pnp(f, tags, lens, mount);
        // No calibration: PhotonVision's own solves.
        if (f.hasMultiTag() && f.multiTagIds().size() >= 2) {
            if (f.multiTagReprojErrPx() > config.maxReprojPx) return null;
            return new Pose3d().plus(f.multiTagFieldToCamera());
        }
        if (tags.size() != 1) return null;
        var t = tags.get(0);
        if (t.ambiguity() < 0 || t.ambiguity() > config.maxAmbiguity || zero(t.bestCameraToTag())) return null;
        if (sidePx(t) < config.minSingleTagSidePx) return null;
        return field.getTagPose(t.id()).get().transformBy(t.bestCameraToTag().inverse());
    }

    private static boolean zero(Transform3d t) {
        return t == null || t.getTranslation().getNorm() < 1e-6;
    }

    private static boolean allCorners(List<TagObservation> tags) {
        for (var t : tags) {
            double[] c = t.corners();
            if (c == null || c.length != 8) return false;
            for (double v : c) if (!Double.isFinite(v)) return false;
        }
        return true;
    }

    private static double sidePx(TagObservation t) {
        double[] c = t.corners();
        if (c == null || c.length != 8) return Double.NaN;
        double s = 0;
        for (int i = 0; i < 4; i++) {
            int j = (i + 1) % 4;
            s += Math.hypot(c[2 * j] - c[2 * i], c[2 * j + 1] - c[2 * i + 1]);
        }
        return s / 4;
    }

    private Pose3d pnp(FrameObservation f, List<TagObservation> tags, TagQualityEstimator lens, Transform3d mount) {
        if (tags.size() == 1 && sidePx(tags.get(0)) < config.minSingleTagSidePx) return null;
        int n = tags.size() * 4;
        double[] pts = new double[3 * n], obs = new double[2 * n];
        var model = lens.tagCorners();
        int k = 0;
        for (var t : tags) {
            var tp = field.getTagPose(t.id()).get();
            for (int i = 0; i < 4; i++, k++) {
                var p = model[i].rotateBy(tp.getRotation()).plus(tp.getTranslation());
                pts[3 * k] = p.getX();
                pts[3 * k + 1] = p.getY();
                pts[3 * k + 2] = p.getZ();
                double[] u = lens.undistort(t.corners()[2 * i], t.corners()[2 * i + 1]);
                obs[2 * k] = u[0];
                obs[2 * k + 1] = u[1];
            }
        }
        // Seeds: PhotonVision's multi-tag, and each tag's two single-tag solutions.
        var seeds = new ArrayList<Pose3d>();
        // Several tags have one solution: one seed is enough (multi-tag, else each tag's best). One
        // tag can have two: both are tried.
        boolean multi = tags.size() >= 2;
        if (multi && f.hasMultiTag()) seeds.add(new Pose3d().plus(f.multiTagFieldToCamera()));
        if (seeds.isEmpty()) {
            for (var t : tags) {
                var tp = field.getTagPose(t.id()).get();
                if (seeds.size() >= 3) break;
                if (!zero(t.bestCameraToTag())) seeds.add(tp.transformBy(t.bestCameraToTag().inverse()));
                if (!multi && !zero(t.altCameraToTag()) && !t.altCameraToTag().equals(t.bestCameraToTag()))
                    seeds.add(tp.transformBy(t.altCameraToTag().inverse()));
            }
        }
        // From the corners alone (PhotonVision in 2D mode sends no 3D solve): the biggest tag's
        // homography, and for one tag that pose tilted four ways, so both of a lone tag's
        // solutions are found.
        TagObservation biggest = tags.get(0);
        for (var t : tags) if (sidePx(t) > sidePx(biggest)) biggest = t;
        var h = homographySeed(biggest, lens);
        if (h != null) {
            var tp = field.getTagPose(biggest.id()).get();
            seeds.add(tp.transformBy(h.inverse()));
            if (!multi) {
                for (double[] tilt : new double[][] {{0, 0.6, 0}, {0, -0.6, 0}, {0, 0, 0.6}, {0, 0, -0.6}}) {
                    // Tilted about the tag's own axes.
                    var tilted = new Transform3d(h.getTranslation(), compose(h.getRotation(), new Rotation3d(tilt[0], tilt[1], tilt[2])));
                    seeds.add(tp.transformBy(tilted.inverse()));
                }
            }
        }
        if (seeds.isEmpty()) return null;
        Pose3d best = null, second = null;
        double bestErr = Double.POSITIVE_INFINITY, secondErr = Double.POSITIVE_INFINITY, bestPos = 0, bestAng = 0;
        for (var seed : seeds) {
            double[] err = new double[3];
            var p = refine(seed, pts, obs, lens, err);
            if (p == null) continue;
            if (err[0] < bestErr) {
                bestPos = err[1];
                bestAng = err[2];
                if (best != null && differs(best, p)) {
                    second = best;
                    secondErr = bestErr;
                }
                best = p;
                bestErr = err[0];
            } else if (differs(best, p) && err[0] < secondErr) {
                second = p;
                secondErr = err[0];
            }
        }
        if (best == null || bestErr > config.maxReprojPx) return null;
        // Far or bunched-up tags: too uncertain to say anything about a few degrees.
        if (bestPos > config.maxPositionSigma || Math.toDegrees(bestAng) > config.maxAngleSigmaDeg) return null;
        // A single tag can fit two ways about equally well: then neither is trusted.
        if (tags.size() == 1 && second != null && secondErr < Math.max(2 * bestErr, 1.0)) return null;
        return best;
    }

    /** a then b in a's frame (the matrix product a·b). */
    private static Rotation3d compose(Rotation3d a, Rotation3d b) {
        return new Pose3d(new Translation3d(), a).plus(new Transform3d(new Translation3d(), b)).getRotation();
    }

    /** Camera-to-tag from one tag's four corners (planar homography, undistorted). Null if degenerate. */
    static Transform3d homographySeed(TagObservation t, TagQualityEstimator lens) {
        var model = lens.tagCorners();
        double[] fxy = lens.focal();
        double[] A = new double[64], bv = new double[8];
        for (int i = 0; i < 4; i++) {
            double[] u = lens.undistort(t.corners()[2 * i], t.corners()[2 * i + 1]);
            double a = (u[0] - fxy[2]) / fxy[0], b = (u[1] - fxy[3]) / fxy[1];
            double X = model[i].getY(), Y = model[i].getZ();
            int r = 2 * i;
            double[] row1 = {X, Y, 1, 0, 0, 0, -a * X, -a * Y};
            double[] row2 = {0, 0, 0, X, Y, 1, -b * X, -b * Y};
            System.arraycopy(row1, 0, A, 8 * r, 8);
            System.arraycopy(row2, 0, A, 8 * (r + 1), 8);
            bv[r] = a;
            bv[r + 1] = b;
        }
        double[] h = solveN(A, bv, 8);
        if (h == null) return null;
        // Columns of M = [cv(R·ŷ) cv(R·ẑ) cv(t)], cv(v) = (-v.y, -v.z, v.x).
        double[] m1 = {h[0], h[3], h[6]}, m2 = {h[1], h[4], h[7]}, m3 = {h[2], h[5], 1};
        double n1 = Math.sqrt(m1[0] * m1[0] + m1[1] * m1[1] + m1[2] * m1[2]);
        double n2 = Math.sqrt(m2[0] * m2[0] + m2[1] * m2[1] + m2[2] * m2[2]);
        double lambda = 2 / (n1 + n2);
        if (!(lambda > 0) || !Double.isFinite(lambda)) return null; // m3[2] = 1 > 0: in front
        double[] ry = fromCv(m1, lambda), rz = fromCv(m2, lambda), tt = fromCv(m3, lambda);
        double[] c1 = normalize(ry);
        double d = rz[0] * c1[0] + rz[1] * c1[1] + rz[2] * c1[2];
        double[] c2 = normalize(new double[] {rz[0] - d * c1[0], rz[1] - d * c1[1], rz[2] - d * c1[2]});
        double[] c0 = {c1[1] * c2[2] - c1[2] * c2[1], c1[2] * c2[0] - c1[0] * c2[2], c1[0] * c2[1] - c1[1] * c2[0]};
        var R = new Matrix<>(Nat.N3(), Nat.N3());
        for (int i = 0; i < 3; i++) {
            R.set(i, 0, c0[i]);
            R.set(i, 1, c1[i]);
            R.set(i, 2, c2[i]);
        }
        try {
            return new Transform3d(new Translation3d(tt[0], tt[1], tt[2]), new Rotation3d(R));
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    private static double[] fromCv(double[] m, double s) {
        // cv (a, b, c) = (-y, -z, x)  =>  (x, y, z) = (c, -a, -b)
        return new double[] {s * m[2], -s * m[0], -s * m[1]};
    }

    private static double[] normalize(double[] v) {
        double n = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        return new double[] {v[0] / n, v[1] / n, v[2] / n};
    }

    private static boolean differs(Pose3d a, Pose3d b) {
        return new Transform3d(a, b).getRotation().getAngle() > Math.toRadians(2)
                || a.getTranslation().getDistance(b.getTranslation()) > 0.05;
    }

    /** Levenberg–Marquardt on the corners' pixel error, Huber-weighted; RMS error in err[0]. */
    private static Pose3d refine(Pose3d seed, double[] pts, double[] obs, TagQualityEstimator lens, double[] err) {
        int n = obs.length / 2;
        Pose3d x = seed;
        double[] r = new double[2 * n];
        if (!residuals(x, pts, obs, lens, r)) return null;
        double cost = cost(r), lambda = 1e-3;
        double[] rp = new double[2 * n];
        double[][] J = new double[2 * n][6];
        for (int it = 0; it < 30; it++) {
            for (int j = 0; j < 6; j++) {
                double h = j < 3 ? 1e-6 : 1e-7;
                if (!residuals(perturb(x, j, h), pts, obs, lens, rp)) return null;
                for (int i = 0; i < 2 * n; i++) J[i][j] = (rp[i] - r[i]) / h;
            }
            double[] H = new double[36], g = new double[6];
            for (int i = 0; i < 2 * n; i++) {
                double w = Math.abs(r[i]) <= 2 ? 1 : 2 / Math.abs(r[i]);
                for (int a = 0; a < 6; a++) {
                    g[a] += w * J[i][a] * r[i];
                    for (int b = 0; b < 6; b++) H[6 * a + b] += w * J[i][a] * J[i][b];
                }
            }
            boolean improved = false;
            for (int tries = 0; tries < 8 && !improved; tries++) {
                double[] A = H.clone();
                for (int a = 0; a < 6; a++) A[7 * a] *= 1 + lambda;
                double[] d = solve6(A, g);
                if (d == null) return null;
                var y = x;
                for (int j = 0; j < 6; j++) d[j] = -d[j];
                y = step(x, d);
                if (residuals(y, pts, obs, lens, rp) && cost(rp) < cost) {
                    x = y;
                    System.arraycopy(rp, 0, r, 0, r.length);
                    double c = cost(r);
                    boolean done = cost - c < 1e-10 * (1 + cost);
                    cost = c;
                    lambda = Math.max(lambda / 10, 1e-9);
                    improved = true;
                    if (done) it = 1000;
                } else {
                    lambda *= 10;
                }
            }
            if (!improved) break;
        }
        err[0] = Math.sqrt(sumSq(r) / n);
        // Uncertainty at 1 px (or the fit's RMS, if worse): (JᵀJ)⁻¹ diagonal.
        double[] H = new double[36];
        for (int i = 0; i < 2 * n; i++)
            for (int a = 0; a < 6; a++) for (int b = 0; b < 6; b++) H[6 * a + b] += J[i][a] * J[i][b];
        double s2 = Math.max(1.0, err[0] * err[0]);
        double pos = 0, ang = 0;
        for (int a = 0; a < 6; a++) {
            double[] e = new double[6];
            e[a] = 1;
            double[] col = solve6(H, e);
            if (col == null) return null;
            if (a < 3) pos += col[a] * s2;
            else ang = Math.max(ang, col[a] * s2);
        }
        if (err.length > 2) {
            err[1] = Math.sqrt(pos);
            err[2] = Math.sqrt(ang);
        }
        return x;
    }

    private static Pose3d perturb(Pose3d x, int j, double h) {
        double[] d = new double[6];
        d[j] = h;
        return step(x, d);
    }

    /** Body-frame step: translation d0..2, rotation vector d3..5. */
    private static Pose3d step(Pose3d x, double[] d) {
        return x.plus(new Transform3d(new Translation3d(d[0], d[1], d[2]), new Rotation3d(VecBuilder.fill(d[3], d[4], d[5]))));
    }

    private static boolean residuals(Pose3d cam, double[] pts, double[] obs, TagQualityEstimator lens, double[] r) {
        var inv = new Transform3d(new Translation3d(), cam.getRotation()).inverse().getRotation();
        var t = cam.getTranslation();
        for (int k = 0; k < obs.length / 2; k++) {
            var p = new Translation3d(pts[3 * k], pts[3 * k + 1], pts[3 * k + 2]).minus(t).rotateBy(inv);
            double[] px = lens.project(p);
            if (px == null) return false;
            r[2 * k] = px[0] - obs[2 * k];
            r[2 * k + 1] = px[1] - obs[2 * k + 1];
        }
        return true;
    }

    private static double cost(double[] r) {
        double c = 0;
        for (double v : r) {
            double a = Math.abs(v);
            c += a <= 2 ? 0.5 * a * a : 2 * a - 2;
        }
        return c;
    }

    private static double sumSq(double[] r) {
        double s = 0;
        for (double v : r) s += v * v;
        return s;
    }

    private static double[] solve6(double[] A, double[] b) {
        return solveN(A, b, 6);
    }

    private static double[] solveN(double[] A, double[] b, int n) {
        double[] M = A.clone(), x = b.clone();
        for (int c = 0; c < n; c++) {
            int p = c;
            for (int i = c + 1; i < n; i++) if (Math.abs(M[n * i + c]) > Math.abs(M[n * p + c])) p = i;
            if (Math.abs(M[n * p + c]) < 1e-15) return null;
            if (p != c) {
                for (int j = 0; j < n; j++) {
                    double tmp = M[n * c + j];
                    M[n * c + j] = M[n * p + j];
                    M[n * p + j] = tmp;
                }
                double tmp = x[c];
                x[c] = x[p];
                x[p] = tmp;
            }
            for (int i = c + 1; i < n; i++) {
                double f = M[n * i + c] / M[n * c + c];
                for (int j = c; j < n; j++) M[n * i + j] -= f * M[n * c + j];
                x[i] -= f * x[c];
            }
        }
        for (int i = n - 1; i >= 0; i--) {
            for (int j = i + 1; j < n; j++) x[i] -= M[n * i + j] * x[j];
            x[i] /= M[n * i + i];
        }
        return x;
    }

    // ---- Judging ----

    private CameraReport judge(String name, Samples s, Transform3d mount, Set<String> trusted) {
        var cfg = Mount.of(mount);
        double[] error = new double[6];
        Arrays.fill(error, Double.NaN);
        double[] est = cfg.toArray();
        Status worst = Status.NO_DATA;
        var why = new ArrayList<String>();
        if (s.zrp.size() >= config.minSamples) {
            worst = Status.OK;
            double[][] cols = columns(s.zrp, 3);
            double[] conf = {cfg.z(), Math.toRadians(cfg.rollDeg()), Math.toRadians(cfg.pitchDeg())};
            int[] dim = {2, 3, 4};
            for (int i = 0; i < 3; i++) {
                double m = median(cols[i]);
                double e = i == 0 ? m - conf[0] : MathUtil.angleModulus(m - conf[i]);
                double se = standardError(cols[i], i > 0);
                worst = max(worst, rate(dim[i], e, se, error, est, m, why));
            }
        }
        String reference = "none";
        var refs = new ArrayList<ArrayDeque<double[]>>();
        var names = new ArrayList<String>();
        if (trusted != null) {
            for (var p : s.partner.entrySet()) {
                if (trusted.contains(p.getKey()) && p.getValue().size() >= config.minSamples) {
                    refs.add(p.getValue());
                    names.add(p.getKey());
                }
            }
        }
        if (!refs.isEmpty()) {
            reference = "cameras:" + String.join("+", names);
        } else {
            var p = s.partner.entrySet().stream()
                    .filter(e -> e.getValue().size() >= config.minSamples)
                    .max((x, y) -> Integer.compare(x.getValue().size(), y.getValue().size()));
            if (p.isPresent()) {
                refs.add(p.get().getValue());
                reference = "pair:" + p.get().getKey();
            } else if (s.est.size() >= config.minSamples) {
                refs.add(s.est);
                reference = "estimator";
            }
        }
        int refSamples = 0;
        if (!refs.isEmpty()) {
            if (worst == Status.NO_DATA) worst = Status.OK;
            double[] conf = {cfg.x(), cfg.y(), Math.toRadians(cfg.yawDeg())};
            int[] dim = {0, 1, 5};
            for (int i = 0; i < 3; i++) {
                // Each reference's median, averaged; standard errors combined.
                double sum = 0, var = 0;
                for (var q : refs) {
                    double[] col = columns(q, 3)[i];
                    double m = median(col);
                    sum += i < 2 ? m - conf[i] : MathUtil.angleModulus(m - conf[i]);
                    double se = standardError(col, i == 2);
                    var += se * se;
                }
                double e = sum / refs.size();
                worst = max(worst, rate(dim[i], e, Math.sqrt(var) / refs.size(), error, est, conf[i] + e, why));
            }
            for (var q : refs) refSamples += q.size();
        }
        double dm = Double.NaN, dd = Double.NaN;
        if (!s.disagree.isEmpty()) {
            var c = columns(s.disagree, 2);
            dm = median(c[0]);
            dd = Math.toDegrees(median(c[1]));
        }
        var estimated = new Mount(est[0], est[1], est[2], est[3], est[4], est[5]);
        String msg = switch (worst) {
            case NO_DATA -> "Camera " + name + " mount: not checked yet (tags in view, robot slow)";
            case OK -> "Camera " + name + " mount OK";
            default -> "Camera " + name + " mount " + (worst == Status.BAD ? "wrong" : "suspect") + ": "
                    + String.join(", ", why) + " (" + reference + "); measured " + estimated;
        };
        return new CameraReport(name, worst, s.zrp.size(), refSamples, reference, cfg, estimated, error, dm, dd, msg);
    }

    /**
     * The largest group of cameras that agree with each other on x/y/yaw (each pair within the
     * limits), if there's one largest group of 2 or more: the reference for every camera. Null when
     * there's no such group (2 cameras that disagree: {@link #resolvePairs} decides).
     */
    private Set<String> trustedSet(Map<String, Transform3d> mounts) {
        var names = new ArrayList<String>();
        for (var e : cameras.entrySet()) {
            if (mounts.containsKey(e.getKey()) && e.getValue().partner.values().stream().anyMatch(q -> q.size() >= config.minSamples))
                names.add(e.getKey());
        }
        int n = Math.min(names.size(), 10);
        if (n < 2) return null;
        // agree[i][j]: -1 unknown, 0 disagree, 1 agree.
        int[][] agree = new int[n][n];
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++) {
                if (i == j) continue;
                var q = cameras.get(names.get(i)).partner.get(names.get(j));
                if (q == null || q.size() < config.minSamples) {
                    agree[i][j] = -1;
                    continue;
                }
                agree[i][j] = consistent(q, Mount.of(mounts.get(names.get(i)))) ? 1 : 0;
            }
        }
        int bestSize = 0, bestMask = 0, count = 0;
        for (int mask = 1; mask < (1 << n); mask++) {
            int size = Integer.bitCount(mask);
            if (size < 2 || size < bestSize) continue;
            boolean ok = true;
            for (int i = 0; i < n && ok; i++) {
                if ((mask & (1 << i)) == 0) continue;
                for (int j = i + 1; j < n && ok; j++) {
                    if ((mask & (1 << j)) == 0) continue;
                    int ab = agree[i][j], ba = agree[j][i];
                    ok = (ab == 1 || ba == 1) && ab != 0 && ba != 0;
                }
            }
            if (!ok) continue;
            if (size > bestSize) {
                bestSize = size;
                bestMask = mask;
                count = 1;
            } else {
                count++;
            }
        }
        if (bestSize < 2 || count != 1) return null;
        var out = new HashSet<String>();
        for (int i = 0; i < n; i++) if ((bestMask & (1 << i)) != 0) out.add(names.get(i));
        return out;
    }

    /** Whether x/y/yaw implied with one partner's poses are within the limits of the configured mount. */
    private boolean consistent(ArrayDeque<double[]> q, Mount cfg) {
        double[][] c = columns(q, 3);
        double ex = median(c[0]) - cfg.x(), ey = median(c[1]) - cfg.y();
        double eyaw = MathUtil.angleModulus(median(c[2]) - Math.toRadians(cfg.yawDeg()));
        return Math.abs(ex) - 2 * standardError(c[0], false) <= config.maxOffsetMeters
                && Math.abs(ey) - 2 * standardError(c[1], false) <= config.maxOffsetMeters
                && Math.abs(eyaw) - 2 * standardError(c[2], true) <= Math.toRadians(config.maxAngleDeg);
    }

    private static final String[] DIM = {"x", "y", "z", "roll", "pitch", "yaw"};

    /** Fills error/estimate for one dimension and rates it. Angles in radians in, degrees out. */
    private Status rate(int dim, double e, double se, double[] error, double[] est, double median, List<String> why) {
        boolean angle = dim >= 3;
        double limit = angle ? Math.toRadians(config.maxAngleDeg) : config.maxOffsetMeters;
        error[dim] = angle ? Math.toDegrees(e) : e;
        est[dim] = angle ? Math.toDegrees(median) : median;
        double excess = Math.abs(e) - 2 * se;
        Status st = excess > config.badFactor * limit ? Status.BAD : excess > limit ? Status.SUSPECT : Status.OK;
        if (st != Status.OK) why.add(String.format(angle ? "%s %+.1f deg" : "%s %+.3f m", DIM[dim], error[dim]));
        return st;
    }

    /** With two cameras, a disagreement is blamed on the one the estimator (and its own z/roll/pitch) agrees with less. */
    private void resolvePairs() {
        for (var e : cameras.entrySet()) {
            var r = e.getValue().report;
            if (r == null || !r.reference().startsWith("pair:")) continue;
            var other = cameras.get(r.reference().substring(5));
            if (other == null || other.report == null) continue;
            if (!xyyFlagged(r)) continue;
            double mine = blame(e.getValue(), r), theirs = blame(other, other.report);
            if (Double.isNaN(mine) || Double.isNaN(theirs)) continue;
            if (mine * 1.5 < theirs) {
                // The other camera is the odd one: this camera's x/y/yaw only look off through it.
                double[] err = r.error().clone();
                var est = r.estimated().toArray();
                var cfg = r.configured().toArray();
                for (int d : new int[] {0, 1, 5}) {
                    err[d] = Double.NaN;
                    est[d] = cfg[d];
                }
                Status st = zrpStatus(r);
                String msg = st == Status.OK
                        ? "Camera " + e.getKey() + " mount OK (disagrees with " + r.reference().substring(5) + ", which looks wrong)"
                        : r.message();
                e.getValue().report = new CameraReport(r.camera(), st, r.samples(), r.refSamples(), r.reference(),
                        r.configured(), new Mount(est[0], est[1], est[2], est[3], est[4], est[5]), err,
                        r.disagreementMeters(), r.disagreementDeg(), msg);
            }
        }
    }

    private boolean xyyFlagged(CameraReport r) {
        for (int d : new int[] {0, 1, 5}) {
            double e = r.error()[d];
            if (!Double.isNaN(e) && Math.abs(e) > (d == 5 ? config.maxAngleDeg : config.maxOffsetMeters)) return true;
        }
        return false;
    }

    private Status zrpStatus(CameraReport r) {
        Status st = Status.OK;
        for (int d : new int[] {2, 3, 4}) {
            double e = r.error()[d];
            if (Double.isNaN(e)) continue;
            double lim = d == 2 ? config.maxOffsetMeters : config.maxAngleDeg;
            if (Math.abs(e) > config.badFactor * lim) st = max(st, Status.BAD);
            else if (Math.abs(e) > lim) st = max(st, Status.SUSPECT);
        }
        return st;
    }

    /** How wrong a camera looks on its own: its distance from the estimator, and its z/roll/pitch error, in limits. */
    private double blame(Samples s, CameraReport r) {
        double b = 0;
        if (s.estDev.size() >= config.minSamples / 2) {
            var c = columns(s.estDev, 2);
            b += median(c[0]) / config.maxOffsetMeters + Math.toDegrees(median(c[1])) / config.maxAngleDeg;
        }
        for (int d : new int[] {2, 3, 4}) {
            double e = r.error()[d];
            if (!Double.isNaN(e)) b += Math.abs(e) / (d == 2 ? config.maxOffsetMeters : config.maxAngleDeg);
        }
        return b == 0 && s.estDev.isEmpty() ? Double.NaN : b;
    }

    private static Status max(Status a, Status b) {
        return a.ordinal() >= b.ordinal() ? a : b;
    }

    private static double[][] columns(ArrayDeque<double[]> q, int n) {
        double[][] c = new double[n][q.size()];
        int i = 0;
        for (var v : q) {
            for (int j = 0; j < n; j++) c[j][i] = v[j];
            i++;
        }
        return c;
    }

    private static double median(double[] a) {
        double[] s = a.clone();
        Arrays.sort(s);
        int n = s.length;
        return n == 0 ? Double.NaN : n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2]);
    }

    /** Standard error of the median, from the MAD (angles: about their median, wrapped). */
    private static double standardError(double[] a, boolean angle) {
        double m = median(a);
        double[] d = new double[a.length];
        for (int i = 0; i < a.length; i++) d[i] = Math.abs(angle ? MathUtil.angleModulus(a[i] - m) : a[i] - m);
        return 1.253 * 1.4826 * median(d) / Math.sqrt(a.length);
    }

    // ---- Results ----

    /** Every camera's latest result (updated twice a second). The pre-match check. */
    public List<CameraReport> reports() {
        var out = new ArrayList<CameraReport>();
        for (var s : cameras.values()) if (s.report != null) out.add(s.report);
        return out;
    }

    /** One camera's latest result, or null. */
    public CameraReport report(String camera) {
        var s = cameras.get(camera);
        return s == null ? null : s.report;
    }

    /** "left OK, right BAD (yaw -5.2 deg)", for a dashboard or a log line. */
    public String summary() {
        var parts = new ArrayList<String>();
        for (var r : reports()) {
            String p = r.camera() + " " + r.status();
            if (r.status() == Status.SUSPECT || r.status() == Status.BAD) {
                var off = new ArrayList<String>();
                for (int d = 0; d < 6; d++) {
                    double e = r.error()[d];
                    double lim = d >= 3 ? config.maxAngleDeg : config.maxOffsetMeters;
                    if (!Double.isNaN(e) && Math.abs(e) > lim) off.add(String.format(d >= 3 ? "%s %+.1f deg" : "%s %+.3f m", DIM[d], e));
                }
                p += " (" + String.join(", ", off) + ")";
            }
            parts.add(p);
        }
        return parts.isEmpty() ? "no data" : String.join(", ", parts);
    }

    private void publishAll() {
        if (table == null) {
            table = NetworkTableInstance.getDefault().getTable("SpectrumVision").getSubTable("mountCheck");
            summaryPub = table.getStringTopic("summary").publish();
        }
        summaryPub.set(summary());
        for (var e : cameras.entrySet()) {
            var r = e.getValue().report;
            if (r == null) continue;
            var p = pubs.computeIfAbsent(e.getKey(), n -> {
                var t = table.getSubTable(n);
                return new Object[] {
                    t.getStringTopic("status").publish(),
                    t.getStringTopic("message").publish(),
                    t.getDoubleArrayTopic("estimated").publish(),
                    t.getDoubleArrayTopic("error").publish(),
                    t.getIntegerTopic("samples").publish(),
                    t.getStringTopic("reference").publish(),
                    t.getStringTopic("code").publish(),
                    t.getStructTopic("estimatedMount", Pose3d.struct).publish(),
                    t.getDoubleArrayTopic("disagreement").publish()
                };
            });
            ((StringPublisher) p[0]).set(r.status().name());
            ((StringPublisher) p[1]).set(r.message());
            ((DoubleArrayPublisher) p[2]).set(r.estimated().toArray());
            ((DoubleArrayPublisher) p[3]).set(r.error());
            ((IntegerPublisher) p[4]).set(r.samples());
            ((StringPublisher) p[5]).set(r.reference());
            ((StringPublisher) p[6]).set(r.estimated().code());
            var m = r.estimated().toTransform();
            @SuppressWarnings("unchecked")
            var mp = (StructPublisher<Pose3d>) p[7];
            mp.set(new Pose3d(m.getTranslation(), m.getRotation()));
            ((DoubleArrayPublisher) p[8]).set(new double[] {r.disagreementMeters(), r.disagreementDeg()});
            var s = e.getValue();
            if (r.status().ordinal() > s.latched.ordinal() || (r.status() == s.latched && s.latched.ordinal() >= Status.SUSPECT.ordinal())) {
                s.latched = r.status();
                if (s.alert == null) s.alert = new VisionAlert("Vision", "", Level.WARNING);
                if (r.status() == Status.BAD) {
                    // Alerts can't change level: a BAD one replaces the warning.
                    if (s.alert != null) s.alert.set(false);
                    s.alert = new VisionAlert("Vision", "", Level.ERROR);
                }
                s.alert.setText(r.message());
                s.alert.set(true);
            }
        }
    }
}
