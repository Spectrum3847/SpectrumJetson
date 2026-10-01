package org.spectrum3847.vision.rehearsal;

import io.avaje.jsonb.Jsonb;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.photonvision.PhotonCamera;
import org.spectrum3847.vision.VisionSystem;
import org.wpilib.driverstation.MatchType;
import org.wpilib.framework.RobotBase;
import org.wpilib.framework.TimedRobot;
import org.wpilib.hardware.hal.AllianceStationID;
import org.wpilib.hardware.hal.RobotMode;
import org.wpilib.math.geometry.Transform3d;
import org.wpilib.networktables.BooleanPublisher;
import org.wpilib.networktables.NetworkTableInstance;
import org.wpilib.simulation.DriverStationSim;
import org.wpilib.system.Timer;
import org.wpilib.vision.apriltag.AprilTagFieldLayout;
import org.wpilib.vision.apriltag.AprilTagFields;

/**
 * SystemCore rehearsal, without a SystemCore.
 *
 * <p>This is a real WPILib 2027 alpha-6 robot program, the same runtime a SystemCore runs, only built
 * for this laptop. The Driver Station is simulated. A real Jetson connects to it as it would to
 * the robot (tests/systemcore-rehearsal/run.sh points it here). The program plays a match:
 * disabled, teleop, then auto, teleop and disabled with the field attached. It checks what
 * matters for an event:
 *
 * <ul>
 *   <li><b>The control word:</b> PhotonVision decodes WPILib 2027's real /FMSInfo/ControlWord
 *       (enabled, autonomous, FMS attached) and idles while disabled. Read from the Jetson's
 *       /api/robotState once a second in every phase.
 *   <li><b>Match data:</b> robot code asks Rewind to record during the match, and the session is
 *       named from WPILib 2027's /FMSInfo MatchType and MatchNumber (Q42 here).
 *   <li><b>Results:</b> every camera's results reach PhotonLib 2027 alpha-2 and decode (the
 *       message format matches). Frames lost on the way are counted from the sequence numbers.
 *   <li><b>Time sync:</b> PhotonLib's time-sync server runs here, PhotonVision's client on the
 *       Jetson. Each result's capture time, converted to robot time by the Jetson, must be a
 *       little in the past when it arrives: the latency. A negative or huge latency means time
 *       sync is broken.
 *   <li><b>Bandwidth</b> from the Jetson (the NetworkTables connection's bytes), and how long
 *       SpectrumVision's {@code periodic()} takes in each loop.
 * </ul>
 *
 * <b>The link matters for the timing checks.</b> Over Wi-Fi (roaming, bursts, uneven delays) the
 * latency is ~50 ms with ~150 ms spikes, NetworkTables drops results during stalls, and time sync
 * can be off by tens of ms for a moment. None of that happens on the robot's Ethernet. So over
 * Wi-Fi the latency, loss and time-sync numbers are printed but not judged; wired (run.sh --wired)
 * they are.
 *
 * <p>System properties: rehearsal.jetson (the Jetson's address, for its web API), rehearsal.link
 * (wired, usb or wifi) and rehearsal.phases (default {@link #DEFAULT_PHASES}). Exits 0 if every
 * check passed.
 */
public class Rehearsal extends TimedRobot {
    // After the match, quiet mode (if on) makes the scratch partition read-only, and with no robot
    // connected it stays that way. The last teleop checks an enable ends it, and leaves the Jetson
    // writable for whatever comes next.
    static final String DEFAULT_PHASES = "disabled:20,teleop:20,fms-auto:15,fms-teleop:15,fms-disabled:10,teleop:8";
    static final double SETTLE_SECONDS = 5; // after a phase starts, before its checks count
    static final double CONNECT_TIMEOUT_SECONDS = 60;

    record Phase(String name, double seconds) {
        boolean fms() {
            return name.startsWith("fms-");
        }

        String state() {
            return fms() ? name.substring(4) : name;
        }

        boolean enabled() {
            return !state().equals("disabled");
        }

        boolean auto() {
            return state().equals("auto");
        }
    }

    /** What one phase saw. */
    static class PhaseStats {
        final Phase phase;
        int stateSamples, stateMismatches, recordingSamples, recordingOn;
        final List<String> mismatchExamples = new ArrayList<>();
        final Map<String, CameraStats> cameras = new LinkedHashMap<>();
        double ntBytesStart = Double.NaN, ntBytesEnd = Double.NaN, ntTimeStart, ntTimeEnd;
        long loops, periodicNanosTotal, periodicNanosMax;
        double maxLoopGapSeconds;
        String session = "";

