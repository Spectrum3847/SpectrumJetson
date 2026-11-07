package org.spectrum3847.tagekf;

import frc.spectrumLib.localization.CornerSighting;
import frc.spectrumLib.localization.MountEstimator;
import frc.spectrumLib.localization.OdometryGuard;
import frc.spectrumLib.localization.TagEkf;
import frc.spectrumLib.localization.TagEkf.Noise;
import frc.spectrumLib.localization.TagSighting;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.stream.Stream;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Pose3d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Rotation3d;
import org.wpilib.math.geometry.Transform3d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.geometry.Translation3d;
import org.wpilib.math.kinematics.SwerveModulePosition;

/**
 * TXMAN1 replay: recorded Orin frames, re-detected by NAPA (min tag 22) with and without the full-tag
 * fit (replay/detect.sh), fed with the match's logged odometry into {@link TagEkf} as the robot does
 * ({@code Vision.feedTagEkf}: per-tag bearing and range from each tag's own pose, the mount
 * corrected online by {@link MountEstimator}), one variant at a time.
 *
 * <p>Scores, per variant, over the time the cameras recorded:
 *
 * <ul>
 *   <li><b>held-out</b>: every 4th frame is never fed; each of its tags' innovation (bearing x range
 *       and range, metres) against the filter at its capture time. Measured with the fitted
 *       corners' pose for every variant, so all variants are scored on the same numbers. NIS is with
 *       the variant's own measurement and noise: 2 is honest.
 *   <li><b>MT1</b>: distance to the Limelights' multi-tag MT1 poses (independent cameras; their own
 *       error, several cm, is in it), and the share over 1 m ("lost").
 *   <li><b>heading</b>: |heading - MT1 heading|, median, degrees.
 *   <li><b>jump</b>: how far each fed frame moves the estimate (RMS, mm): jitter while moving. The
 *       robot is never still for long while the cameras record, so the stationary number is the
 *       bench's (BenchEkf).
 *   <li><b>fit us</b>: full-tag fit time on the Pi 5 for the tags fitted, from the per-cell-size
 *       table in docs/FULL-TAG-REFINEMENT.md (warm, 1 iteration).
 * </ul>
 *
 * <pre>
 * ./gradlew replay -Pargs="--dets DIR --logs DIR [--variants base,fit,...] [--matches Q17,Q24]"
 * </pre>
 */
public final class TxmanReplay {
    static final int HOLDOUT = 4;
    static final double LOST_M = 1.0;
    static final double TAG_SIZE_M = 0.1651;

    /** Frames reach the robot about this long after capture (NT4 + the 20 ms loop). */
    static final double ARRIVAL_S = 0.025;

    static final String TRACE = System.getProperty("trace", "");

    static final boolean DIAG = Boolean.getBoolean("diag");

    /** camera -> per tag {centre du, centre dv, shape rms} against the estimate, px (DIAG). */
    static final Map<String, List<double[]>> diag = new LinkedHashMap<>();

    static final String[] CAMERAS = {"orin-left", "orin-right"};

    /** Module positions: 21.75 in square (SwerveConfig), FL FR BL BR. */
    static final Translation2d[] MODULES;

    static {
        double h = 21.75 * 0.0254 / 2;
        MODULES =
                new Translation2d[] {
                    new Translation2d(h, h),
                    new Translation2d(h, -h),
                    new Translation2d(-h, h),
                    new Translation2d(-h, -h)
                };
    }

    /** Vision.orinRobotToCamera on tagekf-replay-tuner (48e0b78): measured over 9 TXMAN1 logs. */
    static final Transform3d[] MEASURED = {
        mount(0.0836, 0.3231, 0.4883, 1.5, -18.12, 85.13), mount(0.0836, -0.3231, 0.4883, -0.03, -21.85, -84.41)
    };

    /** The CAD mounts before that (3ab436b). */
    static final Transform3d[] CAD = {
        mount(0.0836, 0.3231, 0.4883, 0, -18, 90), mount(0.0836, -0.3231, 0.4883, 0, -18, -84.5)
    };

    static Transform3d mount(double x, double y, double z, double r, double p, double yw) {
        return new Transform3d(
                new Translation3d(x, y, z),
                new Rotation3d(Math.toRadians(r), Math.toRadians(p), Math.toRadians(yw)));
    }

