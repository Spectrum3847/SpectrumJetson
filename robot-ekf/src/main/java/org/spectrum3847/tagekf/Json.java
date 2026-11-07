package org.spectrum3847.tagekf;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.TreeMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.wpilib.math.geometry.Pose3d;
import org.wpilib.math.geometry.Quaternion;
import org.wpilib.math.geometry.Rotation3d;
import org.wpilib.math.geometry.Translation3d;

/** The two JSON files the tools read (WPILib field layout, PhotonVision calibration), by regex. */
final class Json {
    private Json() {}

    private static final String NUM = "(-?[0-9.eE+-]+)";

    /** Tag id to field pose from a WPILib AprilTag layout. */
    static Map<Integer, Pose3d> layout(Path file) throws IOException {
        String s = Files.readString(file);
        Pattern p =
                Pattern.compile(
                        "\"ID\"\\s*:\\s*(\\d+)\\s*,\\s*\"pose\"\\s*:\\s*\\{\\s*\"translation\"\\s*:\\s*\\{\\s*"
                                + "\"x\"\\s*:\\s*" + NUM + "\\s*,\\s*\"y\"\\s*:\\s*" + NUM
                                + "\\s*,\\s*\"z\"\\s*:\\s*" + NUM
                                + "\\s*}\\s*,\\s*\"rotation\"\\s*:\\s*\\{\\s*\"quaternion\"\\s*:\\s*\\{\\s*"
                                + "\"W\"\\s*:\\s*" + NUM + "\\s*,\\s*\"X\"\\s*:\\s*" + NUM
                                + "\\s*,\\s*\"Y\"\\s*:\\s*" + NUM + "\\s*,\\s*\"Z\"\\s*:\\s*" + NUM);
        Matcher m = p.matcher(s);
        Map<Integer, Pose3d> out = new TreeMap<>();
        while (m.find()) {
            double[] v = new double[7];
            for (int i = 0; i < 7; i++) {
                v[i] = Double.parseDouble(m.group(i + 2));
            }
            out.put(
                    Integer.parseInt(m.group(1)),
                    new Pose3d(
                            new Translation3d(v[0], v[1], v[2]),
                            new Rotation3d(new Quaternion(v[3], v[4], v[5], v[6]))));
        }
        if (out.isEmpty()) {
            throw new IOException("no tags in " + file);
        }
        return out;
    }

    /** {fx, fy, cx, cy} and the distortion coefficients from a PhotonVision calibration. */
    static double[][] calibration(Path file) throws IOException {
        String s = Files.readString(file);
        double[] k = array(s, "cameraIntrinsics");
        double[] d = array(s, "distCoeffs");
        return new double[][] {{k[0], k[4], k[2], k[5]}, d};
    }

    private static double[] array(String s, String key) throws IOException {
        Matcher m =
                Pattern.compile("\"" + key + "\"\\s*:\\s*\\{[^}]*?\"data\"\\s*:\\s*\\[([^\\]]*)]")
                        .matcher(s);
        if (!m.find()) {
            throw new IOException("no " + key);
        }
        String[] parts = m.group(1).split(",");
        double[] out = new double[parts.length];
        for (int i = 0; i < parts.length; i++) {
            out[i] = Double.parseDouble(parts[i].trim());
        }
        return out;
    }
}
