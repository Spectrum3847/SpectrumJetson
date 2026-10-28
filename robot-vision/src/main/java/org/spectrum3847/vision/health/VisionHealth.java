package org.spectrum3847.vision.health;

import edu.wpi.first.networktables.BooleanSubscriber;
import edu.wpi.first.networktables.DoubleSubscriber;
import edu.wpi.first.networktables.IntegerSubscriber;
import edu.wpi.first.networktables.NetworkTable;
import edu.wpi.first.networktables.NetworkTableInstance;
import edu.wpi.first.networktables.StringSubscriber;
import java.util.LinkedHashMap;
import java.util.Map;
import org.photonvision.targeting.PhotonPipelineResult;
import org.spectrum3847.vision.compat.VisionAlert;
import org.spectrum3847.vision.compat.VisionAlert.Level;
import org.spectrum3847.vision.io.CameraIO;
import org.spectrum3847.vision.log.VisionStats;

/**
 * Dashboard alerts for what the drive team must know before (and during) a match. Works with any
 * PhotonVision; the Jetson checks only fire when SpectrumJetson's topics exist.
 *
 * <ul>
 *   <li>a camera disconnected (after a 10 s start-up grace)
 *   <li>PhotonVision's message format differs from this robot's PhotonLib (the coprocessor's
 *       {@code rawBytes} type string against PhotonLib's): results can't be read
 *   <li>the coprocessor's time sync is stale (frames' {@code timeSinceLastPong})
 *   <li>a camera's fps is below {@link #minFps} while enabled (SpectrumJetson's {@code health/fps})
 *   <li>a camera reports a problem (SpectrumJetson's {@code health/problem}: stuck, wrong mode, ...)
 *   <li>the Jetson has given up on a camera (SpectrumJetson's {@code health/state} "gave-up": only
 *       a power cycle brings a wedged Thriftiest Cam back)
 *   <li>the Jetson is throttling (over-current or temperature) or hot ({@link #maxJetsonTempC})
 *   <li>the Jetson is in quiet mode while the robot is enabled (it shouldn't be)
 *   <li>frames arrive but every candidate is rejected (with the top reason), while enabled
 * </ul>
 *
 * With SpectrumJetson's photonvision-76 diagnostics, also (each stays up until robot code restarts,
 * so the pit sees it after the match):
 *
 * <ul>
 *   <li>the Jetson's input voltage dipped below {@link #minJetsonInputV}
 *   <li>USB trouble on the Jetson (a camera dropped off USB, a hub disabled a port, ...), with the
 *       kernel's latest line
 *   <li>the Jetson's Ethernet link dropped (its cable or the switch, not the NT server)
 *   <li>the Jetson rebooted
 *   <li>the Jetson's clock was never set from the robot (its logs and Rewind names carry a wrong
 *       date): robot code should publish {@code /photonvision/clock/unixMs}
 *   <li>the SSD reports media errors or a critical warning; ext4 recorded errors; the settings
 *       partition went read-only
 *   <li>RAM above {@link #maxJetsonRamPct}
 * </ul>
 */
public class VisionHealth {
    public double minFps = 20;
    public double maxJetsonTempC = 92;
    public double startupGraceSeconds = 10;
    public double allRejectedAfterSeconds = 3;
    /** The Jetson's input should hold steady: set this a few volts under your supply's output. */
    public double minJetsonInputV = 12.0;
    public double maxJetsonRamPct = 90;

    private final NetworkTable pv = NetworkTableInstance.getDefault().getTable("photonvision");
    private final Map<String, CameraAlerts> cameras = new LinkedHashMap<>();
    private final StringSubscriber throttle = pv.getSubTable("jetson").getStringTopic("throttle").subscribe("");
    private final DoubleSubscriber tjTemp = pv.getSubTable("jetson").getDoubleTopic("tjTempC").subscribe(Double.NaN);
    private final BooleanSubscriber quietNow =
            pv.getSubTable("jetson").getBooleanTopic("quietNow").subscribe(false);
    private final VisionAlert throttleAlert = new VisionAlert("Vision", "", Level.WARNING);
    private final VisionAlert hotAlert = new VisionAlert("Vision", "", Level.WARNING);
    private final VisionAlert quietAlert =
            new VisionAlert("Vision", "Jetson in quiet mode while enabled (it should leave it within 0.1 s)", Level.WARNING);
    private final VisionAlert allRejected = new VisionAlert("Vision", "", Level.WARNING);
    private final double startedSeconds;
    private double rejectingSince = Double.NaN;

