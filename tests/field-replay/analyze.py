"""Field replay analysis: every detector variant's sightings against ground truth from the robot's
logged pose. See RESULTS.md for what it answers and run.sh for how it's run.

  analyze.py REPLAY_DIR [--matches M1,M2..] > report.txt

REPLAY_DIR/<match>/ holds prep.py's output and out/<variant>/<session>.{csv,log} from detector-replay.
"""
import argparse
import glob
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
import fieldgt as g  # noqa: E402

try:
    import cv2
except ImportError:
    cv2 = None
try:
    from scipy.optimize import least_squares
except ImportError:
    least_squares = None

ap = argparse.ArgumentParser()
ap.add_argument("root")
ap.add_argument("--matches", default="")
ap.add_argument("--base", default="base")
ap.add_argument("--json", default="")
ap.add_argument("--variants", default="", help="only these variants (comma list; the base always)")
ap.add_argument("--compare", default="", help="variants to compare with the base by size and range (far sightings included)")
ap.add_argument("--pose", default="odom", help="odom (default) or fused: see fieldgt.Robot")
args = ap.parse_args()
P = print
summary = {}

matches = sorted(os.path.basename(m) for m in glob.glob(os.path.join(args.root, "TXMAN1_*")) if os.path.isdir(os.path.join(m, "out")))
if args.matches:
    matches = [m for m in matches if m in args.matches.split(",")]


def load_variant(mdir, variant, frames):
    ds, times = [], []
    for f in sorted(glob.glob(os.path.join(mdir, "out", variant, "*.csv"))):
        sess = os.path.basename(f)[:-4]
        ds.append(common.load_dets(f, sess, frames))
        log = f[:-4] + ".log"
        if os.path.exists(log):
            t = open(log).read()
            m = re.search(r"Time: detect ([\d.]+) ms a frame, far search ([\d.]+) ms", t)
            n = re.search(r"(\d+) cameras, (\d+) frames", t)
            if m and n:
                times.append((float(m.group(1)), float(m.group(2)), int(n.group(2))))
    d = common.concat(ds)
    tm = None
    if times:
        w = np.array([t[2] for t in times], float)
        tm = (np.average([t[0] for t in times], weights=w), np.average([t[1] for t in times], weights=w), int(w.sum()))
    return d, tm


def key(d):
    return np.array([f"{s}|{c}|{f}|{i}" for s, c, f, i in zip(d["session"], d["camera"], d["frame"], d["id"])])


# ---------------------------------------------------------------------------------------------
# Ground truth per match: corner order, field, mounts, time shift, errors.
CORNER_PERM = None  # detector order -> fieldgt's BL, BR, TR, TL; found on the first match


def perms():
    out = []
    for rev in (False, True):
        for r in range(4):
            idx = list(range(4))[::-1] if rev else list(range(4))
            out.append((rev, r, np.roll(idx, r)))
    return out


def solve_mount_pnp(s, det_cv, robot, tags, K, dist):
    """Per-sighting camera pose from the tag (SQPnP) combined with the robot pose: the median
    robot-to-camera transform. det_cv: corners in OpenCV's convention, fieldgt's order."""
    Km = np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]])
    x, y, th, ok = robot.at(s["robot_us"])
    sp, w = robot.motion(s["robot_us"])
    est = []
    for i in np.flatnonzero(ok & (s["side"] > 35) & (sp < 0.5) & (np.abs(w) < 0.5)):
        if s["id"][i] not in tags:
            continue
        okp, rv, tv = cv2.solvePnP(np.ascontiguousarray(tags[s["id"][i]], np.float64), np.ascontiguousarray(det_cv[i], np.float64), Km, np.array(dist), flags=cv2.SOLVEPNP_SQPNP)
        if not okp:
            continue
        R, _ = cv2.Rodrigues(rv)
        cam = (-R.T @ tv).ravel()
        Rf = np.stack([R.T[:, 2], -R.T[:, 0], -R.T[:, 1]], 1)
        c, sn = np.cos(th[i]), np.sin(th[i])
        Rr = np.array([[c, -sn, 0], [sn, c, 0], [0, 0, 1]])
        t = Rr.T @ (cam - np.array([x[i], y[i], 0]))
        Rc = Rr.T @ Rf
        est.append([*t, np.degrees(np.arctan2(Rc[2, 1], Rc[2, 2])), np.degrees(-np.arcsin(np.clip(Rc[2, 0], -1, 1))),
                    np.degrees(np.arctan2(Rc[1, 0], Rc[0, 0]))])
    est = np.array(est)
    if len(est) < 10:
        return None, len(est)
    return np.median(est, 0), len(est)


