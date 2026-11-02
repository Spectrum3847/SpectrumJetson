"""Shared code: load PhotonVision calibration JSON (mrcal-produced), refit it with our own
bundle adjustment (OpenCV projection, 5/8/12/14 coefficients, optional mrcal-style board warp),
and compare models over the image (rotation-compensated, as mrcal's projection-diff does)."""
import json
import os

import cv2
import numpy as np
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def load(name):
    d = json.load(open(os.path.join(REPO, "calibrations", name + ".json")))
    K = np.array(d["cameraIntrinsics"]["data"]).reshape(3, 3)
    W, H = int(d["resolution"]["width"]), int(d["resolution"]["height"])
    bw, bh = int(d["calobjectSize"]["width"]), int(d["calobjectSize"]["height"])
    sp = d["calobjectSpacing"]
    snaps = []
    for o in d["observations"]:
        obj = np.array([[p["x"], p["y"], p["z"]] for p in o["locationInObjectSpace"]])
        img = np.array([[p["x"], p["y"]] for p in o["locationInImageSpace"]])
        ij = np.round(obj[:, :2] / sp).astype(int)
        # cornersUsed is indexed by board corner id (row-major, bw per row), all bw*bh of them:
        # False for undetected corners and for mrcal's outliers. reprojectionErrors is shorter
        # than the detections and unaligned, so residuals are recomputed, not read.
        cu = np.array(o["cornersUsed"], bool)
        used = cu[ij[:, 1] * bw + ij[:, 0]]
        snaps.append(dict(obj=obj, img=img, used=used, ij=ij, name=o["snapshotName"]))
    return dict(K=K, dist=np.array(d["distCoeffs"]["data"]), W=W, H=H, bw=bw, bh=bh, sp=sp,
                warp=np.array(d.get("calobjectWarp") or [0, 0]), snaps=snaps)


def warp_basis(ij, bw, bh):
    """mrcal's board deflection: z = w0*(1-xr^2) + w1*(1-yr^2), xr = 2i/bw - 1 (as the files
    store it; checked against the stored z)."""
    xr = 2 * ij[:, 0] / bw - 1
    yr = 2 * ij[:, 1] / bh - 1
    return np.stack([1 - xr ** 2, 1 - yr ** 2], 1)


def flat(c, s):
    o = s["obj"].copy()
    o[:, 0], o[:, 1], o[:, 2] = s["ij"][:, 0] * c["sp"], s["ij"][:, 1] * c["sp"], 0
    return o


