package org.spectrum3847.vision.solve;

import edu.wpi.first.apriltag.AprilTagFieldLayout;
import edu.wpi.first.math.MathUtil;
import edu.wpi.first.math.Matrix;
import edu.wpi.first.math.Nat;
import edu.wpi.first.math.geometry.Pose2d;
import edu.wpi.first.math.geometry.Pose3d;
import edu.wpi.first.math.geometry.Rotation2d;
import edu.wpi.first.math.geometry.Rotation3d;
import edu.wpi.first.math.geometry.Transform2d;
import edu.wpi.first.math.geometry.Transform3d;
import edu.wpi.first.math.geometry.Translation3d;
import edu.wpi.first.math.interpolation.TimeInterpolatableBuffer;
import edu.wpi.first.math.numbers.N3;
import edu.wpi.first.math.util.Units;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import org.spectrum3847.vision.heading.RobotMotionHistory;
import org.spectrum3847.vision.io.TagQualityEstimator;
import org.spectrum3847.vision.observation.FrameObservation;
import org.spectrum3847.vision.observation.PoseObservation;
import org.spectrum3847.vision.observation.TagObservation;

/**
 * One robot pose from every corner of every tag of every camera: the robot-side multi-tag solve,
 * for PhotonVision in 2D mode (it sends corners, the robot does the 3D).
 *
 * <p><b>Model.</b> The unknown is the robot's pose on the floor at one reference time, (x, y, θ):
 * 3 degrees of freedom. The robot is taken as flat (z, roll, pitch 0), so each camera's height and
 * tilt come from its measured mount. That's what makes one tag on one camera solvable, and it's
 * much better conditioned than a 6-DoF solve per camera (which has to find height, roll and pitch
 * from the pixels too, and spends its accuracy on them). An optional gyro prior adds one residual,
 * (θ − gyro) / σ<sub>gyro</sub>.
 *
 * <p><b>Time.</b> Cameras capture at different times. The reference time is the newest frame's.
 * Each other frame is moved to it with the odometry: the robot at that frame's capture time is
 * {@code X ∘ Δ}, {@code Δ = odom(tRef)⁻¹ ∘ odom(tFrame)}, so the camera's effective mount becomes
 * {@code Δ ∘ robotToCamera} and every frame constrains the same unknown X. Without an odometry
 * history the gyro's heading change alone is used (rotation about the robot centre); without
 * either, frames are taken as simultaneous (fine within a few ms when slow).
 *
 * <p><b>Measurements.</b> Corners are undistorted with each camera's OpenCV model (8 coefficients,
 * PhotonLib's {@code getCameraMatrix()} / {@code getDistCoeffs()}) and compared with the pinhole
 * projection of the field's tag corners, in pixels. Corners are expected in OpenCV's pixel
 * convention (pixel centres at integers), which is what the calibration uses and what the 2027
 * PhotonVision fork sends; {@link Config#cornerShiftPx} adds a constant for a source that doesn't.
 * Each tag's corner σ comes from {@link Config#weighting} (tag size in pixels, distance, image-edge
 * proximity, decision margin). Distance needs no extra weight beyond that: a far tag's pixels
 * already move less per metre, which the Jacobian accounts for.
 *
 * <p><b>Solve.</b> Seeds: each tag on its own (range from its vertical edges, bearing from its
 * centre, heading from the gyro or "facing the tag", refined on its 4 corners), plus the caller's
 * prior pose. Every seed is scored on all corners with the robust loss and the best is refined
 * with Levenberg–Marquardt and iteratively reweighted robust loss (Cauchy by default, Huber
 * optional). A tag whose corners still fit worse than {@link Config#outlierTagSigmas} is dropped
 * and the solve repeated once. The analytic Jacobian is 2×3 per corner.
 *
 * <p><b>Out.</b> Pose, 3×3 covariance ((JᵀWJ)⁻¹, scaled up by the fit's reduced χ² when that is
 * above 1), and every tag's RMS residual, weight and outlier flag (for gates).
 */
public final class MultiCameraSolver {

    /** A camera's calibration: PhotonLib's camera matrix (row-major 3×3) and distortion coefficients. */
    public static final class CameraIntrinsics {
        final double fx, fy, cx, cy;
        final TagQualityEstimator lens;