def refine_mount(s, det_cv, robot, tags, K, dist, p0):
    sp, w = robot.motion(s["robot_us"])
    m = (sp < 0.5) & (np.abs(w) < 0.5)
    s2 = {k: v[m] for k, v in s.items()}
    d2 = det_cv[m]
    if least_squares is None or m.sum() < 20:
        return p0

    def res(p):
        uv, val, _ = g.predict(s2, robot, tags, p, K, dist)
        r = d2 - uv
        r[~val] = 0
        return np.clip(r, -300, 300).ravel()

    return least_squares(res, p0, loss="soft_l1", f_scale=10, x_scale=[0.05, 0.05, 0.05, 2, 2, 2]).x


def to_cv(corners, half=True):
    c = corners[:, CORNER_PERM[2]] if CORNER_PERM is not None else corners
    return c - 0.5 if half else c


def pct(a, q):
    a = np.asarray(a, float)
    a = a[np.isfinite(a)]
    return np.percentile(a, q) if len(a) else float("nan")


allrows = {}   # variant -> list of per-sighting dicts (concatenated across matches)
times = {}     # variant -> list of (detect ms, far ms, frames)
info = {}
def still_error(s, det, robot, tags, mount, K, dist):
    uv, val, _ = g.predict(s, robot, tags, mount, K, dist)
    sp, w = robot.motion(s["robot_us"])
    still = val & (sp < 0.5) & (np.abs(w) < 0.5)
    e = g.corner_errors(det, uv)[0][still]
    return float(np.median(e)) if len(e) > 20 else float("inf")


def loo_errors(d, cal, tags):
    """In-frame ground truth, independent of the robot's pose: each tag's corners reprojected from
    the camera pose solved (SQPnP) from the OTHER tags in the same frame, rms px. NaN where the
    other tags aren't enough (fewer than two, or one smaller than 40 px)."""
    out = np.full(len(d["id"]), np.nan)
    if cv2 is None:
        return out
    groups = {}
    for i, k in enumerate(zip(d["session"], d["camera"], d["frame"])):
        if d["id"][i] in tags:
            groups.setdefault(k, []).append(i)
    for (sess, cam, fr), idx in groups.items():
        if len(idx) < 2:
            continue
        K, dist, _ = cal[cam]
        Km = np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]])
        dc = np.array(dist, np.float64)
        det = to_cv(d["corners"][idx])
        for j, i in enumerate(idx):
            others = [o for o in range(len(idx)) if o != j]
            if len(others) < 2 and d["side"][idx[others[0]]] < 40:
                continue
            obj = np.concatenate([tags[d["id"][idx[o]]] for o in others]).astype(np.float64)
            img = np.concatenate([det[o] for o in others]).astype(np.float64)
            try:
                ok, rv, tv = cv2.solvePnP(obj, img, Km, dc, flags=cv2.SOLVEPNP_SQPNP)
                if not ok:
                    continue
                pr, _ = cv2.projectPoints(np.ascontiguousarray(tags[d["id"][i]], np.float64), rv, tv, Km, dc)
            except cv2.error:
                continue
            out[i] = np.sqrt(np.mean(np.sum((pr.reshape(4, 2) - det[j]) ** 2, -1)))
    return out


def timing_scan(s, robot, tags, mount, K, dist, shifts):
    """Frame-to-frame motion of each tag's centre (same camera, tag, consecutive recorded frames)
    against the motion the robot's odometry predicts with the frame times shifted by each shift.
    A constant pose error cancels in the difference, so this measures timing, not position."""
    order = np.lexsort((s["frame"], s["id"], s["camera"], s["session"]))
    a, b = order[:-1], order[1:]
    pair = ((s["session"][a] == s["session"][b]) & (s["camera"][a] == s["camera"][b]) & (s["id"][a] == s["id"][b])
            & (s["frame"][b] == s["frame"][a] + 1))
    a, b = a[pair], b[pair]
    _, w = robot.motion(s["robot_us"][a])
    sp, _ = robot.motion(s["robot_us"][a])
    moving = (np.abs(w) > 0.5) | (sp > 0.5)
    a, b = a[moving], b[moving]
    if len(a) < 30:
        return None, len(a)
    det = to_cv(s["corners"])
    dd = det[b].mean(1) - det[a].mean(1)
    res = []
    for sh in shifts:
        sa = {k: v[a] for k, v in s.items()}
        sb = {k: v[b] for k, v in s.items()}
        ua, va, _ = g.predict(sa, robot, tags, mount, K, dist, sh * 1000)
        ub, vb, _ = g.predict(sb, robot, tags, mount, K, dist, sh * 1000)
        e = np.linalg.norm(dd - (ub.mean(1) - ua.mean(1)), axis=-1)[va & vb]
        res.append((float(np.median(e)), float(sh)))
    return res, len(a)


