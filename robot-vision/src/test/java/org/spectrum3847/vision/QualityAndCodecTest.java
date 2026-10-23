package org.spectrum3847.vision;

import static org.junit.jupiter.api.Assertions.*;
import static org.spectrum3847.vision.TestField.*;

import edu.wpi.first.math.geometry.Pose3d;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.spectrum3847.vision.io.TagQualityEstimator;
import org.spectrum3847.vision.io.TagQualityMatcher;
import org.spectrum3847.vision.observation.ObservationCodec;

class QualityAndCodecTest {
    @Test
    void undistortInvertsDistort() {
        var cam = camera("c");
        var lens = new TagQualityEstimator(cam.cameraMatrix(), cam.distCoeffs);
        for (double u = 20; u < 1280; u += 200) {
            for (double v = 20; v < 800; v += 150) {
                double[] d = lens.distort(u, v);
                double[] back = lens.undistort(d[0], d[1]);
                // With the real Thriftiest Cam lens, undistort's 20 iterations reach ~2e-4 px at the corners.
                assertEquals(u, back[0], 1e-3);
                assertEquals(v, back[1], 1e-3);
            }
        }
    }

    @Test
    void robotSideQualityOnAPerfectFrame() {
        var cam = camera("c");
        cam.multiTag = false;
        var frame = cam.frame(FIELD, new Pose3d(facingWall(2.5, 4.0)), FRONT, 1.0);
        for (var t : frame.tags()) {
            assertEquals(0, t.reprojBestPx(), 1e-6, "noise-free corners fit the true pose exactly");
            assertTrue(t.reprojAltPx() > 1, "the wrong solution doesn't fit");
            assertTrue(t.edgePx() >= 0 && t.edgePx() < 640);
            assertTrue(t.undistortPx() > 0, "this lens has distortion");
            assertTrue(Double.isNaN(t.decisionMargin()), "only the Jetson knows the margin");
        }
    }

    @Test
    void jetsonQualityMatchesBySequenceId() {
        var cam = camera("TopLeft");
        var frame = cam.frame(FIELD, new Pose3d(facingWall(3, 4)), FRONT, 1.0);
        var m = new TagQualityMatcher();
        // [seq, n, (id, margin, edge, undistort, reprojBest, reprojAlt) x n], tags in any order
        int n = frame.tags().size();
        double[] q = new double[2 + 6 * n];
        q[0] = frame.sequenceId();
        q[1] = n;
        for (int i = 0; i < n; i++) {
            var t = frame.tags().get(n - 1 - i);
            System.arraycopy(new double[] {t.id(), 100 + t.id(), 50, 1.5, 0.3, 4.0}, 0, q, 2 + 6 * i, 6);
        }
        m.offer(new double[] {frame.sequenceId() + 99, 0}); // another frame's
        m.offer(q);
        var filled = m.apply(frame);
        for (var t : filled.tags()) {
            assertEquals(100 + t.id(), t.decisionMargin());
            assertEquals(50, t.edgePx());
            assertEquals(0.3, t.reprojBestPx());
        }
        assertEquals(1, m.matchedCount());
        assertSame(frame, m.apply(frame), "used once");
        m.offer(new double[] {1, 2, 3}); // malformed: ignored
    }

    @Test
    void codecRoundTrip() {
        var cam = camera("TopLeft");
        var a = cam.frame(FIELD, new Pose3d(facingWall(3, 4)), FRONT, 1.0);
        cam.multiTag = false;
        var b = cam.frame(FIELD, new Pose3d(facingWall(2.4, 3.5)), FRONT, 1.02);
        var back = ObservationCodec.decode("TopLeft", ObservationCodec.encode(List.of(a, b)));
        assertEquals(2, back.size());
        for (int k = 0; k < 2; k++) {
            var x = List.of(a, b).get(k);
            var y = back.get(k);
            assertEquals(x.sequenceId(), y.sequenceId());
            assertEquals(x.timestampSeconds(), y.timestampSeconds());
            assertEquals(x.hasMultiTag(), y.hasMultiTag());
            assertEquals(x.multiTagIds(), y.multiTagIds());
            assertEquals(x.tags().size(), y.tags().size());
            for (int i = 0; i < x.tags().size(); i++) {
                var s = x.tags().get(i);
                var t = y.tags().get(i);
                assertEquals(s.id(), t.id());
                assertEquals(s.bestCameraToTag(), t.bestCameraToTag());
                assertEquals(s.reprojAltPx(), t.reprojAltPx(), 1e-12);
                assertArrayEquals(s.corners(), t.corners(), 1e-12);
            }
        }
        assertTrue(ObservationCodec.decode("x", new double[] {7, 1}).isEmpty(), "unknown version");
        assertTrue(ObservationCodec.decode("x", new double[] {1, 3, 5}).isEmpty(), "truncated");
    }
}
