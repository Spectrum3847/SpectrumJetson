package org.spectrum3847.tagekf;

import frc.spectrumLib.localization.TagEkf;
import frc.spectrumLib.localization.TagEkf.Noise;
import frc.spectrumLib.localization.TagSighting;
import java.io.IOException;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import org.wpilib.math.geometry.Pose2d;
import org.wpilib.math.geometry.Rotation2d;
import org.wpilib.math.geometry.Transform3d;
import org.wpilib.math.geometry.Translation2d;
import org.wpilib.math.geometry.Translation3d;
import org.wpilib.math.kinematics.SwerveModulePosition;

/**
 * The robot's TagEkf on the bench, stationary: PhotonVision's results (both cameras, NT4 rawBytes)
 * go into {@link TagEkf} exactly as {@code Vision.feedTagEkf} builds them (each tag's
 * bestCameraToTarget translation, bearing and range), with zero odometry and a fixed gyro, so any
 * pose movement is noise.
 *
 * <p>Truth: the bench doesn't move. Its tags' positions are surveyed from the first {@code
 * --survey} seconds (each camera's mean of each tag, in that camera's frame; each camera is its own
 * "robot" at the origin, mount identity), the filter is reset to (0, 0, 0), and from then on every
 * pose it reports is error. The survey makes the bias zero by construction; what's measured is the
 * scatter (pose and per-tag innovation).
 *
 * <pre>
 * live:    java -cp tagekf-bench.jar:WPILIB_JARS org.spectrum3847.tagekf.BenchEkf live [--seconds 40]
 *          [--survey 5] [--out DIR] [--cameras thrifty,swyft] [noise options]     (robot-ekf/bench.sh)
 * offline: java ... BenchEkf file DIR/tags.csv [noise options]                     (same numbers, any noise)
 * noise:   [--bearing-deg 0.25] [--range 0.005,0.005] [--timing-ms 0.625] [--no-adaptive]
 * </pre>
 *
 * Writes tags.csv (every sighting), innov.csv (each tag's innovation before it is fed) and
 * poses.csv (the estimate after each frame) to DIR, and a summary to stdout.
 */
public final class BenchEkf {
    private final TagEkf ekf;
    private final double surveySeconds;
    private final Map<String, double[]> survey = new LinkedHashMap<>(); // cam:id -> sum x y z n
    private final Map<String, Translation3d> field = new TreeMap<>();
    private final Transform3d mount = new Transform3d();
    private final SwerveModulePosition[] zero = new SwerveModulePosition[4];
    private final PrintWriter tags;
    private final PrintWriter innov;
    private final PrintWriter poses;
    private double first = Double.NaN;
    private double lastOdom = Double.NEGATIVE_INFINITY;
    private boolean started = false;
    // statistics after the survey
    private final List<double[]> poseLog = new ArrayList<>();
    private final Map<String, List<double[]>> innovations = new TreeMap<>();
    private long frames;

    BenchEkf(Noise noise, boolean adaptive, double surveySeconds, Path out) throws IOException {
        double h = 21.75 * 0.0254 / 2;
        ekf =
                new TagEkf(
                        new Translation2d[] {
                            new Translation2d(h, h), new Translation2d(h, -h), new Translation2d(-h, h),
                            new Translation2d(-h, -h)
                        },
                        noise);
        if (adaptive) {
            ekf.setAdaptive(10, 1);
        }
        Arrays.fill(zero, new SwerveModulePosition(0, new Rotation2d()));
        this.surveySeconds = surveySeconds;
        if (out != null) {
            Files.createDirectories(out);
            tags = new PrintWriter(Files.newBufferedWriter(out.resolve("tags.csv")));
            tags.println("camera,t,seq,id,x,y,z,ambiguity,u0,v0,u1,v1,u2,v2,u3,v3");
            innov = new PrintWriter(Files.newBufferedWriter(out.resolve("innov.csv")));
            innov.println("camera,t,id,bearing_deg,range_mm,nis");
            poses = new PrintWriter(Files.newBufferedWriter(out.resolve("poses.csv")));
            poses.println("t,x,y,theta_deg,std_x,std_y,std_theta_deg,accepted,rejected");
        } else {
            tags = null;
            innov = null;
            poses = null;
        }
    }