        public CameraIntrinsics(double[] cameraMatrix, double[] distCoeffs) {
            fx = cameraMatrix[0];
            cx = cameraMatrix[2];
            fy = cameraMatrix[4];
            cy = cameraMatrix[5];
            lens = new TagQualityEstimator(cameraMatrix, distCoeffs);
        }

        /** OpenCV's undistortion of one raw pixel, to an ideal pinhole pixel. */
        public double[] undistort(double u, double v) {
            return lens.undistort(u, v);
        }
    }

    /** One camera's frame, with the camera's calibration and mount. */
    public record CameraFrame(FrameObservation frame, CameraIntrinsics intrinsics, Transform3d robotToCamera) {}

    /** The robot's odometry pose by time (robot timebase), for moving frames to one time. */
    @FunctionalInterface
    public interface PoseHistory {
        Optional<Pose2d> poseAt(double timestampSeconds);

        static PoseHistory of(TimeInterpolatableBuffer<Pose2d> buffer) {
            return buffer::getSample;
        }
    }

    /** A tag's corner standard deviation, pixels. */
    @FunctionalInterface
    public interface TagWeighting {
        /**
         * @param tag the observation (decision margin, edge distance when known)
         * @param sidePx mean side length of the tag in the image, pixels
         * @param distanceMeters rough camera-to-tag distance (from its size)
         */
        double sigmaPx(TagObservation tag, double sidePx, double distanceMeters);
    }

    public enum Loss {
        /** Quadratic near zero, linear beyond {@link Config#lossScale} σ: bounded pull, never zero. */
        HUBER,
        /** Redescending: a corner many σ off has almost no pull. The default (seeds make it safe). */
        CAUCHY
    }

    /** Settings. Public fields, chainable setters. */
    public static final class Config {
        /** Corner noise of a big, clear, central tag, pixels. */
        public double cornerSigmaPx = 0.7;
        public Loss loss = Loss.CAUCHY;
        /** Where the robust loss turns, in σ. */
        public double lossScale = 2.5;
        /** The gyro prior's σ, radians; ≤ 0 or infinite: no gyro prior. */
        public double gyroSigmaRad = Math.toRadians(1.5);
        /** Drop a tag whose RMS whitened residual is above this, and solve again (≤ 0: never). */
        public double outlierTagSigmas = 5;
        public int maxIterations = 20;
        /** Added to every corner before undistorting (0 for OpenCV-convention corners). */
        public double cornerShiftPx = 0;
        public double tagSizeMeters = Units.inchesToMeters(6.5);
        /** Scale the covariance by the reduced χ² when the fit is worse than σ says. */
        public boolean scaleCovarianceByFit = true;
        public TagWeighting weighting = defaultWeighting(this);

        public Config loss(Loss l) {
            loss = l;
            return this;
        }

        public Config cornerSigmaPx(double v) {
            cornerSigmaPx = v;
            return this;
        }

        public Config gyroSigmaDeg(double deg) {
            gyroSigmaRad = Math.toRadians(deg);
            return this;
        }

        public Config noGyroPrior() {
            gyroSigmaRad = 0;
            return this;
        }

        public Config outlierTagSigmas(double v) {
            outlierTagSigmas = v;
            return this;
        }

        public Config cornerShiftPx(double v) {
            cornerShiftPx = v;
            return this;
        }

        public Config weighting(TagWeighting w) {
            weighting = w;
            return this;
        }
    }

    /**
     * The default per-tag σ: {@code cornerSigmaPx}, times (25 px / side) below 25 px, times (1 +
     * 0.05/m), times 2 within 10 px of the image edge, times √(40 / margin) below a decision margin
     * of 40.
     */
    public static TagWeighting defaultWeighting(Config cfg) {
        return (tag, sidePx, d) -> {
            double s = cfg.cornerSigmaPx;
            if (sidePx < 25) s *= 25 / Math.max(sidePx, 1);
            s *= 1 + 0.05 * d;
            if (!Double.isNaN(tag.edgePx()) && tag.edgePx() < 10) s *= 2;
            if (!Double.isNaN(tag.decisionMargin()) && tag.decisionMargin() < 40)
                s *= Math.sqrt(40 / Math.max(tag.decisionMargin(), 1));
            return s;
        };
    }

    /** One tag's fit. */
    public record TagResidual(
            String camera, int id, double rmsPx, double sigmaPx, double robustWeight, double distanceMeters, boolean outlier) {}