# Pass 1: per match, the corner order, field fit and each camera's mount solved from that match.
M = {}
for match in matches:
    mdir = os.path.join(args.root, match)
    frames = common.load_frames(mdir)
    cal, caminfo = common.calibrations(mdir)
    robot = g.Robot(os.path.join(mdir, "robot.npz"), mode=args.pose)
    base, tm = load_variant(mdir, args.base, frames)
    if base is None:
        continue
    P(f"\n=== {match}: {len(base['id'])} sightings in {args.base}")
    if CORNER_PERM is None:
        tags = g.load_layout("andymark")
        best = None
        for p in perms():
            errs = []
            for cam in cal:
                m = base["camera"] == cam
                s = {k: v[m] for k, v in base.items()}
                uv, val, _ = g.predict(s, robot, tags, g.MOUNTS["cad"][cam], cal[cam][0], cal[cam][1])
                errs.append(g.corner_errors(s["corners"][:, p[2]] - 0.5, uv)[2][val])
            e = np.median(np.concatenate(errs))
            P(f"  corner order reversed={p[0]} roll={p[1]}: median shape error {e:.1f} px")
            if best is None or e < best[0]:
                best = (e, p)
        CORNER_PERM = best[1]
        P(f"  -> corner order reversed={CORNER_PERM[0]} roll={CORNER_PERM[1]}")
    own = {}
    for lay in ("andymark", "welded"):
        tags = g.load_layout(lay)
        for cam in cal:
            m = base["camera"] == cam
            s = {k: v[m] for k, v in base.items()}
            K, dist, _ = cal[cam]
            det = to_cv(s["corners"])
            p0, n = solve_mount_pnp(s, det, robot, tags, K, dist)
            if p0 is None:
                p0 = np.array(g.MOUNTS["cad"][cam], float)
            pm = refine_mount(s, det, robot, tags, K, dist, p0)
            own[(lay, cam)] = (pm, still_error(s, det, robot, tags, pm, K, dist))
    M[match] = dict(mdir=mdir, frames=frames, cal=cal, caminfo=caminfo, robot=robot, base=base, tm=tm, own=own)