    /** Zero odometry up to {@code t}, every 20 ms (the robot loop). */
    private void odometryTo(double t) {
        if (lastOdom == Double.NEGATIVE_INFINITY) {
            ekf.addOdometry(t - 1.0, new Rotation2d(), zero);
            lastOdom = t - 1.0;
        }
        while (lastOdom + 0.02 <= t) {
            lastOdom += 0.02;
            ekf.addOdometry(lastOdom, new Rotation2d(), zero);
        }
    }

    /** One camera frame. */
    void frame(String cam, PhotonResult r) {
        double t = r.captureSeconds();
        if (tags != null) {
            for (PhotonResult.Target g : r.targets()) {
                StringBuilder sb = new StringBuilder();
                sb.append(String.format(Locale.ROOT, "%s,%.6f,%d,%d,%.6f,%.6f,%.6f,%.4f", cam, t, r.sequence(), g.id(),
                        g.cameraToTag().getX(), g.cameraToTag().getY(), g.cameraToTag().getZ(), g.ambiguity()));
                for (double c : g.corners()) {
                    sb.append(String.format(Locale.ROOT, ",%.4f", c));
                }
                tags.println(sb);
            }
        }
        if (r.targets().isEmpty()) {
            return;
        }
        if (Double.isNaN(first)) {
            first = t;
        }
        odometryTo(t + 0.01);
        if (t - first < surveySeconds) {
            for (PhotonResult.Target g : r.targets()) {
                double[] s = survey.computeIfAbsent(cam + ":" + g.id(), k -> new double[4]);
                s[0] += g.cameraToTag().getX();
                s[1] += g.cameraToTag().getY();
                s[2] += g.cameraToTag().getZ();
                s[3]++;
            }
            return;
        }
        if (!started) {
            started = true;
            survey.forEach((k, s) -> field.put(k, new Translation3d(s[0] / s[3], s[1] / s[3], s[2] / s[3])));
            ekf.reset(new Pose2d());
            System.out.println("survey: " + field.size() + " tags " + field.keySet());
        }
        List<TagSighting> frame = new ArrayList<>();
        for (PhotonResult.Target g : r.targets()) {
            Translation3d tag = field.get(cam + ":" + g.id());
            if (tag == null) {
                continue;
            }
            TagSighting s = new TagSighting(cam, t, g.id(), tag, mount, g.cameraToTag(), 1.0);
            double[] in = ekf.innovation(s);
            if (in != null) {
                innovations.computeIfAbsent(cam + ":" + g.id(), k -> new ArrayList<>())
                        .add(new double[] {Math.toDegrees(in[0]), in[1] * 1000, in[2], g.cameraToTag().getNorm()});
                if (innov != null) {
                    innov.printf(Locale.ROOT, "%s,%.6f,%d,%.5f,%.3f,%.3f%n", cam, t, g.id(), Math.toDegrees(in[0]),
                            in[1] * 1000, in[2]);
                }
            }
            frame.add(s);
        }
        ekf.addFrame(frame);
        frames++;
        Pose2d p = ekf.getPose();
        double[] sd = ekf.getStdDevs();
        poseLog.add(new double[] {t, p.getX(), p.getY(), p.getRotation().getRadians()});
        if (poses != null) {
            poses.printf(Locale.ROOT, "%.6f,%.6f,%.6f,%.5f,%.5f,%.5f,%.5f,%d,%d%n", t, p.getX(), p.getY(),
                    p.getRotation().getDegrees(), sd[0], sd[1], Math.toDegrees(sd[2]), ekf.getAcceptedCount(),
                    ekf.getRejectedCount());
        }
    }

