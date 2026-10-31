"""Refit the stored calibration snapshots into improved, non-folding 8-coefficient calibrations
and write them as PhotonVision-importable JSON (calibrations/<name>-refit.json).

  PYTHONPATH=<numpy/scipy/opencv> python3 refit.py [--replay REPLAY_DIR] [--boot N] [--cams ...]

Per camera: candidates are OpenCV 8-coefficient rational fits (mrcal-style global board warp) of
ALL detected corners (mrcal's rejected corners re-admitted), with robust rejection of only truly
bad ones (residual > max(1 px, 6x the robust sigma), iterated). Each candidate is checked for a
fold over the whole image (radial curve strictly increasing past 1.05x the image-corner radius,
and every pixel of the image plus a 16 px border unprojects and round-trips); folding candidates
are never chosen. (With all corners kept, none of TC01/TC02 folds before r = 3.3, so no
constrained/penalized fit was needed; a quick penalized-fit attempt from the folded deployed
start did not converge and was dropped.) Candidates are scored on the TXMAN1 replays (field_tie.py's in-frame leave-one-tag-out
measure) when --replay is given; the best non-folding one is written. Bootstrap uncertainty of the
chosen fit is summarized like analyze.py's. Results -> refit.json next to this file.
"""
import argparse
import glob
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "field-replay"))
import calib_lib as L  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--replay", default=None, help="TXMAN1 replay dir (as field_tie.py) for field scoring")
ap.add_argument("--boot", type=int, default=20)
ap.add_argument("--cams", default="SJ-TC01-1280x800,SJ-TC02-1280x800,SJ-TC02-320x240")
ap.add_argument("--no-write", action="store_true")
args = ap.parse_args()

FIELDCAM = {"SJ-TC01-1280x800": "orin-left", "SJ-TC02-1280x800": "orin-right"}
NX, NY = 10, 8
MARGIN = 1.05  # fold must lie beyond 1.05x the image-corner normalized radius
BORDER = 16  # px outside the image that must also unproject


def rms(a):
    a = np.asarray(a).reshape(-1, 2)
    return float(np.sqrt(np.mean(np.sum(a ** 2, 1)))) if len(a) else float("nan")


def fold_check(K, d, W, H):
    """(ok, fold radius, corner radius, frac of image+border with no valid ray)."""
    mr, _ = L.max_radius(d, rmax=6.0)
    cr = float(L.norm_radius(np.array([[0, 0], [W, 0], [0, H], [W, H]], float), K).max())
    xs = np.linspace(-BORDER, W + BORDER, 161)
    ys = np.linspace(-BORDER, H + BORDER, 101)
    X, Y = np.meshgrid(xs, ys)
    q = np.stack([X.ravel(), Y.ravel()], 1)
    v = L.unproject(q, K, d)
    bad = ~np.isfinite(v).all(1)
    ok = (~bad).all() and mr > MARGIN * cr
    if ok:  # round trip through OpenCV's own projection
        p, _ = cv2.projectPoints(v.reshape(-1, 1, 3), np.zeros(3), np.zeros(3), K, d)
        ok = bool(np.abs(p.reshape(-1, 2) - q).max() < 1e-3)
    return bool(ok), mr, cr, float(bad.mean())


def robust_fit(c, **kw):
    """Fit all corners; drop only gross outliers (iterated), refit. Returns fit + kept masks."""
    keep = [np.ones(len(s["img"]), bool) for s in c["snaps"]]
    f = None
    for it in range(4):
        sn = [dict(s, used=k) for s, k in zip(c["snaps"], keep)]
        cc = dict(c, snaps=sn)
        f = L.fit(cc, mask="used", K0=None if f is None else f["K"], d0=None if f is None else f["dist"], **kw)
        e = np.linalg.norm(np.concatenate(f["allres"]), axis=1)
        k_all = np.concatenate(keep)
        sig = 1.4826 * np.median(e[k_all])
        thr = max(1.0, 6 * sig)
        new = [np.linalg.norm(a, axis=1) <= thr for a in f["allres"]]
        if all((a == b).all() for a, b in zip(new, keep)):
            break
        keep = new
    f["keep"] = keep
    f["thr"] = thr
    f["snaps"] = sn
    return f