# Pass 2: per match, pick field and mounts (own or reference, whichever fits better), then timing,
# the half pixel, and every variant's sightings.
pose_ok = {}
for match, mm in M.items():
    frames, cal, caminfo, robot, base, tm, mdir = (mm[k] for k in ("frames", "cal", "caminfo", "robot", "base", "tm", "mdir"))
    P(f"\n=== {match}")
    fits = {}
    for lay in ("andymark", "welded"):
        tags = g.load_layout(lay)
        mounts, errs = {}, []
        for cam in cal:
            m = base["camera"] == cam
            s = {k: v[m] for k, v in base.items()}
            K, dist, _ = cal[cam]
            det = to_cv(s["corners"])
            # Each match's own solution: a joint solve over the matches doesn't converge (the
            # robot pose's errors differ from match to match, and orin-right's seems to have moved).
            cands = [("own", mm["own"][(lay, cam)][0])]
            ev = [(still_error(s, det, robot, tags, p, K, dist), nm, p) for nm, p in cands]
            ev.sort(key=lambda x: x[0])
            mounts[cam] = (ev[0][2], ev[0][1], ev[0][0])
            errs.append(ev[0][0])
        fits[lay] = (float(np.mean(errs)), mounts)
        P(f"  field {lay}: median corner error (robot still) " + ", ".join(f"{c} {v[2]:.1f} px ({v[1]} mount)" for c, v in mounts.items()))
    layout = min(fits, key=lambda k: fits[k][0])
    tags = g.load_layout(layout)
    mounts = {c: v[0] for c, v in fits[layout][1].items()}
    for cam in cal:
        pose_ok[(match, cam)] = fits[layout][1][cam][2] < 30
    pose_ok[match] = any(pose_ok[(match, c)] for c in cal)
    P(f"  -> {layout}; robot pose usable as ground truth (still-robot median error < 30 px): " +
      ", ".join(f"{c} {pose_ok[(match, c)]} ({fits[layout][1][c][2]:.1f} px)" for c in cal))
    info[match] = {"layout": layout, "fits": {k: v[0] for k, v in fits.items()}, "pose_ok": pose_ok[match],
                   "mounts": {c: [round(float(x), 3) for x in p] for c, p in mounts.items()},
                   "mount_source": {c: v[1] for c, v in fits[layout][1].items()},
                   "exposure": {c: v.get("exposure_time_absolute") for c, v in caminfo.items()}}
    for cam, pm in mounts.items():
        ref = g.MOUNTS["cad"][cam]
        P(f"  {cam} mount used: " + ", ".join(f"{v:.3f}" if i < 3 else f"{v:.1f}" for i, v in enumerate(pm)) +
          f"; minus robot code's CAD: dx {pm[0]-ref[0]:+.3f} dy {pm[1]-ref[1]:+.3f} dz {pm[2]-ref[2]:+.3f} m, "
          f"droll {pm[3]-ref[3]:+.1f} dpitch {pm[4]-ref[4]:+.1f} dyaw {pm[5]-ref[5]:+.1f} deg")
        K, dist, _ = cal[cam]
        m = base["camera"] == cam
        s = {k: v[m] for k, v in base.items()}
        e_cad = still_error(s, to_cv(s["corners"]), robot, tags, ref, K, dist)
        P(f"    still-robot median error with the CAD mount {e_cad:.1f} px vs solved {fits[layout][1][cam][2]:.1f} px")

    # Timing (frame-to-frame motion; needs only short-term odometry, so pose quality matters little).
    for cam in cal:
        m = base["camera"] == cam
        s = {k: v[m] for k, v in base.items()}
        K, dist, _ = cal[cam]
        fine, n = timing_scan(s, robot, tags, mounts[cam], K, dist, np.arange(-10, 20.01, 0.5))
        if fine is None:
            P(f"  timing {cam}: too few moving frame pairs ({n})")
            continue
        wide, _ = timing_scan(s, robot, tags, mounts[cam], K, dist, np.arange(-60, 60.1, 2))
        f0 = [r for r in fine if r[1] == 0][0][0]
        bw = min(wide)
        bf = min(r for r in fine if r[1] <= 10)
        P(f"  timing {cam} ({n} moving frame pairs): best shift in -10..+10 {bf[1]:+.1f} ms, in -10..+20 {min(fine)[1]:+.1f} ms (median motion residual {bf[0]:.2f} px vs "
          f"{f0:.2f} at 0); best within +-60 ms: {bw[1]:+.0f} ms ({bw[0]:.2f} px)")
        info[match].setdefault("timing", {})[cam] = {"best_ms": bf[1], "resid": bf[0], "resid0": f0, "wide_ms": bw[1], "pairs": n,
                                                     "curve": [(r[1], round(r[0], 3)) for r in sorted(fine, key=lambda x: x[1])]}

    # -0.5 px: with the robot's pose as the reference, and in-frame (other tags in the frame).
    for cam in cal:
        m = base["camera"] == cam
        s = {k: v[m] for k, v in base.items()}
        K, dist, _ = cal[cam]
        uv, val, _ = g.predict(s, robot, tags, mounts[cam], K, dist)
        a = g.corner_errors(to_cv(s["corners"], True), uv)[0]
        b = g.corner_errors(to_cv(s["corners"], False), uv)[0]
        P(f"  half-pixel {cam}: robot-pose median corner error with -0.5 {np.nanmedian(a[val]):.3f} px, without {np.nanmedian(b[val]):.3f} px")

    # Every variant's sightings with their errors and features.
    for vdir in sorted(glob.glob(os.path.join(mdir, "out", "*"))):
        variant = os.path.basename(vdir)
        if args.variants and variant != args.base and variant not in args.variants.split(","):
            continue
        d, tmv = load_variant(mdir, variant, frames) if variant != args.base else (base, tm)
        if tmv:
            times.setdefault(variant, []).append(tmv)
        if d is None:
            continue
        n = len(d["id"])
        tot, cen, shp, rng = (np.full(n, np.nan) for _ in range(4))
        edge = np.zeros(n)
        pnp = np.full(n, np.nan)
        amb = np.full(n, np.nan)
        for cam in cal:
            m = d["camera"] == cam
            if not m.any():
                continue
            s = {k: v[m] for k, v in d.items()}
            K, dist, (W, H) = cal[cam]
            det = to_cv(s["corners"])
            uv, val, r = g.predict(s, robot, tags, mounts[cam], K, dist)
            t, c, sh = g.corner_errors(det, uv)
            t[~val] = np.nan
            c[~val] = np.nan
            sh[~val] = np.nan
            tot[m], cen[m], shp[m] = t, c, sh  # range: from the single-tag solve below
            edge[m] = common.edge_dist(s["corners"], W, H)
            if cv2 is not None:
                Km = np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]])
                h2 = g.TAG_SIZE / 2
                obj = np.array([[-h2, h2, 0], [h2, h2, 0], [h2, -h2, 0], [-h2, -h2, 0]])
                for j, i in enumerate(np.flatnonzero(m)):
                    try:
                        _, rvs, tvs, errs = cv2.solvePnPGeneric(obj, np.ascontiguousarray(det[j], np.float64), Km,
                                                                np.array(dist), flags=cv2.SOLVEPNP_IPPE_SQUARE)
                        order_e = np.argsort(np.ravel(errs))
                        e = sorted(float(x) for x in np.ravel(errs))
                        pnp[i] = e[0]
                        rng[i] = float(np.linalg.norm(tvs[order_e[0]]))
                        amb[i] = e[0] / e[1] if len(e) > 1 and e[1] > 0 else 0
                    except cv2.error:
                        pass
        for cam in cal:
            if not pose_ok[(match, cam)]:
                m = d["camera"] == cam
                tot[m] = np.nan
                shp[m] = np.nan
                cen[m] = np.nan
        loo = loo_errors(d, cal, tags)
        sp, w = robot.motion(d["robot_us"])
        en = robot.is_enabled(d["robot_us"])
        rows = dict(match=np.array([match] * n), key=key(d), camera=d["camera"], id=d["id"], margin=d["margin"],
                    side=d["side"], far=d["far"], edge=edge, tot=tot, cen=cen, shape=shp, loo=loo, range=rng, speed=sp,
                    w=w, enabled=en, pnp=pnp, amb=amb, corners=d["corners"])
        allrows.setdefault(variant, []).append(rows)