    static double std(List<Double> v) {
        double m = v.stream().mapToDouble(Double::doubleValue).average().orElse(Double.NaN);
        return Math.sqrt(v.stream().mapToDouble(x -> (x - m) * (x - m)).sum() / Math.max(1, v.size() - 1));
    }

    static double mean(List<Double> v) {
        return v.stream().mapToDouble(Double::doubleValue).average().orElse(Double.NaN);
    }

    static double maxAbs(List<Double> v) {
        return v.stream().mapToDouble(x -> Math.abs(x)).max().orElse(Double.NaN);
    }

    void summary() {
        if (tags != null) {
            tags.close();
            innov.close();
            poses.close();
        }
        List<Double> x = poseLog.stream().map(p -> p[1] * 1000).toList();
        List<Double> y = poseLog.stream().map(p -> p[2] * 1000).toList();
        List<Double> th = poseLog.stream().map(p -> Math.toDegrees(p[3])).toList();
        System.out.printf(Locale.ROOT,
                "pose over %d frames (%.1f s after the survey): x mean %+.2f std %.2f max %.2f mm | y mean %+.2f std %.2f "
                        + "max %.2f mm | theta mean %+.3f std %.3f max %.3f deg%n",
                frames, poseLog.isEmpty() ? 0 : poseLog.get(poseLog.size() - 1)[0] - poseLog.get(0)[0], mean(x),
                std(x), maxAbs(x), mean(y), std(y), maxAbs(y), mean(th), std(th), maxAbs(th));
        System.out.printf(Locale.ROOT, "accepted %d rejected %d %s%n", ekf.getAcceptedCount(), ekf.getRejectedCount(),
                ekf.getRejectionCounts());
        System.out.println("per tag innovation (before each frame is fed): n, range m, bearing mean/std deg, range mean/std mm, NIS mean");
        innovations.forEach(
                (k, l) -> {
                    List<Double> b = l.stream().map(v -> v[0]).toList();
                    List<Double> r = l.stream().map(v -> v[1]).toList();
                    List<Double> n = l.stream().map(v -> Math.min(v[2], 50)).toList();
                    System.out.printf(Locale.ROOT, "  %-12s %6d %5.2f  %+.4f / %.4f  %+.2f / %.2f  %.2f%n", k, l.size(),
                            mean(l.stream().map(v -> v[3]).toList()), mean(b), std(b), mean(r), std(r), mean(n));
                });
    }

