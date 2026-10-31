"""Accuracy judge for detector variants: corner accuracy measured directly, no robot pose needed.

  judge.py REPLAY_DIR [--base base] [--variants v1,v2,..] [--json OUT.json] > judge.txt

REPLAY_DIR as tests/field-replay/run.sh writes it (<match>/{frames.csv,cameras.json,robot.npz,
out/<variant>/*.csv}). Three measures, each compared PAIRED against the base on the sightings both
found (so a variant that finds more or fewer tags isn't credited or blamed for which tags):

1. Static jitter. Stretches of 10+ consecutive frames where the image is still (median tag-
   centroid step < 0.3 px frame to frame, from the base; the logged odometry/gyro read ~0 through
   stretches where the tags moved tens of px, so it can't be used), and (the tags' common-mode drift over the stretch under --drift px, default 1). Per tag per
   stretch, each corner coordinate's robust std (1.4826 MAD) over the frames both variants have:
   pure detection noise, px. The per-tag value is the rms over the 8 coordinates.
2. In-frame consistency. Per frame, using only the tags both variants found: each tag's corners
   reprojected from the camera pose solved (SQPnP) from the OTHER tags (needs 2+ others, or 1 of
   40+ px); rms px. Layout, calibration and the other tags' errors add a floor common to both.
3. Smoothness while moving slowly (speed < 0.5 m/s, |yaw rate| < 0.5 rad/s): per corner
   coordinate, the residual of a quadratic fitted over 7 consecutive frames at the centre frame,
   scaled to a per-frame noise std (divided by sqrt(1 - h)). Robust std over all.

Bootstrap: 95% CIs of the paired difference (variant - base) of the median, resampling stretches
(1, 3) or frames (2) as clusters, 400 resamples. A variant "differs" when the CI excludes 0.

Synthetic variants for validating the judge: "<base>+noiseX" (base corners + N(0, X px) per
coordinate, fixed seed).
"""
import argparse
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import common  # noqa: E402  (read-only use of the field-replay helpers)
import fieldgt as g  # noqa: E402

import cv2  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("root")
ap.add_argument("--base", default="base")
ap.add_argument("--variants", default="")
ap.add_argument("--json", default="")
ap.add_argument("--boot", type=int, default=400)
ap.add_argument("--step", type=float, default=0.3, help="still frame: median tag-centroid step under this (px)")
ap.add_argument("--drift", type=float, default=1.0, help="max common-mode drift (px) over a still stretch")
ap.add_argument("--still", type=float, default=0.01, help="still: odometry speed (m/s) and |yaw rate| (rad/s) under this")
args = ap.parse_args()
P = print
rng = np.random.default_rng(1)

matches = sorted(os.path.basename(m) for m in glob.glob(os.path.join(args.root, "TXMAN1_*"))
                 if os.path.isdir(os.path.join(m, "out")))
report = {}
try:
    report = json.load(open(os.path.join(args.root, "report.json")))
except (OSError, ValueError):
    pass


def layout_of(match):
    try:
        return report["info"][match]["layout"]
    except (KeyError, TypeError):
        return "andymark"


def load(mdir, variant, frames):
    """{key: (corners_cv (4,2), side, margin)}; key = (session, camera, frame, id). The first row
    per key wins (normal before far). Corners to OpenCV's convention (x - 0.5)."""
    noise = None
    if "+noise" in variant:
        variant, noise = variant.split("+noise")
        noise = float(noise)
    ds = []
    for f in sorted(glob.glob(os.path.join(mdir, "out", variant, "*.csv"))):
        ds.append(common.load_dets(f, os.path.basename(f)[:-4], frames))
    d = common.concat(ds)
    if d is None:
        return None
    c = d["corners"] - 0.5
    if noise:
        c = c + np.random.default_rng(7).normal(0, noise, c.shape)
    out = {}
    for i, k in enumerate(zip(d["session"], d["camera"], d["frame"], d["id"])):
        k = (str(k[0]), str(k[1]), int(k[2]), int(k[3]))
        if k not in out:
            out[k] = (c[i], float(d["side"][i]), float(d["margin"][i]))
    return out


def times(mdir, variant):
    variant = variant.split("+noise")[0]
    det, ref, n = [], [], []
    import re
    for f in glob.glob(os.path.join(mdir, "out", variant, "*.log")):
        t = open(f).read()
        m = re.search(r"Time: detect ([\d.]+) ms", t)
        r = re.search(r"Refine: ([\d.]+) ms", t)
        k = re.search(r"(\d+) cameras, (\d+) frames", t)
        if m and k:
            det.append(float(m.group(1))); ref.append(float(r.group(1)) if r else 0.0); n.append(int(k.group(2)))
    return (np.average(det, weights=n), np.average(ref, weights=n), sum(n)) if n else (np.nan, np.nan, 0)