    /** check-ns-replay-merge's TagEkf constants (465a2c3): what the robot ran at TXMAN1. */
    static final Noise OLD =
            new Noise(
                    0.03 * 0.03,
                    0.05,
                    1.0,
                    Math.pow(Math.toRadians(0.4), 2) / 60.0,
                    6e-5,
                    Math.toRadians(1.0),
                    0.02,
                    0.01,
                    0.005,
                    13.8);

    static final Noise NEW = Noise.DEFAULT;

    // ------------------------------------------------------------------------------- inputs

    record Det(
            int id,
            double cell,
            boolean fitOk,
            double fitUs,
            double[] napa,
            double[] fit,
            double[] tNapa,
            double[] tFit) {}

    sealed interface Ev permits Odom, Daq, Gyro, Ref, Frame {
        /** When the robot gets it. */
        double at();
    }

    record Odom(double at, double yaw, double[] dist, double[] ang) implements Ev {}

    /** FailedDaqs rose (a CAN read failed this loop). */
    record Daq(double at) implements Ev {}

    record Gyro(double at, boolean ok) implements Ev {}

    record Ref(double at, Pose2d pose) implements Ev {}

    record Frame(double at, int cam, double t, List<Det> dets) implements Ev {}

    record Match(String name, List<Ev> events, double start, double end) {}

    static Match load(String name, Path dets, Path logs) throws IOException {
        List<Ev> ev = new ArrayList<>();
        Path log;
        try (Stream<Path> s = Files.list(logs)) {
            log =
                    s.filter(
                                    p -> {
                                        String f = p.getFileName().toString().toLowerCase(Locale.ROOT);
                                        return f.endsWith(".tagekf.txt")
                                                && f.contains("_" + name.toLowerCase(Locale.ROOT) + "_");
                                    })
                            .findFirst()
                            .orElseThrow(() -> new IOException("no tagekf.txt for " + name + " in " + logs));
        }
        for (String line : Files.readAllLines(log)) {
            String[] f = line.split(" ");
            if (f[0].equals("O")) {
                double[] d = new double[4];
                double[] a = new double[4];
                for (int i = 0; i < 4; i++) {
                    d[i] = Double.parseDouble(f[3 + i]);
                    a[i] = Double.parseDouble(f[7 + i]);
                }
                ev.add(new Odom(Double.parseDouble(f[1]), Double.parseDouble(f[2]), d, a));
            } else if (f[0].equals("D")) {
                ev.add(new Daq(Double.parseDouble(f[1])));
            } else if (f[0].equals("G")) {
                ev.add(new Gyro(Double.parseDouble(f[1]), f[2].equals("1")));
            } else if (f[0].equals("P")) {
                ev.add(
                        new Ref(
                                Double.parseDouble(f[2]),
                                new Pose2d(
                                        Double.parseDouble(f[3]),
                                        Double.parseDouble(f[4]),
                                        new Rotation2d(Double.parseDouble(f[5])))));
            }
        }
        double start = Double.POSITIVE_INFINITY;
        double end = Double.NEGATIVE_INFINITY;
        for (int c = 0; c < CAMERAS.length; c++) {
            String prefix = name + "-" + CAMERAS[c] + "-";
            List<Path> files;
            try (Stream<Path> s = Files.list(dets)) {
                files =
                        s.filter(
                                        p -> {
                                            String f = p.getFileName().toString();
                                            return f.startsWith(prefix) && f.endsWith(".dets.csv");
                                        })
                                .sorted()
                                .toList();
            }
            for (Path df : files) {
                String base = df.toString();
                Path ff = Path.of(base.substring(0, base.length() - ".dets.csv".length()) + ".frames.csv");
                Map<Integer, Double> robotT = new HashMap<>();
                for (String line : Files.readAllLines(ff)) {
                    if (line.startsWith("#")) {
                        continue;
                    }
                    String[] f = line.split(",", -1);
                    if (f.length > 6 && !f[6].isBlank()) { // blank: no robot time sync yet
                        robotT.put(Integer.parseInt(f[0]), Long.parseLong(f[6].trim()) * 1e-6);
                    }
                }
                Map<Integer, List<Det>> byFrame = new LinkedHashMap<>();
                for (String line : Files.readAllLines(df)) {
                    if (line.startsWith("#")) {
                        continue;
                    }
                    String[] f = line.split(",");
                    double[] v = new double[f.length];
                    for (int i = 0; i < f.length; i++) {
                        // tagfit_bench prints C's "-nan"/"nan" for a pose it could not solve
                        v[i] = f[i].trim().toLowerCase(Locale.ROOT).endsWith("nan") ? Double.NaN : Double.parseDouble(f[i]);
                    }
                    byFrame.computeIfAbsent((int) v[0], k -> new ArrayList<>())
                            .add(
                                    new Det(
                                            (int) v[1],
                                            v[2],
                                            v[3] != 0,
                                            v[4],
                                            Arrays.copyOfRange(v, 6, 14),
                                            Arrays.copyOfRange(v, 14, 22),
                                            Arrays.copyOfRange(v, 22, 25),
                                            Arrays.copyOfRange(v, 25, 28)));
                }
                for (var e : byFrame.entrySet()) {
                    Double t = robotT.get(e.getKey());
                    if (t == null) {
                        continue;
                    }
                    ev.add(new Frame(t + ARRIVAL_S, c, t, e.getValue()));
                    start = Math.min(start, t);
                    end = Math.max(end, t);
                }
            }
        }
        ev.sort(Comparator.comparingDouble(Ev::at));
        return new Match(name, ev, start, end);
    }

