// Bench test for PhotonVision's RobotClockSync (patch 08): stands in for robot code by running a
// NetworkTables server that publishes /photonvision/clock/unixMs, first OFFSET seconds wrong,
// then correct. Run ON THE JETSON with PhotonVision's NT server address set to 127.0.0.1 (see
// run.sh):
//   java -cp /opt/photonvision/photonvision.jar FakeRobotClock.java [offset_s] [seconds_each]
import org.wpilib.networktables.NetworkTableInstance;
import org.photonvision.jni.LibraryLoader;

public class FakeRobotClock {
    public static void main(String[] args) throws Exception {
        long offsetMs = (long) (Double.parseDouble(args.length > 0 ? args[0] : "120") * 1000);
        long phaseMs = (long) (Double.parseDouble(args.length > 1 ? args[1] : "40") * 1000);
        LibraryLoader.loadWpiLibraries();
        var nt = NetworkTableInstance.create();
        nt.startServer("/tmp/fake-robot-clock-nt.json");
        var pub = nt.getIntegerTopic("/photonvision/clock/unixMs").publish();
        System.out.println("NT server up; waiting for PhotonVision to connect...");
        while (nt.getConnections().length == 0) Thread.sleep(200);
        System.out.println("PhotonVision connected. Publishing a clock " + offsetMs / 1000.0 + " s off.");
        long end = System.nanoTime() / 1_000_000 + phaseMs;
        // System.currentTimeMillis() changes under us once PhotonVision sets the clock, so keep
        // our own time from a monotonic clock.
        long startWall = System.currentTimeMillis(), startMono = System.nanoTime() / 1_000_000;
        while (System.nanoTime() / 1_000_000 < end) {
            pub.set(startWall + (System.nanoTime() / 1_000_000 - startMono) + offsetMs);
            Thread.sleep(100);
        }
        System.out.println("Now publishing the correct time.");
        end = System.nanoTime() / 1_000_000 + phaseMs;
        while (System.nanoTime() / 1_000_000 < end) {
            pub.set(startWall + (System.nanoTime() / 1_000_000 - startMono));
            Thread.sleep(100);
        }
        System.out.println("Done.");
        nt.close();
    }
}