def robust_std(a, axis=0):
    med = np.median(a, axis=axis, keepdims=True)
    return 1.4826 * np.median(np.abs(a - med), axis=axis)


# -----------------------------------------------------------------------------------------------
# Per match: still stretches, slow frames, calibrations, layout.
ctx = {}
for m in matches:
    mdir = os.path.join(args.root, m)
    frames = common.load_frames(mdir)
    cal, _ = common.calibrations(mdir)
    robot = g.Robot(os.path.join(mdir, "robot.npz"))
    z = np.load(os.path.join(mdir, "robot.npz"))
    still, slow = {}, {}
    for (s, c), ft in frames.items():
        t = ft[:, 2].astype(float)
        sp, w = robot.motion(t)
        # Raw odometry speed (no fused-pose correction) for stillness: the wheels themselves.
        ot = z["odom_t"].astype(float)
        ov = np.hypot(np.gradient(z["odom"][:, 0]), np.gradient(z["odom"][:, 1])) / np.maximum(np.gradient(ot / 1e6), 1e-3)
        osp = np.interp(t, ot, ov)
        inside = (t >= ot[0]) & (t <= ot[-1])
        st = inside & (osp < args.still) & (np.abs(w) < args.still)
        runs = []  # filled from the images below (odometry 'still' turned out not to be)
        still[(s, c)] = runs
        slow[(s, c)] = {int(f) for f, ok in zip(ft[:, 0], inside & (sp < 0.5) & (np.abs(w) < 0.5)) if ok}
    ctx[m] = dict(frames=frames, cal=cal, tags=g.load_layout(layout_of(m)), still=still, slow=slow)

variants = [v for v in args.variants.split(",") if v] or sorted(
    {os.path.basename(p) for m in matches for p in glob.glob(os.path.join(args.root, m, "out", "*"))})
variants = [v for v in variants if v != args.base]
data = {}
for v in [args.base] + variants:
    data[v] = {m: load(os.path.join(args.root, m), v, ctx[m]["frames"]) for m in matches}


# Still stretches from the images: odometry and gyro read ~0 through stretches where the tags
# moved tens of px (the camera/robot was pushed, or odometry isn't logged then), so stillness is
# taken from the base's tag centroids (mean of 4 corners: ~4x less noisy than a corner): a frame
# is still when the median over its tags of the centroid's frame-to-frame motion is under
# --step px; 10+ consecutive still frames; the stretch's common-mode drift checked after.
for m in matches:
    B0 = data[args.base][m] or {}
    byf = {}
    for k, (cc, _, _) in B0.items():
        byf.setdefault(k[:3], {})[k[3]] = cc.mean(0)
    for (s, c) in ctx[m]["still"]:
        ft = ctx[m]["frames"][(s, c)][:, 0]
        ok = np.zeros(len(ft), bool)
        for i in range(1, len(ft)):
            a, b = byf.get((s, c, int(ft[i - 1]))), byf.get((s, c, int(ft[i])))
            if a and b:
                common_t = set(a) & set(b)
                if common_t:
                    ok[i] = np.median([np.hypot(*(b[t] - a[t])) for t in common_t]) < args.step
        runs, i = [], 0
        while i < len(ok):
            if ok[i]:
                j = i
                while j + 1 < len(ok) and ok[j + 1]:
                    j += 1
                if j - i + 2 >= 10:
                    runs.append((int(ft[i - 1]), int(ft[j])))
                i = j + 1
            else:
                i += 1
        ctx[m]["still"][(s, c)] = runs
P("still stretches (image): " + ", ".join(f"{m}: {sum(len(r) for r in ctx[m]['still'].values())}" for m in matches))