    // ------------------------------------------------------------------------------- variants

    /**
     * @param fit use the full-tag fit's corners (and their pose)
     * @param maxCell fit only tags with cells up to this many px (0: all), SPECTRUM_TAGFIT_MAX_CELL
     * @param cornerPx feed corners (addCornerFrame) with this pixel std; 0 feeds bearing and range
     * @param mountTau MountEstimator time constant, s; 0 is off (fixed mounts)
     * @param cad start from the CAD mounts instead of the measured ones
     * @param timeOffset added to every frame's capture time, s
     * @param adaptive self-checking uncertainty as on the robot (setAdaptive(10, 1))
     * @param mountAtCapture MountEstimator compares corners with the pose at the frame's capture time
     *     (smoothedAt), as the robot does since 2026-FM-SystemCore aeca58c; false passes the newest pose
     *     (getPose), the robot before it ({@code *-newest})
     */
    record Variant(
            String name,
            boolean fit,
            double maxCell,
            double cornerPx,
            Noise noise,
            double mountTau,
            boolean cad,
            double timeOffset,
            boolean adaptive,
            boolean mountAtCapture) {
        Variant(String name, boolean fit, double maxCell, double cornerPx, Noise noise, double mountTau, boolean cad,
                double timeOffset, boolean adaptive) {
            this(name, fit, maxCell, cornerPx, noise, mountTau, cad, timeOffset, adaptive, true);
        }

        Variant with(String n, Noise nz) {
            return new Variant(n, fit, maxCell, cornerPx, nz, mountTau, cad, timeOffset, adaptive, mountAtCapture);
        }
    }

    static Noise noise(Noise b, double bearingDeg, double rangeBase, double rangePer, double timingS) {
        return new Noise(
                b.odomVarPerMeter(),
                b.slipVarPerMeter(),
                b.slipYawWeight(),
                b.headingVarPerSecond(),
                b.headingVarPerRadian(),
                Math.toRadians(bearingDeg),
                rangeBase,
                rangePer,
                timingS,
                b.gateChi2());
    }