# ------------------------------------------------------------------ field scoring
def field_rows(root):
    """Pre-load TXMAN1 base detections grouped per frame (as field_tie.py)."""
    import common
    import fieldgt as g
    report = json.load(open(os.path.join(root, "report.json")))
    G = []
    deployed = None
    for mdir in sorted(glob.glob(os.path.join(root, "TXMAN1_*"))):
        m = os.path.basename(mdir)
        frames = common.load_frames(mdir)
        cal, _ = common.calibrations(mdir)
        deployed = cal
        tags = g.load_layout(report["info"].get(m, {}).get("layout", "andymark"))
        ds = [common.load_dets(f, os.path.basename(f)[:-4], frames) for f in sorted(glob.glob(os.path.join(mdir, "out", "base", "*.csv")))]
        d = common.concat(ds)
        A = {}
        for i, k in enumerate(zip(d["session"], d["camera"], d["frame"], d["id"])):
            k = (str(k[0]), str(k[1]), int(k[2]), int(k[3]))
            if k not in A:
                A[k] = (d["corners"][i] - 0.5, float(d["side"][i]))
        groups = {}
        for k in A:
            if k[3] in tags:
                groups.setdefault(k[:3], []).append(k)
        for (s, cam, f), ks in groups.items():
            if len(ks) >= 2:
                G.append((cam, [(k, A[k], tags[k[3]]) for k in ks]))
    return G, deployed


def field_score(G, cam, K, d):
    srms = []
    for c_, ks in G:
        if c_ != cam:
            continue
        for k, (crn, side), tg in ks:
            others = [o for o in ks if o[0] != k]
            if len(others) < 2 and others[0][1][1] < 40:
                continue
            obj = np.concatenate([o[2] for o in others]).astype(np.float64)
            img = np.concatenate([o[1][0] for o in others]).astype(np.float64)
            try:
                ok, rv, tv = cv2.solvePnP(obj, img, K, d, flags=cv2.SOLVEPNP_SQPNP)
                if not ok:
                    continue
                pr, _ = cv2.projectPoints(np.ascontiguousarray(tg, np.float64), rv, tv, K, d)
            except cv2.error:
                continue
            e = crn - pr.reshape(4, 2)
            srms.append(float(np.sqrt(np.mean(np.sum(e ** 2, 1)))))
    s = np.array(srms)
    return dict(sightings=len(s), median=float(np.median(s)), p90=float(np.percentile(s, 90)))


# ------------------------------------------------------------------ bootstrap
def bootstrap(c, f, W, H, nboot):
    K = f["K"]
    sn = f["snaps"]
    img = np.concatenate([s["img"][s["used"]] for s in sn])
    robs = L.norm_radius(img, K)
    FR = lambda qq: L.norm_radius(qq, K) < np.percentile(robs, 90)  # noqa: E731
    rng = np.random.default_rng(1)
    maps = []
    for b in range(nboot):
        idx = rng.integers(0, len(sn), len(sn))
        fb = L.fit(c, nd=8, warp="global", snaps=[sn[k] for k in idx], K0=K, d0=f["dist"],
                   poses0=[f["poses"][k] for k in idx])
        dd, _ = L.projection_diff(K, f["dist"], fb["K"], fb["dist"], W, H, fit_region=FR)
        maps.append(dd)
        print("  boot", b, round(float(np.nanmedian(dd)), 3), flush=True)
    M = np.array(maps)
    unc = np.sqrt(np.nanmean(M ** 2, 0))
    g, _ = L.grid(W, H)
    gi = np.clip((g[:, 0] / W * NX).astype(int), 0, NX - 1)
    gj = np.clip((g[:, 1] / H * NY).astype(int), 0, NY - 1)
    cell = np.zeros((NY, NX))
    for a in range(NY):
        for b2 in range(NX):
            cell[a, b2] = np.nanmedian(unc.ravel()[(gj == a) & (gi == b2)])
    ring = np.zeros((NY, NX), bool)
    ring[0, :] = ring[-1, :] = ring[:, 0] = ring[:, -1] = True
    cm = np.zeros((NY, NX), bool)
    cm[:2, :2] = cm[:2, -2:] = cm[-2:, :2] = cm[-2:, -2:] = True
    return dict(boot=nboot, median_px=float(np.nanmedian(unc)), centre_cells_median=float(np.nanmedian(cell[~ring])),
                ring_cells_median=float(np.nanmedian(cell[ring])), corner_cells_max=float(np.nanmax(cell[cm])),
                frac_pixels_any_fold=float(np.isnan(M).any(0).mean()), cells=cell.round(3).tolist())