R = {v: {k: np.concatenate([r[k] for r in rs]) for k in rs[0]} for v, rs in allrows.items()}
if args.base not in R:
    sys.exit("no base variant")
B = R[args.base]

# ---------------------------------------------------------------------------------------------
# Good / bad. Reference sightings: nothing should go wrong (away from the edge, a decent size and
# margin, robot still). Thresholds from them:
#   shape error (corner geometry vs the expected outline; little affected by pose error) <= its p95,
#   in-frame error (reprojected from the other tags in the frame) <= its p95, where available,
#   total corner error vs the robot pose <= 3x its p95 (a gross check: wrong tag, wrong place).
# Only (match, camera) pairs whose robot pose fits (still-robot median error < 30 px) get the
# robot-pose checks; the in-frame check doesn't need the robot pose.
ref = (B["edge"] > 50) & (B["side"] > 30) & (B["margin"] > 50) & (B["speed"] < 0.3) & (np.abs(B["w"]) < 0.3)
T_SHAPE = float(pct(B["shape"][ref & np.isfinite(B["shape"])], 95))
T_LOO = float(pct(B["loo"][ref & np.isfinite(B["loo"])], 95))
T_TOT = 3 * float(pct(B["tot"][ref & np.isfinite(B["tot"])], 95))
P(f"\n=== Ground truth: reference sightings n={(ref & np.isfinite(B['shape'])).sum()} (in-frame {(ref & np.isfinite(B['loo'])).sum()})")
for nm, k in (("shape", "shape"), ("in-frame", "loo"), ("total vs robot pose", "tot")):
    a = B[k][ref & np.isfinite(B[k])]
    P(f"  {nm} error p50 {pct(a, 50):.2f} p90 {pct(a, 90):.2f} p95 {pct(a, 95):.2f} p99 {pct(a, 99):.2f} px")
P(f"Bad = shape error > {T_SHAPE:.2f} px, or in-frame error > {T_LOO:.2f} px, or total error > {T_TOT:.1f} px; "
  "good = checked by at least one and none says bad; unknown = no check possible")


def label(r):
    sb = np.isfinite(r["shape"]) & (r["shape"] > T_SHAPE)
    lb = np.isfinite(r["loo"]) & (r["loo"] > T_LOO)
    tb = np.isfinite(r["tot"]) & (r["tot"] > T_TOT)
    known = np.isfinite(r["shape"]) | np.isfinite(r["loo"])
    bad = known & (sb | lb | tb)
    return known & ~bad, bad, known


for v in R:
    R[v]["good"], R[v]["bad"], R[v]["known"] = label(R[v])
B = R[args.base]
P(f"All {args.base} sightings: {len(B['id'])}, good {B['good'].sum()}, bad {B['bad'].sum()}, unknown {(~B['known']).sum()}; "
  f"while enabled: good {(B['good'] & B['enabled']).sum()}, bad {(B['bad'] & B['enabled']).sum()}")
for nm, k in (("shape", "shape"), ("in-frame", "loo"), ("total", "tot")):
    a = B[k][np.isfinite(B[k])]
    P(f"  {nm} error, all base sightings with it (n={len(a)}): p50 {pct(a, 50):.2f} p90 {pct(a, 90):.2f} p99 {pct(a, 99):.2f} px")

EDGE_BINS = [(0, 10), (10, 25), (25, 50), (50, 1e9)]
SIDE_BINS = [(0, 15), (15, 20), (20, 30), (30, 60), (60, 1e9)]
MARGIN_BINS = [(15, 30), (30, 50), (50, 100), (100, 1e9)]


def gb(r, m):
    return f"{m.sum():6d} (good {(m & r['good']).sum():5d}, bad {(m & r['bad']).sum():4d}, ? {(m & ~r['known']).sum():4d})"


def binned(r, m, field, bins, name):
    for lo, hi in bins:
        mm = m & (r[field] >= lo) & (r[field] < hi)
        P(f"      {name} {lo:g}-{hi:g}: {gb(r, mm)}")