    /** The solve. */
    public record Result(
            Pose2d pose,
            double timestampSeconds,
            Matrix<N3, N3> covariance,
            List<TagResidual> tags,
            double rmsPx,
            int iterations,
            boolean gyroPrior,
            int cameras,
            int corners,
            FrameObservation referenceFrame) {

        public Pose3d pose3d() {
            return new Pose3d(pose);
        }

        /** σx, σy, σθ (metres, metres, radians): the square roots of the covariance's diagonal. */
        public double[] stdDevs() {
            return new double[] {
                Math.sqrt(covariance.get(0, 0)), Math.sqrt(covariance.get(1, 1)), Math.sqrt(covariance.get(2, 2))
            };
        }

        public List<Integer> inlierIds() {
            var ids = new ArrayList<Integer>();
            for (var t : tags) if (!t.outlier && !ids.contains(t.id)) ids.add(t.id);
            return ids;
        }

        /** As a candidate for the gates and the pose sink ({@link PoseObservation.Type#MULTI_CAMERA}). */
        public PoseObservation toObservation(RobotMotionHistory motion) {
            double sum = 0, min = Double.POSITIVE_INFINITY, edge = Double.NaN, margin = Double.NaN;
            int n = 0;
            for (var t : tags) {
                if (t.outlier) continue;
                sum += t.distanceMeters;
                min = Math.min(min, t.distanceMeters);
                n++;
            }
            for (var t : referenceFrame.tags()) {
                if (!Double.isNaN(t.edgePx())) edge = Double.isNaN(edge) ? t.edgePx() : Math.min(edge, t.edgePx());
                if (!Double.isNaN(t.decisionMargin()))
                    margin = Double.isNaN(margin) ? t.decisionMargin() : Math.min(margin, t.decisionMargin());
            }
            double dis = Double.NaN;
            if (motion != null) {
                var g = motion.headingAt(timestampSeconds);
                if (g.isPresent()) dis = Math.abs(MathUtil.angleModulus(pose.getRotation().getRadians() - g.get().getRadians()));
            }
            return new PoseObservation(
                    pose3d(), timestampSeconds, PoseObservation.Type.MULTI_CAMERA, inlierIds(),
                    n == 0 ? Double.NaN : sum / n, n == 0 ? Double.NaN : min, 0, rmsPx, edge, margin, dis, referenceFrame);
        }
    }

    private final Config cfg;

    public MultiCameraSolver(Config cfg) {
        this.cfg = cfg;
    }

    public MultiCameraSolver() {
        this(new Config());
    }

    public Config config() {
        return cfg;
    }

    // ---- The problem, flattened into arrays (no allocation in the inner loops) ----

    private static final class Problem {
        int n; // corners
        double[] px, py, pz, uo, vo, sigma; // field corner, observed undistorted pixel, σ
        int[] cam, tag;
        // Per camera: effective mount (rotation row-major, translation) and intrinsics.
        double[][] rot, trans;
        double[] fx, fy, cx, cy;
        // Per tag.
        int tags;
        String[] tagCamera;
        int[] tagId, tagFirst;
        double[] tagSigma, tagRange, tagSide;
        TagObservation[] tagObs;
        Pose3d[] tagPose;
        boolean[] dropped;
        double[] w; // robust weights per corner
        double[] rx, ry; // last residuals

        Problem(int corners, int cams, int tagCount) {
            px = new double[corners];
            py = new double[corners];
            pz = new double[corners];
            uo = new double[corners];
            vo = new double[corners];
            sigma = new double[corners];
            cam = new int[corners];
            tag = new int[corners];
            w = new double[corners];
            rx = new double[corners];
            ry = new double[corners];
            rot = new double[cams][];
            trans = new double[cams][];
            fx = new double[cams];
            fy = new double[cams];
            cx = new double[cams];
            cy = new double[cams];
            tagCamera = new String[tagCount];
            tagId = new int[tagCount];
            tagFirst = new int[tagCount];
            tagSigma = new double[tagCount];
            tagRange = new double[tagCount];
            tagSide = new double[tagCount];
            tagObs = new TagObservation[tagCount];
            tagPose = new Pose3d[tagCount];
            dropped = new boolean[tagCount];
        }
    }