# ------------------------------------------------------------------ PhotonVision JSON
def quat(rv):
    th = float(np.linalg.norm(rv))
    if th < 1e-12:
        return dict(W=1.0, X=0.0, Y=0.0, Z=0.0)
    a = np.asarray(rv) / th
    s = np.sin(th / 2)
    return dict(W=float(np.cos(th / 2)), X=float(a[0] * s), Y=float(a[1] * s), Z=float(a[2] * s))


def pose_json(p):
    return dict(translation=dict(x=float(p[3]), y=float(p[4]), z=float(p[5])), rotation=dict(quaternion=quat(p[:3])))


def write_pv(name, c, f, path):
    src = json.load(open(os.path.join(L.REPO, "calibrations", name + ".json")))
    K, d, w = f["K"], f["dist"], f["warp"]
    obs = []
    for k, (s, so) in enumerate(zip(f["snaps"], src["observations"])):
        p = f["poses"][k]
        oo = L.flat(c, s)
        oo[:, 2] = L.warp_basis(s["ij"], c["bw"], c["bh"]) @ w
        pr, _ = cv2.projectPoints(oo, p[:3], p[3:6], K, d)
        # PV convention (Calibrate3dPipe): reprojection error = projected - observed. Every list
        # here has one entry per detected corner, in the same order: no misalignment.
        e = pr.reshape(-1, 2) - s["img"]
        obs.append(dict(
            locationInObjectSpace=[dict(x=float(a), y=float(b), z=float(z)) for a, b, z in oo],
            locationInImageSpace=[dict(x=float(a), y=float(b)) for a, b in s["img"]],
            reprojectionErrors=[dict(x=float(a), y=float(b)) for a, b in e],
            optimisedCameraToObject=pose_json(p),
            cornerIds=[int(i) for i in s["ij"][:, 1] * c["bw"] + s["ij"][:, 0]],
            cornersUsed=[bool(u) for u in s["used"]],
            snapshotName=so["snapshotName"], snapshotDataLocation=so.get("snapshotDataLocation")))
    out = dict(
        resolution=src["resolution"],
        cameraIntrinsics=dict(rows=3, cols=3, type=6, data=[float(x) for x in K.ravel()]),
        distCoeffs=dict(rows=1, cols=8, type=6, data=[float(x) for x in d]),
        calobjectWarp=[float(x) for x in w],
        observations=obs,
        calobjectSize=src["calobjectSize"], calobjectSpacing=src["calobjectSpacing"],
        lensmodel="LENSMODEL_OPENCV",
        optimizationInputs=dict(rt_cam_ref=[pose_json(p) for p in f["poses"]]))
    json.dump(out, open(path, "w"))


# ------------------------------------------------------------------ main
G = deployed = None
if args.replay:
    G, deployed = field_rows(args.replay)