    static Map<String, Variant> variants() {
        Map<String, Variant> v = new LinkedHashMap<>();
        // The robot today (tagekf-replay-tuner aeca58c): as-built noise, mounts corrected online from the pose at
        // capture time; napa: NAPA's corners (PhotonVision's fit off), fit: the full-tag fit's (on).
        Variant robot = new Variant("napa", false, 0, 0, NEW, 2, false, 0, true);
        Variant fit = new Variant("fit", true, 0, 0, NEW, 2, false, 0, true);
        v.put("old-noise", new Variant("old-noise", false, 0, 0, OLD, 2, false, 0, true));
        v.put("napa", robot);
        v.put("fit", fit);
        // Before aeca58c: MountEstimator fed the newest pose.
        v.put("napa-newest", new Variant("napa-newest", false, 0, 0, NEW, 2, false, 0, true, false));
        v.put("fit-newest", new Variant("fit-newest", true, 0, 0, NEW, 2, false, 0, true, false));
        // a. corner reprojection instead of bearing and range
        for (double px : new double[] {0.1, 1, 4, 8, 16}) {
            String n = "a-corners-" + px + "px";
            v.put(n, new Variant(n, true, 0, px, NEW, 2, false, 0, true));
        }
        v.put("a-corners-8px-at-capture", new Variant("a-corners-8px-at-capture", true, 0, 8, NEW, 2, false, 0, true, true));
        // b. timing noise, and the capture-time offset the field replay measured (+8 ms)
        for (double ms : new double[] {0.25, 1, 2, 5}) {
            v.put("b-timing-" + ms + "ms", fit.with("b-timing-" + ms + "ms", noise(NEW, 0.25, 0.005, 0.005, ms / 1000)));
        }
        for (double ms : new double[] {4, 8, 12}) {
            String n = "b-offset+" + ms + "ms";
            v.put(n, new Variant(n, true, 0, 0, NEW, 2, false, ms / 1000, true));
        }
        // c. mount yaw: fixed measured mounts, CAD mounts with and without the online estimate, and bearing std
        v.put("c-fixed-measured", new Variant("c-fixed-measured", true, 0, 0, NEW, 0, false, 0, true));
        v.put("c-cad-fixed", new Variant("c-cad-fixed", true, 0, 0, NEW, 0, true, 0, true));
        v.put("c-cad-online", new Variant("c-cad-online", true, 0, 0, NEW, 2, true, 0, true));
        v.put("c-mount-at-capture", new Variant("c-mount-at-capture", true, 0, 0, NEW, 2, false, 0, true, true));
        v.put("c-bearing-0.1-newest", new Variant("c-bearing-0.1-newest", true, 0, 0,
                noise(NEW, 0.1, 0.005, 0.005, 0.000625), 2, false, 0, true, false));
        v.put("c-cad-at-capture", new Variant("c-cad-at-capture", true, 0, 0, NEW, 2, true, 0, true, true));
        for (double deg : new double[] {0.1, 0.15, 0.5, 1.0}) {
            v.put("c-bearing-" + deg, fit.with("c-bearing-" + deg, noise(NEW, deg, 0.005, 0.005, 0.000625)));
        }
        // e. range noise from data
        for (double[] r : new double[][] {{0.002, 0.002}, {0.002, 0.005}, {0.01, 0.005}, {0.005, 0.01}, {0.005, 0.0025}}) {
            String n = "e-range-" + r[0] + "+" + r[1] + "r2";
            v.put(n, fit.with(n, noise(NEW, 0.25, r[0], r[1], 0.000625)));
        }
        v.put("e-no-adaptive", new Variant("e-no-adaptive", true, 0, 0, NEW, 2, false, 0, false));
        v.put("e-bearing-0.5-at-capture", new Variant("e-bearing-0.5-at-capture", true, 0, 0,
                noise(NEW, 0.5, 0.005, 0.005, 0.000625), 2, false, 0, true, true));
        v.put("e-bearing-0.35-at-capture", new Variant("e-bearing-0.35-at-capture", true, 0, 0,
                noise(NEW, 0.35, 0.005, 0.005, 0.000625), 2, false, 0, true, true));
        // g. skip the fit on close (big) tags
        for (double c : new double[] {4, 6, 9, 14}) {
            String n = "g-maxcell-" + c;
            v.put(n, new Variant(n, true, c, 0, NEW, 2, false, 0, true));
        }
        return v;
    }

    // ------------------------------------------------------------------------------- scoring

    static final class Score {
        final List<Double> err = new ArrayList<>();
        final List<Double> mt1 = new ArrayList<>();
        double nisSum;
        int nisN;
        int lost;
        long accepted;
        long rejected;
        double fitUs;
        long fitted;
        long tags;
        long outOfRange;
        double outOfRangeUs;
        final List<Double> heading = new ArrayList<>();
        double jump2;
        long jumps;
        long relocalizations;

        void add(Score o) {
            relocalizations += o.relocalizations;
            err.addAll(o.err);
            mt1.addAll(o.mt1);
            nisSum += o.nisSum;
            nisN += o.nisN;
            lost += o.lost;
            accepted += o.accepted;
            rejected += o.rejected;
            fitUs += o.fitUs;
            fitted += o.fitted;
            tags += o.tags;
            outOfRange += o.outOfRange;
            outOfRangeUs += o.outOfRangeUs;
            heading.addAll(o.heading);
            jump2 += o.jump2;
            jumps += o.jumps;
        }
    }

