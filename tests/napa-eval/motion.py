"""Blur check: each variant against the base (GPU detector) by how fast the tag moves in the image, and by
robot speed. NAPA's README names motion blur as its weakness.

  python3 tests/napa-eval/motion.py REPLAY_DIR [--base d15s_far] [--variants napa,napa16,...]

Image motion of a sighting: the tag centroid's step from the previous frame of the same camera, from
whichever detector saw the tag in both frames (base first), px/frame. Robot motion: odometry speed (m/s)
and gyro yaw rate (rad/s) at the frame (fieldgt.Robot). Per bin:
  base     sightings the base found
  found    of those, the share the variant also found (recall vs the GPU detector)
  extra    sightings the variant found that the base did not
  |d| p50  median corner distance variant vs base on the common ones (px)
"""
import argparse
import glob
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "field-replay"))
import common  # noqa: E402
import fieldgt as g  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("root")
ap.add_argument("--base", default="d15s_far")
ap.add_argument("--variants", default="napa,napa22,napa16,napa_h3,at3_d2,at3_d1")
args = ap.parse_args()


def load(mdir, v, frames):
    ds = [common.load_dets(f, os.path.basename(f)[:-4], frames) for f in sorted(glob.glob(os.path.join(mdir, "out", v, "*.csv")))]
    d = common.concat(ds)
    out = {}
    if d is None:
        return out
    for i in range(len(d["id"])):
        k = (str(d["session"][i]), str(d["camera"][i]), int(d["frame"][i]), int(d["id"][i]))
        out.setdefault(k, (d["corners"][i], int(d["robot_us"][i])))
    return out


IMG_BINS = [(0, 1), (1, 3), (3, 8), (8, 20), (20, 1e9)]
SPD_BINS = [("still (<0.1 m/s, <0.2 rad/s)", 0), ("moving (0.1-1.5 m/s)", 1), ("fast (>1.5 m/s or >2 rad/s)", 2)]
variants = [v for v in args.variants.split(",") if v]
acc = {v: {} for v in variants}
for mdir in sorted(glob.glob(os.path.join(args.root, "TXMAN1_*"))):
    if not os.path.isdir(os.path.join(mdir, "out", args.base)):
        continue
    frames = common.load_frames(mdir)
    base = load(mdir, args.base, frames)
    robot = g.Robot(os.path.join(mdir, "robot.npz"))
    vs = {v: load(mdir, v, frames) for v in variants}

    def step(k, srcs):
        s, c, f, i = k
        for src in srcs:
            a, b = src.get(k), src.get((s, c, f - 1, i))
            if a is not None and b is not None:
                return float(np.linalg.norm(a[0].mean(0) - b[0].mean(0)))
        return np.nan

    def spd_bin(t):
        sp, w = robot.motion(t)
        if sp > 1.5 or abs(w) > 2:
            return 2
        return 0 if sp < 0.1 and abs(w) < 0.2 else 1

    for v in variants:
        V = vs[v]
        for k, (c, t) in base.items():
            st, sb = step(k, [base, V]), spd_bin(t)
            hit = k in V
            d = float(np.median(np.linalg.norm(V[k][0] - c, axis=1))) if hit else np.nan
            acc[v].setdefault("rows", []).append((st, sb, 1, hit, d))
        for k, (c, t) in V.items():
            if k not in base:
                acc[v]["rows"].append((step(k, [V, base]), spd_bin(t), 0, 1, np.nan))

for v in variants:
    r = np.array(acc[v].get("rows", []), dtype=float)
    if not len(r):
        continue
    print(f"\n== {v} vs {args.base}")
    print(f"{'bin':34s} {'base':>7s} {'found':>7s} {'extra':>7s} {'|d| p50':>8s} {'|d| p90':>8s}")

    def line(name, m):
        b = m & (r[:, 2] == 1)
        e = m & (r[:, 2] == 0)
        d = r[b & (r[:, 3] == 1), 4]
        p50 = f"{np.median(d):8.3f}" if len(d) else "       -"
        p90 = f"{np.percentile(d, 90):8.3f}" if len(d) else "       -"
        print(f"{name:34s} {b.sum():7d} {100 * r[b, 3].mean() if b.sum() else 0:6.1f}% {e.sum():7d} {p50} {p90}")

    for lo, hi in IMG_BINS:
        line(f"image step {lo:g}-{hi:g} px/frame" if hi < 1e9 else f"image step {lo:g}+ px/frame",
             (r[:, 0] >= lo) & (r[:, 0] < hi))
    line("image step unknown (no prev frame)", np.isnan(r[:, 0]))
    for name, b in SPD_BINS:
        line(name, r[:, 1] == b)
    line("all", np.ones(len(r), bool))
