"""Calibration analysis of the deployed 1280x800 calibrations (items 1-4 of RESULTS.md).

  PYTHONPATH=<numpy/scipy/opencv/matplotlib> python3 analyze.py [--boot N] [--out DIR]

Writes PNGs + analysis.json next to this file (or --out) and caches the refits in fits.npz for
field_tie.py. CPU only; a full run with --boot 30 takes ~20 min on the laptop."""
import argparse
import json
import os

import cv2
import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

import calib_lib as L  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--boot", type=int, default=30)
ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
ap.add_argument("--cams", default="SJ-TC01-1280x800,SJ-TC02-1280x800")
args = ap.parse_args()
OUT = args.out
NX, NY = 10, 8  # coverage grid
R = {}
fits_cache = {}


def cellidx(px, W, H, nx=NX, ny=NY):
    i = np.clip((px[:, 0] / W * nx).astype(int), 0, nx - 1)
    j = np.clip((px[:, 1] / H * ny).astype(int), 0, ny - 1)
    return j, i


def ring_mask(nx=NX, ny=NY):
    m = np.zeros((ny, nx), bool)
    m[0, :] = m[-1, :] = m[:, 0] = m[:, -1] = True
    return m


def corner_mask(nx=NX, ny=NY):
    m = np.zeros((ny, nx), bool)
    m[:2, :2] = m[:2, -2:] = m[-2:, :2] = m[-2:, -2:] = True
    return m


def deployed_residuals(c):
    """Residuals of the deployed (PV/mrcal) model: per snapshot, pose re-solved with the deployed
    intrinsics and the deployed warped board. Returns per-snapshot arrays (all detected corners)."""
    out, poses = [], []
    for s in c["snaps"]:
        m = s["used"]
        o = s["obj"]
        ok, rv, tv = cv2.solvePnP(o[m], s["img"][m], c["K"], c["dist"])
        rv, tv = cv2.solvePnPRefineLM(o[m], s["img"][m], c["K"], c["dist"], rv, tv)
        p, _ = cv2.projectPoints(o, rv, tv, c["K"], c["dist"])
        out.append(p.reshape(-1, 2) - s["img"])
        poses.append((rv.ravel(), tv.ravel()))
    return out, poses


def rms(a):
    a = np.asarray(a).reshape(-1, 2)
    return float(np.sqrt(np.mean(np.sum(a ** 2, 1)))) if len(a) else float("nan")