    /** Pi 5 fit time per tag by cell size (warm, 1 iteration; FULL-TAG-REFINEMENT.md pass 3). */
    static double piFitUs(double cell) {
        if (cell < 2.5) {
            return 72;
        } else if (cell < 4) {
            return 59;
        } else if (cell < 6) {
            return 62;
        } else if (cell < 9) {
            return 78;
        } else if (cell < 14) {
            return 97;
        }
        return 143;
    }

    static double pct(List<Double> v, double p) {
        if (v.isEmpty()) {
            return Double.NaN;
        }
        double[] a = v.stream().mapToDouble(Double::doubleValue).sorted().toArray();
        return a[(int) Math.min(a.length - 1, Math.round(p * (a.length - 1)))];
    }

    static boolean finite(double[] a) {
        for (double x : a) {
            if (!Double.isFinite(x)) {
                return false;
            }
        }
        return true;
    }

    /** OpenCV camera frame (x right, y down, z out) to WPILib's (x out, y left, z up). */
    static Translation3d wpi(double[] t) {
        return new Translation3d(t[2], -t[0], -t[1]);
    }

    static Score run(Match m, Variant v, Map<Integer, Pose3d> layout, double[][][] calib) {
        TagEkf ekf = new TagEkf(MODULES, v.noise());
        if (v.adaptive()) {
            ekf.setAdaptive(10, 1);
        }
        MountEstimator mounts = v.mountTau() > 0 ? new MountEstimator(v.mountTau(), 40, 2.5, 20) : null;
        Transform3d[] base = v.cad() ? CAD : MEASURED;
        Score sc = new Score();
        boolean haveOdom = false;
        int frameIndex = 0;
        double nextTrace = 0;
        // As Swerve builds it: 1.5 x the free speeds (5.12 m/s, 540 deg/s).
        OdometryGuard guard = new OdometryGuard(new OdometryGuard.Settings(1.5 * 5.12, 1.5 * Math.toRadians(540), MODULES));
        boolean gyroOk = true;
        double daqAt = Double.NaN;
        for (Ev e : m.events()) {
            switch (e) {
                case Gyro g -> gyroOk = g.ok();
                case Daq d -> daqAt = d.at();
                case Odom o -> {
                    // As TagEkfTuner: a loop whose DAQ failed may carry a dead 0.
                    boolean daqFailed = !Double.isNaN(daqAt) && o.at() - daqAt < 0.02;
                    boolean[] ok = new boolean[4];
                    for (int i = 0; i < 4; i++) {
                        ok[i] = !(daqFailed && (o.dist()[i] == 0 || o.ang()[i] == 0));
                    }
                    var out =
                            guard.update(
                                    new OdometryGuard.Sample(
                                            o.at(),
                                            o.yaw(),
                                            gyroOk && !(daqFailed && o.yaw() == 0),
                                            0,
                                            false,
                                            o.dist(),
                                            o.ang(),
                                            ok));
                    if (out.isEmpty()) {
                        continue;
                    }
                    ekf.addOdometry(o.at(), out.get().heading(), out.get().positions());
                    haveOdom = true;
                }
                case Ref r -> {
                    if (!haveOdom) {
                        continue;
                    }
                    if (!ekf.isSeeded()) {
                        ekf.addPose(r.pose(), r.at(), 0.1, 0.05);
                        continue;
                    }
                    if (r.at() < m.start() + 2 || r.at() > m.end()) {
                        continue;
                    }
                    double d = ekf.getPose().getTranslation().getDistance(r.pose().getTranslation());
                    if (TRACE.equals(m.name() + ":" + v.name()) && r.at() >= nextTrace) {
                        nextTrace = r.at() + 1;
                        Pose2d p = ekf.getPose();
                        System.out.printf(
                                "  t %7.2f ekf %6.2f %6.2f %7.1f  mt1 %6.2f %6.2f %7.1f  off %5.2f  std %.3f  acc %d rej %d %s%n",
                                r.at(), p.getX(), p.getY(), p.getRotation().getDegrees(), r.pose().getX(),
                                r.pose().getY(), r.pose().getRotation().getDegrees(), d, ekf.getStdDevs()[0],
                                ekf.getAcceptedCount(), ekf.getRejectedCount(), ekf.getRejectionCounts());
                    }
                    sc.mt1.add(d);
                    sc.heading.add(Math.abs(ekf.getPose().getRotation().minus(r.pose().getRotation()).getDegrees()));
                    if (d > LOST_M) {
                        sc.lost++;
                    }
                }
                case Frame f -> {
                    if (!haveOdom || !ekf.isSeeded()) {
                        continue;
                    }
                    String cam = CAMERAS[f.cam()];
                    double t = f.t() + v.timeOffset();
                    Transform3d mount = mounts == null ? base[f.cam()] : mounts.corrected(cam, base[f.cam()]);
                    List<CornerSighting> corners = new ArrayList<>();
                    List<TagSighting> tags = new ArrayList<>();
                    List<TagSighting> refs = new ArrayList<>();
                    for (Det d : f.dets()) {
                        Pose3d tag = layout.get(d.id());
                        if (tag == null) {
                            continue;
                        }
                        if (!finite(d.tNapa()) || !finite(d.tFit())) {
                            continue; // no pose for this sighting (counted by neither variant)
                        }
                        boolean useFit = v.fit() && d.fitOk() && (v.maxCell() <= 0 || d.cell() <= v.maxCell());
                        sc.tags++;
                        if (useFit) {
                            sc.fitted++;
                            sc.fitUs += piFitUs(d.cell());
                        }
                        Translation3d own = wpi(useFit ? d.tFit() : d.tNapa());
                        Translation3d inRobot = own.rotateBy(mount.getRotation());
                        double range = Math.hypot(inRobot.getX(), inRobot.getY());
                        if (range < 0.2 || range > 8.0) {
                            sc.outOfRange++;
                            if (useFit) {
                                sc.outOfRangeUs += piFitUs(d.cell());
                            }
                        }
                        double[] px = useFit ? d.fit() : d.napa();
                        double[][] pix = {
                            {px[0], px[1]}, {px[2], px[3]}, {px[4], px[5]}, {px[6], px[7]}
                        };
                        corners.add(
                                new CornerSighting(
                                        cam,
                                        t,
                                        d.id(),
                                        CornerSighting.tagCorners(tag, TAG_SIZE_M),
                                        pix,
                                        mount,
                                        calib[f.cam()][0],
                                        calib[f.cam()][1],
                                        v.cornerPx() > 0 ? v.cornerPx() : 1));
                        tags.add(new TagSighting(cam, t, d.id(), tag.getTranslation(), mount, own, 1.0));
                        refs.add(
                                new TagSighting(
                                        cam, t, d.id(), tag.getTranslation(), mount, wpi(d.tFit()), 1.0));
                    }
                    if (tags.isEmpty()) {
                        continue;
                    }
                    boolean scoring = t >= m.start() + 2;
                    if (frameIndex++ % HOLDOUT == 0) {
                        if (!scoring) {
                            continue;
                        }
                        for (int i = 0; i < tags.size(); i++) {
                            double[] in = ekf.innovationSmoothed(refs.get(i));
                            if (in != null) {
                                sc.err.add(Math.hypot(in[0] * refs.get(i).cameraToTag().getNorm(), in[1]));
                            }
                            double[] own = ekf.innovationSmoothed(tags.get(i));
                            if (own != null) {
                                sc.nisSum += Math.min(own[2], 50);
                                sc.nisN++;
                            }
                        }
                        continue;
                    }
                    // The pose at the frame's capture time; the robot passes the current one (getPose).
                    double[] sm = ekf.smoothedAt(t);
                    Pose2d atCapture =
                            sm == null ? ekf.getPose() : new Pose2d(sm[0], sm[1], new Rotation2d(sm[2]));
                    if (mounts != null) {
                        mounts.update(v.mountAtCapture() ? atCapture : ekf.getPose(), corners);
                    }
                    if (DIAG && scoring) {
                        Pose2d est = atCapture;
                        for (CornerSighting c : corners) {
                            double[][] pr = new double[4][];
                            double pu = 0;
                            double pv = 0;
                            double du = 0;
                            double dv = 0;
                            for (int i = 0; i < 4; i++) {
                                pr[i] = c.project(est.getX(), est.getY(), est.getRotation().getRadians(), c.fieldCorners()[i]);
                                if (pr[i] == null) {
                                    pr = null;
                                    break;
                                }
                                pu += pr[i][0] / 4;
                                pv += pr[i][1] / 4;
                                du += c.pixels()[i][0] / 4;
                                dv += c.pixels()[i][1] / 4;
                            }
                            if (pr == null) {
                                continue;
                            }
                            // centre offset, and the shape residual (each set about its centre, nearest corner)
                            double shape = 0;
                            for (int i = 0; i < 4; i++) {
                                double best = Double.POSITIVE_INFINITY;
                                for (int j = 0; j < 4; j++) {
                                    best = Math.min(best, Math.hypot(
                                            (c.pixels()[i][0] - du) - (pr[j][0] - pu), (c.pixels()[i][1] - dv) - (pr[j][1] - pv)));
                                }
                                shape += best * best / 4;
                            }
                            diag.computeIfAbsent(c.camera(), k -> new ArrayList<>())
                                    .add(new double[] {du - pu, dv - pv, Math.sqrt(shape)});
                        }
                    }
                    Pose2d before = ekf.getPose();
                    long a0 = ekf.getAcceptedCount();
                    long r0 = ekf.getRejectedCount();
                    if (v.cornerPx() > 0) {
                        ekf.addCornerFrame(corners);
                    } else {
                        ekf.addFrame(tags);
                    }
                    if (scoring) {
                        sc.accepted += ekf.getAcceptedCount() - a0;
                        sc.rejected += ekf.getRejectedCount() - r0;
                    }
                    if (scoring) {
                        double j = ekf.getPose().getTranslation().getDistance(before.getTranslation());
                        sc.jump2 += j * j;
                        sc.jumps++;
                    }
                }
            }
        }
        sc.relocalizations = ekf.getRelocalizations();
        return sc;
    }

