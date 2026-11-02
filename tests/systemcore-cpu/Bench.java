// SystemCore CPU benchmark: MJPEG decode and WPILib's CPU AprilTag detector on Rewind recordings.
// See README.md here. Runs on any Linux with a PhotonVision jar for its architecture (natives
// inside): java -cp photonvision.jar:. Bench DIR... (run.sh does the compile and the run).
//
// Per frame, each timed separately on the same JPEG:
//   decode  color   imdecode to BGR + cvtColor to gray (what cscore's gray sink does)
//           gray    imdecode IMREAD_GRAYSCALE (libjpeg-turbo, Y only)
//           half    imdecode IMREAD_REDUCED_GRAYSCALE_2 (libjpeg-turbo scaled IDCT, Y only, 1/2)
//   detect  full_d2 full-res gray, quad_decimate 2   (PhotonVision's usual CPU setting)
//           half_d1 half-res gray, quad_decimate 1   (the fork's low-CPU decode), corners x2
//           full_d1 full-res gray, quad_decimate 1   (only with -Dfulld1=1: slow)
//   at each thread count in -Dthreads (default 1,2,4). Detector settings are AprilTagPipeline's.
// Decode times are the thread's CPU time; detect times are the process's CPU time (all detector
// threads) and wall time. Detections (hamming 0) go to OUT/<variant>/<session>.csv in
// detector-replay's format, corners in its convention, for compare.py and accuracy/judge.py.
import java.io.*;
import java.lang.management.ManagementFactory;
import java.nio.file.*;
import java.util.*;
import org.opencv.core.*;
import org.opencv.imgcodecs.Imgcodecs;
import org.opencv.imgproc.Imgproc;
import org.photonvision.common.LoadJNI;
import org.wpilib.vision.apriltag.AprilTagDetection;
import org.wpilib.vision.apriltag.AprilTagDetector;