# -----------------------------------------------------------------------------------------------
def jitter_pairs(a, b):
    """Static jitter per (stretch, tag), on frames both variants have. Returns rows:
    (cluster id, side, edge distance, jitter a, jitter b, drift)."""
    rows = []
    for m in matches:
        A, B = a[m], b[m]
        if A is None or B is None:
            continue
        for (s, c), runs in ctx[m]["still"].items():
            W, H = ctx[m]["cal"][c][2]
            for r0, r1 in runs:
                cid = f"{m}|{s}|{c}|{r0}"
                per_tag = {}
                for f in range(r0, r1 + 1):
                    for tid in range(1, 33):
                        k = (s, c, f, tid)
                        if k in A and k in B:
                            per_tag.setdefault(tid, []).append(k)
                if not per_tag:
                    continue
                # Image stillness: the tags' common-mode centroid drift over the stretch.
                cen = {}
                for tid, ks in per_tag.items():
                    for k in ks:
                        cen.setdefault(k[2], []).append(A[k][0].mean(0) - np.median([A[q][0].mean(0) for q in ks], 0))
                fs = np.array(sorted(cen))
                cm = np.array([np.mean(cen[f], 0) for f in fs])
                drift = 0.0
                if len(fs) >= 6:
                    for dim in range(2):
                        p = np.polyfit(fs, cm[:, dim], 1)
                        drift = max(drift, abs(p[0]) * (fs[-1] - fs[0]))
                for tid, ks in per_tag.items():
                    if len(ks) < 8:
                        continue
                    ca = np.array([A[k][0] for k in ks]).reshape(len(ks), 8)
                    cb = np.array([B[k][0] for k in ks]).reshape(len(ks), 8)
                    ja = np.sqrt(np.mean(robust_std(ca) ** 2))
                    jb = np.sqrt(np.mean(robust_std(cb) ** 2))
                    side = np.median([A[k][1] for k in ks])
                    ed = np.median(common.edge_dist(ca.reshape(-1, 4, 2), W, H))
                    rows.append((cid, side, ed, ja, jb, drift))
    return rows


def loo(Akeys_by_frame, A, m):
    """In-frame (leave-one-out) error for each key in the frame groups, using A's corners."""
    tags, cal = ctx[m]["tags"], ctx[m]["cal"]
    out = {}
    for (s, c, f), ks in Akeys_by_frame.items():
        ks = [k for k in ks if k[3] in tags]
        if len(ks) < 2:
            continue
        K, dist, _ = cal[c]
        Km = np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]])
        dc = np.array(dist, np.float64)
        for j, k in enumerate(ks):
            others = [o for o in ks if o != k]
            if len(others) < 2 and A[others[0]][1] < 40:
                continue
            obj = np.concatenate([tags[o[3]] for o in others]).astype(np.float64)
            img = np.concatenate([A[o][0] for o in others]).astype(np.float64)
            try:
                ok, rv, tv = cv2.solvePnP(obj, img, Km, dc, flags=cv2.SOLVEPNP_SQPNP)
                if not ok:
                    continue
                pr, _ = cv2.projectPoints(np.ascontiguousarray(tags[k[3]], np.float64), rv, tv, Km, dc)
            except cv2.error:
                continue
            out[k] = float(np.sqrt(np.mean(np.sum((pr.reshape(4, 2) - A[k][0]) ** 2, -1))))
    return out


def inframe_pairs(a, b):
    rows = []  # (cluster, side, edge, err a, err b)
    for m in matches:
        A, B = a[m], b[m]
        if A is None or B is None:
            continue
        common_keys = set(A) & set(B)
        groups = {}
        for k in common_keys:
            groups.setdefault(k[:3], []).append(k)
        ea, eb = loo(groups, A, m), loo(groups, B, m)
        for k in ea:
            if k in eb:
                W, H = ctx[m]["cal"][k[1]][2]
                rows.append((f"{m}|{k[0]}|{k[1]}|{k[2]}", A[k][1],
                             float(common.edge_dist(A[k][0][None], W, H)[0]), ea[k], eb[k]))
    return rows


# Quadratic over 7 frames: residual at the centre = v . r, std factor sqrt(1 - h).
_t = np.arange(-3, 4, dtype=float)
_V = np.stack([np.ones(7), _t, _t ** 2], 1)
_Hm = _V @ np.linalg.pinv(_V)
_r = (np.eye(7) - _Hm)[3]
_rs = np.sqrt(1 - _Hm[3, 3])


def smooth_pairs(a, b):
    rows = []  # (cluster, resid a (8,), resid b (8,))
    for m in matches:
        A, B = a[m], b[m]
        if A is None or B is None:
            continue
        ks = set(A) & set(B)
        for k in ks:
            s, c, f, tid = k
            sl = ctx[m]["slow"][(s, c)]
            win = [(s, c, f + d, tid) for d in range(-3, 4)]
            if not all(w in ks and w[2] in sl for w in win):
                continue
            va = np.array([A[w][0].reshape(8) for w in win])
            vb = np.array([B[w][0].reshape(8) for w in win])
            rows.append((f"{m}|{s}|{c}|{tid}|{f // 30}", (_r @ va) / _rs, (_r @ vb) / _rs))
    return rows


