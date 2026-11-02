"""Camera delay from rotation: each tag's bearing in the image against the bearing the robot's gyro
heading predicts, scanned over a time shift. See RESULTS.md "Camera delay from rotation".

  camera_delay.py REPLAY_DIR [--matches M1,M2..] [--variant base] [--boot 1000]

Why rotation: the gyro measures yaw with low latency and good accuracy, and a turn moves a tag
across the image fast (3 rad/s: 1 ms = 3 mrad = ~2 px at fx 740), while the fused pose's position
errors barely matter for a bearing. Why absolute bearings and not frame-to-frame changes: in a
steady turn a time shift moves every bearing by the same amount, so a difference cancels it; the
shift only shows where the turn rate changes. So each segment (one camera, one tag, contiguous
frames, <= SEG_S long) has its own constant offset removed (mount yaw, heading offset, tag
position error), and the shift is what's left to explain bearing against turn rate. A segment counts
only if its turn rate spans >= W_SPAN rad/s and reaches W_MIN somewhere.

Shift convention (as analyze.py's timing scan): the log's pose at robot_us + shift matches the
image. robot_us is the frame's ARRIVAL time on the robot clock (Rewind's frames table).
"""
import argparse
import glob
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
import fieldgt as g  # noqa: E402

try:
    import cv2
except ImportError:
    sys.exit("needs OpenCV (python3-opencv)")

ap = argparse.ArgumentParser()
ap.add_argument("root")
ap.add_argument("--matches", default="")
ap.add_argument("--variant", default="base")
ap.add_argument("--boot", type=int, default=1000)
ap.add_argument("--w-min", type=float, default=1.0, help="segment's peak |yaw rate|, rad/s")
ap.add_argument("--w-span", type=float, default=0.8, help="segment's yaw rate range, rad/s")
ap.add_argument("--speed-max", type=float, default=3.0, help="m/s, translation (odometry)")
ap.add_argument("--seg-s", type=float, default=3.0)
ap.add_argument("--min-side", type=float, default=20)
ap.add_argument("--heading", default="gyro", help="gyro (integrated yaw rate) or odom (logged pose heading)")
args = ap.parse_args()
P = print
SHIFTS = np.arange(-40, 40.01, 0.5)
TRIM = 0.03  # rad: residuals beyond this count as this (a misdetection or a bad segment)
rng = np.random.default_rng(1)

matches = sorted(os.path.basename(m) for m in glob.glob(os.path.join(args.root, "TXMAN1_*"))
                 if os.path.isdir(os.path.join(m, "out", args.variant)))
if args.matches:
    matches = [m for m in matches if m in args.matches.split(",")]
tags = g.load_layout("andymark")
centres = {k: v.mean(0) for k, v in tags.items()}


def wrap(a):
    return (a + np.pi) % (2 * np.pi) - np.pi


def measured_bearing(corners, K, dist, mount):
    """Tag centre's bearing (azimuth in the robot frame, rad) from the image: undistorted ray,
    turned by the mount's rotation. Corners: detector convention (pixel edges at whole numbers)."""
    c = corners.mean(1) - 0.5
    Km = np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]])
    n = cv2.undistortPoints(c.reshape(-1, 1, 2).astype(np.float64), Km, np.array(dist, np.float64)).reshape(-1, 2)
    ray = np.stack([np.ones(len(n)), -n[:, 0], -n[:, 1]], -1)  # OpenCV (x right, y down, z fwd) -> x fwd, y left, z up
    Rm = g.rot(*np.radians(mount[3:]))
    rr = ray @ Rm.T
    return np.arctan2(rr[:, 1], rr[:, 0])


class Heading:
    """Robot heading and position against the robot clock. heading "gyro": the logged yaw rate
    integrated (its constant offset doesn't matter: each segment's offset is removed)."""

    def __init__(self, robot, z, mode):
        self.r = robot
        self.mode = mode
        if mode == "gyro":
            t, w = z["yawrate_t"].astype(np.int64), z["yawrate"]
            th = np.concatenate([[0], np.cumsum(0.5 * (w[1:] + w[:-1]) * np.diff(t) / 1e6)])
            self.t, self.th = t, th

    def at(self, t_us):
        x, y, th, ok = self.r.at(t_us)
        if self.mode == "gyro":
            th = np.interp(t_us, self.t, self.th)
            ok &= (t_us >= self.t[0]) & (t_us <= self.t[-1])
        return x, y, th, ok


def predicted_bearing(ids, t_us, hd, mount):
    x, y, th, ok = hd.at(t_us)
    p = np.array([centres[i] for i in ids])
    dx, dy = p[:, 0] - x, p[:, 1] - y
    c, s = np.cos(th), np.sin(th)
    rx = c * dx + s * dy - mount[0]
    ry = -s * dx + c * dy - mount[1]
    return np.arctan2(ry, rx), ok


