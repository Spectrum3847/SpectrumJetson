// Bench check for PhotonVision's Jetson telemetry (patch 16) and camera mount estimate (patch 17):
// stands in for robot code by running a NetworkTables server, then prints every value under
// /photonvision/jetson and each camera's /health and /mount tables. Run ON THE JETSON with
// PhotonVision's NT server address set to 127.0.0.1 (see run.sh):
//   java -cp /opt/photonvision/photonvision.jar NtTelemetryDump.java [seconds]
import org.wpilib.networktables.MultiSubscriber;
import org.wpilib.networktables.NetworkTableInstance;
import org.wpilib.networktables.NetworkTableValue;
import org.wpilib.networktables.PubSubOption;
import org.wpilib.networktables.Topic;
import java.util.Arrays;
import java.util.TreeMap;
import org.photonvision.jni.LibraryLoader;

public class NtTelemetryDump {
    public static void main(String[] args) throws Exception {
        int seconds = Integer.parseInt(args.length > 0 ? args[0] : "6");
        LibraryLoader.loadWpiLibraries();
        var nt = NetworkTableInstance.create();
        nt.startServer("/tmp/nt-telemetry-dump.json");
        // Subscribe to everything under /photonvision so the values are sent to us.
        var sub = new MultiSubscriber(
                nt, new String[] {"/photonvision/"}, PubSubOption.sendAll(false));
        System.out.println("NT server up; waiting for PhotonVision to connect...");
        long deadline = System.nanoTime() + 30_000_000_000L;
        while (nt.getConnections().length == 0) {
            if (System.nanoTime() > deadline) {
                System.out.println("PhotonVision didn't connect in 30 s: is its NT server address 127.0.0.1?");
                System.exit(1);
            }
            Thread.sleep(200);
        }
        System.out.println("PhotonVision connected; collecting for " + seconds + " s");
        Thread.sleep(seconds * 1000L);
        var values = new TreeMap<String, String>();
        for (Topic t : nt.getTopics("/photonvision/")) {
            String name = t.getName();
            if (!(name.startsWith("/photonvision/jetson/") || name.contains("/health/") || name.contains("/mount/"))) {
                continue;
            }
            var entry = t.getGenericEntry();
            NetworkTableValue v = entry.get();
            values.put(name, v.isValid() ? format(v) : "(no value)");
            entry.close();
        }
        values.forEach((k, v) -> System.out.println(k + " = " + v));
        if (values.isEmpty()) System.out.println("No telemetry topics found (is the patch 16/17 jar installed?)");
        sub.close();
        nt.close();
    }

    private static String format(NetworkTableValue v) {
        Object o = v.getValue();
        if (o instanceof Double d) return String.format("%.3f", d);
        if (o instanceof double[] a) return Arrays.toString(a);
        return String.valueOf(o);
    }
}