def boot_diff(clusters, a, b, stat):
    """95% CI of stat(b) - stat(a), resampling clusters."""
    cl = np.asarray(clusters)
    u, inv = np.unique(cl, return_inverse=True)
    idx_by = [[] for _ in u]
    for i, j in enumerate(inv):
        idx_by[j].append(i)
    idx_by = [np.array(x) for x in idx_by]
    d = []
    for _ in range(args.boot):
        pick = rng.integers(0, len(u), len(u))
        ii = np.concatenate([idx_by[p] for p in pick])
        d.append(stat(b[ii]) - stat(a[ii]))
    return np.percentile(d, [2.5, 97.5])


def rstd(x):
    return 1.4826 * np.median(np.abs(x - np.median(x)))


_full = {}


def full_loo(v):
    """In-frame error of every sighting of variant v, with all of v's tags in the frame."""
    if v not in _full:
        out = {}
        for m in matches:
            A = data[v][m]
            if not A:
                continue
            groups = {}
            for k in A:
                groups.setdefault(k[:3], []).append(k)
            out.update({(m,) + k: e for k, e in loo(groups, A, m).items()})
        _full[v] = out
    return _full[v]


def lost_gained(v):
    """Sightings only the base has (lost) and only v has (gained), with their in-frame error."""
    fb, fv = full_loo(args.base), full_loo(v)
    res = {}
    for name, A, B, F in (("lost", args.base, v, fb), ("gained", v, args.base, fv)):
        keys = [(m,) + k for m in matches for k in set(data[A][m] or {}) - set(data[B][m] or {})]
        e = np.array([F[k] for k in keys if k in F])
        res[name] = dict(n=len(keys), checkable=int(len(e)),
                         median=float(np.median(e)) if len(e) else float("nan"),
                         p90=float(np.percentile(e, 90)) if len(e) else float("nan"),
                         over5=int(np.sum(e > 5)), over20=int(np.sum(e > 20.4)))
    allb = np.array(list(fb.values()))
    res["base_all"] = dict(median=float(np.median(allb)), p90=float(np.percentile(allb, 90)))
    return res