def fit(c, nd=8, warp="global", mask="used", snaps=None, K0=None, d0=None, poses0=None):
    """Bundle-adjust intrinsics + nd distortion coeffs + per-snapshot pose (+ warp).
    warp: 'none' | 'global' (2 params, mrcal) | 'per' (2 per snapshot).
    mask: 'used' (PV/mrcal inliers) | 'all'. Returns dict with K, dist, poses, residuals."""
    snaps = c["snaps"] if snaps is None else snaps
    K0 = c["K"] if K0 is None else K0
    d0 = np.zeros(nd) if d0 is None else d0
    d0 = np.concatenate([d0, np.zeros(max(0, nd - len(d0)))])[:nd]
    S = []
    for s in snaps:
        m = s["used"] if mask == "used" else np.ones(len(s["used"]), bool)
        S.append((flat(c, s)[m], s["img"][m], warp_basis(s["ij"][m], c["bw"], c["bh"])))
    nw = {"none": 0, "global": 2, "per": 0}[warp]
    npp = 8 if warp == "per" else 6
    ni = 4 + nd + nw
    poses = []
    for k, (o, im, _) in enumerate(S):
        if poses0 is not None:
            poses.append(poses0[k])
            continue
        ok, rv, tv = cv2.solvePnP(o, im, K0, c["dist"][:min(8, len(c["dist"]))], flags=cv2.SOLVEPNP_ITERATIVE)
        poses.append(np.concatenate([rv.ravel(), tv.ravel()]))
    x0 = [K0[0, 0], K0[1, 1], K0[0, 2], K0[1, 2], *d0]
    if nw:
        x0 += [0.0, 0.0]
    for p in poses:
        x0 += list(p[:6]) + ([0.0, 0.0] if warp == "per" else [])
    x0 = np.array(x0, float)
    nres = sum(2 * len(o) for o, _, _ in S)
    sl = []
    r0 = 0
    for k, (o, _, _) in enumerate(S):
        sl.append((r0, r0 + 2 * len(o), ni + npp * k))
        r0 += 2 * len(o)
    sparsity = lil_matrix((nres, len(x0)), dtype=int)
    for a, b, p in sl:
        sparsity[a:b, :ni] = 1
        sparsity[a:b, p:p + npp] = 1

    def unpack(x):
        K = np.array([[x[0], 0, x[2]], [0, x[1], x[3]], [0, 0, 1]])
        return K, x[4:4 + nd], x[4 + nd:4 + nd + nw]

    def proj(x, k, eps_w=None):
        K, d, w = unpack(x)
        o, im, B = S[k]
        p = x[sl[k][2]:sl[k][2] + npp]
        ww = p[6:8] if warp == "per" else w
        oo = o.copy()
        if len(ww):
            oo[:, 2] = B @ ww
        pr, J = cv2.projectPoints(oo, p[:3], p[3:6], K, d)
        return pr.reshape(-1, 2), J, oo

    def resid(x):
        return np.concatenate([(proj(x, k)[0] - S[k][1]).ravel() for k in range(len(S))])

    def jac(x):
        Jm = lil_matrix((nres, len(x0)))
        K, d, w = unpack(x)
        for k in range(len(S)):
            a, b, p = sl[k]
            pr, J, oo = proj(x, k)
            # cv2 jacobian columns: rvec3 tvec3 fx fy cx cy dist...
            Jm[a:b, p:p + 6] = J[:, :6]
            Jm[a:b, 0:4] = J[:, 6:10]
            Jm[a:b, 4:4 + nd] = J[:, 10:10 + nd]
            if nw or warp == "per":
                cols = list(range(4 + nd, 4 + nd + 2)) if nw else [p + 6, p + 7]
                for q in range(2):
                    e = 1e-6
                    o2 = oo.copy()
                    o2[:, 2] += e * S[k][2][:, q]
                    pp, _ = cv2.projectPoints(o2, x[p:p + 3], x[p + 3:p + 6], K, d)
                    Jm[a:b, cols[q]] = ((pp.reshape(-1, 2) - pr) / e).ravel()[:, None]
        return Jm.tocsr()

    r = least_squares(resid, x0, jac=jac, method="trf", x_scale="jac", tr_solver="lsmr",
                      max_nfev=60, ftol=1e-10, xtol=1e-10)
    K, d, w = unpack(r.x)
    res = resid(r.x).reshape(-1, 2)
    out_poses = [r.x[p:p + npp] for _, _, p in sl]
    # residual of every corner (incl. masked) at the solution
    allres = []
    for k, s in enumerate(snaps):
        p = out_poses[k]
        ww = p[6:8] if warp == "per" else w
        oo = flat(c, s)
        if len(ww):
            oo[:, 2] = warp_basis(s["ij"], c["bw"], c["bh"]) @ ww
        pr, _ = cv2.projectPoints(oo, p[:3], p[3:6], K, d)
        allres.append(pr.reshape(-1, 2) - s["img"])
    return dict(K=K, dist=d, warp=w, poses=out_poses, res=res, allres=allres,
                rms=float(np.sqrt(np.mean(np.sum(res ** 2, 1)))), nparam=len(x0), nobs=len(res),
                cost=r.cost)


def distort(xy, d):
    """OpenCV distortion of normalized coords (N,2); d has 5, 8, 12 or 14 coefficients (14:
    the tilt terms are ignored, they are 0 in every fit here)."""
    d = np.concatenate([d, np.zeros(14 - len(d))])
    k1, k2, p1, p2, k3, k4, k5, k6, s1, s2, s3, s4 = d[:12]
    x, y = xy[:, 0], xy[:, 1]
    r2 = x * x + y * y
    rad = (1 + k1 * r2 + k2 * r2 ** 2 + k3 * r2 ** 3) / (1 + k4 * r2 + k5 * r2 ** 2 + k6 * r2 ** 3)
    xd = x * rad + 2 * p1 * x * y + p2 * (r2 + 2 * x * x) + s1 * r2 + s2 * r2 ** 2
    yd = y * rad + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y + s3 * r2 + s4 * r2 ** 2
    return np.stack([xd, yd], 1)