def compare(va, vb, title, normal_only=True):
    if va not in R or vb not in R:
        P(f"\n--- {title}: missing variant")
        return
    A, Bv = R[va], R[vb]
    ma = np.ones(len(A["id"]), bool) if not normal_only else ~A["far"]
    mb = np.ones(len(Bv["id"]), bool) if not normal_only else ~Bv["far"]
    ka, kb = A["key"][ma], Bv["key"][mb]
    ia = np.flatnonzero(ma)[~np.isin(ka, kb)]
    ib = np.flatnonzero(mb)[~np.isin(kb, ka)]
    both_a = np.flatnonzero(ma)[np.isin(ka, kb)]
    P(f"\n--- {title}")
    for match in matches + ["TOTAL"]:
        sa = ma & ((A["match"] == match) if match != "TOTAL" else True)
        sb = mb & ((Bv["match"] == match) if match != "TOTAL" else True)
        oa = np.zeros(len(A["id"]), bool); oa[ia] = True
        ob = np.zeros(len(Bv["id"]), bool); ob[ib] = True
        P(f"  {match:16s} {va}: {gb(A, sa)} | {vb}: {gb(Bv, sb)}")
        P(f"  {'':16s} only {va}: {gb(A, sa & oa)} | only {vb}: {gb(Bv, sb & ob)}")
    oa = np.zeros(len(A["id"]), bool); oa[ia] = True
    ob = np.zeros(len(Bv["id"]), bool); ob[ib] = True
    for nm, r, o in ((f"only {va}", A, oa), (f"only {vb}", Bv, ob)):
        if o.sum() == 0:
            continue
        li = o & np.isfinite(r["loo"])
        P(f"    {nm}, in-frame check only (pose-independent): {li.sum()} checked, {(li & (r['loo'] > T_LOO)).sum()} bad; "
          f"in-frame error p50 {pct(r['loo'][li], 50):.2f} p90 {pct(r['loo'][li], 90):.2f} px")
        P(f"    {nm} by edge distance / side / margin:")
        binned(r, o, "edge", EDGE_BINS, "edge px")
        binned(r, o, "side", SIDE_BINS, "side px")
        binned(r, o, "margin", MARGIN_BINS, "margin")
    # Corner shift on sightings in both.
    if len(both_a):
        pos = {k: i for i, k in enumerate(Bv["key"])}
        ib2 = np.array([pos[k] for k in A["key"][both_a]])
        shift = np.sqrt(np.mean(np.sum((A["corners"][both_a] - Bv["corners"][ib2]) ** 2, -1), -1))
        dt = Bv["tot"][ib2] - A["tot"][both_a]
        P(f"    in both: {len(both_a)}; corner shift rms p50 {pct(shift, 50):.3f} p90 {pct(shift, 90):.3f} p99 {pct(shift, 99):.3f} px; "
          f"changed (>0.01 px) {np.mean(shift > 0.01) * 100:.1f}%; error change ({vb} - {va}) median {np.nanmedian(dt):+.3f} px")
        flip = (A["good"][both_a] != Bv["good"][ib2])
        P(f"    good/bad label changed on {flip.sum()} of them")
    summary[title] = {"only_a": [int(oa.sum()), int((oa & A['good']).sum()), int((oa & A['bad']).sum())],
                      "only_b": [int(ob.sum()), int((ob & Bv['good']).sum()), int((ob & Bv['bad']).sum())]}


def tsum(v):
    if v not in times:
        return "n/a"
    t = np.array(times[v])
    return f"detect {np.average(t[:, 0], weights=t[:, 2]):.2f} ms/frame, far search {np.average(t[:, 1], weights=t[:, 2]):.2f} ms/frame"


P("\n=== Detect time per variant (detector-replay's own timing; the Jetson GPU, nice 10, one replay at a time)")
for v in sorted(times):
    P(f"  {v:12s} {tsum(v)}")

# Item 2: detector settings.
compare(args.base, "mse2.5", "max_line_fit_mse 10 (base) vs 2.5")
for x in ("mse15", "mse20"):
    compare(args.base, x, f"max_line_fit_mse 10 (base) vs {x[3:]}")
for x in ("mwbd5", "mwbd10", "mwbd30"):
    compare(args.base, x, f"min_white_black_diff 20 (base) vs {x[4:]}")
for x in ("mcp50", "mcp100"):
    compare(args.base, x, f"min_cluster_pixels 24 (base) vs {x[3:]}")
compare(args.base, "fullres", "half-res quad search (base) vs full-res")
compare(args.base, "far", "far search off (base) vs on (default budget)", normal_only=False)
compare(args.base, "half", "1280x800 (base) vs 640x400 (frames downscaled 2x)")