    static final String HEADER =
            String.format(
                    "%-26s %7s %7s %6s | %7s %7s %6s %7s %5s | %7s %6s %6s | %9s %5s",
                    "variant", "ho p50", "ho p90", "NIS", "MT1 p50", "MT1 p90", "lost%", "head", "reloc", "jump mm",
                    "acc%", "tags", "fit us/fr", "fit%");

    static String row(String name, Score s, long frames) {
        return String.format(
                "%-26s %7.3f %7.3f %6.2f | %7.3f %7.3f %6.1f %7.2f %5d | %7.1f %6.1f %6d | %9.0f %5.0f",
                name,
                pct(s.err, 0.5),
                pct(s.err, 0.9),
                s.nisSum / Math.max(1, s.nisN),
                pct(s.mt1, 0.5),
                pct(s.mt1, 0.9),
                100.0 * s.lost / Math.max(1, s.mt1.size()),
                pct(s.heading, 0.5),
                s.relocalizations,
                1000 * Math.sqrt(s.jump2 / Math.max(1, s.jumps)),
                100.0 * s.accepted / Math.max(1, s.accepted + s.rejected),
                s.tags,
                s.fitUs / Math.max(1, frames),
                100.0 * s.fitted / Math.max(1, s.tags));
    }

    static final String CSV_HEADER =
            "cal,variant,match,ho_p50_m,ho_p90_m,nis,mt1_p50_m,mt1_p90_m,lost_pct,heading_deg,relocalizations,"
                    + "held_out_tags,mt1_samples";