    // SpectrumJetson photonvision-76: the Jetson's diagnostics.
    private final NetworkTable jetson = pv.getSubTable("jetson");
    private final DoubleSubscriber inputLowest = jetson.getDoubleTopic("inputVoltageLowestV").subscribe(Double.NaN);
    private final IntegerSubscriber usbEvents = jetson.getIntegerTopic("usbEvents").subscribe(-1);
    private final StringSubscriber lastUsbEvent = jetson.getStringTopic("lastUsbEvent").subscribe("");
    private final IntegerSubscriber carrierChanges = jetson.getIntegerTopic("ethCarrierChanges").subscribe(-1);
    private final StringSubscriber bootId = jetson.getStringTopic("bootId").subscribe("");
    private final StringSubscriber clockSource = jetson.getStringTopic("clockSource").subscribe("");
    private final IntegerSubscriber ssdMediaErrors = jetson.getIntegerTopic("ssdMediaErrors").subscribe(0);
    private final IntegerSubscriber ssdCriticalWarning = jetson.getIntegerTopic("ssdCriticalWarning").subscribe(0);
    private final IntegerSubscriber fsErrors = jetson.getIntegerTopic("fsErrors").subscribe(0);
    private final BooleanSubscriber settingsReadOnly = jetson.getBooleanTopic("settingsReadOnly").subscribe(false);
    private final DoubleSubscriber ramUsed = jetson.getDoubleTopic("ramUsedPct").subscribe(Double.NaN);
    private final VisionAlert lowInputAlert = new VisionAlert("Vision", "", Level.ERROR);
    private final VisionAlert usbAlert = new VisionAlert("Vision", "", Level.ERROR);
    private final VisionAlert ethernetAlert = new VisionAlert("Vision", "", Level.WARNING);
    private final VisionAlert rebootAlert = new VisionAlert("Vision", "Jetson rebooted (power?)", Level.WARNING);
    private final VisionAlert clockAlert =
            new VisionAlert(
                    "Vision",
                    "Jetson clock not set from the robot: publish /photonvision/clock/unixMs (its logs carry a wrong date)",
                    Level.WARNING);
    private final VisionAlert ssdAlert = new VisionAlert("Vision", "", Level.ERROR);
    private final VisionAlert ramAlert = new VisionAlert("Vision", "", Level.WARNING);
    // Counters as first seen after robot code started: a rise is trouble this run.
    private long usbEventsAtStart = -1, carrierChangesAtStart = -1;
    private String firstBootId = null;

    private static final class CameraAlerts {
        final VisionAlert disconnected, format, sync, fps, problem, gaveUp;
        final DoubleSubscriber fpsSub;
        final StringSubscriber problemSub, stateSub;
        final String name;

        CameraAlerts(NetworkTable pv, String name) {
            this.name = name;
            disconnected = new VisionAlert("Vision", "Camera " + name + " disconnected", Level.ERROR);
            format = new VisionAlert("Vision", "", Level.ERROR);
            sync = new VisionAlert("Vision", "Camera " + name + ": time sync stale (timestamps may be wrong)", Level.WARNING);
            fps = new VisionAlert("Vision", "", Level.WARNING);
            problem = new VisionAlert("Vision", "", Level.ERROR);
            gaveUp = new VisionAlert(
                    "Vision", "Camera " + name + " won't recover by itself: power-cycle the robot", Level.ERROR);
            var health = pv.getSubTable(name).getSubTable("health");
            fpsSub = health.getDoubleTopic("fps").subscribe(Double.NaN);
            problemSub = health.getStringTopic("problem").subscribe("");
            stateSub = health.getStringTopic("state").subscribe("");
        }
    }

    /**
     * SpectrumJetson's {@code health/state} for a camera: "streaming", "stalled", "recovering",
     * "disconnected", "gave-up", "paused" or "starting"; "" when the coprocessor doesn't publish it
     * (stock PhotonVision, or before SpectrumJetson's photonvision-75). Log it with the camera.
     */
    public String cameraState(String name) {
        var c = cameras.get(name);
        return c == null ? "" : c.stateSub.get();
    }

    public VisionHealth(double nowSeconds) {
        startedSeconds = nowSeconds;
    }