    static Noise noise(String[] args) {
        Noise d = Noise.DEFAULT;
        double b = d.bearingStdRad();
        double rb = d.rangeStdBaseM();
        double rp = d.rangeStdPerM2();
        double tm = d.timingStdSeconds();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--bearing-deg" -> b = Math.toRadians(Double.parseDouble(args[++i]));
                case "--range" -> {
                    String[] p = args[++i].split(",");
                    rb = Double.parseDouble(p[0]);
                    rp = Double.parseDouble(p[1]);
                }
                case "--timing-ms" -> tm = Double.parseDouble(args[++i]) / 1000;
                default -> {}
            }
        }
        return new Noise(d.odomVarPerMeter(), d.slipVarPerMeter(), d.slipYawWeight(), d.headingVarPerSecond(),
                d.headingVarPerRadian(), b, rb, rp, tm, d.gateChi2());
    }

    static String opt(String[] args, String name, String def) {
        for (int i = 0; i + 1 < args.length; i++) {
            if (args[i].equals(name)) {
                return args[i + 1];
            }
        }
        return def;
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: BenchEkf live [--seconds 40] [--survey 5] [--out DIR] [--cameras a,b] | file TAGS.csv; "
                    + "[--bearing-deg D] [--range BASE,PER_M2] [--timing-ms MS] [--no-adaptive]");
            System.exit(2);
        }
        boolean adaptive = !Arrays.asList(args).contains("--no-adaptive");
        double surveyS = Double.parseDouble(opt(args, "--survey", "5"));
        Noise n = noise(args);
        System.out.printf(Locale.ROOT, "noise: bearing %.3f deg, range %.4f + %.4f r^2 m, timing %.3f ms, adaptive %b%n",
                Math.toDegrees(n.bearingStdRad()), n.rangeStdBaseM(), n.rangeStdPerM2(), n.timingStdSeconds() * 1000,
                adaptive);
        if (args[0].equals("file")) {
            BenchEkf b = new BenchEkf(n, adaptive, surveyS, null);
            // Frames in capture order: rows of one camera result share t and seq.
            List<String> lines = Files.readAllLines(Path.of(args[1]));
            Map<String, List<PhotonResult.Target>> cur = new LinkedHashMap<>();
            List<Object[]> results = new ArrayList<>();
            String key = null;
            for (String line : lines.subList(1, lines.size())) {
                String[] f = line.split(",");
                String k = f[0] + "," + f[2];
                if (!k.equals(key)) {
                    cur = new LinkedHashMap<>();
                    results.add(new Object[] {f[0], Long.parseLong(f[2]), Double.parseDouble(f[1]), cur});
                    key = k;
                }
                double[] c = new double[f.length - 8];
                for (int i = 8; i < f.length; i++) {
                    c[i - 8] = Double.parseDouble(f[i]);
                }
                cur.computeIfAbsent("t", z -> new ArrayList<>())
                        .add(new PhotonResult.Target(Integer.parseInt(f[3]),
                                new Translation3d(Double.parseDouble(f[4]), Double.parseDouble(f[5]), Double.parseDouble(f[6])),
                                Double.parseDouble(f[7]), c));
            }
            results.sort((a, c) -> Double.compare((double) a[2], (double) c[2]));
            for (Object[] r : results) {
                @SuppressWarnings("unchecked")
                Map<String, List<PhotonResult.Target>> m = (Map<String, List<PhotonResult.Target>>) r[3];
                b.frame((String) r[0], new PhotonResult((long) r[1], (double) r[2], m.get("t")));
            }
            b.summary();
            return;
        }
        Live.run(args, n, adaptive, surveyS);
    }

    /** The NT4 part, apart so the file mode never loads ntcore. */
    static final class Live {
        static void run(String[] args, Noise n, boolean adaptive, double surveyS) throws Exception {
            double seconds = Double.parseDouble(opt(args, "--seconds", "40"));
            String[] cams = opt(args, "--cameras", "thrifty,swyft").split(",");
            Path out = Path.of(opt(args, "--out", "/dev/shm/tagekf"));
            BenchEkf b = new BenchEkf(n, adaptive, surveyS, out);
            var inst = org.wpilib.networktables.NetworkTableInstance.getDefault();
            inst.startClient("tagekf-bench");
            inst.setServer("127.0.0.1");
            List<org.wpilib.networktables.RawSubscriber> subs = new ArrayList<>();
            // NT4 drops a subscription whose type differs from the publisher's: the fork's struct interface.
            String type = opt(args, "--type", "photonstruct:PhotonPipelineResult:" + PhotonResult.INTERFACE);
            for (String c : cams) {
                subs.add(inst.getRawTopic("/photonvision/" + c + "/rawBytes")
                        .subscribe(type, new byte[0], org.wpilib.networktables.PubSubOption.pollStorage(64)));
            }
            long end = System.nanoTime() + (long) ((seconds + surveyS) * 1e9);
            long results = 0;
            while (System.nanoTime() < end) {
                // The robot loop: each camera's queued results, oldest first, then sleep to the next 20 ms.
                for (int i = 0; i < cams.length; i++) {
                    for (var v : subs.get(i).readQueue()) {
                        if (v.value.length > 0) {
                            b.frame(cams[i], PhotonResult.decode(v.value));
                            results++;
                        }
                    }
                }
                Thread.sleep(20);
            }
            System.out.println("results " + results + ", logs in " + out);
            b.summary();
            inst.stopClient();
            System.exit(0);
        }
    }
}