for name in args.cams.split(","):
    c = L.load(name)
    W, H, K, D = c["W"], c["H"], c["K"], c["dist"]
    tag = name.split("-")[1]
    r = R[name] = {}
    img = np.concatenate([s["img"] for s in c["snaps"]])
    used = np.concatenate([s["used"] for s in c["snaps"]])
    r["snapshots"] = len(c["snaps"])
    r["corners_detected"] = int(len(img))
    r["corners_outliers"] = int((~used).sum())
    r["corners_per_snapshot_median"] = float(np.median([len(s["img"]) for s in c["snaps"]]))
    r["partial_snapshots(<88)"] = int(sum(len(s["img"]) < c["bw"] * c["bh"] for s in c["snaps"]))

    # ---------------- 1. coverage
    cnt = np.zeros((NY, NX), int)
    j, i = cellidx(img[used], W, H)
    np.add.at(cnt, (j, i), 1)
    snapcnt = np.zeros((NY, NX), int)
    for s in c["snaps"]:
        jj, ii = cellidx(s["img"][s["used"]], W, H)
        z = np.zeros((NY, NX), bool)
        z[jj, ii] = True
        snapcnt += z
    ring, cm = ring_mask(), corner_mask()
    r["coverage"] = dict(
        cells_empty=int((cnt == 0).sum()), cells_lt20=int((cnt < 20).sum()), cells=NX * NY,
        ring_cells=int(ring.sum()), ring_empty=int((cnt[ring] == 0).sum()), ring_lt20=int((cnt[ring] < 20).sum()),
        corner_2x2_blocks_corners=[int(cnt[:2, :2].sum()), int(cnt[:2, -2:].sum()), int(cnt[-2:, :2].sum()), int(cnt[-2:, -2:].sum())],
        centre_cells_median=float(np.median(cnt[~ring])), ring_cells_median=float(np.median(cnt[ring])),
        snapshots_per_cell_min=int(snapcnt.min()), snapshots_per_cell_ring_median=float(np.median(snapcnt[ring])),
        snapshots_per_cell_centre_median=float(np.median(snapcnt[~ring])),
        counts=cnt.tolist(), snaps_per_cell=snapcnt.tolist())
    # Fraction of image pixels farther (normalized radius) than any observed corner
    q, sh = L.grid(W, H, 128, 80)
    rq = L.norm_radius(q, K)
    robs = L.norm_radius(img[used], K)
    r["coverage"]["max_observed_radius_norm"] = float(robs.max())
    r["coverage"]["image_frac_beyond_observed_radius"] = float((rq > robs.max()).mean())
    r["coverage"]["image_frac_beyond_p99_observed_radius"] = float((rq > np.percentile(robs, 99)).mean())
    # Pixel distance of observations to the image border
    edge = np.minimum(np.minimum(img[:, 0], W - img[:, 0]), np.minimum(img[:, 1], H - img[:, 1]))
    r["coverage"]["inliers_within_40px_of_border"] = int((edge[used] < 40).sum())
    r["coverage"]["inliers_within_80px_of_border"] = int((edge[used] < 80).sum())

    # Model range: the radial curve of the deployed model folds over
    mr, mr_u = L.max_radius(D)
    corners_px = np.array([[0, 0], [W, 0], [0, H], [W, H]], float)
    FR = lambda qq: L.norm_radius(qq, K) < np.percentile(robs, 90)  # noqa: E731  rotation fit region
    gq, _ = L.grid(W, H)
    inside = (L.norm_radius(gq, K) <= robs.max()).reshape(40, 64)
    r["model_range"] = dict(max_distorted_radius=mr, at_undistorted_radius=mr_u,
                            image_corner_radii=L.norm_radius(corners_px, K).round(3).tolist(),
                            image_frac_outside_model=float((rq > mr).mean()))

    fig, ax = plt.subplots(1, 2, figsize=(13, 4.4))
    im = ax[0].imshow(cnt, extent=(0, W, H, 0), cmap="viridis")
    for jj in range(NY):
        for ii in range(NX):
            ax[0].text((ii + .5) * W / NX, (jj + .5) * H / NY, cnt[jj, ii], ha="center", va="center",
                       color="w" if cnt[jj, ii] < cnt.max() / 2 else "k", fontsize=7)
    plt.colorbar(im, ax=ax[0], fraction=.03)
    ax[0].set_title(f"{tag}: inlier corners per cell ({NX}x{NY})")
    ax[1].scatter(img[used, 0], img[used, 1], s=.3, c="0.6", label="inlier")
    ax[1].scatter(img[~used, 0], img[~used, 1], s=8, c="r", label="outlier")
    th = np.linspace(0, 2 * np.pi, 400)
    for rr, col, lab in ((robs.max(), "b", "max observed radius"), (mr, "m", "model folds (no valid ray beyond)")):
        # undistorted circle at normalized distorted radius rr -> pixel (approx, ignores tangential)
        ax[1].plot(K[0, 2] + K[0, 0] * rr * np.cos(th), K[1, 2] + K[1, 1] * rr * np.sin(th), col, lw=1, label=lab)
    ax[1].set_xlim(0, W); ax[1].set_ylim(H, 0); ax[1].set_aspect("equal")
    ax[1].legend(fontsize=7, loc="lower right"); ax[1].set_title(f"{tag}: all detected corners, outliers red")
    fig.tight_layout(); fig.savefig(os.path.join(OUT, f"{tag}_coverage.png"), dpi=80); plt.close(fig)

    # ---------------- 2. residual structure (deployed model)
    dres, dposes = deployed_residuals(c)
    allr = np.concatenate(dres)
    r["deployed_rms_inliers"] = rms(allr[used])
    r["deployed_mean_inliers"] = float(np.linalg.norm(allr[used], axis=1).mean())
    r["deployed_rms_outliers"] = rms(allr[~used])
    # binned mean residual (systematic part) vs per-cell scatter
    BX, BY = 16, 10
    jj, ii = cellidx(img[used], W, H, BX, BY)
    mean = np.full((BY, BX, 2), np.nan)
    n = np.zeros((BY, BX), int)
    for a in range(BY):
        for b in range(BX):
            m = (jj == a) & (ii == b)
            n[a, b] = m.sum()
            if m.sum() >= 10:
                mean[a, b] = allr[used][m].mean(0)
    mag = np.linalg.norm(mean, axis=2)
    r["residual_binned"] = dict(cell_mean_mag_median=float(np.nanmedian(mag)), cell_mean_mag_max=float(np.nanmax(mag)),
                                systematic_rms=float(np.sqrt(np.nanmean(mag ** 2))),
                                note="mean residual per 16x10 cell (>=10 corners); compare with overall rms")
    # radial / tangential components vs normalized radius
    rad = L.norm_radius(img, K)
    u = np.stack([(img[:, 0] - K[0, 2]) / K[0, 0], (img[:, 1] - K[1, 2]) / K[1, 1]], 1)
    u /= np.maximum(np.linalg.norm(u, axis=1, keepdims=True), 1e-9)
    # residual is projected - observed; flip to observed - model so "+" means corner lies outward
    res_out = -allr
    rcomp = np.sum(res_out * u, 1)
    tcomp = res_out[:, 0] * -u[:, 1] + res_out[:, 1] * u[:, 0]
    edges = np.linspace(0, robs.max() + 1e-6, 13)
    rb = []
    for a, b in zip(edges[:-1], edges[1:]):
        m = used & (rad >= a) & (rad < b)
        if m.sum() > 20:
            rb.append([float((a + b) / 2), int(m.sum()), float(np.median(rcomp[m])), float(np.median(tcomp[m])),
                       float(np.sqrt(np.mean(np.sum(allr[m] ** 2, 1))))])
    r["radial_bins(r_norm,n,median_radial,median_tangential,rms)"] = rb

    # per snapshot vs tilt / distance
    tilt, dist, srms = [], [], []
    for s, (rv, tv), e in zip(c["snaps"], dposes, dres):
        Rm, _ = cv2.Rodrigues(rv)
        tilt.append(np.degrees(np.arccos(abs(Rm[2, 2]))))
        dist.append(float(np.linalg.norm(Rm @ np.array([c["bw"] - 1, c["bh"] - 1, 0]) * c["sp"] / 2 + tv)))
        srms.append(rms(e[s["used"]]))
    tilt, dist, srms = map(np.array, (tilt, dist, srms))
    r["snapshots_geometry"] = dict(dist_m_min=float(dist.min()), dist_m_median=float(np.median(dist)), dist_m_max=float(dist.max()),
                                   tilt_deg_median=float(np.median(tilt)), tilt_deg_max=float(tilt.max()),
                                   frac_tilt_lt15=float((tilt < 15).mean()), frac_tilt_gt35=float((tilt > 35).mean()),
                                   corr_rms_tilt=float(np.corrcoef(tilt, srms)[0, 1]), corr_rms_dist=float(np.corrcoef(dist, srms)[0, 1]),
                                   snap_rms_median=float(np.median(srms)), snap_rms_max=float(srms.max()))

    fig, ax = plt.subplots(1, 3, figsize=(17, 4.6))
    X, Y = np.meshgrid((np.arange(BX) + .5) * W / BX, (np.arange(BY) + .5) * H / BY)
    sc = 200
    ax[0].quiver(X, Y, -mean[..., 0] * sc, -mean[..., 1] * sc, mag, angles="xy", scale_units="xy", scale=1, cmap="plasma")
    ax[0].set_xlim(0, W); ax[0].set_ylim(H, 0); ax[0].set_aspect("equal")
    ax[0].set_title(f"{tag}: mean residual per cell (obs - model) x{sc}\nsystematic rms {r['residual_binned']['systematic_rms']:.3f} px vs total {r['deployed_rms_inliers']:.3f}", fontsize=9)
    rb_ = np.array(rb)
    ax[1].scatter(rad[used], rcomp[used], s=.3, c="0.7")
    ax[1].plot(rb_[:, 0], rb_[:, 2], "r-o", label="median radial")
    ax[1].plot(rb_[:, 0], rb_[:, 3], "b-o", label="median tangential")
    ax[1].plot(rb_[:, 0], rb_[:, 4], "k--", label="rms")
    ax[1].set_ylim(-1, 1); ax[1].axhline(0, c="k", lw=.5); ax[1].legend(fontsize=7)
    ax[1].set_xlabel("normalized radius"); ax[1].set_ylabel("px"); ax[1].set_title(f"{tag}: residual vs radius")
    p = ax[2].scatter(dist, srms, c=tilt, cmap="coolwarm", s=12)
    plt.colorbar(p, ax=ax[2], label="board tilt deg")
    ax[2].set_xlabel("board distance m"); ax[2].set_ylabel("snapshot rms px"); ax[2].set_title(f"{tag}: per-snapshot rms")
    fig.tight_layout(); fig.savefig(os.path.join(OUT, f"{tag}_residuals.png"), dpi=80); plt.close(fig)

    # ---------------- flatness + 4. model check (refits)
    fits = {}
    for key, kw in [("8_global", dict(nd=8, warp="global")), ("8_flat", dict(nd=8, warp="none")),
                    ("8_per_snapshot_warp", dict(nd=8, warp="per")), ("5_global", dict(nd=5, warp="global")),
                    ("12_global", dict(nd=12, warp="global")), ("14_global", dict(nd=14, warp="global")),
                    ("8_global_all_corners", dict(nd=8, warp="global", mask="all"))]:
        f = L.fit(c, **kw)
        fits[key] = f
        ar = np.concatenate(f["allres"])
        ring_px = np.zeros(len(img), bool)
        jx, ix = cellidx(img, W, H)
        ring_px = ring[jx, ix]
        dd, _ = L.projection_diff(c["K"], c["dist"], f["K"], f["dist"], W, H, fit_region=FR)
        mr2, _ = L.max_radius(f["dist"])
        R[name].setdefault("fits", {})[key] = dict(
            rms_inliers=rms(ar[used]), rms_outliers=rms(ar[~used]), rms_ring_inliers=rms(ar[used & ring_px]),
            rms_centre_inliers=rms(ar[used & ~ring_px]), nparam=f["nparam"],
            fx=float(f["K"][0, 0]), fy=float(f["K"][1, 1]), cx=float(f["K"][0, 2]), cy=float(f["K"][1, 2]),
            dist=f["dist"].tolist(), warp_m=f["warp"].tolist() if len(f["warp"]) else None,
            per_snapshot_warp_mm_median=(float(np.median(np.abs([p[6:8] for p in f["poses"]])) * 1e3) if key == "8_per_snapshot_warp" else None),
            model_max_radius=mr2, image_frac_outside_model=float((rq > mr2).mean()),
            diff_vs_deployed_px=dict(median=float(np.nanmedian(dd)), p90=float(np.nanpercentile(dd, 90)),
                                     covered_median=float(np.nanmedian(dd[inside])), covered_p90=float(np.nanpercentile(dd[inside], 90)),
                                     beyond_median=float(np.nanmedian(dd[~inside])), beyond_p90=float(np.nanpercentile(dd[~inside], 90)),
                                     corners_2x2=[float(np.nanmax(dd[:8, :8])), float(np.nanmax(dd[:8, -8:])), float(np.nanmax(dd[-8:, :8])), float(np.nanmax(dd[-8:, -8:]))],
                                     nan_frac=float(np.isnan(dd).mean())))
        print(name, key, R[name]["fits"][key]["rms_inliers"], flush=True)
    fits_cache[name] = {k: (f["K"], f["dist"]) for k, f in fits.items()}

    # model-difference maps (edge behaviour)
    fig, ax = plt.subplots(1, 4, figsize=(20, 3.6))
    for a, key in zip(ax, ["5_global", "12_global", "14_global", "8_global_all_corners"]):
        dd, _ = L.projection_diff(fits["8_global"]["K"], fits["8_global"]["dist"], fits[key]["K"], fits[key]["dist"], W, H, fit_region=FR)
        im = a.imshow(dd, extent=(0, W, H, 0), vmin=0, vmax=3, cmap="magma")
        a.scatter(img[used, 0][::7], img[used, 1][::7], s=.1, c="c")
        a.set_title(f"{tag}: |8-coef refit - {key}| px\n(median {np.nanmedian(dd):.2f}, white/grey = no valid ray)", fontsize=8)
    plt.colorbar(im, ax=ax[-1], fraction=.04)
    fig.tight_layout(); fig.savefig(os.path.join(OUT, f"{tag}_model_diff.png"), dpi=80); plt.close(fig)

    # ---------------- 3. uncertainty: bootstrap snapshots
    base = fits["8_global"]
    rng = np.random.default_rng(1)
    maps = []
    for b in range(args.boot):
        idx = rng.integers(0, len(c["snaps"]), len(c["snaps"]))
        sn = [c["snaps"][k] for k in idx]
        f = L.fit(c, nd=8, warp="global", snaps=sn, K0=base["K"], d0=base["dist"],
                  poses0=[base["poses"][k] for k in idx])
        dd, _ = L.projection_diff(base["K"], base["dist"], f["K"], f["dist"], W, H, fit_region=FR)
        maps.append(dd)
        print(name, "boot", b, np.nanmedian(dd), flush=True)
    if maps:
        M = np.array(maps)
        unc = np.sqrt(np.nanmean(M ** 2, 0))  # rms projection shift over resamples
        nanfrac = np.isnan(M).mean(0)
        g, sh = L.grid(W, H)
        gj, gi = cellidx(g, W, H)
        cellunc = np.zeros((NY, NX))
        for a in range(NY):
            for b2 in range(NX):
                cellunc[a, b2] = np.nanmedian(unc.ravel()[(gj == a) & (gi == b2)])
        r["uncertainty"] = dict(boot=args.boot, median_px=float(np.nanmedian(unc)),
                                covered_median=float(np.nanmedian(unc[inside])), beyond_median=float(np.nanmedian(unc[~inside])), centre_cells_median=float(np.nanmedian(cellunc[~ring])),
                                ring_cells_median=float(np.nanmedian(cellunc[ring])), corner_cells_max=float(np.nanmax(cellunc[cm])),
                                frac_pixels_gt_0p5px=float(np.nanmean(unc > .5)), frac_pixels_any_fold=float((nanfrac > 0).mean()),
                                cells=cellunc.round(3).tolist())
        fig, ax = plt.subplots(figsize=(7, 4.6))
        im = ax.imshow(unc, extent=(0, W, H, 0), cmap="magma", vmin=0, vmax=max(1.0, np.nanpercentile(unc, 95)))
        ax.scatter(img[used, 0][::5], img[used, 1][::5], s=.1, c="c")
        plt.colorbar(im, ax=ax, label="rms projection shift px")
        ax.set_title(f"{tag}: bootstrap projection uncertainty ({args.boot} resamples)\ncyan = calibration corners; grey = a resample has no valid ray", fontsize=9)
        fig.tight_layout(); fig.savefig(os.path.join(OUT, f"{tag}_uncertainty.png"), dpi=80); plt.close(fig)
        np.save(os.path.join(OUT, f".{tag}_unc.npy"), unc)
    json.dump(R, open(os.path.join(OUT, "analysis.json"), "w"), indent=1)

np.savez(os.path.join(OUT, "fits.npz"), **{f"{n}|{k}|{p}": v for n, d in fits_cache.items() for k, kv in d.items() for p, v in zip("Kd", kv)})
json.dump(R, open(os.path.join(OUT, "analysis.json"), "w"), indent=1)
print("done")