    /** Once per loop, after the cameras' inputs are updated. */
    public void update(
            double now, boolean enabled, Map<String, CameraIO.Inputs> inputs, VisionStats.Counts loopCounts, String topReason) {
        boolean pastGrace = now - startedSeconds > startupGraceSeconds;
        inputs.forEach((name, in) -> {
            var c = cameras.computeIfAbsent(name, n -> new CameraAlerts(pv, n));
            c.disconnected.set(pastGrace && !in.connected);
            // The coprocessor's message format, from the rawBytes topic's type string.
            String remote = pv.getSubTable(name).getRawTopic("rawBytes").getTypeString();
            String local = PhotonPipelineResult.photonStruct.getTypeString();
            boolean mismatch = remote != null && !remote.isEmpty() && !remote.equals(local);
            c.format.setText("Camera " + name + ": PhotonVision's message format (" + remote
                    + ") isn't this PhotonLib's (" + local + "): update one to match the other");
            c.format.set(mismatch);
            long worstPong = -1;
            for (var f : in.frames) worstPong = Math.max(worstPong, f.timeSinceLastPongMicros());
            if (!in.frames.isEmpty()) c.sync.set(worstPong > 1_000_000);
            double fps = c.fpsSub.get();
            c.fps.setText(String.format("Camera %s: %.0f fps (below %.0f)", name, fps, minFps));
            c.fps.set(enabled && !Double.isNaN(fps) && fps < minFps);
            String p = c.problemSub.get();
            c.problem.setText("Camera " + name + ": " + p);
            c.problem.set(p != null && !p.isEmpty());
            // The Jetson has given up on it (a wedged camera needs its power cut). Its problem says
            // why; this says what to do, and covers a Jetson that hasn't filled in a problem.
            c.gaveUp.set("gave-up".equals(c.stateSub.get()) && (p == null || p.isEmpty()));
        });
        String t = throttle.get();
        throttleAlert.setText("Jetson throttling: " + t);
        // SpectrumJetson's reason: "None", "Prev. over-current (n)" (earlier, not now), or what's
        // limiting it now ("OVER-CURRENT", "HIGH TEMP (...)", "CPU CLOCK CAPPED", ...).
        throttleAlert.set(t != null && !t.isEmpty() && !t.equalsIgnoreCase("none") && !t.startsWith("Prev."));
        double temp = tjTemp.get();
        hotAlert.setText(String.format("Jetson at %.0f °C (cameras capped from 95 °C)", temp));
        hotAlert.set(!Double.isNaN(temp) && temp >= maxJetsonTempC);
        quietAlert.set(enabled && quietNow.get());
        updateDiagnostics(pastGrace);
        // Frames arriving but nothing accepted, for a while: say why.
        if (enabled && loopCounts.candidates > 0 && loopCounts.accepted == 0) {
            if (Double.isNaN(rejectingSince)) rejectingSince = now;
        } else if (loopCounts.accepted > 0 || !enabled) {
            rejectingSince = Double.NaN;
        }
        boolean stuck = !Double.isNaN(rejectingSince) && now - rejectingSince > allRejectedAfterSeconds;
        allRejected.setText("Vision rejecting every pose (most: " + topReason + ")");
        allRejected.set(stuck);
    }

    /** photonvision-76's diagnostics. Each alert stays up until robot code restarts. */
    private void updateDiagnostics(boolean pastGrace) {
        double lowest = inputLowest.get();
        if (!Double.isNaN(lowest) && lowest < minJetsonInputV) {
            lowInputAlert.setText(String.format("Jetson input voltage dipped to %.1f V (power supply or wiring)", lowest));
            lowInputAlert.set(true);
        }
        long usb = usbEvents.get();
        if (usb >= 0 && usbEventsAtStart < 0) usbEventsAtStart = usb;
        if (usbEventsAtStart >= 0 && usb > usbEventsAtStart) {
            usbAlert.setText("Jetson USB trouble (" + (usb - usbEventsAtStart) + "): " + lastUsbEvent.get());
            usbAlert.set(true);
        }
        long carrier = carrierChanges.get();
        if (carrier >= 0 && carrierChangesAtStart < 0) carrierChangesAtStart = carrier;
        if (carrierChangesAtStart >= 0 && carrier > carrierChangesAtStart) {
            ethernetAlert.setText(
                    "Jetson Ethernet link dropped " + (carrier - carrierChangesAtStart) / 2
                            + " time(s): its cable or the switch port");
            ethernetAlert.set(carrier - carrierChangesAtStart >= 2);
        }
        String boot = bootId.get();
        if (!boot.isEmpty()) {
            if (firstBootId == null) firstBootId = boot;
            else if (!boot.equals(firstBootId)) rebootAlert.set(true);
        }
        clockAlert.set(pastGrace && "unset".equals(clockSource.get()));
        long media = ssdMediaErrors.get(), critical = ssdCriticalWarning.get(), fs = fsErrors.get();
        boolean settingsRo = settingsReadOnly.get();
        if (media > 0 || critical != 0 || fs > 0 || settingsRo) {
            ssdAlert.setText(
                    "Jetson SSD: "
                            + (media > 0 ? media + " media errors (replace it) " : "")
                            + (critical != 0 ? "critical warning " + critical + " " : "")
                            + (fs > 0 ? fs + " filesystem errors " : "")
                            + (settingsRo ? "settings partition read-only" : ""));
            ssdAlert.set(true);
        }
        double ram = ramUsed.get();
        ramAlert.setText(String.format("Jetson RAM at %.0f%%", ram));
        ramAlert.set(!Double.isNaN(ram) && ram > maxJetsonRamPct);
    }
}