def unproject(px, K, d):
    """Pixel -> unit ray. Newton on our own distort() (OpenCV's iterative undistort fails by
    tens of px at the corners of this lens with these rational models)."""
    t = np.stack([(px[:, 0] - K[0, 2]) / K[0, 0], (px[:, 1] - K[1, 2]) / K[1, 1]], 1)
    x = t.copy()
    for _ in range(50):
        f = distort(x, d) - t
        e = 1e-7
        jx = (distort(x + [e, 0], d) - distort(x, d)) / e
        jy = (distort(x + [0, e], d) - distort(x, d)) / e
        det = jx[:, 0] * jy[:, 1] - jy[:, 0] * jx[:, 1]
        dx = (jy[:, 1] * f[:, 0] - jy[:, 0] * f[:, 1]) / det
        dy = (-jx[:, 1] * f[:, 0] + jx[:, 0] * f[:, 1]) / det
        x = x - np.stack([dx, dy], 1)
    bad = ~(np.linalg.norm(distort(x, d) - t, axis=1) < 1e-9)
    x[bad] = np.nan  # outside the model's range (the rational model folds over there)
    v = np.concatenate([x, np.ones((len(px), 1))], 1)
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def max_radius(d, rmax=3.0):
    """Largest distorted (normalized) radius the model reaches before its radial curve folds:
    pixels beyond it have no valid ray."""
    r = np.linspace(0, rmax, 30001)
    rd = distort(np.stack([r, 0 * r], 1), d)[:, 0]
    i = np.argmax(np.diff(rd) <= 0) if (np.diff(rd) <= 0).any() else len(r) - 1
    return float(rd[i]), float(r[i])


def norm_radius(px, K):
    return np.hypot((px[:, 0] - K[0, 2]) / K[0, 0], (px[:, 1] - K[1, 2]) / K[1, 1])


def grid(W, H, nx=64, ny=40):
    xs = (np.arange(nx) + 0.5) * W / nx
    ys = (np.arange(ny) + 0.5) * H / ny
    X, Y = np.meshgrid(xs, ys)
    return np.stack([X.ravel(), Y.ravel()], 1), (ny, nx)


def projection_diff(KA, dA, KB, dB, W, H, fit_region=None, nx=64, ny=40):
    """mrcal-style: pixel q -> ray with model A (at infinity; with rotation-only compensation range doesn't matter) -> best rigid
    rotation (fit over fit_region mask, default whole image) -> project with model B -> |diff|.
    Rotation-only compensation (the camera frame is arbitrary between solves)."""
    q, shape = grid(W, H, nx, ny)
    va = unproject(q, KA, dA)
    vb = unproject(q, KB, dB)
    m = np.ones(len(q), bool) if fit_region is None else fit_region(q)
    m &= np.isfinite(va).all(1) & np.isfinite(vb).all(1)
    # Kabsch: R such that R va ~= vb
    Hm = va[m].T @ vb[m]
    U, _, Vt = np.linalg.svd(Hm)
    D = np.diag([1, 1, np.sign(np.linalg.det(Vt.T @ U.T))])
    R = Vt.T @ D @ U.T
    pts = (R @ va.T).T
    pr = np.full((len(q), 2), np.nan)
    ok = np.isfinite(pts).all(1)
    p2, _ = cv2.projectPoints(pts[ok], np.zeros(3), np.zeros(3), KB, dB)
    pr[ok] = p2.reshape(-1, 2)
    e = np.linalg.norm(pr - q, axis=1)
    e[~np.isfinite(vb).all(1)] = np.nan  # B can't represent this pixel either
    return e.reshape(shape), q
