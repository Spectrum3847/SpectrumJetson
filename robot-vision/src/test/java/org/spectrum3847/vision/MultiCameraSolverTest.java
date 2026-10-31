package org.spectrum3847.vision;

import static org.junit.jupiter.api.Assertions.*;

import edu.wpi.first.apriltag.AprilTagFieldLayout;
import edu.wpi.first.apriltag.AprilTagFields;
import edu.wpi.first.math.geometry.Pose2d;
import edu.wpi.first.math.geometry.Pose3d;
import edu.wpi.first.math.geometry.Rotation2d;
import edu.wpi.first.math.geometry.Rotation3d;
import edu.wpi.first.math.geometry.Transform2d;
import edu.wpi.first.math.geometry.Transform3d;
import edu.wpi.first.math.geometry.Translation3d;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.Random;
import org.ejml.simple.SimpleMatrix;
import org.junit.jupiter.api.Test;
import org.spectrum3847.vision.heading.RobotMotionHistory;
import org.spectrum3847.vision.io.TagQualityEstimator;
import org.spectrum3847.vision.observation.FrameObservation;
import org.spectrum3847.vision.observation.PoseObservation;
import org.spectrum3847.vision.observation.TagObservation;
import org.spectrum3847.vision.solve.MultiCameraSolver;
import org.spectrum3847.vision.solve.MultiCameraSolver.CameraFrame;
import org.spectrum3847.vision.solve.MultiCameraSolver.CameraIntrinsics;
import org.spectrum3847.vision.solve.Solvers;
import org.spectrum3847.vision.testing.SyntheticCamera;

/**
 * The multi-camera solve on synthetic corners from 1-4 cameras on the real 2026 field: exact
 * without noise, time alignment, noise sweeps against the per-camera multi-tag solve and the trig
 * solve (both computed from the same noisy corners), an outlier tag, covariance consistency, and
 * its cost.
 */
class MultiCameraSolverTest {
    static final AprilTagFieldLayout FIELD = AprilTagFieldLayout.loadField(AprilTagFields.kDefaultField);
    /** Four cameras like a typical swerve: corners of the frame, looking out, 15° up. */
    static final Transform3d[] MOUNTS = {
        new Transform3d(0.30, 0.30, 0.25, new Rotation3d(0, Math.toRadians(-15), Math.toRadians(20))),
        new Transform3d(0.30, -0.30, 0.25, new Rotation3d(0, Math.toRadians(-15), Math.toRadians(-20))),
        new Transform3d(-0.30, 0.30, 0.45, new Rotation3d(0, Math.toRadians(-15), Math.toRadians(160))),
        new Transform3d(-0.30, -0.30, 0.45, new Rotation3d(0, Math.toRadians(-15), Math.toRadians(-160))),
    };

    static SyntheticCamera[] cams(double noise, long seed) {
        var c = new SyntheticCamera[MOUNTS.length];
        for (int i = 0; i < c.length; i++) {
            c[i] = SyntheticCamera.typical("cam" + i, seed + i);
            c[i].pixelNoise = noise;
            c[i].maxRange = 7;
        }
        return c;
    }

    static CameraIntrinsics intrinsics(SyntheticCamera c) {
        return new CameraIntrinsics(c.cameraMatrix(), c.distCoeffs);
    }

    static RobotMotionHistory gyro(double t, double heading) {
        var m = new RobotMotionHistory();
        m.add(t - 0.5, new Rotation2d(heading), 0, 0);
        m.add(t + 0.01, new Rotation2d(heading), 0, 0);
        return m;
    }

    /** Frames from the first {@code n} cameras with the robot at {@code robot}. */
    static List<CameraFrame> frames(SyntheticCamera[] c, int n, Pose2d robot, double t) {
        var out = new ArrayList<CameraFrame>();
        for (int i = 0; i < n; i++) {
            var f = c[i].frame(FIELD, new Pose3d(robot), MOUNTS[i], t);
            if (f != null) out.add(new CameraFrame(f, intrinsics(c[i]), MOUNTS[i]));
        }
        return out;
    }

    static int tagCount(List<CameraFrame> fs) {
        return fs.stream().mapToInt(f -> f.frame().tags().size()).sum();
    }