summary = {}
base = data[args.base]
P(f"Judge: base {args.base}; matches {', '.join(matches)}")
for v in variants:
    vb = data[v]
    tms = [times(os.path.join(args.root, m), v) for m in matches]
    n = sum(t[2] for t in tms)
    det_ms = sum(t[0] * t[2] for t in tms if t[2]) / n if n else np.nan
    ref_ms = sum(t[1] * t[2] for t in tms if t[2]) / n if n else np.nan
    cnt_a = sum(len(base[m] or {}) for m in matches)
    cnt_b = sum(len(vb[m] or {}) for m in matches)
    common_n = sum(len(set(base[m] or {}) & set(vb[m] or {})) for m in matches)
    res = {"sightings": cnt_b, "base_sightings": cnt_a, "common": common_n, "detect_ms": det_ms, "refine_ms": ref_ms}
    P(f"\n== {v}: {cnt_b} sightings (base {cnt_a}, common {common_n}); detect {det_ms:.2f} ms/frame, refine {ref_ms:.3f} ms/frame")

    if "+noise" not in v:
        lg = lost_gained(v)
        res["lost_gained"] = lg
        P("  " + "; ".join(f"{k} {lg[k]['n']} (in-frame checkable {lg[k]['checkable']}: median {lg[k]['median']:.2f} px, "
                            f"p90 {lg[k]['p90']:.2f}, >5 px {lg[k]['over5']}, >20.4 px {lg[k]['over20']})" for k in ("lost", "gained"))
          + f"; all base: median {lg['base_all']['median']:.2f}, p90 {lg['base_all']['p90']:.2f}")

    jr = jitter_pairs(base, vb)
    if jr:
        cl = np.array([r[0] for r in jr]); side = np.array([r[1] for r in jr]); ed = np.array([r[2] for r in jr])
        ja = np.array([r[3] for r in jr]); jb = np.array([r[4] for r in jr]); drift = np.array([r[5] for r in jr])
        ok = drift < args.drift
        P(f"  still stretches: {len(set(cl))}, tag-stretches {len(drift)}; drift p50 {np.median(drift):.2f} p90 {np.percentile(drift, 90):.2f} px")
        cl, side, ed, ja, jb = cl[ok], side[ok], ed[ok], ja[ok], jb[ok]
        ci = boot_diff(cl, ja, jb, np.median)
        ci90 = boot_diff(cl, ja, jb, lambda x: np.percentile(x, 90))
        res["jitter"] = dict(n=int(len(ja)), stretches=int(len(set(cl))), still_ok_frac=float(ok.mean()),
                             base_med=float(np.median(ja)), med=float(np.median(jb)), ci=list(map(float, ci)),
                             base_p90=float(np.percentile(ja, 90)), p90=float(np.percentile(jb, 90)), ci90=list(map(float, ci90)))
        P(f"  static jitter ({len(ja)} tag-stretches in {len(set(cl))} still stretches; {100 * ok.mean():.0f}% image-still): "
          f"median {np.median(ja):.3f} -> {np.median(jb):.3f} px (diff CI {ci[0]:+.3f}..{ci[1]:+.3f}); "
          f"p90 {np.percentile(ja, 90):.3f} -> {np.percentile(jb, 90):.3f} (CI {ci90[0]:+.3f}..{ci90[1]:+.3f})")
        strata = []
        for lo, hi in ((0, 20), (20, 40), (40, 80), (80, 1e9)):
            mm = (side >= lo) & (side < hi)
            if mm.sum() >= 5:
                strata.append(f"side {lo}-{hi if hi < 1e9 else '+'}: {np.median(ja[mm]):.3f}->{np.median(jb[mm]):.3f} (n {mm.sum()})")
        for lo, hi in ((0, 10), (10, 50), (50, 1e9)):
            mm = (ed >= lo) & (ed < hi)
            if mm.sum() >= 5:
                strata.append(f"edge {lo}-{hi if hi < 1e9 else '+'}: {np.median(ja[mm]):.3f}->{np.median(jb[mm]):.3f} (n {mm.sum()})")
        P("    " + "; ".join(strata))
        res["jitter"]["strata"] = strata

    ir = inframe_pairs(base, vb)
    if ir:
        cl = np.array([r[0] for r in ir]); side = np.array([r[1] for r in ir]); ed = np.array([r[2] for r in ir])
        ea = np.array([r[3] for r in ir]); eb = np.array([r[4] for r in ir])
        out = {}
        txt = []
        for q in (50, 75, 90):
            ci = boot_diff(cl, ea, eb, lambda x, q=q: np.percentile(x, q))
            out[f"p{q}"] = (float(np.percentile(ea, q)), float(np.percentile(eb, q)), list(map(float, ci)))
            txt.append(f"p{q} {np.percentile(ea, q):.3f} -> {np.percentile(eb, q):.3f} (CI {ci[0]:+.3f}..{ci[1]:+.3f})")
        pd = eb - ea
        out["n"] = int(len(ea))
        out["paired_median_diff"] = float(np.median(pd))
        out["frac_better"] = float(np.mean(pd < 0)); out["frac_worse"] = float(np.mean(pd > 0))
        res["inframe"] = out
        P(f"  in-frame ({len(ea)} common sightings): " + "; ".join(txt))
        P(f"    per sighting: better {100 * np.mean(pd < -1e-6):.0f}%, worse {100 * np.mean(pd > 1e-6):.0f}%, "
          f"same {100 * np.mean(np.abs(pd) <= 1e-6):.0f}%; median paired diff {np.median(pd):+.4f} px")
        strata = []
        for lo, hi in ((0, 20), (20, 40), (40, 80), (80, 1e9)):
            mm = (side >= lo) & (side < hi)
            if mm.sum() >= 20:
                strata.append(f"side {lo}-{hi if hi < 1e9 else '+'}: {np.median(ea[mm]):.2f}->{np.median(eb[mm]):.2f} (n {mm.sum()})")
        for lo, hi in ((0, 10), (10, 50), (50, 1e9)):
            mm = (ed >= lo) & (ed < hi)
            if mm.sum() >= 20:
                strata.append(f"edge {lo}-{hi if hi < 1e9 else '+'}: {np.median(ea[mm]):.2f}->{np.median(eb[mm]):.2f} (n {mm.sum()})")
        P("    " + "; ".join(strata))
        out["strata"] = strata

    sr = smooth_pairs(base, vb)
    if sr:
        cl = np.array([r[0] for r in sr])
        ra = np.array([r[1] for r in sr]); rb = np.array([r[2] for r in sr])
        # Per-window rms over the 8 coordinates; robust std ~ median |r| * 1.4826
        ma, mb = np.median(np.abs(ra), 1) * 1.4826, np.median(np.abs(rb), 1) * 1.4826
        ci = boot_diff(cl, ma, mb, np.median)
        res["smooth"] = dict(n=int(len(ma)), base=float(np.median(ma)), v=float(np.median(mb)), ci=list(map(float, ci)))
        P(f"  smoothness ({len(ma)} 7-frame windows, slow motion): {np.median(ma):.3f} -> {np.median(mb):.3f} px "
          f"(CI {ci[0]:+.3f}..{ci[1]:+.3f})")
    summary[v] = res

if args.json:
    json.dump(summary, open(args.json, "w"), indent=1, default=float)