        PhaseStats(Phase p) {
            phase = p;
        }
    }

    static class CameraStats {
        long results, lost, lastSeq = -1, maxPongMicros, negative;
        // Results for frames that never came: with no frame from a camera (unplugged, stuck),
        // PhotonVision still publishes ~10 empty results a second whose capture time is 0 on the
        // Jetson (a fixed, long-past robot time). PhotonLib's heartbeat stops, so isConnected() is false.
        long placeholders, qualityMatched;
        boolean connected = true;
        final List<Double> latencyMs = new ArrayList<>();
    }

    static final double PLACEHOLDER_MS = 10_000; // a "frame" this old never existed

    final List<Phase> phases = new ArrayList<>();
    final List<PhaseStats> stats = new ArrayList<>();
    final String jetson = System.getProperty("rehearsal.jetson", "10.100.0.194");
    final String link = System.getProperty("rehearsal.link", "wifi");
    final boolean judgeTiming = !link.equals("wifi");
    final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();

    /** One poll of the Jetson: its web API's answers (empty if it didn't answer) and our NT bytes. */
    record Poll(long n, Map<String, Object> robotState, Map<String, Object> rewind, double ntBytes, double time) {}

    volatile Poll latest = new Poll(0, Map.of(), Map.of(), Double.NaN, 0);
    long lastPollChecked = 0; // the robot loop checks each poll once
    static final Pattern BYTES_RECEIVED = Pattern.compile("bytes_received:(\\d+)");
    final BooleanPublisher recordRequest =
            NetworkTableInstance.getDefault().getTable("photonvision").getSubTable("rewind").getBooleanTopic("record").publish();

    final Map<String, PhotonCamera> timingCameras = new LinkedHashMap<>();
    final Map<String, Long> qualityAtPhaseStart = new LinkedHashMap<>();
    VisionSystem vision;
    int phaseIndex = -1; // -1: waiting for the Jetson
    double phaseStart, start, lastLoop = Double.NaN;
    boolean idleWhileDisabled = true, quietAfterMatch = false;

    public Rehearsal() {
        for (String p : System.getProperty("rehearsal.phases", DEFAULT_PHASES).split(",")) {
            String[] s = p.trim().split(":");
            phases.add(new Phase(s[0], Double.parseDouble(s[1])));
        }
        DriverStationSim.setDsAttached(true);
        DriverStationSim.setAllianceStationId(AllianceStationID.RED_1);
        DriverStationSim.setEnabled(false);
        DriverStationSim.notifyNewData();
        recordRequest.set(false);
        var poller = new Thread(this::poll, "rehearsal-poll");
        poller.setDaemon(true);
        poller.start();
        start = Timer.getTimestamp();
        System.out.println("rehearsal: waiting for the Jetson (" + jetson + ") to connect");
    }