    static Pose2d randomPose(Random r) {
        return new Pose2d(1.5 + r.nextDouble() * 13.5, 1 + r.nextDouble() * 6, new Rotation2d(r.nextDouble() * 2 * Math.PI));
    }

    @Test
    void exactWithoutNoise() {
        var c = cams(0, 1);
        var solver = new MultiCameraSolver();
        var r = new Random(5);
        int solved = 0;
        for (int k = 0; k < 40; k++) {
            var truth = randomPose(r);
            var fs = frames(c, 4, truth, 1.0);
            if (fs.isEmpty()) continue;
            var res = solver.solve(fs, FIELD, null, null, null).orElseThrow();
            assertEquals(0, res.pose().getTranslation().getDistance(truth.getTranslation()), 1e-6, "at " + truth);
            assertEquals(0, res.pose().getRotation().minus(truth.getRotation()).getRadians(), 1e-6);
            assertTrue(res.rmsPx() < 1e-5);
            solved++;
        }
        assertTrue(solved > 20);
    }

    @Test
    void oneTagOneCamera() {
        var c = cams(0.5, 2);
        var solver = new MultiCameraSolver();
        var r = new Random(6);
        double[] noGyro = new double[200], withGyro = new double[200];
        int n = 0;
        while (n < 200) {
            var truth = randomPose(r);
            var f = c[0].frame(FIELD, new Pose3d(truth), MOUNTS[0], 1.0);
            if (f == null) continue;
            var one = new FrameObservation(f.camera(), f.sequenceId(), 1.0, 1000, null, Double.NaN, List.of(), List.of(f.tags().get(0)));
            var fs = List.of(new CameraFrame(one, intrinsics(c[0]), MOUNTS[0]));
            var a = solver.solve(fs, FIELD, null, null, null);
            var b = solver.solve(fs, FIELD, gyro(1.0, truth.getRotation().getRadians()), null, null);
            if (a.isEmpty() || b.isEmpty()) continue;
            noGyro[n] = a.get().pose().getTranslation().getDistance(truth.getTranslation());
            withGyro[n] = b.get().pose().getTranslation().getDistance(truth.getTranslation());
            n++;
        }
        System.out.printf("1 tag, 1 camera, 0.5 px: median/p90 error %.3f/%.3f m without gyro, %.3f/%.3f m with%n",
                pct(noGyro, 50), pct(noGyro, 90), pct(withGyro, 50), pct(withGyro, 90));
        assertTrue(pct(withGyro, 50) < 0.10);
        assertTrue(pct(withGyro, 90) <= pct(noGyro, 90));
    }

    @Test
    void framesAtDifferentTimesAreAligned() {
        var c = cams(0, 3);
        var solver = new MultiCameraSolver();
        // Driving at 3 m/s and turning at 2 rad/s; the cameras capture 0-24 ms apart.
        double vx = 3, w = 2, t0 = 5;
        java.util.function.DoubleFunction<Pose2d> truthAt =
                t -> new Pose2d(6 + vx * (t - t0), 4, new Rotation2d(0.3 + w * (t - t0)));
        // Odometry that drifted 0.4 m and 5° from the field: only its changes matter.
        var drift = new Pose2d(0.4, -0.2, Rotation2d.fromDegrees(5));
        MultiCameraSolver.PoseHistory odom =
                t -> Optional.of(drift.plus(new Transform2d(new Pose2d(), truthAt.apply(t))));
        var motion = new RobotMotionHistory();
        for (double t = t0 - 0.3; t < t0 + 0.05; t += 0.005) motion.add(t, truthAt.apply(t).getRotation(), w, vx);
        var fs = new ArrayList<CameraFrame>();
        double[] times = {t0 - 0.024, t0 - 0.016, t0 - 0.008, t0};
        for (int i = 0; i < 4; i++) {
            var f = c[i].frame(FIELD, new Pose3d(truthAt.apply(times[i])), MOUNTS[i], times[i]);
            if (f != null) fs.add(new CameraFrame(f, intrinsics(c[i]), MOUNTS[i]));
        }
        assertTrue(fs.size() >= 2, "needs 2+ cameras seeing tags");
        Pose2d truth = truthAt.apply(t0);
        var aligned = solver.solve(fs, FIELD, motion, odom, null).orElseThrow();
        var gyroOnly = solver.solve(fs, FIELD, motion, null, null).orElseThrow();
        var none = new MultiCameraSolver(new MultiCameraSolver.Config().noGyroPrior()).solve(fs, FIELD, null, null, null).orElseThrow();
        double eA = aligned.pose().getTranslation().getDistance(truth.getTranslation());
        double eG = gyroOnly.pose().getTranslation().getDistance(truth.getTranslation());
        double eN = none.pose().getTranslation().getDistance(truth.getTranslation());
        System.out.printf("time alignment (3 m/s, 2 rad/s, 24 ms spread, %d cameras): odometry %.4f m, gyro only %.3f m, none %.3f m%n",
                fs.size(), eA, eG, eN);
        assertEquals(t0, aligned.timestampSeconds(), 1e-12);
        assertTrue(eA < 1e-6);
        assertTrue(eN > 10 * eA);
    }

