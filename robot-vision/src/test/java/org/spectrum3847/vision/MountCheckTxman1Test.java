package org.spectrum3847.vision;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import edu.wpi.first.apriltag.AprilTagFieldLayout;
import edu.wpi.first.math.geometry.Pose2d;
import edu.wpi.first.math.geometry.Rotation2d;
import edu.wpi.first.math.geometry.Transform3d;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import org.junit.jupiter.api.Test;
import org.spectrum3847.vision.health.MountCheck;
import org.spectrum3847.vision.health.MountCheck.Status;
import org.spectrum3847.vision.heading.RobotMotionHistory;
import org.spectrum3847.vision.observation.FrameObservation;
import org.spectrum3847.vision.observation.TagObservation;

/**
 * The mount check on team 8515's TXMAN1 matches (tests/field-replay): the Jetson's detections
 * replayed with the robot's logged pose, and the mounts that were in their robot code. Skipped
 * unless MOUNTCHECK_TXMAN1 names the export's folder (sightings.csv and meta.csv, made on the
 * Jetson by robot-vision/tools/export_mountcheck_txman1.py).
 *
 * <p>The cameras face sideways and never see tags together, so x/y/yaw are judged against the
 * logged pose (fused from these same cameras: errors read smaller than they are); height, roll and
 * pitch need no reference.
 */
class MountCheckTxman1Test {
    @Test
    void flags8515Mounts() throws IOException {
        String dir = System.getenv("MOUNTCHECK_TXMAN1");
        assumeTrue(dir != null && Files.isDirectory(Path.of(dir)), "MOUNTCHECK_TXMAN1 not set");
        // meta.csv: match,<m>,<layout>,<mounts>  cal,<m>,<cam>,fx,fy,cx,cy,dist..  mount,<name>,<cam>,x,y,z,r,p,y
        var matchInfo = new TreeMap<String, String[]>();
        var cals = new TreeMap<String, Map<String, double[]>>();
        var mountSets = new TreeMap<String, Map<String, Transform3d>>();
        for (var l : Files.readAllLines(Path.of(dir, "meta.csv"))) {
            var v = l.split(",");
            switch (v[0]) {
                case "match" -> matchInfo.put(v[1], v);
                case "cal" -> {
                    double[] d = new double[v.length - 3];
                    for (int i = 0; i < d.length; i++) d[i] = Double.parseDouble(v[3 + i]);
                    cals.computeIfAbsent(v[1], k -> new TreeMap<>()).put(v[2], d);
                }
                case "mount" -> mountSets.computeIfAbsent(v[1], k -> new TreeMap<>()).put(v[2],
                        new MountCheck.Mount(Double.parseDouble(v[3]), Double.parseDouble(v[4]), Double.parseDouble(v[5]),
                                Double.parseDouble(v[6]), Double.parseDouble(v[7]), Double.parseDouble(v[8])).toTransform());
                default -> {}
            }
        }
        Path layouts = Path.of(System.getenv().getOrDefault("MOUNTCHECK_LAYOUTS", "../../tools/fieldcal/layouts"));
        // match -> rows, in file order (time order per camera).
        var byMatch = new TreeMap<String, List<String[]>>();
        try (var lines = Files.lines(Path.of(dir, "sightings.csv"))) {
            lines.skip(1).forEach(l -> {
                var v = l.split(",");
                byMatch.computeIfAbsent(v[0], k -> new ArrayList<>()).add(v);
            });
        }
        int leftFlagged = 0, matches = 0;
        for (var e : byMatch.entrySet()) {
            var info = matchInfo.get(e.getKey());
            var field = new AprilTagFieldLayout(layouts.resolve("2026-rebuilt-" + info[2] + ".json"));
            var mc = new MountCheck(field, false);
            var mounts = mountSets.get(info[3]);
            cals.get(e.getKey()).forEach((cam, c) -> mc.intrinsics(cam,
                    new double[] {c[0], 0, c[2], 0, c[1], c[3], 0, 0, 1}, Arrays.copyOfRange(c, 4, c.length)));
            var motion = new RobotMotionHistory(5);
            // Group rows into frames (camera, time), and feed them in time order.
            var frames = new TreeMap<Long, Map<String, List<String[]>>>();
            for (var v : e.getValue()) frames.computeIfAbsent(Long.parseLong(v[2]), k -> new TreeMap<>()).computeIfAbsent(v[1], k -> new ArrayList<>()).add(v);
            long seq = 0, nanos = 0, nframes = 0;
            for (var f : frames.entrySet()) {
                double t = f.getKey() / 1e6;
                var out = new ArrayList<FrameObservation>();
                for (var c : f.getValue().entrySet()) {
                    var tags = new ArrayList<TagObservation>();
                    String[] last = null;
                    for (var v : c.getValue()) {
                        double[] corners = new double[8];
                        for (int i = 0; i < 8; i++) corners[i] = Double.parseDouble(v[4 + i]);
                        tags.add(new TagObservation(Integer.parseInt(v[3]), new Transform3d(), new Transform3d(), -1,
                                0, 0, 0, corners, Double.NaN, Double.NaN, Double.NaN, Double.NaN, Double.NaN));
                        last = v;
                    }
                    var pose = new Pose2d(Double.parseDouble(last[12]), Double.parseDouble(last[13]), new Rotation2d(Double.parseDouble(last[14])));
                    mc.addEstimatorPose(t, pose);
                    motion.add(t, pose.getRotation(), Double.parseDouble(last[16]), Double.parseDouble(last[15]));
                    out.add(new FrameObservation(c.getKey(), ++seq, t, 0, null, Double.NaN, List.of(), tags));
                }
                long t0 = System.nanoTime();
                mc.update(t, out, mounts, motion);
                nanos += System.nanoTime() - t0;
                nframes += out.size();
            }
            mc.update(Double.MAX_VALUE / 4, List.of(), mounts, motion);
            matches++;
            System.out.printf("%s (robot code: %s mounts), %d frames, %.0f us a frame (rate-limited to %.0f Hz a camera)%n",
                    e.getKey(), info[3], nframes, nanos / 1e3 / nframes, mc.config.maxSampleHz);
            for (var r : mc.reports()) {
                System.out.printf("  %-10s %-8s n=%d/%d ref=%s%n    configured %s%n    measured   %s%n    error %s%n",
                        r.camera(), r.status(), r.samples(), r.refSamples(), r.reference(), r.configured(), r.estimated(),
                        fmt(r.error()));
                if (r.camera().equals("orin-left") && r.status().compareTo(Status.SUSPECT) >= 0) leftFlagged++;
            }
        }
        System.out.println("orin-left flagged in " + leftFlagged + " of " + matches + " matches");
        assertTrue(leftFlagged >= matches - 1, "orin-left's mount (yaw ~84-87 vs 90, z, pitch) should be flagged");
    }

    private static String fmt(double[] e) {
        return String.format("dx %+.3f dy %+.3f dz %+.3f m, droll %+.1f dpitch %+.1f dyaw %+.1f deg", e[0], e[1], e[2], e[3], e[4], e[5]);
    }
}