OUTJ = os.path.join(HERE, "refit.json")
R = json.load(open(OUTJ)) if os.path.exists(OUTJ) else {}
for name in args.cams.split(","):
    c = L.load(name)
    W, H = c["W"], c["H"]
    used0 = np.concatenate([s["used"] for s in c["snaps"]])
    r = R[name] = {"candidates": {}}
    # deployed
    okd, mrd, crd, badd = fold_check(c["K"], c["dist"], W, H)
    rd = dict(fold_ok=okd, fold_radius=mrd, corner_radius=crd, frac_no_ray=badd)
    dres = []
    for s in c["snaps"]:
        m = s["used"]
        if m.sum() < 6:
            dres.append(np.full((len(m), 2), np.nan))
            continue
        _, rv, tv = cv2.solvePnP(s["obj"][m], s["img"][m], c["K"], c["dist"])
        rv, tv = cv2.solvePnPRefineLM(s["obj"][m], s["img"][m], c["K"], c["dist"], rv, tv)
        pp, _ = cv2.projectPoints(s["obj"], rv, tv, c["K"], c["dist"])
        dres.append(pp.reshape(-1, 2) - s["img"])
    da = np.concatenate(dres)
    rd["rms_mrcal_inliers"] = rms(da[used0 & np.isfinite(da).all(1)])
    if G is not None and name in FIELDCAM:
        Kd, dd_, _ = deployed[FIELDCAM[name]]
        rd["field"] = field_score(G, FIELDCAM[name], np.array([[Kd[0], 0, Kd[2]], [0, Kd[1], Kd[3]], [0, 0, 1]]), np.array(dd_, float))
    r["deployed"] = rd
    print(name, "deployed", rd, flush=True)

    fits = {}
    fits["8_all_robust"] = robust_fit(c, nd=8, warp="global")
    fits["8_all_robust_flat"] = robust_fit(c, nd=8, warp="none")
    for key, f in fits.items():
        ok, mr, cr, bad = fold_check(f["K"], f["dist"], W, H)
        ar = np.concatenate(f["allres"])
        keep = np.concatenate(f["keep"])
        cd = dict(fold_ok=ok, fold_radius=mr, corner_radius=cr, frac_no_ray=bad,
                  rms_kept=rms(ar[keep]), rms_mrcal_inliers=rms(ar[used0]), rms_mrcal_outliers=rms(ar[~used0 & keep]),
                  kept=int(keep.sum()), dropped=int((~keep).sum()), mrcal_outliers_readmitted=int((~used0 & keep).sum()),
                  reject_thr_px=f["thr"], fx=float(f["K"][0, 0]), fy=float(f["K"][1, 1]), cx=float(f["K"][0, 2]),
                  cy=float(f["K"][1, 2]), dist=f["dist"].tolist(), warp_m=[float(x) for x in f["warp"]])
        if G is not None and name in FIELDCAM:
            cd["field"] = field_score(G, FIELDCAM[name], f["K"], f["dist"])
        r["candidates"][key] = cd
        print(name, key, {k: v for k, v in cd.items() if k not in ("dist",)}, flush=True)
    good = [k for k, v in r["candidates"].items() if v["fold_ok"]]
    if not good:
        print(name, "NO non-folding candidate", flush=True)
        continue
    if all("field" in r["candidates"][k] for k in good):
        score = {k: r["candidates"][k]["field"]["p90"] + 2 * r["candidates"][k]["field"]["median"] for k in good}
        best = min(good, key=score.get)
        # prefer the mrcal-style warped board unless another candidate is clearly (>2%) better
        if "8_all_robust" in good and score["8_all_robust"] <= 1.02 * score[best]:
            best = "8_all_robust"
    else:
        best = min(good, key=lambda k: r["candidates"][k]["rms_kept"])
    r["chosen"] = best
    if args.boot:
        r["candidates"][best]["uncertainty"] = bootstrap(c, fits[best], W, H, args.boot)
    if not args.no_write:
        path = os.path.join(L.REPO, "calibrations", f"{name}-refit.json")
        write_pv(name, c, fits[best], path)
        r["file"] = os.path.relpath(path, L.REPO)
    json.dump(R, open(OUTJ, "w"), indent=1)
    print(name, "chosen", best, flush=True)
json.dump(R, open(OUTJ, "w"), indent=1)
print("done")