    static String csv(String label, String variant, String match, Score s) {
        return String.format(
                Locale.ROOT,
                "%s,%s,%s,%.4f,%.4f,%.3f,%.4f,%.4f,%.2f,%.2f,%d,%d,%d",
                label,
                variant,
                match,
                pct(s.err, 0.5),
                pct(s.err, 0.9),
                s.nisSum / Math.max(1, s.nisN),
                pct(s.mt1, 0.5),
                pct(s.mt1, 0.9),
                100.0 * s.lost / Math.max(1, s.mt1.size()),
                pct(s.heading, 0.5),
                s.relocalizations,
                s.err.size(),
                s.mt1.size());
    }

    /** Match names in a dets directory: the part of {@code <match>-orin-<side>-...dets.csv} before the camera. */
    static List<String> allMatches(Path dets) throws IOException {
        try (Stream<Path> s = Files.list(dets)) {
            return s.map(p -> p.getFileName().toString())
                    .filter(f -> f.endsWith(".dets.csv") && f.contains("-orin-"))
                    .map(f -> f.substring(0, f.indexOf("-orin-")))
                    .distinct()
                    .sorted(Comparator.comparing((String n) -> n.charAt(0))
                            .thenComparingInt(n -> Integer.parseInt(n.substring(1))))
                    .toList();
        }
    }

