"""Item 5: does the TXMAN1 in-frame error follow the calibration's weak regions?

  PYTHONPATH=<deps> python3 field_tie.py REPLAY_DIR

REPLAY_DIR as tests/field-replay/run.sh writes it (only report.json, <match>/frames.csv,
cameras.json and out/base/*.csv are needed). Uses accuracy/judge.py's in-frame (leave-one-tag-out)
measure, but keeps each held-out corner's residual vector and image position, and re-runs it with
the refits from analyze.py (fits.npz) swapped in for the deployed calibration."""
import glob
import json
import os
import sys

import cv2
import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "field-replay"))
import common  # noqa: E402
import fieldgt as g  # noqa: E402
import calib_lib as L  # noqa: E402

root = sys.argv[1]
report = json.load(open(os.path.join(root, "report.json")))
CAMFILE = {"orin-left": "SJ-TC01-1280x800", "orin-right": "SJ-TC02-1280x800"}
fits = np.load(os.path.join(HERE, "fits.npz"))
ana = json.load(open(os.path.join(HERE, "analysis.json")))
VARIANTS = ["deployed", "8_global", "8_global_all_corners", "5_global", "12_global", "14_global"]
NX, NY = 10, 8
W, H = 1280, 800


def caldict(variant, cam, deployed):
    if variant == "deployed":
        K, d, _ = deployed[cam]
        return np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]]), np.array(d, float)
    n = CAMFILE[cam]
    return fits[f"{n}|{variant}|K"], fits[f"{n}|{variant}|d"]


rows = {v: [] for v in VARIANTS}  # (cam, match, x, y, dx, dy, sighting_rms, side)
for mdir in sorted(glob.glob(os.path.join(root, "TXMAN1_*"))):
    m = os.path.basename(mdir)
    frames = common.load_frames(mdir)
    cal, _ = common.calibrations(mdir)
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
    for v in VARIANTS:
        for (s, cam, f), ks in groups.items():
            if len(ks) < 2 or cam not in CAMFILE:
                continue
            Km, dc = caldict(v, cam, cal)
            for k in ks:
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
                e = A[k][0] - pr.reshape(4, 2)  # observed - predicted
                srms = float(np.sqrt(np.mean(np.sum(e ** 2, 1))))
                for c4 in range(4):
                    rows[v].append((cam, m, *A[k][0][c4], *e[c4], srms, A[k][1]))
    print(m, {v: len(rows[v]) for v in VARIANTS}, flush=True)