    /** Errors from one noise level, every method from the same frames. */
    record Sweep(double[] mc, double[] mcGyro, double[] perCam, double[] trig, double[] mc1, double headingMc, double headingPerCam) {}

    static Sweep sweep(double noise, int trials, long seed) {
        var c = cams(noise, seed);
        var solver = new MultiCameraSolver(new MultiCameraSolver.Config().cornerSigmaPx(Math.max(noise, 0.1)));
        var r = new Random(seed);
        var mc = new double[trials];
        var mcG = new double[trials];
        var per = new double[trials];
        var trig = new double[trials];
        var mc1 = new double[trials];
        double hMc = 0, hPer = 0;
        int n = 0;
        while (n < trials) {
            var truth = randomPose(r);
            var fs = frames(c, 4, truth, 1.0);
            // Comparable frames: every camera that sees tags sees 2+ (so per-camera multi-tag runs).
            if (fs.size() < 2 || fs.stream().anyMatch(f -> f.frame().tags().size() < 2)) continue;
            var g = gyro(1.0, truth.getRotation().getRadians());
            var a = solver.solve(fs, FIELD, null, null, null);
            var b = solver.solve(fs, FIELD, g, null, null);
            var one = solver.solve(fs.subList(0, 1), FIELD, null, null, null);
            if (a.isEmpty() || b.isEmpty() || one.isEmpty()) continue;
            mc[n] = err(a.get().pose(), truth);
            mcG[n] = err(b.get().pose(), truth);
            mc1[n] = err(one.get().pose(), truth);
            hMc += Math.abs(a.get().pose().getRotation().minus(truth.getRotation()).getRadians());
            // Existing paths, from the same noisy corners: PhotonVision-style per-camera 6-DoF
            // multi-tag (all corners of one camera) through Solvers.multiTag(), averaged over
            // cameras; and TAG_TRIG from per-tag PnP translations plus the true gyro, averaged.
            double ex = 0, ey = 0, eh = 0, tx = 0, ty = 0;
            int nt = 0;
            for (var f : fs) {
                var withPnp = pnpFrame(f, c);
                var o = Solvers.multiTag().solve(withPnp, f.robotToCamera(), FIELD, g).get(0);
                ex += o.robotPose().getX() / fs.size();
                ey += o.robotPose().getY() / fs.size();
                eh += Math.abs(o.robotPose().getRotation().toRotation2d().minus(truth.getRotation()).getRadians()) / fs.size();
                for (var p : Solvers.tagTrig().solve(withPnp, f.robotToCamera(), FIELD, g)) {
                    tx += p.robotPose().getX();
                    ty += p.robotPose().getY();
                    nt++;
                }
            }
            per[n] = Math.hypot(ex - truth.getX(), ey - truth.getY());
            trig[n] = Math.hypot(tx / nt - truth.getX(), ty / nt - truth.getY());
            hPer += eh;
            n++;
        }
        return new Sweep(mc, mcG, per, trig, mc1, hMc / trials, hPer / trials);
    }