    public static void main(String[] args) throws IOException {
        Path dets = null;
        Path logs = null;
        Path repo = Path.of("..").toAbsolutePath().normalize();
        String only = "";
        String matches = "Q17,Q24";
        String cal = "";
        boolean perMatch = false;
        Path csvOut = null;
        String label = "";
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--dets" -> dets = Path.of(args[++i]);
                case "--logs" -> logs = Path.of(args[++i]);
                case "--repo" -> repo = Path.of(args[++i]);
                case "--variants" -> only = args[++i];
                case "--matches" -> matches = args[++i];
                case "--cal" -> cal = args[++i];
                case "--per-match" -> perMatch = true;
                case "--csv" -> csvOut = Path.of(args[++i]);
                case "--label" -> label = args[++i];
                default -> throw new IllegalArgumentException("unknown " + args[i]);
            }
        }
        if (dets == null || logs == null) {
            System.err.println("usage: TxmanReplay --dets DIR --logs DIR [--cal -refit] [--repo DIR] [--variants a,b]"
                    + " [--matches Q17,Q24|all] [--per-match] [--csv FILE --label NAME]");
            System.exit(2);
        }
        Map<Integer, Pose3d> layout = Json.layout(repo.resolve("tools/fieldcal/layouts/2026-rebuilt-andymark.json"));
        double[][][] calib = {
            Json.calibration(repo.resolve("calibrations/SJ-TC01-1280x800" + cal + ".json")),
            Json.calibration(repo.resolve("calibrations/SJ-TC02-1280x800" + cal + ".json"))
        };
        List<Match> ms = new ArrayList<>();
        if (label.isEmpty()) {
            label = cal.isEmpty() ? "deployed" : cal.substring(1);
        }
        List<String> names = matches.equals("all") ? allMatches(dets) : List.of(matches.split(","));
        for (String n : names) {
            Match m = load(n, dets, logs);
            long frames = m.events().stream().filter(e -> e instanceof Frame).count();
            long odom = m.events().stream().filter(e -> e instanceof Odom).count();
            System.out.printf(
                    "%s: %d frames with tags over %.1f s, %d odometry samples%n", n, frames, m.end() - m.start(), odom);
            ms.add(m);
        }
        System.out.println(HEADER);
        List<String> csvRows = new ArrayList<>();
        List<String> want = only.isEmpty() ? List.of() : List.of(only.split(","));
        for (Variant v : variants().values()) {
            if (!want.isEmpty() && !want.contains(v.name())) {
                continue;
            }
            Score total = new Score();
            for (Match m : ms) {
                Score one = run(m, v, layout, calib);
                total.add(one);
                if (perMatch) {
                    long fr = m.events().stream().filter(e -> e instanceof Frame).count();
                    System.out.println(row("  " + m.name(), one, fr));
                }
                csvRows.add(csv(label, v.name(), m.name(), one));
            }
            csvRows.add(csv(label, v.name(), "pooled", total));
            long frames = ms.stream().mapToLong(m -> m.events().stream().filter(e -> e instanceof Frame).count()).sum();
            System.out.println(row(v.name() + (perMatch ? " (pooled)" : ""), total, frames));
            for (var d : diag.entrySet()) {
                List<double[]> l = d.getValue();
                List<Double> du = l.stream().map(x -> x[0]).toList();
                List<Double> dv = l.stream().map(x -> x[1]).toList();
                List<Double> sh = l.stream().map(x -> x[2]).toList();
                List<Double> cen = l.stream().map(x -> Math.hypot(x[0], x[1])).toList();
                System.out.printf(
                        "   corners vs estimate %s: centre du p50 %+.1f dv p50 %+.1f, |centre| p50/p90 %.1f/%.1f px; "
                                + "shape p50/p90 %.2f/%.2f px (%d tags)%n",
                        d.getKey(), pct(du, 0.5), pct(dv, 0.5), pct(cen, 0.5), pct(cen, 0.9), pct(sh, 0.5),
                        pct(sh, 0.9), l.size());
            }
            diag.clear();
            if (v.name().equals("fit")) {
                System.out.printf(
                        "   (h) tags outside 0.2-8 m: %d of %d (%.1f%%), %.0f us of fit on them%n",
                        total.outOfRange, total.tags, 100.0 * total.outOfRange / total.tags, total.outOfRangeUs);
            }
        }
        if (csvOut != null) {
            List<String> lines = new ArrayList<>();
            if (!Files.exists(csvOut)) {
                lines.add(CSV_HEADER);
            }
            lines.addAll(csvRows);
            Files.write(csvOut, lines, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        }
    }
}