public class Bench {
    static final com.sun.management.OperatingSystemMXBean OS =
            (com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
    static final java.lang.management.ThreadMXBean TH = ManagementFactory.getThreadMXBean();

    record Chunk(Path mjpeg, Path index, String session, String camera) {}

    static class Stat {
        final ArrayList<Double> v = new ArrayList<>();
        void add(double ms) { v.add(ms); }
        double mean() { return v.stream().mapToDouble(d -> d).average().orElse(Double.NaN); }
        double pct(double p) {
            if (v.isEmpty()) return Double.NaN;
            var s = v.stream().mapToDouble(d -> d).sorted().toArray();
            return s[Math.min(s.length - 1, (int) (p * s.length))];
        }
    }

    /** CPU time of every thread of this process, ns (schedstat: ns, unlike getProcessCpuTime's ticks). */
    static long procCpuNs() {
        long sum = 0;
        File[] tasks = new File("/proc/self/task").listFiles();
        if (tasks == null) return OS.getProcessCpuTime();
        for (File t : tasks) {
            try (var r = new BufferedReader(new FileReader(new File(t, "schedstat")))) {
                String l = r.readLine();
                if (l != null) sum += Long.parseLong(l.substring(0, l.indexOf(' ')));
            } catch (IOException | RuntimeException e) {
                // the thread ended
            }
        }
        return sum;
    }

    static AprilTagDetector detector(int decimate, int threads) {
        var d = new AprilTagDetector();
        var c = new AprilTagDetector.Config();
        c.numThreads = threads;
        c.refineEdges = true;
        c.quadSigma = 0;
        c.quadDecimate = decimate;
        d.setConfig(c);
        var q = new AprilTagDetector.QuadThresholdParameters();
        q.minClusterPixels = 5;
        q.maxNumMaxima = 10;
        q.criticalAngle = 45 * Math.PI / 180.0;
        q.maxLineFitMSE = 10.0f;
        q.minWhiteBlackDiff = 5;
        q.deglitch = false;
        d.setQuadThresholdParameters(q);
        d.addFamily("tag36h11");
        return d;
    }

    public static void main(String[] args) throws Exception {
        if (!LoadJNI.loadLibraries()) throw new IllegalStateException("native libraries didn't load");
        int maxFrames = Integer.getInteger("frames", 400); // per camera
        int stride = Integer.getInteger("stride", 1);
        int[] threads = Arrays.stream(System.getProperty("threads", "1,2,4").split(","))
                .mapToInt(Integer::parseInt).toArray();
        boolean fullD1 = "1".equals(System.getProperty("fulld1"));
        Path out = Path.of(System.getProperty("out", "out"));

        var chunks = new ArrayList<Chunk>();
        for (String a : args) {
            try (var w = Files.walk(Path.of(a), FileVisitOption.FOLLOW_LINKS)) {
                w.filter(p -> p.toString().endsWith(".mjpeg")).sorted().forEach(p -> {
                    Path idx = Path.of(p.toString().replaceAll("\\.mjpeg$", ".csv"));
                    if (Files.exists(idx)) {
                        chunks.add(new Chunk(p, idx, p.getParent().getParent().getFileName().toString(),
                                p.getParent().getFileName().toString()));
                    }
                });
            }
        }
        if (chunks.isEmpty()) throw new IllegalArgumentException("no .mjpeg with a .csv index under " + List.of(args));

        String[] variants = fullD1 ? new String[] {"full_d2", "half_d1", "full_d1"} : new String[] {"full_d2", "half_d1"};
        int[] dec = fullD1 ? new int[] {2, 1, 1} : new int[] {2, 1};
        var dets = new AprilTagDetector[variants.length][threads.length];
        for (int v = 0; v < variants.length; v++)
            for (int t = 0; t < threads.length; t++) dets[v][t] = detector(dec[v], threads[t]);

        var decode = new LinkedHashMap<String, Stat>();
        for (String k : new String[] {"color", "gray", "half"}) decode.put(k, new Stat());
        var detCpu = new LinkedHashMap<String, Stat>();
        var detWall = new LinkedHashMap<String, Stat>();
        var found = new LinkedHashMap<String, Integer>();
        for (String v : variants) {
            found.put(v, 0);
            for (int t : threads) {
                detCpu.put(v + " t" + t, new Stat());
                detWall.put(v + " t" + t, new Stat());
            }
        }
        var writers = new HashMap<String, PrintWriter>();
        var perCam = new HashMap<String, Integer>(); // frames taken per session/camera
        var frameNo = new HashMap<String, Integer>(); // running frame index per session/camera
        int total = 0;
        Files.createDirectories(out);
        var framesOut = new PrintWriter(new BufferedWriter(new FileWriter(out.resolve("frames.csv").toFile())));
        framesOut.println("session,camera,jetson_us");
        String res = "";

        for (Chunk ch : chunks) {
            String key = ch.session + "/" + ch.camera;
            if (perCam.getOrDefault(key, 0) >= maxFrames) continue;
            var raf = new RandomAccessFile(ch.mjpeg.toFile(), "r");
            for (String line : Files.readAllLines(ch.index)) {
                if (line.startsWith("#") || line.isBlank()) continue;
                String[] f = line.split(",");
                int fi = frameNo.merge(key, 1, Integer::sum) - 1;
                if (fi % stride != 0) continue;
                if (perCam.getOrDefault(key, 0) >= maxFrames) continue;
                perCam.merge(key, 1, Integer::sum);
                long off = Long.parseLong(f[1]);
                int size = Integer.parseInt(f[2]);
                String jetsonUs = f[5];
                var buf = new MatOfByte();
                byte[] jpeg = new byte[size];
                raf.seek(off);
                raf.readFully(jpeg);
                buf.fromArray(jpeg);

                // decodes
                long t0 = TH.getCurrentThreadCpuTime();
                Mat bgr = Imgcodecs.imdecode(buf, Imgcodecs.IMREAD_COLOR);
                Mat g0 = new Mat();
                if (!bgr.empty()) Imgproc.cvtColor(bgr, g0, Imgproc.COLOR_BGR2GRAY);
                long t1 = TH.getCurrentThreadCpuTime();
                Mat gray = Imgcodecs.imdecode(buf, Imgcodecs.IMREAD_GRAYSCALE);
                long t2 = TH.getCurrentThreadCpuTime();
                Mat half = Imgcodecs.imdecode(buf, Imgcodecs.IMREAD_REDUCED_GRAYSCALE_2);
                long t3 = TH.getCurrentThreadCpuTime();
                bgr.release();
                g0.release();
                buf.release();
                if (gray.empty() || half.empty()) {
                    gray.release();
                    half.release();
                    continue;
                }
                decode.get("color").add((t1 - t0) / 1e6);
                decode.get("gray").add((t2 - t1) / 1e6);
                decode.get("half").add((t3 - t2) / 1e6);
                res = gray.cols() + "x" + gray.rows() + " (half " + half.cols() + "x" + half.rows() + ")";
                double scaleX = (double) gray.cols() / half.cols(), scaleY = (double) gray.rows() / half.rows();
                total++;
                framesOut.println(ch.session + "," + ch.camera + "," + jetsonUs);

                for (int v = 0; v < variants.length; v++) {
                    Mat img = variants[v].startsWith("half") ? half : gray;
                    double sx = variants[v].startsWith("half") ? scaleX : 1, sy = variants[v].startsWith("half") ? scaleY : 1;
                    for (int t = 0; t < threads.length; t++) {
                        long c0 = procCpuNs(), w0 = System.nanoTime();
                        AprilTagDetection[] r = dets[v][t].detect(img);
                        long w1 = System.nanoTime(), c1 = procCpuNs();
                        detCpu.get(variants[v] + " t" + threads[t]).add((c1 - c0) / 1e6);
                        detWall.get(variants[v] + " t" + threads[t]).add((w1 - w0) / 1e6);
                        if (t != 0) continue;
                        var pw = writers.computeIfAbsent(variants[v] + "/" + ch.session, k -> {
                            try {
                                Files.createDirectories(out.resolve(k).getParent());
                                var w = new PrintWriter(new BufferedWriter(new FileWriter(out.resolve(k + ".csv").toFile())));
                                w.println("camera,frame,jetson_us,id,margin,side_px,source,x0,y0,x1,y1,x2,y2,x3,y3");
                                return w;
                            } catch (IOException e) {
                                throw new UncheckedIOException(e);
                            }
                        });
                        for (var d : r) {
                            if (d.getHamming() != 0) continue;
                            found.merge(variants[v], 1, Integer::sum);
                            double[] c = new double[8];
                            for (int i = 0; i < 4; i++) {
                                // apriltag's convention (pixel centres at +0.5) scales exactly
                                c[2 * i] = d.getCornerX(i) * sx;
                                c[2 * i + 1] = d.getCornerY(i) * sy;
                            }
                            double side = 0;
                            for (int i = 0; i < 4; i++) {
                                int j = (i + 1) % 4;
                                side += Math.hypot(c[2 * j] - c[2 * i], c[2 * j + 1] - c[2 * i + 1]) / 4;
                            }
                            var sb = new StringBuilder();
                            sb.append(ch.camera).append(',').append(fi).append(',').append(jetsonUs).append(',')
                                    .append(d.getId()).append(',').append(String.format("%.4f", d.getDecisionMargin()))
                                    .append(',').append(String.format("%.4f", side)).append(",normal");
                            for (double x : c) sb.append(',').append(String.format("%.3f", x));
                            pw.println(sb);
                        }
                    }
                }
                gray.release();
                half.release();
            }
            raf.close();
        }
        for (var w : writers.values()) w.close();
        framesOut.close();
        for (var row : dets) for (var d : row) d.close();

        String cpu = "?";
        try {
            cpu = Files.readAllLines(Path.of("/proc/cpuinfo")).stream()
                    .filter(l -> l.startsWith("model name") || l.startsWith("CPU part")).findFirst().orElse("?");
        } catch (IOException e) {
            // not Linux
        }
        var sb = new StringBuilder();
        sb.append(String.format("frames %d (%d cameras) %s; %s; java %s; %d cpus visible%n", total, perCam.size(), res,
                cpu.replaceAll("\\s+", " "), System.getProperty("java.version"), Runtime.getRuntime().availableProcessors()));
        sb.append(String.format("%-22s %8s %8s %8s%n", "decode (thread CPU)", "mean ms", "p50", "p95"));
        for (var e : decode.entrySet())
            sb.append(String.format("%-22s %8.2f %8.2f %8.2f%n", e.getKey(), e.getValue().mean(), e.getValue().pct(.5), e.getValue().pct(.95)));
        sb.append(String.format("%-22s %8s %8s %8s %8s%n", "detect", "cpu ms", "cpu p95", "wall ms", "wall p95"));
        for (var k : detCpu.keySet())
            sb.append(String.format("%-22s %8.2f %8.2f %8.2f %8.2f%n", k, detCpu.get(k).mean(), detCpu.get(k).pct(.95),
                    detWall.get(k).mean(), detWall.get(k).pct(.95)));
        sb.append("tags found (hamming 0, any margin):");
        for (var e : found.entrySet()) sb.append(" ").append(e.getKey()).append(" ").append(e.getValue());
        sb.append("\n");
        System.out.print(sb);
        Files.createDirectories(out);
        Files.writeString(out.resolve("summary.txt"), sb.toString());
    }
}