    @Test
    void noiseSweepAgainstTheExistingSolvers() {
        System.out.println("noise sweep, 4 cameras, real 2026 field, 150 poses each; translation error median/p90, cm:");
        System.out.println("  px    multi-camera  +gyro prior   per-camera MULTI_TAG (mean of cams)  TAG_TRIG (mean of tags)  multi-camera, 1 cam");
        for (double noise : new double[] {0.25, 0.5, 1, 2}) {
            var s = sweep(noise, 150, 100 + (long) (noise * 10));
            System.out.printf("  %.2f  %5.1f/%5.1f   %5.1f/%5.1f   %5.1f/%5.1f                          %5.1f/%5.1f              %5.1f/%5.1f%n",
                    noise, cm(s.mc, 50), cm(s.mc, 90), cm(s.mcGyro, 50), cm(s.mcGyro, 90), cm(s.perCam, 50), cm(s.perCam, 90),
                    cm(s.trig, 50), cm(s.trig, 90), cm(s.mc1, 50), cm(s.mc1, 90));
            System.out.printf("        mean heading error: multi-camera %.2f°, per-camera MULTI_TAG %.2f°%n",
                    Math.toDegrees(s.headingMc), Math.toDegrees(s.headingPerCam));
            assertTrue(pct(s.mc, 50) < pct(s.perCam, 50), "multi-camera beats the per-camera multi-tag at " + noise + " px");
            assertTrue(pct(s.mcGyro, 90) <= pct(s.mc, 90) * 1.05);
        }
    }

    @Test
    void oneBadTagCannotDragThePose() {
        var c = cams(0.5, 7);
        var r = new Random(8);
        var cauchy = new MultiCameraSolver(new MultiCameraSolver.Config().cornerSigmaPx(0.5));
        var huberNoDrop = new MultiCameraSolver(new MultiCameraSolver.Config().cornerSigmaPx(0.5)
                .loss(MultiCameraSolver.Loss.HUBER).outlierTagSigmas(0));
        var plain = new MultiCameraSolver(new MultiCameraSolver.Config().cornerSigmaPx(0.5).outlierTagSigmas(0));
        plain.config().lossScale = 1e9; // effectively least squares
        double[] eC = new double[100], eH = new double[100], eP = new double[100];
        int n = 0, flagged = 0;
        while (n < 100) {
            var truth = randomPose(r);
            var fs = frames(c, 4, truth, 1.0);
            if (tagCount(fs) < 3) continue;
            // One tag's corners 12 px off (a mis-decoded or reflected tag, a bad corner refine).
            var f0 = fs.get(0).frame();
            var bad = f0.tags().get(0);
            double[] cs = bad.corners().clone();
            for (int i = 0; i < 8; i += 2) cs[i] += 12;
            var badTag = new TagObservation(bad.id(), bad.bestCameraToTag(), bad.altCameraToTag(), bad.ambiguity(), bad.yawDeg(),
                    bad.pitchDeg(), bad.area(), cs, bad.decisionMargin(), bad.edgePx(), bad.undistortPx(), bad.reprojBestPx(), bad.reprojAltPx());
            var tags = new ArrayList<>(f0.tags());
            tags.set(0, badTag);
            var fs2 = new ArrayList<>(fs);
            fs2.set(0, new CameraFrame(new FrameObservation(f0.camera(), f0.sequenceId(), 1.0, 1000, null, Double.NaN, List.of(), tags),
                    fs.get(0).intrinsics(), fs.get(0).robotToCamera()));
            var a = cauchy.solve(fs2, FIELD, null, null, null).orElseThrow();
            eC[n] = err(a.pose(), truth);
            eH[n] = err(huberNoDrop.solve(fs2, FIELD, null, null, null).orElseThrow().pose(), truth);
            eP[n] = err(plain.solve(fs2, FIELD, null, null, null).orElseThrow().pose(), truth);
            var t0 = a.tags().stream().filter(t -> t.camera().equals(f0.camera()) && t.id() == bad.id()).findFirst().orElseThrow();
            if (t0.outlier()) flagged++;
            n++;
        }
        System.out.printf("one tag 12 px off (100 poses, 3+ tags): median/p90 error cm: Cauchy+drop %.1f/%.1f, Huber %.1f/%.1f, least squares %.1f/%.1f; flagged %d/100%n",
                cm(eC, 50), cm(eC, 90), cm(eH, 50), cm(eH, 90), cm(eP, 50), cm(eP, 90), flagged);
        assertTrue(pct(eC, 50) < pct(eP, 50) / 2);
        assertTrue(flagged >= 50);
    }