P("\n--- Edge filter on the base output (reject a tag with any corner within N px of the border)")
for n in (5, 10, 25, 50):
    m = B["edge"] < n
    li = m & np.isfinite(B["loo"])
    P(f"  N={n:2d}: removes {gb(B, m)}; of the bad ones it removes {(m & B['bad']).sum()}/{B['bad'].sum()}; "
      f"in-frame checked {li.sum()}: bad {(li & (B['loo'] > T_LOO)).sum()}, in-frame error p50 {pct(B['loo'][li], 50):.2f} px "
      f"(rest: p50 {pct(B['loo'][~m & np.isfinite(B['loo'])], 50):.2f})")
    summary[f"edge{n}"] = [int(m.sum()), int((m & B['good']).sum()), int((m & B['bad']).sum())]
P("  base sightings by edge distance (all):")
binned(B, np.ones(len(B["id"]), bool), "edge", EDGE_BINS, "edge px")


# Item 3: robot-side gates.
def gate(name, vals, thresholds, reject_above, labels="in-frame"):
    """Good/bad by the in-frame check alone (pose-independent: what the detection itself got
    right), or by the robot-pose labels (also counts pose and timing error, e.g. when turning)."""
    if labels == "in-frame":
        k = np.isfinite(B["loo"]) & np.isfinite(vals)
        gd, bd = k & (B["loo"] <= T_LOO), k & (B["loo"] > T_LOO)
    else:
        k = B["known"] & np.isfinite(vals)
        gd, bd = k & B["good"], k & B["bad"]
    ng, nb = gd.sum(), bd.sum()
    P(f"\n--- Gate: {name} ({'reject above' if reject_above else 'reject below'}); {labels} labels: {k.sum()} sightings, bad {nb} ({100 * nb / max(k.sum(), 1):.1f}%)")
    best = None
    for t in thresholds:
        rej = (vals > t) if reject_above else (vals < t)
        rg, rb = (rej & gd).sum(), (rej & bd).sum()
        j = (rb / max(nb, 1)) - (rg / max(ng, 1))
        P(f"  {t:8.3g}: rejects good {rg:5d} ({100 * rg / max(ng, 1):4.1f}%), bad {rb:4d} ({100 * rb / max(nb, 1):4.1f}%); bad share of the kept "
          f"{100 * (nb - rb) / max(ng - rg + nb - rb, 1):.2f}%")
        if best is None or j > best[0]:
            best = (j, t)
    P(f"  best separation (Youden J {best[0]:.2f}) at {best[1]:g}")
    summary[f"gate {name} ({labels})"] = [best[1], best[0]]


for lab in ("in-frame", "robot pose"):
    gate("decision margin", B["margin"], [15, 20, 30, 40, 50, 60, 80, 100], False, lab)
    gate("|yaw rate| rad/s", np.abs(B["w"]), [0.5, 1, 1.6, 2, 2.5, 3, 3.5, 4, 5], True, lab)
    gate("robot speed m/s", B["speed"], [0.5, 1, 1.5, 2, 2.5, 3, 4], True, lab)
    gate("single-tag reprojection error px", B["pnp"], [0.25, 0.5, 1, 1.5, 2, 3, 5], True, lab)
    gate("ambiguity", B["amb"], [0.05, 0.1, 0.2, 0.3, 0.5], True, lab)
    gate("tag side px", B["side"], [15, 20, 25, 30, 40], False, lab)
    gate("distance m (single-tag solve)", B["range"], [2, 3, 4, 5, 6, 7], True, lab)
    gate("edge distance px", B["edge"], [5, 10, 25, 50], False, lab)

# Item 4: camera setup.
P("\n=== Error vs motion (base, known; robot pose quality also drops with motion)")
for lo, hi in [(0, 0.5), (0.5, 1), (1, 2), (2, 3), (3, 99)]:
    m = B["known"] & (B["speed"] >= lo) & (B["speed"] < hi) & (np.abs(B["w"]) < 0.5)
    P(f"  speed {lo}-{hi} m/s, not turning: n={m.sum():5d} shape p50 {pct(B['shape'][m], 50):.2f} p90 {pct(B['shape'][m], 90):.2f}, "
      f"total p50 {pct(B['tot'][m], 50):.1f}, bad {100 * np.mean(B['bad'][m]) if m.sum() else 0:.1f}%; in-frame p50 {pct(B['loo'][m], 50):.2f} "
      f"p90 {pct(B['loo'][m], 90):.2f} (n={np.isfinite(B['loo'][m]).sum()})")