def segment_curves(d, cam, cal, hd, robot, mount):
    """Per segment: trimmed sum of squared demeaned residuals at each shift. Also counts."""
    K, dist, (W, H) = cal
    m = (d["camera"] == cam) & np.isin(d["id"], list(centres)) & (d["side"] >= args.min_side)
    m &= common.edge_dist(d["corners"], W, H) >= 10
    s = {k: v[m] for k, v in d.items()}
    if len(s["id"]) < 50:
        return None
    order = np.lexsort((s["robot_us"], s["id"], s["session"]))
    s = {k: v[order] for k, v in s.items()}
    t = s["robot_us"].astype(float)
    speed, w = robot.motion(t)
    az = measured_bearing(s["corners"], K, dist, mount)
    # Segments: same session and tag, gaps < 0.1 s, at most seg_s long, translation slow-ish.
    new = np.ones(len(t), bool)
    new[1:] = (s["session"][1:] != s["session"][:-1]) | (s["id"][1:] != s["id"][:-1]) | (np.diff(t) > 1e5)
    seg = np.cumsum(new) - 1
    start = t[np.r_[np.flatnonzero(new)]][seg]
    seg = seg * 1000 + ((t - start) // (args.seg_s * 1e6)).astype(int)
    keep = speed <= args.speed_max
    segs = []
    for u in np.unique(seg[keep]):
        i = np.flatnonzero((seg == u) & keep)
        if len(i) >= 8 and np.max(np.abs(w[i])) >= args.w_min and np.ptp(w[i]) >= args.w_span:
            segs.append(i)
    if not segs:
        return None
    curves = np.zeros((len(segs), len(SHIFTS)))
    allidx = np.concatenate(segs)
    for k, sh in enumerate(SHIFTS):
        pr, ok = predicted_bearing(s["id"][allidx], t[allidx] + sh * 1000, hd, mount)
        r = wrap(az[allidx] - pr)
        r[~ok] = 0
        pos = 0
        for j, i in enumerate(segs):
            rr = r[pos:pos + len(i)]
            pos += len(i)
            rr = rr - np.median(rr)
            curves[j, k] = np.sum(np.minimum(rr * rr, TRIM * TRIM)) / len(i)
    n = np.array([len(i) for i in segs])
    return curves, n, float(np.median(np.abs(w[allidx])))


def best(curve):
    k = int(np.argmin(curve))
    if 0 < k < len(curve) - 1:  # parabola through the minimum and its neighbours
        a, b, c = curve[k - 1], curve[k], curve[k + 1]
        den = a - 2 * b + c
        off = 0.5 * (a - c) / den if den > 0 else 0
        return SHIFTS[k] + off * (SHIFTS[1] - SHIFTS[0])
    return SHIFTS[k]


def estimate(curves, n):
    wts = n[:, None]
    est = best((curves * wts).sum(0) / n.sum())
    boots = []
    for _ in range(args.boot):
        j = rng.integers(0, len(n), len(n))
        boots.append(best((curves[j] * wts[j]).sum(0) / n[j].sum()))
    lo, hi = np.percentile(boots, [2.5, 97.5])
    c = (curves * wts).sum(0) / n.sum()
    depth = 1 - c.min() / c[np.abs(SHIFTS) <= 40].max()
    return est, lo, hi, depth


P(f"Camera delay from rotation: heading {args.heading}, segments <= {args.seg_s} s with |w| peak >= {args.w_min} "
  f"and span >= {args.w_span} rad/s, speed <= {args.speed_max} m/s, tags >= {args.min_side} px; "
  f"shift scan {SHIFTS[0]:+.0f}..{SHIFTS[-1]:+.0f} ms step 0.5; 95% CIs: {args.boot} bootstraps over segments")
pooled = {}
for match in matches:
    mdir = os.path.join(args.root, match)
    frames = common.load_frames(mdir)
    cal, _ = common.calibrations(mdir)
    z = np.load(os.path.join(mdir, "robot.npz"))
    robot = g.Robot(os.path.join(mdir, "robot.npz"))
    hd = Heading(robot, z, args.heading)
    d = common.concat([common.load_dets(f, os.path.basename(f)[:-4], frames)
                       for f in sorted(glob.glob(os.path.join(mdir, "out", args.variant, "*.csv")))])
    if d is None:
        continue
    # The gyro rate against the logged heading's own rate: their relative lag (ms).
    if "yawrate_t" in z and "odom_t" in z:
        ot, oth = z["odom_t"].astype(float), np.unwrap(z["odom"][:, 2])
        tt = np.arange(ot[0] + 1e6, ot[-1] - 1e6, 5000.0)
        wo = np.gradient(np.interp(tt, ot, oth), tt / 1e6)
        lags = np.arange(-40, 40.5, 0.5)
        err = [np.mean((np.interp(tt + L * 1000, z["yawrate_t"], z["yawrate"]) - wo) ** 2) for L in lags]
        lag_note = f"gyro rate vs odometry heading rate: best lag {lags[int(np.argmin(err))]:+.1f} ms; " \
                   f"yaw rate logged every {np.median(np.diff(z['yawrate_t'])) / 1000:.1f} ms, odometry every {np.median(np.diff(ot)) / 1000:.1f} ms"
    else:
        lag_note = ""
    P(f"\n=== {match}  {lag_note}")
    for cam in sorted(cal):
        r = segment_curves(d, cam, cal[cam], hd, robot, g.MOUNTS["cad"][cam])
        if r is None:
            P(f"  {cam}: no turning segments")
            continue
        curves, n, wmed = r
        est, lo, hi, depth = estimate(curves, n)
        P(f"  {cam}: {len(n)} segments, {n.sum()} sightings, median |w| {wmed:.1f} rad/s: "
          f"shift {est:+.1f} ms (95% CI {lo:+.1f} .. {hi:+.1f}), minimum depth {depth * 100:.0f}%")
        pooled.setdefault(cam, []).append((curves, n))
        pooled.setdefault("all", []).append((curves, n))

P("\n=== pooled (all matches)")
for cam, lst in pooled.items():
    curves = np.concatenate([c for c, _ in lst])
    n = np.concatenate([x for _, x in lst])
    est, lo, hi, depth = estimate(curves, n)
    P(f"  {cam}: {len(n)} segments, {n.sum()} sightings: shift {est:+.1f} ms (95% CI {lo:+.1f} .. {hi:+.1f}), depth {depth * 100:.0f}%")