    @Test
    void covarianceMatchesTheErrors() {
        var c = cams(1.0, 9);
        var solver = new MultiCameraSolver(new MultiCameraSolver.Config().cornerSigmaPx(1.0));
        solver.config().weighting = (t, side, d) -> 1.0; // the true noise: NEES should be ~3
        var r = new Random(10);
        double nees = 0;
        int n = 0;
        while (n < 300) {
            var truth = randomPose(r);
            var fs = frames(c, 4, truth, 1.0);
            if (tagCount(fs) < 2) continue;
            var res = solver.solve(fs, FIELD, null, null, null).orElseThrow();
            var e = new SimpleMatrix(3, 1, true, new double[] {
                res.pose().getX() - truth.getX(), res.pose().getY() - truth.getY(),
                res.pose().getRotation().minus(truth.getRotation()).getRadians()});
            var cov = new SimpleMatrix(res.covariance().getStorage());
            nees += e.transpose().mult(cov.invert()).mult(e).get(0);
            n++;
        }
        nees /= n;
        System.out.printf("covariance consistency: mean NEES %.2f (3 is ideal)%n", nees);
        assertTrue(nees > 1.5 && nees < 6, "NEES " + nees);
    }

    @Test
    void asAnObservation() {
        var c = cams(0.3, 11);
        var truth = new Pose2d(3, 4, Rotation2d.fromDegrees(170));
        var fs = frames(c, 4, truth, 2.0);
        var res = Solvers.multiCamera(new MultiCameraSolver.Config()).solve(fs, FIELD, gyro(2.0, truth.getRotation().getRadians()), null, null)
                .orElseThrow();
        var o = res.toObservation(gyro(2.0, truth.getRotation().getRadians()));
        assertEquals(PoseObservation.Type.MULTI_CAMERA, o.type());
        assertTrue(o.headingFromVision());
        assertEquals(2.0, o.timestampSeconds());
        assertTrue(o.tagCount() >= 1);
        assertTrue(o.averageDistanceMeters() > 0);
        double[] sd = res.stdDevs();
        assertTrue(sd[0] > 0 && sd[0] < 0.5 && sd[2] > 0);
    }

    @Test
    void timing() {
        var c = cams(0.5, 12);
        var solver = new MultiCameraSolver();
        var r = new Random(13);
        var sets = new ArrayList<List<CameraFrame>>();
        while (sets.size() < 50) {
            var truth = randomPose(r);
            var fs = frames(c, 4, truth, 1.0);
            if (tagCount(fs) >= 8) sets.add(fs);
        }
        double tags = sets.stream().mapToInt(MultiCameraSolverTest::tagCount).average().orElse(0);
        var g = gyro(1.0, 0);
        int warm = 2000, loops = 5000;
        long t0 = 0;
        for (int i = 0; i < warm + loops; i++) {
            if (i == warm) t0 = System.nanoTime();
            solver.solve(sets.get(i % sets.size()), FIELD, null, null, null);
        }
        double us = (System.nanoTime() - t0) / 1e3 / loops;
        System.out.printf("multi-camera solve: %.0f µs (4 cameras, %.1f tags on average; this machine)%n", us, tags);
        assertTrue(us < 5000, "must fit a 20 ms loop on a slow machine");
    }

    // ---- Baselines from the same noisy corners ----