out = {}
for v in VARIANTS:
    a = rows[v]
    cams = np.array([r[0] for r in a])
    X = np.array([r[2:] for r in a], float)
    out[v] = {}
    for cam in CAMFILE:
        mm = cams == cam
        s = X[mm, 4][::4]  # one per sighting
        out[v][cam] = dict(sightings=int(mm.sum() // 4), sighting_rms_median=float(np.median(s)),
                           sighting_rms_p75=float(np.percentile(s, 75)), sighting_rms_p90=float(np.percentile(s, 90)))
    out[v]["all"] = dict(sighting_rms_median=float(np.median(X[::4, 4])), p90=float(np.percentile(X[::4, 4], 90)))
    if v != "deployed":
        continue
    # per-cell stats for the deployed calibration, per camera
    for cam, name in CAMFILE.items():
        mm = cams == cam
        x, y, dx, dy, srms, side = X[mm].T
        en = np.hypot(dx, dy)
        ci = np.clip((x / W * NX).astype(int), 0, NX - 1)
        cj = np.clip((y / H * NY).astype(int), 0, NY - 1)
        med = np.full((NY, NX), np.nan)
        cnt = np.zeros((NY, NX), int)
        mside = np.full((NY, NX), np.nan)
        for j in range(NY):
            for i in range(NX):
                q = (cj == j) & (ci == i)
                cnt[j, i] = q.sum()
                if q.sum() >= 40:
                    med[j, i] = np.median(en[q])
                    mside[j, i] = np.median(side[q])
        cov = np.array(ana[name]["coverage"]["counts"], float)
        unc = np.array(ana[name]["uncertainty"]["cells"], float) if "uncertainty" in ana[name] else None
        ring = np.zeros((NY, NX), bool)
        ring[0, :] = ring[-1, :] = ring[:, 0] = ring[:, -1] = True
        ok = np.isfinite(med)

        def spear(a, b):
            k = ok & np.isfinite(a) & np.isfinite(b)
            ra = np.argsort(np.argsort(a[k]))
            rb = np.argsort(np.argsort(b[k]))
            return float(np.corrcoef(ra, rb)[0, 1]), int(k.sum())

        # bin by normalized radius too (deployed K)
        K = np.array(caldict("deployed", cam, common.calibrations(glob.glob(os.path.join(root, "TXMAN1_*"))[0])[0])[0])
        rn = L.norm_radius(np.stack([x, y], 1), K)
        robs = ana[name]["coverage"]["max_observed_radius_norm"]
        rb = []
        for a0, a1 in [(0, .2), (.2, .4), (.4, .6), (.6, robs), (robs, .95), (.95, 2)]:
            q = (rn >= a0) & (rn < a1)
            if q.sum() > 40:
                rb.append([round(a0, 3), round(a1, 3), int(q.sum()), float(np.median(en[q])), float(np.median(side[q]))])
        # does small/far tag size explain it? median error by side bin, inside vs beyond observed radius
        sb = []
        for s0, s1 in [(0, 20), (20, 30), (30, 50), (50, 1e9)]:
            q = (side >= s0) & (side < s1)
            qi, qo = q & (rn < robs), q & (rn >= robs)
            sb.append([s0, s1, int(qi.sum()), float(np.median(en[qi])) if qi.sum() > 20 else None,
                       int(qo.sum()), float(np.median(en[qo])) if qo.sum() > 20 else None])
        # systematic part: mean residual vector per 16x10 cell
        BX, BY = 16, 10
        bi = np.clip((x / W * BX).astype(int), 0, BX - 1)
        bj = np.clip((y / H * BY).astype(int), 0, BY - 1)
        mv = np.full((BY, BX, 2), np.nan)
        for j in range(BY):
            for i in range(BX):
                q = (bj == j) & (bi == i)
                if q.sum() >= 40:
                    mv[j, i] = [np.median(dx[q]), np.median(dy[q])]
        out[v][cam].update(
            corner_err_median=float(np.median(en)),
            centre_cells_median=float(np.nanmedian(med[~ring])), ring_cells_median=float(np.nanmedian(med[ring])),
            spearman_err_vs_calib_corners=spear(med, -cov), spearman_err_vs_boot_unc=spear(med, unc) if unc is not None else None,
            spearman_err_vs_tag_side=spear(med, -mside),
            radius_bins=rb, side_bins_inside_vs_beyond=sb, cell_median=np.round(med, 2).tolist(), cell_count=cnt.tolist(),
            cell_vector_median_mag_median=float(np.nanmedian(np.linalg.norm(mv, axis=2))))
        fig, ax = plt.subplots(1, 3, figsize=(18, 4.4))
        im = ax[0].imshow(med, extent=(0, W, H, 0), cmap="magma", vmin=0, vmax=np.nanpercentile(med, 95))
        for j in range(NY):
            for i in range(NX):
                if np.isfinite(med[j, i]):
                    ax[0].text((i + .5) * W / NX, (j + .5) * H / NY, f"{med[j, i]:.1f}\n{int(cov[j, i])}", ha="center", va="center", fontsize=6, color="c")
        plt.colorbar(im, ax=ax[0], fraction=.03)
        ax[0].set_title(f"{cam}: field in-frame corner error median px\n(cyan 2nd line: calibration corners in cell)", fontsize=9)
        X_, Y_ = np.meshgrid((np.arange(BX) + .5) * W / BX, (np.arange(BY) + .5) * H / BY)
        ax[1].quiver(X_, Y_, mv[..., 0] * 30, mv[..., 1] * 30, angles="xy", scale_units="xy", scale=1)
        ax[1].set_xlim(0, W); ax[1].set_ylim(H, 0); ax[1].set_aspect("equal")
        ax[1].set_title(f"{cam}: median field residual vector per cell x30 (obs - pred)", fontsize=9)
        if unc is not None:
            ax[2].scatter(unc[ok].ravel(), med[ok].ravel(), c=ring[ok].ravel(), cmap="coolwarm")
            ax[2].set_xlabel("calibration bootstrap uncertainty px (cell median)")
            ax[2].set_ylabel("field corner error median px"); ax[2].set_title("per cell; red = outer ring", fontsize=9)
        fig.tight_layout(); fig.savefig(os.path.join(HERE, f"field_{cam}.png"), dpi=80); plt.close(fig)

json.dump(out, open(os.path.join(HERE, "field_tie.json"), "w"), indent=1)
for v in VARIANTS:
    print(v, json.dumps({c: {k: (round(x, 3) if isinstance(x, float) else x) for k, x in o.items() if k in ("sightings", "sighting_rms_median", "sighting_rms_p75", "sighting_rms_p90", "p90")} for c, o in out[v].items()}))
