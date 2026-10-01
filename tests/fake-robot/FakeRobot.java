// A stand-in for robot code: a NetworkTables server that publishes the Driver Station's control
// word (/FMSInfo/FMSControlData) through a list of phases, so PhotonVision's robot-state features
// (idle while disabled, photonvision-49) can be tested on the bench.
// Run ON THE JETSON, reached by PhotonVision as its robot (see tests/fake-robot/run.sh):
//   java -cp /opt/photonvision/photonvision.jar FakeRobot.java disabled:30 enabled:30 disabled:30
// Each phase is STATE:SECONDS, STATE one of disabled, enabled, auto, and any of those with "fms-"
// in front (FMS attached). Prints "phase <n> <state> <unix ms>" as each one starts. Touching
// /tmp/fake-robot-stop ends the run early.
// FAKE_ROBOT_WPILIB=2027 (the default: our SystemCore robot) publishes the control word as WPILib
// 2027 does, the /FMSInfo/ControlWord struct; FAKE_ROBOT_WPILIB=2026 as a roboRIO on 2026 does,
// the /FMSInfo/FMSControlData integer. PhotonVision reads both (photonvision-62).
import org.wpilib.networktables.NetworkTableInstance;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.photonvision.jni.LibraryLoader;

public class FakeRobot {
    static long word(String state) {
        long w = 32; // DS attached
        if (state.startsWith("fms-")) {
            w |= 16;
            state = state.substring(4);
        }
        switch (state) {
            case "disabled" -> {}
            case "enabled" -> w |= 1;
            case "auto" -> w |= 1 | 2;
            default -> throw new IllegalArgumentException("Unknown state " + state);
        }
        return w;
    }

    // The same state as WPILib 2027's ControlWord struct: one little-endian uint64 with the robot
    // mode in bits 56-57 (1 autonomous, 2 teleoperated), enabled 58, FMS attached 60, DS 61.
    static byte[] word2027(long w2026) {
        boolean enabled = (w2026 & 1) != 0, auto = (w2026 & 2) != 0;
        long w = ((auto ? 1L : 2L) << 56)
                | (enabled ? 1L << 58 : 0)
                | ((w2026 & 16) != 0 ? 1L << 60 : 0)
                | ((w2026 & 32) != 0 ? 1L << 61 : 0);
        return ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(w).array();
    }

    // Touch this file to end the run early (tests/ui's idle test does, over SSH).
    static final java.io.File STOP = new java.io.File("/tmp/fake-robot-stop");

    public static void main(String[] args) throws Exception {
        STOP.delete();
        LibraryLoader.loadWpiLibraries();
        var nt = NetworkTableInstance.create();
        nt.startServer("/tmp/fake-robot-nt.json");
        var fms = nt.getTable("FMSInfo");
        final boolean wpilib2027 = !"2026".equals(System.getenv("FAKE_ROBOT_WPILIB"));
        System.out.println("control word as WPILib " + (wpilib2027 ? "2027 (/FMSInfo/ControlWord struct)" : "2026 (/FMSInfo/FMSControlData)"));
        var control2026 = wpilib2027 ? null : fms.getIntegerTopic("FMSControlData").publish();
        var control2027 = wpilib2027 ? fms.getRawTopic("ControlWord").publish("struct:ControlWord") : null;
        java.util.function.LongConsumer control =
                w -> {
                    if (wpilib2027) control2027.set(word2027(w));
                    else control2026.set(w);
                };
        control.accept(word("disabled"));
        System.out.println("waiting for PhotonVision to connect");
        long giveUp = System.currentTimeMillis() + 30_000;
        while (nt.getConnections().length == 0) {
            if (System.currentTimeMillis() > giveUp) {
                System.out.println("TIMEOUT: PhotonVision didn't connect within 30 s");
                System.exit(2);
            }
            Thread.sleep(100);
        }
        System.out.println("connected " + System.currentTimeMillis());
        Thread.sleep(2000);
        for (int i = 0; i < args.length; i++) {
            String[] p = args[i].split(":");
            control.accept(word(p[0]));
            nt.flush();
            System.out.println("phase " + i + " " + p[0] + " " + System.currentTimeMillis());
            long until = System.currentTimeMillis() + (long) (Double.parseDouble(p[1]) * 1000);
            while (System.currentTimeMillis() < until) {
                if (STOP.exists()) {
                    System.out.println("stopped early " + System.currentTimeMillis());
                    i = args.length;
                    break;
                }
                Thread.sleep(100);
            }
        }
        System.out.println("done " + System.currentTimeMillis());
        nt.close();
    }
}