for lo, hi in [(0, 0.5), (0.5, 1.6), (1.6, 3), (3, 5), (5, 99)]:
    m = B["known"] & (np.abs(B["w"]) >= lo) & (np.abs(B["w"]) < hi)
    P(f"  |yaw rate| {lo}-{hi} rad/s: n={m.sum():5d} shape p50 {pct(B['shape'][m], 50):.2f} p90 {pct(B['shape'][m], 90):.2f}, "
      f"total p50 {pct(B['tot'][m], 50):.1f}, bad {100 * np.mean(B['bad'][m]) if m.sum() else 0:.1f}%; in-frame p50 {pct(B['loo'][m], 50):.2f} "
      f"p90 {pct(B['loo'][m], 90):.2f} (n={np.isfinite(B['loo'][m]).sum()})")
P("\n=== Per match: field fit, mounts, exposure, timing")
for m, v in info.items():
    P(f"  {m}: {json.dumps(v)}")
if "half" in R:
    H = R["half"]
    P("\n=== 640x400 vs 1280x800 range: smallest side (full-frame px) and farthest range found, good sightings")
    for nm, r in ((args.base, B), ("half", H)):
        gd = r["good"] & ~r["far"]
        P(f"  {nm}: good {gd.sum()}, side p1 {pct(r['side'][gd], 1):.1f} px, range p99 {pct(r['range'][gd], 99):.2f} m, max {pct(r['range'][gd], 100):.2f} m; side p1 of all {pct(r['side'], 1):.1f} px")
if "fullres" in R:
    F = R["fullres"]
    gd = F["good"]
    P(f"  fullres: good {gd.sum()}, side p1 {pct(F['side'][gd], 1):.1f} px, range p99 {pct(F['range'][gd], 99):.2f} m")
for x in ("mse2.5", "mse15", "mse20"):
    if x not in R:
        continue
    X = R[x]
    P(f"\n=== {args.base} vs {x}: size and range of what each finds that the other doesn't (good / bad by in-frame, all)")
    for nm, r, o in ((f"only {args.base}", B, ~np.isin(B["key"], X["key"]) & ~B["far"]), (f"only {x}", X, ~np.isin(X["key"], B["key"]) & ~X["far"])):
        if o.sum() == 0:
            P(f"  {nm}: none"); continue
        li = o & np.isfinite(r["loo"])
        P(f"  {nm}: {o.sum()}; side px p10/p50/p90 {pct(r['side'][o], 10):.1f}/{pct(r['side'][o], 50):.1f}/{pct(r['side'][o], 90):.1f}, "
          f"range m p50/p90/max {pct(r['range'][o], 50):.2f}/{pct(r['range'][o], 90):.2f}/{pct(r['range'][o], 100):.2f}; "
          f"in-frame {li.sum()} checked, {(li & (r['loo'] > T_LOO)).sum()} bad, p50 {pct(r['loo'][li], 50):.2f} px")
    for nm, r in ((args.base, B), (x, X)):
        gd = r["good"] & ~r["far"]
        P(f"  {nm}: good {gd.sum()}, side p1 {pct(r['side'][gd], 1):.1f} px, range p99 {pct(r['range'][gd], 99):.2f} m, max {pct(r['range'][gd], 100):.2f} m")
for x in [v for v in args.compare.split(",") if v in R]:
    X = R[x]
    P(f"\n=== {args.base} vs {x}: size and range (far sightings included; good / bad by robot pose, in-frame)")
    for nm, r, o in ((f"only {args.base}", B, ~np.isin(B["key"], X["key"])), (f"only {x}", X, ~np.isin(X["key"], B["key"]))):
        if o.sum() == 0:
            P(f"  {nm}: none"); continue
        li = o & np.isfinite(r["loo"])
        P(f"  {nm}: {o.sum()} (good {(o & r['good']).sum()}, bad {(o & r['bad']).sum()}); side px p10/p50/p90 "
          f"{pct(r['side'][o], 10):.1f}/{pct(r['side'][o], 50):.1f}/{pct(r['side'][o], 90):.1f}, "
          f"range m p50/p90/max {pct(r['range'][o], 50):.2f}/{pct(r['range'][o], 90):.2f}/{pct(r['range'][o], 100):.2f}; "
          f"in-frame {li.sum()} checked, {(li & (r['loo'] > T_LOO)).sum()} bad, p50 {pct(r['loo'][li], 50):.2f} px")
    for nm, r in ((args.base, B), (x, X)):
        gd = r["good"]
        P(f"  {nm}: {len(r['good'])} sightings, good {gd.sum()}, bad {r['bad'].sum()}; good side p1 {pct(r['side'][gd], 1):.1f} px, "
          f"min {pct(r['side'][gd], 0):.1f}; range p99 {pct(r['range'][gd], 99):.2f} m, max {pct(r['range'][gd], 100):.2f} m")
if args.json:
    json.dump({"summary": summary, "info": info, "T_TOT": T_TOT, "T_SHAPE": T_SHAPE}, open(args.json, "w"), indent=1, default=float)