    /** The Jetson's web API and this connection's byte count, once a second (off the robot loop). */
    void poll() {
        for (long n = 1; ; n++) {
            var state = get("/api/robotState");
            var rw = get("/api/rewind");
            double bytes = Double.NaN;
            try {
                var p = new ProcessBuilder("ss", "-tinH", "state", "established", "dst", jetson, "( sport = :5810 )")
                        .redirectErrorStream(true)
                        .start();
                String out = new String(p.getInputStream().readAllBytes());
                p.waitFor();
                Matcher m = BYTES_RECEIVED.matcher(out);
                while (m.find()) bytes = (Double.isNaN(bytes) ? 0 : bytes) + Double.parseDouble(m.group(1));
            } catch (Exception e) {
                // no count this time
            }
            latest = new Poll(n, state, rw, bytes, Timer.getTimestamp());
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    @SuppressWarnings("unchecked")
    Map<String, Object> get(String path) {
        try {
            var r = http.send(HttpRequest.newBuilder(URI.create("http://" + jetson + ":5800" + path))
                            .timeout(Duration.ofSeconds(2)).build(),
                    HttpResponse.BodyHandlers.ofString());
            if (r.statusCode() == 200 && Jsonb.instance().type(Object.class).fromJson(r.body()) instanceof Map<?, ?> m) {
                return (Map<String, Object>) m;
            }
        } catch (Exception e) {
            // the Jetson didn't answer (or not with JSON): an empty poll
        }
        return Map.of();
    }

    static Boolean flag(Map<String, Object> json, String key) {
        return json.get(key) instanceof Boolean b ? b : null;
    }

    static String text(Map<String, Object> json, String key) {
        return json.get(key) instanceof String t ? t : "";
    }

    /** PhotonVision cameras publishing results: /photonvision subtables with a rawBytes topic. */
    static List<String> discoverCameras() {
        var pv = NetworkTableInstance.getDefault().getTable("photonvision");
        var names = new TreeSet<String>();
        for (String s : pv.getSubTables()) {
            if (pv.getSubTable(s).containsKey("rawBytes")) names.add(s);
        }
        return new ArrayList<>(names);
    }

    @Override
    public void robotPeriodic() {
        double now = Timer.getTimestamp();
        if (phaseIndex < 0) {
            waitForJetson(now);
            return;
        }
        var ps = stats.get(phaseIndex);
        if (!Double.isNaN(lastLoop)) ps.maxLoopGapSeconds = Math.max(ps.maxLoopGapSeconds, now - lastLoop);
        lastLoop = now;
        long t0 = System.nanoTime();
        vision.periodic();
        long dt = System.nanoTime() - t0;
        for (var cam : vision.cameras()) { // a running total: this phase's share
            ps.cameras.computeIfAbsent(cam.name(), k -> new CameraStats()).qualityMatched =
                    cam.inputs().qualityMatched - qualityAtPhaseStart.getOrDefault(cam.name(), 0L);
        }
        ps.loops++;
        ps.periodicNanosTotal += dt;
        ps.periodicNanosMax = Math.max(ps.periodicNanosMax, dt);
        boolean settled = settled(now);
        long nowMicros = (long) (now * 1e6);
        for (var e : timingCameras.entrySet()) {
            var cs = ps.cameras.computeIfAbsent(e.getKey(), k -> new CameraStats());
            for (var r : e.getValue().getAllUnreadResults()) {
                var md = r.metadata;
                long gap = cs.lastSeq >= 0 ? md.sequenceID - cs.lastSeq - 1 : 0;
                cs.lastSeq = md.sequenceID;
                if (!settled) continue;
                if (gap > 0) cs.lost += gap;
                double latency = (nowMicros - md.captureTimestampMicros) / 1000.0;
                if (latency > PLACEHOLDER_MS) {
                    cs.placeholders++;
                    continue;
                }
                cs.results++;
                cs.latencyMs.add(latency);
                if (latency < -2) cs.negative++;
                cs.maxPongMicros = Math.max(cs.maxPongMicros, md.timeSinceLastPong);
            }
        }
        var poll = latest;
        if (settled && poll.n() != lastPollChecked) {
            lastPollChecked = poll.n();
            var s = poll.robotState();
            if (!s.isEmpty()) {
                ps.stateSamples++;
                var p = ps.phase;
                var expected = new LinkedHashMap<String, Boolean>();
                expected.put("robotConnected", true);
                expected.put("enabled", p.enabled());
                if (p.enabled()) expected.put("autonomous", p.auto());
                expected.put("fmsAttached", p.fms());
                expected.put("idleNow", !p.enabled() && idleWhileDisabled);
                // Quiet mode: on once a match has ended (if set to), off at any enable. (The
                // disabled phases are shorter than quietAfterDisabledSeconds.)
                expected.put("quietNow", p.fms() && !p.enabled() && quietAfterMatch);
                boolean ok = true;
                for (var x : expected.entrySet()) {
                    if (!x.getValue().equals(flag(s, x.getKey()))) {
                        ok = false;
                        if (ps.mismatchExamples.size() < 3) {
                            ps.mismatchExamples.add(x.getKey() + "=" + flag(s, x.getKey()) + " (expected " + x.getValue() + ")");
                        }
                    }
                }
                if (!ok) ps.stateMismatches++;
            }
            var rw = poll.rewind();
            if (!rw.isEmpty()) {
                ps.recordingSamples++;
                if (Boolean.TRUE.equals(flag(rw, "recording"))) {
                    ps.recordingOn++;
                    ps.session = text(rw, "session");
                }
            }
            if (!Double.isNaN(poll.ntBytes())) {
                if (Double.isNaN(ps.ntBytesStart)) {
                    ps.ntBytesStart = poll.ntBytes();
                    ps.ntTimeStart = poll.time();
                }
                ps.ntBytesEnd = poll.ntBytes();
                ps.ntTimeEnd = poll.time();
            }
        }
        if (now - phaseStart >= ps.phase.seconds()) {
            for (var e : timingCameras.entrySet()) ps.cameras.get(e.getKey()).connected = e.getValue().isConnected();
            nextPhase(now);
        }
    }

    boolean settled(double now) {
        return now - phaseStart >= SETTLE_SECONDS;
    }

    void waitForJetson(double now) {
        var names = discoverCameras();
        var state = latest.robotState();
        Boolean connected = flag(state, "robotConnected");
        if (Boolean.TRUE.equals(connected) && !names.isEmpty()) {
            Boolean idle = flag(state, "idleWhileDisabled");
            idleWhileDisabled = idle == null || idle;
            quietAfterMatch = Boolean.TRUE.equals(flag(state, "quietAfterMatch"));
            System.out.printf("rehearsal: Jetson connected after %.1f s; cameras %s; idle while disabled %s; quiet after a match %s%n",
                    now - start, names, idleWhileDisabled, quietAfterMatch);
            var field = AprilTagFieldLayout.loadField(AprilTagFields.kDefaultField);
            // No drivetrain here: accepted measurements are counted (stats) and dropped.
            var b = VisionSystem.builder(field).readJetsonExcludedTags(true).sink((pose, t, std) -> {});
            for (String n : names) {
                b.camera(n, new Transform3d());
                timingCameras.put(n, new PhotonCamera(n));
            }
            vision = b.build();
            nextPhase(now);
        } else if (now - start > CONNECT_TIMEOUT_SECONDS) {
            System.out.println("rehearsal: FAIL the Jetson didn't connect in " + CONNECT_TIMEOUT_SECONDS
                    + " s (robotConnected=" + connected + ", cameras " + names + ")");
            finish(1);
        }
    }

    void nextPhase(double now) {
        phaseIndex++;
        if (phaseIndex >= phases.size()) {
            DriverStationSim.setEnabled(false);
            DriverStationSim.notifyNewData();
            recordRequest.set(false);
            report();
            return;
        }
        var p = phases.get(phaseIndex);
        stats.add(new PhaseStats(p));
        for (var cam : vision.cameras()) qualityAtPhaseStart.put(cam.name(), cam.inputs().qualityMatched);
        phaseStart = now;
        if (p.fms()) {
            DriverStationSim.setEventName("REHEARSAL");
            DriverStationSim.setMatchType(MatchType.QUALIFICATION);
            DriverStationSim.setMatchNumber(42);
        }
        DriverStationSim.setFmsAttached(p.fms());
        DriverStationSim.setRobotMode(p.auto() ? RobotMode.AUTONOMOUS : RobotMode.TELEOPERATED);
        DriverStationSim.setEnabled(p.enabled());
        DriverStationSim.notifyNewData();
        // As robot code would: record from the start of the match until it's over.
        recordRequest.set(p.fms() && p.enabled());
        System.out.printf("rehearsal: phase %d %s (%.0f s)%n", phaseIndex + 1, p.name(), p.seconds());
    }

    static double percentile(List<Double> v, double q) {
        if (v.isEmpty()) return Double.NaN;
        var s = new ArrayList<>(v);
        Collections.sort(s);
        return s.get(Math.min(s.size() - 1, (int) Math.floor(q * s.size())));
    }

    final StringBuilder report = new StringBuilder();

    void say(String format, Object... args) {
        report.append(String.format(format, args));
    }

    void sayln(String line) {
        report.append(line).append('\n');
    }

    void sayln() {
        report.append('\n');
    }

    void report() {
        int fails = 0;
        sayln();
        sayln("== SystemCore rehearsal (WPILib 2027 alpha-6 runtime, PhotonLib 2027 alpha-2) against " + jetson + ", " + link);
        if (!judgeTiming) sayln("   (over Wi-Fi: latency, loss and time sync are shown, not judged; run.sh --wired judges them)");
        boolean sawMatchSession = false, recordedInMatch = false;
        var deadCameras = new TreeSet<String>();
        for (var ps : stats) {
            var p = ps.phase;
            double secs = Math.max(1e-3, p.seconds() - SETTLE_SECONDS);
            double kbps = (ps.ntBytesEnd - ps.ntBytesStart) / Math.max(1e-3, ps.ntTimeEnd - ps.ntTimeStart) * 8 / 1000;
            say("%n-- %s: Jetson robot state %d/%d samples as expected%s; recording %d/%d%s%n",
                    p.name(), ps.stateSamples - ps.stateMismatches, ps.stateSamples,
                    ps.mismatchExamples.isEmpty() ? "" : " (" + String.join(", ", ps.mismatchExamples) + ")",
                    ps.recordingOn, ps.recordingSamples, ps.session.isEmpty() ? "" : " (" + ps.session + ")");
            say("   NetworkTables from the Jetson %.0f kbit/s; vision.periodic() mean %.0f us, max %.1f ms; longest loop gap %.0f ms%n",
                    kbps, ps.loops == 0 ? 0 : ps.periodicNanosTotal / 1e3 / ps.loops, ps.periodicNanosMax / 1e6,
                    ps.maxLoopGapSeconds * 1e3);
            if (ps.stateSamples == 0 || ps.stateMismatches > 0) {
                sayln("   FAIL  PhotonVision's view of the robot state");
                fails++;
            }
            if (p.fms() && p.enabled()) {
                if (ps.recordingOn > 0) recordedInMatch = true;
                if (ps.session.contains("_Q42_")) sawMatchSession = true;
            }
            for (var e : ps.cameras.entrySet()) {
                var cs = e.getValue();
                double fps = cs.results / secs;
                double p50 = percentile(cs.latencyMs, 0.5), p95 = percentile(cs.latencyMs, 0.95);
                if (cs.results == 0 && (cs.placeholders > 0 || !cs.connected)) {
                    // Not an integration problem: that camera isn't delivering frames on the Jetson.
                    say("   %-12s no frames: %.1f placeholder results/s, PhotonLib connected %s (unplugged or stuck on the Jetson?)%n",
                            e.getKey(), cs.placeholders / secs, cs.connected);
                    deadCameras.add(e.getKey());
                    continue;
                }
                double lostPct = 100.0 * cs.lost / Math.max(1, cs.lost + cs.results);
                say("   %-12s %5.1f results/s, %d lost (%.2f%%); latency p50 %.1f ms, p95 %.1f ms; %d from the future; last pong %.1f s ago at most%s%n",
                        e.getKey(), fps, cs.lost, lostPct, p50, p95, cs.negative, cs.maxPongMicros / 1e6,
                        cs.qualityMatched > 0 ? "; Jetson tag quality on " + cs.qualityMatched + " frames" : "");
                if (cs.results == 0) {
                    sayln("   FAIL  " + e.getKey() + ": no results");
                    fails++;
                } else if (cs.maxPongMicros > 5_000_000) {
                    sayln("   FAIL  " + e.getKey() + ": time sync stopped (no pong for over 5 s)");
                    fails++;
                } else if (judgeTiming && (cs.negative > 0 || p50 > 30)) {
                    sayln("   FAIL  " + e.getKey() + ": time sync or latency (" + cs.negative
                            + " results from the future, p50 " + String.format("%.1f", p50) + " ms)");
                    fails++;
                } else if (judgeTiming && lostPct > 0.5) {
                    sayln("   FAIL  " + e.getKey() + String.format(": %.2f%% of results lost on the way", lostPct));
                    fails++;
                }
            }
        }
        sayln();
        if (!recordedInMatch) {
            sayln("FAIL  Rewind didn't record when robot code asked during the match");
            fails++;
        } else if (!sawMatchSession) {
            sayln("FAIL  the match recording isn't named Q42 (from /FMSInfo MatchType and MatchNumber)");
            fails++;
        }
        if (!deadCameras.isEmpty()) sayln("WARN  no frames from " + deadCameras + " (not counted as a failure: fix on the Jetson)");
        sayln("SpectrumVision: " + vision.stats().summary().strip());
        // What the drive team's dashboard shows: WPILib alerts are string arrays in NetworkTables, in
        // a table named after the group ("Vision"; /SmartDashboard/Vision in 2026).
        for (var t : NetworkTableInstance.getDefault().getTopics("")) {
            if (!t.getTypeString().equals("string[]") || !t.getName().contains("/Vision/") || t.getName().startsWith("/photonvision")) continue;
            String[] v = NetworkTableInstance.getDefault().getStringArrayTopic(t.getName()).subscribe(new String[0]).get();
            if (v.length > 0) sayln("SpectrumVision alerts " + t.getName().substring(t.getName().lastIndexOf('/') + 1) + ": " + String.join("; ", v));
        }
        sayln(fails == 0 ? "rehearsal: PASS" : "rehearsal: FAIL (" + fails + " checks)");
        System.out.print(report);
        finish(fails == 0 ? 0 : 1);
    }

    void finish(int code) {
        System.out.flush();
        RobotBase.suppressExitWarning(true);
        System.exit(code);
    }

    // Empty, so WPILib doesn't print "Override me!" for each.
    @Override
    public void disabledPeriodic() {}

    @Override
    public void autonomousPeriodic() {}

    @Override
    public void teleopPeriodic() {}

    @Override
    public void simulationPeriodic() {}

    public static void main(String... args) {
        RobotBase.startRobot(Rehearsal.class);
    }
}
