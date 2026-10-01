// Holds quiet mode (photonvision-56) off while files are written to the scratch partition, the way
// robot code can: publishes /photonvision/jetson/quiet = false on the robot's NetworkTables server
// (the fake robot's on the bench) until /tmp/quiet-off-stop appears or SECONDS pass. Unpublishing
// it hands quiet mode back to PhotonVision. Prints "holding" once the Jetson reports quietNow false.
//   java -cp /opt/photonvision/photonvision.jar QuietOff.java [SECONDS]
import org.wpilib.networktables.NetworkTableInstance;
import org.photonvision.jni.LibraryLoader;

public class QuietOff {
    public static void main(String[] args) throws Exception {
        long until = System.currentTimeMillis() + (long) (Double.parseDouble(args.length > 0 ? args[0] : "1800") * 1000);
        var stop = new java.io.File("/tmp/quiet-off-stop");
        stop.delete();
        LibraryLoader.loadWpiLibraries();
        var nt = NetworkTableInstance.create();
        nt.setServer("10.85.15.2");
        nt.startClient("quiet-off");
        var t = nt.getTable("photonvision").getSubTable("jetson");
        var pub = t.getBooleanTopic("quiet").publish();
        var now = t.getBooleanTopic("quietNow").subscribe(true);
        boolean said = false;
        long giveUp = System.currentTimeMillis() + 20_000;
        while (System.currentTimeMillis() < until && !stop.exists()) {
            pub.set(false);
            if (!said && nt.isConnected() && !now.get(true)) {
                System.out.println("holding");
                said = true;
            }
            if (!said && System.currentTimeMillis() > giveUp) {
                System.out.println("TIMEOUT: the Jetson didn't leave quiet mode within 20 s");
                System.exit(2);
            }
            Thread.sleep(200);
        }
        pub.close();
        nt.flush();
        Thread.sleep(300);
        nt.close();
        System.out.println("released");
    }
}
