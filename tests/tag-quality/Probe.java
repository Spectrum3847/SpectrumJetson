// Live check of /photonvision/<camera>/tagQuality (photonvision-61), the way robot code would read
// it: a second NetworkTables client of the robot's server, subscribed to every value of each
// camera's rawBytes and tagQuality. Run ON THE JETSON (see run.sh), with the fake robot's server up:
//   java -cp /opt/photonvision/photonvision.jar Probe.java SECONDS
// Per camera it prints frames with tags, how many found their quality array by sequence ID, whether
// the tag IDs agreed, the medians of each value, and the bytes each costs on the network.
// Exit 0 when every camera that saw tags matched at least 99% of its frames with the same IDs.
import org.wpilib.networktables.DoubleArraySubscriber;
import org.wpilib.networktables.NetworkTableInstance;
import org.wpilib.networktables.PubSubOption;
import org.wpilib.networktables.RawSubscriber;
import java.util.*;
import org.photonvision.common.dataflow.structures.Packet;
import org.photonvision.jni.LibraryLoader;
import org.photonvision.targeting.PhotonPipelineResult;

public class Probe {
    static double median(List<Double> v) {
        var x = v.stream().filter(d -> !d.isNaN()).sorted().toList();
        return x.isEmpty() ? Double.NaN : x.get(x.size() / 2);
    }

    public static void main(String[] args) throws Exception {
        double seconds = args.length > 0 ? Double.parseDouble(args[0]) : 20;
        LibraryLoader.loadWpiLibraries();
        LibraryLoader.loadTargeting();
        var nt = NetworkTableInstance.create();
        nt.setServer("10.85.15.2");
        nt.startClient("tag-quality-probe");
        long giveUp = System.currentTimeMillis() + 20_000;
        while (!nt.isConnected()) {
            if (System.currentTimeMillis() > giveUp) {
                System.out.println("TIMEOUT: no NetworkTables server at 10.85.15.2 (run tests/fake-robot first)");
                System.exit(2);
            }
            Thread.sleep(100);
        }
        // Topic announcements need a subscription; a prefix one with only topics is cheap.
        var all = new org.wpilib.networktables.MultiSubscriber(
                nt, new String[] {"/photonvision/"}, PubSubOption.TOPICS_ONLY);
        Thread.sleep(2000);
        var cams = new TreeSet<String>();
        for (var t : nt.getTopics("/photonvision/")) {
            String n = t.getName();
            if (n.endsWith("/rawBytes")) cams.add(n.substring("/photonvision/".length(), n.length() - "/rawBytes".length()));
        }
        if (cams.isEmpty()) {
            System.out.println("FAIL: no cameras on NetworkTables");
            System.exit(1);
        }
        var opts = new PubSubOption[] {PubSubOption.SEND_ALL, PubSubOption.pollStorage(500), PubSubOption.periodic(0.01)};
        var raw = new HashMap<String, RawSubscriber>();
        var q = new HashMap<String, DoubleArraySubscriber>();
        for (var c : cams) {
            raw.put(c, nt.getRawTopic("/photonvision/" + c + "/rawBytes").subscribe(PhotonPipelineResult.photonStruct.getTypeString(), new byte[0], opts));
            q.put(c, nt.getDoubleArrayTopic("/photonvision/" + c + "/tagQuality").subscribe(new double[0], opts));
        }

        var withTags = new HashMap<String, Integer>();
        var matched = new HashMap<String, Integer>();
        var idsOk = new HashMap<String, Integer>();
        var rawBytes = new HashMap<String, Long>();
        var qBytes = new HashMap<String, Long>();
        var frames = new HashMap<String, Integer>();
        var vals = new HashMap<String, List<List<Double>>>();
        var pending = new HashMap<String, Map<Long, double[]>>();
        for (var c : cams) {
            pending.put(c, new HashMap<>());
            var l = new ArrayList<List<Double>>();
            for (int i = 0; i < 5; i++) l.add(new ArrayList<>());
            vals.put(c, l);
        }
        var waiting = new HashMap<String, List<Object[]>>(); // {result, arrival ms}
        for (var c : cams) waiting.put(c, new ArrayList<>());

        long end = System.currentTimeMillis() + (long) (seconds * 1000);
        while (System.currentTimeMillis() < end) {
            for (var c : cams) {
                for (var v : q.get(c).readQueue()) {
                    pending.get(c).put((long) v.value[0], v.value);
                    qBytes.merge(c, 8L * v.value.length, Long::sum);
                }
                for (var v : raw.get(c).readQueue()) {
                    frames.merge(c, 1, Integer::sum);
                    rawBytes.merge(c, (long) v.value.length, Long::sum);
                    var r = PhotonPipelineResult.photonStruct.unpack(new Packet(v.value));
                    if (r.hasTargets()) waiting.get(c).add(new Object[] {r, System.currentTimeMillis()});
                }
                // Give a quality array 0.5 s to arrive, then judge the frame.
                var it = waiting.get(c).iterator();
                while (it.hasNext()) {
                    var w = it.next();
                    var r = (PhotonPipelineResult) w[0];
                    double[] a = pending.get(c).remove(r.metadata.sequenceID);
                    boolean old = System.currentTimeMillis() - (long) w[1] > 500;
                    if (a == null && !old) continue;
                    it.remove();
                    withTags.merge(c, 1, Integer::sum);
                    if (a == null) continue;
                    matched.merge(c, 1, Integer::sum);
                    boolean same = (int) a[1] == r.targets.size();
                    for (int i = 0; same && i < r.targets.size(); i++) {
                        same = (int) a[2 + 6 * i] == r.targets.get(i).fiducialId;
                        for (int k = 0; k < 5; k++) vals.get(c).get(k).add(a[2 + 6 * i + 1 + k]);
                    }
                    if (same) idsOk.merge(c, 1, Integer::sum);
                }
            }
            Thread.sleep(5);
        }

        boolean pass = true;
        int camsWithTags = 0;
        String[] names = {"margin", "edgePx", "undistortPx", "reprojBestPx", "reprojAltPx"};
        for (var c : cams) {
            int n = withTags.getOrDefault(c, 0), m = matched.getOrDefault(c, 0), ok = idsOk.getOrDefault(c, 0);
            int f = frames.getOrDefault(c, 0);
            var sb = new StringBuilder();
            for (int k = 0; k < 5; k++) sb.append(String.format(" %s %.2f", names[k], median(vals.get(c).get(k))));
            System.out.printf(
                    "%s: %d frames, %d with tags, %d matched by sequence ID, %d with the same IDs;%s%n",
                    c, f, n, m, ok, sb);
            if (f > 0) {
                System.out.printf(
                        "  bytes a frame: result %.0f, quality %.0f (only frames with tags send one)%n",
                        rawBytes.getOrDefault(c, 0L) / (double) f, qBytes.getOrDefault(c, 0L) / (double) f);
            }
            if (n > 0) {
                camsWithTags++;
                if (m < 0.99 * n || ok < m) pass = false;
            }
        }
        if (camsWithTags == 0) {
            System.out.println("FAIL: no camera saw tags (start fake cameras: scripts/jetson/fake-cameras.sh start)");
            System.exit(1);
        }
        System.out.println(pass ? "PASS" : "FAIL");
        all.close();
        nt.close();
        System.exit(pass ? 0 : 1);
    }
}