    /**
     * Solves the robot pose at the newest frame's time.
     *
     * @param frames one frame per camera (or more: any frames close in time)
     * @param field the tag layout
     * @param motion gyro history: heading prior and, without odometry, frame alignment (may be null)
     * @param odometry odometry pose history for frame alignment (may be null)
     * @param prior a pose guess at the reference time (the estimator's pose; may be null)
     * @return empty if no tag in the layout was seen, or the solve failed
     */
    public Optional<Result> solve(
            List<CameraFrame> frames, AprilTagFieldLayout field, RobotMotionHistory motion, PoseHistory odometry, Pose2d prior) {
        if (frames.isEmpty()) return Optional.empty();
        CameraFrame ref = frames.get(0);
        for (var f : frames) if (f.frame().timestampSeconds() > ref.frame().timestampSeconds()) ref = f;
        double tRef = ref.frame().timestampSeconds();
        Optional<Pose2d> odomRef = odometry == null ? Optional.empty() : odometry.poseAt(tRef);
        Optional<Rotation2d> gyroRef = motion == null ? Optional.empty() : motion.headingAt(tRef);

        int corners = 0, tagCount = 0;
        for (var f : frames) {
            for (var t : f.frame().tags()) {
                if (validCorners(t) && field.getTagPose(t.id()).isPresent()) {
                    corners += 4;
                    tagCount++;
                }
            }
        }
        if (tagCount == 0) return Optional.empty();
        var P = new Problem(corners, frames.size(), tagCount);
        Translation3d[] model = tagModel(cfg.tagSizeMeters);
        int k = 0, ti = 0;
        for (int c = 0; c < frames.size(); c++) {
            var f = frames.get(c);
            Transform3d mount = f.robotToCamera();
            double t = f.frame().timestampSeconds();
            Transform2d delta = null;
            if (t != tRef) {
                if (odomRef.isPresent()) {
                    var o = odometry.poseAt(t);
                    if (o.isPresent()) delta = o.get().minus(odomRef.get());
                }
                if (delta == null && gyroRef.isPresent()) {
                    var g = motion.headingAt(t);
                    if (g.isPresent()) delta = new Transform2d(0, 0, g.get().minus(gyroRef.get()));
                }
            }
            if (delta != null) {
                mount = new Transform3d(delta.getX(), delta.getY(), 0, new Rotation3d(0, 0, delta.getRotation().getRadians()))
                        .plus(mount);
            }
            P.rot[c] = rotation(mount.getRotation());
            P.trans[c] = new double[] {mount.getX(), mount.getY(), mount.getZ()};
            var in = f.intrinsics();
            P.fx[c] = in.fx;
            P.fy[c] = in.fy;
            P.cx[c] = in.cx;
            P.cy[c] = in.cy;
            for (var tag : f.frame().tags()) {
                var tp = field.getTagPose(tag.id());
                if (!validCorners(tag) || tp.isEmpty()) continue;
                double[] cs = tag.corners();
                P.tagFirst[ti] = k;
                P.tagId[ti] = tag.id();
                P.tagCamera[ti] = f.frame().camera();
                P.tagObs[ti] = tag;
                P.tagPose[ti] = tp.get();
                for (int i = 0; i < 4; i++) {
                    double[] u = in.undistort(cs[2 * i] + cfg.cornerShiftPx, cs[2 * i + 1] + cfg.cornerShiftPx);
                    var w = tp.get().getTranslation().plus(model[i].rotateBy(tp.get().getRotation()));
                    P.px[k] = w.getX();
                    P.py[k] = w.getY();
                    P.pz[k] = w.getZ();
                    P.uo[k] = u[0];
                    P.vo[k] = u[1];
                    P.cam[k] = c;
                    P.tag[k] = ti;
                    k++;
                }
                // Size: mean side; range from the vertical sides (1-2, 3-0), which yaw doesn't shorten.
                int b = P.tagFirst[ti];
                double side = 0;
                for (int i = 0; i < 4; i++) {
                    int j = (i + 1) % 4;
                    side += Math.hypot(P.uo[b + i] - P.uo[b + j], P.vo[b + i] - P.vo[b + j]) / 4;
                }
                double vert = (Math.hypot((P.uo[b + 1] - P.uo[b + 2]) / in.fx, (P.vo[b + 1] - P.vo[b + 2]) / in.fy)
                                + Math.hypot((P.uo[b + 3] - P.uo[b]) / in.fx, (P.vo[b + 3] - P.vo[b]) / in.fy))
                        / 2;
                P.tagSide[ti] = side;
                P.tagRange[ti] = cfg.tagSizeMeters / Math.max(vert, 1e-6);
                P.tagSigma[ti] = Math.max(1e-3, cfg.weighting.sigmaPx(tag, side, P.tagRange[ti]));
                for (int i = 0; i < 4; i++) P.sigma[b + i] = P.tagSigma[ti];
                ti++;
            }
        }
        P.n = k;
        P.tags = ti;

        double gyro = Double.NaN, gyroSigma = 0;
        if (gyroRef.isPresent() && cfg.gyroSigmaRad > 0 && Double.isFinite(cfg.gyroSigmaRad)) {
            gyro = gyroRef.get().getRadians();
            gyroSigma = cfg.gyroSigmaRad;
        }

        // Seeds.
        double[] best = null;
        double bestCost = Double.POSITIVE_INFINITY;
        var seeds = new ArrayList<double[]>();
        if (prior != null) seeds.add(new double[] {prior.getX(), prior.getY(), prior.getRotation().getRadians()});
        for (int t = 0; t < P.tags; t++) {
            int c = P.cam[P.tagFirst[t]];
            double[] s = tagSeed(P, t, c, Double.isNaN(gyro) ? Double.NaN : gyro);
            if (s == null) continue;
            if (!Double.isNaN(gyro)) {
                seeds.add(refine(P, s, gyro, gyroSigma, t, 8));
            } else {
                for (double off : new double[] {0, Math.toRadians(35), -Math.toRadians(35)}) {
                    double[] h = s.clone();
                    double[] s2 = tagSeed(P, t, c, s[2] + off);
                    if (s2 != null) h = s2;
                    seeds.add(refine(P, h, gyro, gyroSigma, t, 8));
                }
            }
        }
        for (var s : seeds) {
            if (s == null) continue;
            double cost = cost(P, s, gyro, gyroSigma, -1, true);
            if (cost < bestCost) {
                bestCost = cost;
                best = s;
            }
        }
        if (best == null) return Optional.empty();

        int[] iters = {0};
        double[] x = lm(P, best, gyro, gyroSigma, iters);
        if (x == null) return Optional.empty();
        if (cfg.outlierTagSigmas > 0 && P.tags > 1) {
            residuals(P, x);
            boolean any = false;
            int kept = P.tags;
            for (int t = 0; t < P.tags; t++) {
                if (tagWhitenedRms(P, t) > cfg.outlierTagSigmas && kept > 1) {
                    P.dropped[t] = true;
                    kept--;
                    any = true;
                }
            }
            if (any) {
                double[] x2 = lm(P, x, gyro, gyroSigma, iters);
                if (x2 != null) x = x2;
            }
        }

        // Covariance from the final weights.
        residuals(P, x);
        setWeights(P, x);
        double[] H = new double[9], g = new double[3];
        double chi2 = normal(P, x, gyro, gyroSigma, H, g);
        int used = 0;
        for (int i = 0; i < P.n; i++) if (!P.dropped[P.tag[i]]) used++;
        int dof = 2 * used + (Double.isNaN(gyro) ? 0 : 1) - 3;
        double[] cov = invert3(H);
        if (cov == null) return Optional.empty();
        if (cfg.scaleCovarianceByFit && dof > 0) {
            double s = chi2 / dof;
            if (s > 1) for (int i = 0; i < 9; i++) cov[i] *= s;
        }
        var covariance = new Matrix<>(Nat.N3(), Nat.N3());
        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) covariance.set(r, c, cov[3 * r + c]);

