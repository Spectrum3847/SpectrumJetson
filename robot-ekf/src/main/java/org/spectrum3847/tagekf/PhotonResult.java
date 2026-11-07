package org.spectrum3847.tagekf;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import org.wpilib.math.geometry.Translation3d;

/**
 * The parts of a PhotonVision {@code PhotonPipelineResult} (rawBytes, photonstruct) the EKF uses,
 * decoded without PhotonLib. Layout of the Spectrum fork (interface fd353b11...): metadata {int64
 * sequenceID, captureTimestampNanos, publishTimestampNanos, timeSinceLastPong}, then int8 count of
 * targets {float64 yaw, pitch, area, skew; int32 fiducialId, objDetectId; float32 objDetectConf;
 * Transform3d best, alt (x y z, qw qx qy qz); float64 poseAmbiguity; int8 n x (float64 x, y)
 * minAreaRectCorners; same for detectedCorners}, then the optional multi-tag result (ignored).
 * Little-endian.
 */
record PhotonResult(long sequence, double captureSeconds, List<Target> targets) {
    /** The struct interface this layout matches (the fork's PhotonPipelineResultSerde). */
    static final String INTERFACE = "fd353b11f3a818e9c5b457c7dc5a8f5c";

    /**
     * @param cameraToTag best solution's translation, camera frame (x out of the lens, y left, z up)
     * @param corners detected corners, u0 v0 .. u3 v3
     */
    record Target(int id, Translation3d cameraToTag, double ambiguity, double[] corners) {}

    static PhotonResult decode(byte[] raw) {
        ByteBuffer b = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        long seq = b.getLong();
        long captureNanos = b.getLong();
        b.getLong();
        b.getLong();
        int n = b.get();
        List<Target> out = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            b.position(b.position() + 4 * 8);
            int id = b.getInt();
            b.getInt();
            b.getFloat();
            Translation3d best = new Translation3d(b.getDouble(), b.getDouble(), b.getDouble());
            b.position(b.position() + 4 * 8 + 7 * 8);
            double amb = b.getDouble();
            int rect = b.get();
            b.position(b.position() + rect * 16);
            int nc = b.get();
            double[] c = new double[2 * nc];
            for (int k = 0; k < 2 * nc; k++) {
                c[k] = b.getDouble();
            }
            out.add(new Target(id, best, amb, c));
        }
        return new PhotonResult(seq, captureNanos * 1e-9, out);
    }
}
