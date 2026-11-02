"""Ground truth for tag sightings: where each tag's corners should be in the image, from the
robot's logged pose, the camera's mount, its calibration and the field layout.

Conventions:
- WPILib field/robot/camera frames: x forward, y left, z up. Rotation3d(roll, pitch, yaw) =
  Rz(yaw) Ry(pitch) Rx(roll).
- Tag frame (WPILib layouts): x out of the tag's face, z up; seen from the front, +y is the
  viewer's right. Corners in the detector's order: bottom-left, bottom-right, top-right, top-left
  (as seen in the image), which is what PhotonVision assumes; check_corner_order() verifies it.
- Pixels: OpenCV's convention (pixel centres at whole numbers). The 971 detector (and detector-replay)
  reports corners with pixel edges at whole numbers, so OpenCV = detector - 0.5 (`half_px`).
"""
import json
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TAG_SIZE = 0.1651  # m, 2026 tags (6.5 in)
LAYOUTS = {
    "andymark": os.path.join(REPO, "tools/fieldcal/layouts/2026-rebuilt-andymark.json"),
    "welded": os.path.join(REPO, "tools/fieldcal/layouts/2026-rebuilt-welded.json"),
}

# FM's robot-to-camera mounts (Spectrum3847/2026-FM-SystemCore Vision.java): x, y, z (m),
# roll, pitch, yaw (deg). "placeholder" was in the code during Friday's matches (06eab78);
# "cad" from 3ab436b (Saturday on: CAD positions, left pitch measured from Q17 video).
MOUNTS = {
    "placeholder": {"orin-left": [0.0, 0.30, 0.25, 0, -15, 90], "orin-right": [0.0, -0.30, 0.25, 0, -15, -90]},
    "cad": {"orin-left": [0.0836, 0.3231, 0.4883, 0, -18, 90], "orin-right": [0.0836, -0.3231, 0.4883, 0, -18, -84.5]},
}


def rot(roll, pitch, yaw):
    cr, sr, cp, sp, cy, sy = np.cos(roll), np.sin(roll), np.cos(pitch), np.sin(pitch), np.cos(yaw), np.sin(yaw)
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
    ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]])
    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
    return rz @ ry @ rx


def quat_to_R(w, x, y, z):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def load_layout(name):
    js = json.load(open(LAYOUTS[name]))
    s = TAG_SIZE / 2
    local = np.array([[0, -s, -s], [0, s, -s], [0, s, s], [0, -s, s]])  # BL, BR, TR, TL
    tags = {}
    for t in js["tags"]:
        p = t["pose"]
        tr = p["translation"]
        q = p["rotation"]["quaternion"]
        R = quat_to_R(q["W"], q["X"], q["Y"], q["Z"])
        tags[t["ID"]] = (local @ R.T) + np.array([tr["x"], tr["y"], tr["z"]])
    return tags


def project(Pc_cv, K, dist):
    """OpenCV's projection (rational model, 8 coefficients) of camera-frame points (N,3), OpenCV axes."""
    fx, fy, cx, cy = K
    k = list(dist) + [0] * (8 - len(dist))
    k1, k2, p1, p2, k3, k4, k5, k6 = k[:8]
    z = Pc_cv[..., 2]
    x = Pc_cv[..., 0] / z
    y = Pc_cv[..., 1] / z
    r2 = x * x + y * y
    rad = (1 + k1 * r2 + k2 * r2 ** 2 + k3 * r2 ** 3) / (1 + k4 * r2 + k5 * r2 ** 2 + k6 * r2 ** 3)
    xd = x * rad + 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
    yd = y * rad + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
    return np.stack([fx * xd + cx, fy * yd + cy], -1), z


def camera_points(P_field, rx, ry, rth, mount):
    """Field points (N,4,3) seen from a camera on a robot at (rx, ry, rth) (arrays of N): OpenCV
    camera-frame coordinates (N,4,3)."""
    mx, my, mz, mr, mp, myaw = mount
    Rm = rot(np.radians(mr), np.radians(mp), np.radians(myaw))
    c, s = np.cos(rth), np.sin(rth)
    # Point relative to the robot, in the robot frame.
    d = P_field - np.stack([rx, ry, np.zeros_like(rx)], -1)[:, None, :]
    pr = np.stack([c[:, None] * d[..., 0] + s[:, None] * d[..., 1],
                   -s[:, None] * d[..., 0] + c[:, None] * d[..., 1], d[..., 2]], -1)
    pc = (pr - np.array([mx, my, mz])) @ Rm  # = Rm^T (pr - t)
    return np.stack([-pc[..., 1], -pc[..., 2], pc[..., 0]], -1)


