// A stand-in for robot code's field map (photonvision-74): a NetworkTables server that publishes
// /SpectrumVision/FieldMap/{Json,Hash,Name} through a list of phases and prints what the Jetson
// reports back under /photonvision/jetson/FieldMap. Run with PhotonVision's jar on the classpath:
//   java -cp /opt/photonvision/photonvision.jar FieldMapRobot.java PHASE...
// Phases, '|'-separated so Windows paths work:
//   silent|SECONDS                              publishes nothing new
//   publish|SECONDS|JSON|HASH|NAME              JSON is a file, or resource:<path> in the jar
//                                               (resource:/edu/wpi/first/apriltag/2026-rebuilt-andymark.json)
// Prints "phase ..." as each starts, "jetson t=... Hash=... Name=... LoadedAt=... Error=..."
// whenever the Jetson's report changes, and once a second "fps t=... <camera>=<fps> ..." from each
// camera's /photonvision/<camera>/health/fps. FIELD_MAP_ROBOT_PORT sets the NT4 port (default 5810;
// PhotonVision only looks for its robot there).
import edu.wpi.first.networktables.DoubleSubscriber;
import edu.wpi.first.networktables.MultiSubscriber;
import edu.wpi.first.networktables.NetworkTableInstance;
import edu.wpi.first.networktables.StringPublisher;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.TreeMap;
import org.photonvision.jni.LibraryLoader;

public class FieldMapRobot {
    static String read(String source) throws Exception {
        if (source.startsWith("resource:")) {
            try (var in = FieldMapRobot.class.getResourceAsStream(source.substring("resource:".length()))) {
                if (in == null) throw new IllegalArgumentException("No resource " + source);
                return new String(in.readAllBytes(), StandardCharsets.UTF_8);
            }
        }
        return Files.readString(Path.of(source));
    }

    public static void main(String[] args) throws Exception {
        if (!LibraryLoader.loadWpiLibraries()) throw new IllegalStateException("WPILib natives didn't load");
        int port = Integer.parseInt(System.getenv().getOrDefault("FIELD_MAP_ROBOT_PORT", "5810"));
        var nt = NetworkTableInstance.create();
        nt.startServer(Files.createTempFile("field-map-robot", ".json").toString(), "", 0, port);
        var robot = nt.getTable("/SpectrumVision/FieldMap");
        StringPublisher json = null, hash = null, name = null;
        var jetson = nt.getTable("/photonvision/jetson/FieldMap");
        var outHash = jetson.getStringTopic("Hash").subscribe("<none>");
        var outName = jetson.getStringTopic("Name").subscribe("<none>");
        var outAt = jetson.getDoubleTopic("LoadedAt").subscribe(-1);
        var outErr = jetson.getStringTopic("Error").subscribe("<none>");
        @SuppressWarnings("unused") // keeps the cameras' topics announced, so they can be found
        var any = new MultiSubscriber(nt, new String[] {"/photonvision/"});
        Map<String, DoubleSubscriber> fps = new TreeMap<>();
        long t0 = System.nanoTime();
        long nextFps = t0;
        String last = "";
        for (String phase : args) {
            String[] p = phase.split("[|]", 5);
            double seconds = Double.parseDouble(p[1]);
            if (p[0].equals("publish")) {
                if (json == null) {
                    json = robot.getStringTopic("Json").publish();
                    hash = robot.getStringTopic("Hash").publish();
                    name = robot.getStringTopic("Name").publish();
                }
                json.set(read(p[2]));
                hash.set(p[3]);
                name.set(p[4]);
                System.out.println("phase publish " + p[4] + " with hash " + p[3] + " for " + p[1] + " s");
            } else if (p[0].equals("silent")) {
                System.out.println("phase silent for " + p[1] + " s");
            } else {
                throw new IllegalArgumentException("Unknown phase " + phase);
            }
            long end = System.nanoTime() + (long) (seconds * 1e9);
            while (System.nanoTime() < end) {
                String now =
                        String.format(
                                "Hash=%s Name=%s LoadedAt=%.0f Error=%s",
                                outHash.get(), outName.get(), outAt.get(), outErr.get());
                if (nt.getConnections().length > 0 && !now.equals(last)) {
                    System.out.printf("jetson t=%.1f %s%n", (System.nanoTime() - t0) / 1e9, now);
                    last = now;
                }
                if (System.nanoTime() >= nextFps) {
                    nextFps += 1_000_000_000L;
                    for (var topic : nt.getTopics("/photonvision/")) {
                        String n = topic.getName();
                        if (n.endsWith("/health/fps") && !fps.containsKey(n)) {
                            fps.put(n, nt.getDoubleTopic(n).subscribe(-1));
                        }
                    }
                    if (!fps.isEmpty()) {
                        var line = new StringBuilder(String.format("fps t=%.1f", (System.nanoTime() - t0) / 1e9));
                        fps.forEach((n, sub) -> line.append(' ').append(n.split("/")[2]).append('=').append(String.format("%.1f", sub.get())));
                        System.out.println(line);
                    }
                }
                Thread.sleep(100);
            }
        }
        System.out.println("done");
        System.exit(0);
    }
}