    /** The frame with every tag's best pose and the multi-tag pose re-solved from its noisy corners (6-DoF). */
    static FrameObservation pnpFrame(CameraFrame cf, SyntheticCamera[] c) {
        var f = cf.frame();
        var lens = new TagQualityEstimator(c[0].cameraMatrix(), c[0].distCoeffs);
        // Camera pose from truth-ish start (PhotonVision's SQPnP finds the global minimum; starting
        // from the multi-tag truth and refining finds the same one).
        var tags = new ArrayList<TagObservation>();
        var allW = new ArrayList<Translation3d>();
        var allU = new ArrayList<double[]>();
        for (var t : f.tags()) {
            var tp = FIELD.getTagPose(t.id()).orElseThrow();
            var w = new ArrayList<Translation3d>();
            var u = new ArrayList<double[]>();
            var model = lens.tagCorners();
            for (int i = 0; i < 4; i++) {
                w.add(tp.getTranslation().plus(model[i].rotateBy(tp.getRotation())));
                u.add(lens.undistort(t.corners()[2 * i], t.corners()[2 * i + 1]));
            }
            allW.addAll(w);
            allU.addAll(u);
            // Single-tag: from the true camera-to-tag (stored as best by SyntheticCamera, no pose noise).
            Pose3d camTruth = tp.transformBy(t.bestCameraToTag().inverse());
            Pose3d cam = refine6(camTruth, w, u, lens);
            tags.add(new TagObservation(t.id(), new Transform3d(cam, tp), new Transform3d(cam, tp), t.ambiguity(), t.yawDeg(),
                    t.pitchDeg(), t.area(), t.corners(), t.decisionMargin(), t.edgePx(), t.undistortPx(), t.reprojBestPx(), t.reprojAltPx()));
        }
        Pose3d camTruth = new Pose3d().plus(f.multiTagFieldToCamera());
        Pose3d cam = refine6(camTruth, allW, allU, lens);
        var ids = new ArrayList<Integer>();
        for (var t : f.tags()) ids.add(t.id());
        return new FrameObservation(f.camera(), f.sequenceId(), f.timestampSeconds(), 1000, new Transform3d(new Pose3d(), cam), 0, ids, tags);
    }

    /** Levenberg-Marquardt on the camera's 6-DoF pose (numeric Jacobian), all given corners. */
    static Pose3d refine6(Pose3d start, List<Translation3d> w, List<double[]> u, TagQualityEstimator lens) {
        Pose3d x = start;
        int m = 2 * w.size();
        double lambda = 1e-3;
        double[] r0 = resid(x, w, u, lens);
        double cur = Arrays.stream(r0).map(v -> v * v).sum();
        for (int it = 0; it < 50; it++) {
            var J = new SimpleMatrix(m, 6);
            double h = 1e-6;
            for (int j = 0; j < 6; j++) {
                double[] d = new double[6];
                d[j] = h;
                double[] r1 = resid(perturb(x, d), w, u, lens);
                for (int i = 0; i < m; i++) J.set(i, j, (r1[i] - r0[i]) / h);
            }
            var H = J.transpose().mult(J);
            var A = H.copy();
            for (int j = 0; j < 6; j++) A.set(j, j, H.get(j, j) * (1 + lambda) + 1e-12);
            var dx = A.solve(J.transpose().mult(new SimpleMatrix(m, 1, true, r0))).scale(-1);
            double[] d = new double[6];
            for (int j = 0; j < 6; j++) d[j] = dx.get(j);
            Pose3d xn = perturb(x, d);
            double[] rn = resid(xn, w, u, lens);
            double c = Arrays.stream(rn).map(v -> v * v).sum();
            if (c < cur) {
                x = xn;
                r0 = rn;
                cur = c;
                lambda = Math.max(lambda / 10, 1e-12);
                if (Arrays.stream(d).map(Math::abs).sum() < 1e-10) break;
            } else {
                lambda *= 10;
                if (lambda > 1e10) break;
            }
        }
        return x;
    }

    static Pose3d perturb(Pose3d p, double[] d) {
        return p.transformBy(new Transform3d(d[0], d[1], d[2], new Rotation3d(d[3], d[4], d[5])));
    }

    static double[] resid(Pose3d cam, List<Translation3d> w, List<double[]> u, TagQualityEstimator lens) {
        double[] r = new double[2 * w.size()];
        for (int i = 0; i < w.size(); i++) {
            var p = new Pose3d(w.get(i), new Rotation3d()).relativeTo(cam).getTranslation();
            double[] px = lens.project(p);
            if (px == null) px = new double[] {1e4, 1e4};
            r[2 * i] = px[0] - u.get(i)[0];
            r[2 * i + 1] = px[1] - u.get(i)[1];
        }
        return r;
    }

    // ---- Stats ----

    static double err(Pose2d a, Pose2d b) {
        return a.getTranslation().getDistance(b.getTranslation());
    }

    static double pct(double[] v, double p) {
        double[] s = v.clone();
        Arrays.sort(s);
        return s[Math.min(s.length - 1, (int) Math.floor(p / 100.0 * s.length))];
    }

    static double cm(double[] v, double p) {
        return 100 * pct(v, p);
    }
}