        var tags = new ArrayList<TagResidual>();
        double sq = 0;
        int nsq = 0;
        Pose3d robot = new Pose3d(new Pose2d(x[0], x[1], new Rotation2d(x[2])));
        for (int t = 0; t < P.tags; t++) {
            int b = P.tagFirst[t];
            double s = 0, wsum = 0;
            for (int i = b; i < b + 4; i++) {
                s += P.rx[i] * P.rx[i] + P.ry[i] * P.ry[i];
                wsum += P.w[i];
            }
            if (!P.dropped[t]) {
                sq += s;
                nsq += 4;
            }
            var camPose = robot.plus(frames.get(P.cam[b]).robotToCamera());
            double dist = camPose.getTranslation().getDistance(P.tagPose[t].getTranslation());
            tags.add(new TagResidual(P.tagCamera[t], P.tagId[t], Math.sqrt(s / 4), P.tagSigma[t], wsum / 4, dist, P.dropped[t]));
        }
        return Optional.of(new Result(
                new Pose2d(x[0], x[1], new Rotation2d(MathUtil.angleModulus(x[2]))),
                tRef,
                covariance,
                tags,
                Math.sqrt(sq / Math.max(nsq, 1)),
                iters[0],
                !Double.isNaN(gyro),
                frames.size(),
                used,
                ref.frame()));
    }

    // ---- Seeds ----

    /** A pose from one tag: range from its size, bearing from its centre, heading given or "facing the tag". */
    private static double[] tagSeed(Problem P, int t, int c, double heading) {
        int b = P.tagFirst[t];
        double xn = 0, yn = 0;
        for (int i = b; i < b + 4; i++) {
            xn += (P.uo[i] - P.cx[c]) / P.fx[c] / 4;
            yn += (P.vo[i] - P.cy[c]) / P.fy[c] / 4;
        }
        // Camera frame (x forward, y left, z up).
        double norm = Math.sqrt(1 + xn * xn + yn * yn), r = P.tagRange[t];
        double[] pc = {r / norm, -xn * r / norm, -yn * r / norm};
        // Robot frame: q = R pc + t.
        double[] R = P.rot[c], T = P.trans[c];
        double qx = R[0] * pc[0] + R[1] * pc[1] + R[2] * pc[2] + T[0];
        double qy = R[3] * pc[0] + R[4] * pc[1] + R[5] * pc[2] + T[1];
        var tp = P.tagPose[t];
        double th = heading;
        if (Double.isNaN(th)) th = tp.getRotation().getZ() + Math.PI - Math.atan2(qy, qx);
        double cs = Math.cos(th), sn = Math.sin(th);
        double x = tp.getX() - (cs * qx - sn * qy), y = tp.getY() - (sn * qx + cs * qy);
        if (!Double.isFinite(x) || !Double.isFinite(y)) return null;
        return new double[] {x, y, th};
    }

    /** A few LM steps on one tag's corners. */
    private double[] refine(Problem P, double[] s, double gyro, double gyroSigma, int onlyTag, int iters) {
        double[] x = s.clone();
        for (int i = P.tagFirst[onlyTag]; i < P.tagFirst[onlyTag] + 4; i++) P.w[i] = 1;
        double lambda = 1e-3;
        double[] H = new double[9], g = new double[3];
        double cur = cost(P, x, gyro, gyroSigma, onlyTag, false);
        if (!Double.isFinite(cur)) return null;
        for (int it = 0; it < iters; it++) {
            normalTag(P, x, gyro, gyroSigma, H, g, onlyTag);
            double[] d = step(H, g, lambda);
            if (d == null) break;
            double[] xn = {x[0] + d[0], x[1] + d[1], x[2] + d[2]};
            double c = cost(P, xn, gyro, gyroSigma, onlyTag, false);
            if (c < cur) {
                x = xn;
                cur = c;
                lambda = Math.max(lambda / 10, 1e-9);
                if (Math.abs(d[0]) + Math.abs(d[1]) + Math.abs(d[2]) < 1e-7) break;
            } else {
                lambda *= 10;
            }
        }
        return x;
    }

    // ---- Levenberg–Marquardt with IRLS ----

    private double[] lm(Problem P, double[] start, double gyro, double gyroSigma, int[] iters) {
        double[] x = start.clone();
        double lambda = 1e-4;
        double[] H = new double[9], g = new double[3];
        setWeights(P, x);
        double cur = cost(P, x, gyro, gyroSigma, -1, true);
        if (!Double.isFinite(cur)) return null;
        for (int it = 0; it < cfg.maxIterations; it++) {
            iters[0]++;
            setWeights(P, x);
            normal(P, x, gyro, gyroSigma, H, g);
            double[] d = step(H, g, lambda);
            if (d == null) return x;
            double[] xn = {x[0] + d[0], x[1] + d[1], x[2] + d[2]};
            double c = cost(P, xn, gyro, gyroSigma, -1, true);
            if (c <= cur) {
                x = xn;
                cur = c;
                lambda = Math.max(lambda / 10, 1e-10);
                if (Math.abs(d[0]) + Math.abs(d[1]) + Math.abs(d[2]) < 1e-8) break;
            } else {
                lambda *= 10;
                if (lambda > 1e8) break;
            }
        }
        return x;
    }

    private static double[] step(double[] H, double[] g, double lambda) {
        double[] A = H.clone();
        for (int i = 0; i < 3; i++) A[4 * i] += lambda * Math.max(H[4 * i], 1e-9);
        double[] inv = invert3(A);
        if (inv == null) return null;
        return new double[] {
            -(inv[0] * g[0] + inv[1] * g[1] + inv[2] * g[2]),
            -(inv[3] * g[0] + inv[4] * g[1] + inv[5] * g[2]),
            -(inv[6] * g[0] + inv[7] * g[1] + inv[8] * g[2])
        };
    }

    /** Residuals for every corner at x into P.rx/ry; false if a used corner is behind its camera. */
    private static boolean residuals(Problem P, double[] x) {
        boolean ok = true;
        double c = Math.cos(x[2]), s = Math.sin(x[2]);
        for (int i = 0; i < P.n; i++) {
            if (!residual(P, i, x[0], x[1], c, s, null)) {
                P.rx[i] = P.ry[i] = 1e3;
                if (!P.dropped[P.tag[i]]) ok = false;
            }
        }
        return ok;
    }

    /**
     * Corner i's residual (into P.rx/ry) and, if J != null, its 2×3 Jacobian (row-major).
     * False if the corner is behind the camera.
     */
    private static boolean residual(Problem P, int i, double x, double y, double c, double s, double[] J) {
        double dX = P.px[i] - x, dY = P.py[i] - y;
        double qx = c * dX + s * dY, qy = -s * dX + c * dY, qz = P.pz[i];
        int k = P.cam[i];
        double[] R = P.rot[k], T = P.trans[k];
        double ex = qx - T[0], ey = qy - T[1], ez = qz - T[2];
        // p = Rᵀ e
        double pX = R[0] * ex + R[3] * ey + R[6] * ez;
        double pY = R[1] * ex + R[4] * ey + R[7] * ez;
        double pZ = R[2] * ex + R[5] * ey + R[8] * ez;
        if (pX < 0.05) return false;
        double inv = 1 / pX, fx = P.fx[k], fy = P.fy[k];
        P.rx[i] = P.cx[k] - fx * pY * inv - P.uo[i];
        P.ry[i] = P.cy[k] - fy * pZ * inv - P.vo[i];
        if (J == null) return true;
        // dq/d(x, y, θ)
        double[][] dq = {{-c, s, 0}, {-s, -c, 0}, {qy, -qx, 0}};
        for (int j = 0; j < 3; j++) {
            double a = dq[j][0], b = dq[j][1];
            double dpX = R[0] * a + R[3] * b, dpY = R[1] * a + R[4] * b, dpZ = R[2] * a + R[5] * b;
            J[j] = fx * pY * inv * inv * dpX - fx * inv * dpY;
            J[3 + j] = fy * pZ * inv * inv * dpX - fy * inv * dpZ;
        }
        return true;
    }

    private double rho(double e2) {
        double k2 = cfg.lossScale * cfg.lossScale;
        if (cfg.loss == Loss.HUBER) {
            double e = Math.sqrt(e2);
            return e2 <= k2 ? e2 : 2 * cfg.lossScale * e - k2;
        }
        return k2 * Math.log1p(e2 / k2);
    }

    private double weight(double e2) {
        double k2 = cfg.lossScale * cfg.lossScale;
        if (cfg.loss == Loss.HUBER) return e2 <= k2 ? 1 : cfg.lossScale / Math.sqrt(e2);
        return 1 / (1 + e2 / k2);
    }

    private void setWeights(Problem P, double[] x) {
        residuals(P, x);
        for (int i = 0; i < P.n; i++) {
            double e2 = (P.rx[i] * P.rx[i] + P.ry[i] * P.ry[i]) / (P.sigma[i] * P.sigma[i]);
            P.w[i] = weight(e2);
        }
    }

    /** Robust cost over all used corners (or one tag's, plain least squares), plus the gyro prior. */
    private double cost(Problem P, double[] x, double gyro, double gyroSigma, int onlyTag, boolean robust) {
        double c = Math.cos(x[2]), s = Math.sin(x[2]), sum = 0;
        int from = onlyTag < 0 ? 0 : P.tagFirst[onlyTag], to = onlyTag < 0 ? P.n : from + 4;
        for (int i = from; i < to; i++) {
            if (P.dropped[P.tag[i]]) continue;
            if (!residual(P, i, x[0], x[1], c, s, null)) return Double.POSITIVE_INFINITY;
            double e2 = (P.rx[i] * P.rx[i] + P.ry[i] * P.ry[i]) / (P.sigma[i] * P.sigma[i]);
            sum += robust ? rho(e2) : e2;
        }
        if (!Double.isNaN(gyro)) {
            double e = MathUtil.angleModulus(x[2] - gyro) / gyroSigma;
            sum += e * e;
        }
        return sum;
    }

    /** JᵀWJ and JᵀWr over all used corners with the current weights; returns Σ w e². */
    private static double normal(Problem P, double[] x, double gyro, double gyroSigma, double[] H, double[] g) {
        return accumulate(P, x, gyro, gyroSigma, H, g, 0, P.n);
    }

    private static void normalTag(Problem P, double[] x, double gyro, double gyroSigma, double[] H, double[] g, int t) {
        accumulate(P, x, gyro, gyroSigma, H, g, P.tagFirst[t], P.tagFirst[t] + 4);
    }

    private static double accumulate(Problem P, double[] x, double gyro, double gyroSigma, double[] H, double[] g, int from, int to) {
        java.util.Arrays.fill(H, 0);
        java.util.Arrays.fill(g, 0);
        double c = Math.cos(x[2]), s = Math.sin(x[2]), chi2 = 0;
        double[] J = new double[6];
        for (int i = from; i < to; i++) {
            if (P.dropped[P.tag[i]]) continue;
            if (!residual(P, i, x[0], x[1], c, s, J)) continue;
            double wi = P.w[i] / (P.sigma[i] * P.sigma[i]);
            double r0 = P.rx[i], r1 = P.ry[i];
            chi2 += wi * (r0 * r0 + r1 * r1);
            for (int a = 0; a < 3; a++) {
                g[a] += wi * (J[a] * r0 + J[3 + a] * r1);
                for (int b = 0; b < 3; b++) H[3 * a + b] += wi * (J[a] * J[b] + J[3 + a] * J[3 + b]);
            }
        }
        if (!Double.isNaN(gyro)) {
            double wg = 1 / (gyroSigma * gyroSigma), e = MathUtil.angleModulus(x[2] - gyro);
            H[8] += wg;
            g[2] += wg * e;
            chi2 += wg * e * e;
        }
        return chi2;
    }

    private static double tagWhitenedRms(Problem P, int t) {
        int b = P.tagFirst[t];
        double s = 0;
        for (int i = b; i < b + 4; i++) s += P.rx[i] * P.rx[i] + P.ry[i] * P.ry[i];
        return Math.sqrt(s / 8) / P.tagSigma[t];
    }

    // ---- Small helpers ----

    private static boolean validCorners(TagObservation t) {
        double[] c = t.corners();
        if (c == null || c.length != 8) return false;
        for (double v : c) if (!Double.isFinite(v)) return false;
        return true;
    }

    static Translation3d[] tagModel(double size) {
        double s = size / 2;
        return new Translation3d[] {
            new Translation3d(0, -s, -s), new Translation3d(0, s, -s), new Translation3d(0, s, s), new Translation3d(0, -s, s)
        };
    }

    /** Row-major rotation matrix: columns are the rotated unit axes. */
    private static double[] rotation(Rotation3d r) {
        var ex = new Translation3d(1, 0, 0).rotateBy(r);
        var ey = new Translation3d(0, 1, 0).rotateBy(r);
        var ez = new Translation3d(0, 0, 1).rotateBy(r);
        return new double[] {
            ex.getX(), ey.getX(), ez.getX(),
            ex.getY(), ey.getY(), ez.getY(),
            ex.getZ(), ey.getZ(), ez.getZ()
        };
    }

    private static double[] invert3(double[] m) {
        double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
        double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
        double det = a * A + b * B + c * C;
        if (!(Math.abs(det) > 1e-300) || !Double.isFinite(det)) return null;
        double id = 1 / det;
        return new double[] {
            A * id, -(b * i - c * h) * id, (b * f - c * e) * id,
            B * id, (a * i - c * g) * id, -(a * f - c * d) * id,
            C * id, -(a * h - b * g) * id, (a * e - b * d) * id
        };
    }
}