class Robot:
    """The robot's logged pose (prep.py's robot.npz), interpolated, on the robot's clock (us).

    mode "fused": the fused pose as logged. mode "odom" (default): wheel odometry + gyro for the
    motion, placed on the field by the fused pose's offset from odometry, smoothed over `smooth_s`
    (a running median). Vision corrections make the fused pose jump and lag; odometry is smooth
    and its gyro heading is good to a fraction of a degree over seconds, so short-term motion
    (and timing) comes from it, the absolute position from the fused pose.
    """

    def __init__(self, path, mode="odom", smooth_s=2.0):
        z = np.load(path)
        self.t = z["fused_t"].astype(np.int64)
        p = z["fused"]
        x, y, th = p[:, 0], p[:, 1], np.unwrap(p[:, 2])
        if mode == "odom" and "odom_t" in z and len(z["odom_t"]) > 100:
            ot = z["odom_t"].astype(np.int64)
            o = z["odom"]
            oth = np.unwrap(o[:, 2])
            ox, oy, oth_f = np.interp(self.t, ot, o[:, 0]), np.interp(self.t, ot, o[:, 1]), np.interp(self.t, ot, oth)
            dth = th - oth_f
            c, s_ = np.cos(dth), np.sin(dth)
            dx = x - (c * ox - s_ * oy)
            dy = y - (s_ * ox + c * oy)
            # Running median over smooth_s (records are ~10 ms apart).
            n = max(1, int(smooth_s / max(np.median(np.diff(self.t)) / 1e6, 1e-3)) // 2)
            def rmed(a):
                from numpy.lib.stride_tricks import sliding_window_view
                pad = np.pad(a, n, mode="edge")
                return np.median(sliding_window_view(pad, 2 * n + 1), axis=-1)
            dth, dx, dy = rmed(dth), rmed(dx), rmed(dy)
            # Back on odometry's own clock and rate, so the motion keeps odometry's timing.
            self.t = ot
            dth, dx, dy = (np.interp(ot, z["fused_t"], a) for a in (dth, dx, dy))
            c, s_ = np.cos(dth), np.sin(dth)
            x = c * o[:, 0] - s_ * o[:, 1] + dx
            y = s_ * o[:, 0] + c * o[:, 1] + dy
            th = oth + dth
        self.mode = mode
        self.x, self.y, self.th = x, y, th
        dt = np.gradient(self.t / 1e6)
        dt[dt <= 0] = 0.01
        self.vx = np.gradient(self.x) / dt
        self.vy = np.gradient(self.y) / dt
        self.w = np.gradient(self.th) / dt
        if "yawrate_t" in z:
            self.gyro_t, self.gyro = z["yawrate_t"], z["yawrate"]
        else:
            self.gyro_t = None
        self.enabled_t = z["enabled_t"] if "enabled_t" in z else None
        self.enabled = z["enabled"] if "enabled" in z else None

    def at(self, t_us):
        t = np.asarray(t_us, dtype=float)
        ok = (t >= self.t[0]) & (t <= self.t[-1])
        x = np.interp(t, self.t, self.x)
        y = np.interp(t, self.t, self.y)
        th = np.interp(t, self.t, self.th)
        return x, y, th, ok

    def motion(self, t_us):
        t = np.asarray(t_us, dtype=float)
        speed = np.hypot(np.interp(t, self.t, self.vx), np.interp(t, self.t, self.vy))
        w = np.interp(t, self.t, self.w)
        if self.gyro_t is not None and len(self.gyro_t):
            w = np.interp(t, self.gyro_t, self.gyro)
        return speed, w

    def is_enabled(self, t_us):
        if self.enabled is None:
            return np.ones(np.shape(t_us), bool)
        i = np.searchsorted(self.enabled_t, t_us, side="right") - 1
        return (i >= 0) & (self.enabled[np.clip(i, 0, None)] > 0.5)


def corner_errors(det, proj):
    """det, proj (N,4,2). Returns total rms corner error, centroid error, shape error (px)."""
    e = det - proj
    total = np.sqrt(np.mean(np.sum(e * e, -1), -1))
    cen = np.linalg.norm(e.mean(1), axis=-1)
    es = e - e.mean(1, keepdims=True)
    shape = np.sqrt(np.mean(np.sum(es * es, -1), -1))
    return total, cen, shape


def predict(sight, robot, tags, mount, K, dist, shift_us=0.0):
    """Projected corners (N,4,2) for sightings (dict of arrays: id, robot_us). Also a validity mask
    (pose known, tag known, all corners in front of the camera)."""
    n = len(sight["id"])
    rx, ry, rth, ok = robot.at(sight["robot_us"] + shift_us)
    P = np.zeros((n, 4, 3))
    known = np.array([i in tags for i in sight["id"]])
    for i in np.unique(sight["id"]):
        if i in tags:
            P[sight["id"] == i] = tags[i]
    pc = camera_points(P, rx, ry, rth, mount)
    uv, z = project(pc, K, dist)
    valid = ok & known & np.all(z > 0.05, -1)
    return uv, valid, np.linalg.norm(pc.mean(1), axis=-1)
