"""Do the extra sightings a detector setting finds help the robot's pose estimate?

  analyze.py REPLAY --base d15s_far --variants napa,napa16,napafar --dump dump.npz   (field-replay)
  extras.py dump.npz REPLAY > extras.txt

For each variant, every camera frame becomes one pose observation as PhotonVision sends it (one tag:
single-tag IPPE solve with ambiguity; two or more: multi-tag SQPnP), turned into a robot pose with the
camera's mount. robot-vision's Gates.recommended() is applied (insideField 0.5, maxHeight 0.3,
maxTilt 20, single-tag ambiguity 0.3, maxDistance 4.5 / 7 m, maxReprojection 3 px, maxYawRate 3.5,
headingAgreesWithGyro 15 deg; the innovation gate runs inside the filter below against its own
estimate) and TrustModel.recommended() gives the std devs. Then:
  1. the extra sightings (in one variant, not the other): what they are;
  2. how many pass the gates, and their quality against passed common sightings;
  3. coverage (enabled time with an accepted observation), multi-tag changes, and a simple pose
     filter (odometry + vision) with and without them.
See extras-value.md for the results.
"""
import argparse
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "field-replay"))
import common  # noqa: E402
import fieldgt as g  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("dump")
ap.add_argument("root")
ap.add_argument("--base", default="d15s_far")
ap.add_argument("--pairs", default="napa:napa16,d15s_far:napa16,napa:napafar,d15s_far:napafar")
ap.add_argument("--mounts", default="cad", help="cad (the robot code's mounts, what the robot uses) or solved (analyze.py's per-match fit)")
ap.add_argument("--bin-ms", type=float, default=100)
args = ap.parse_args()
P = print

Z = np.load(args.dump, allow_pickle=False)
meta = json.loads(str(Z["meta"]))
PERM = Z["perm"]
T_LOO = meta["T_LOO"]
R = {}
for k in Z.files:
    if "/" in k:
        v, f = k.split("/", 1)
        R.setdefault(v, {})[f] = Z[k]
VARS = list(R)
FIELD_L, FIELD_W = 16.518, 8.043
H2 = g.TAG_SIZE / 2
TAG_LOCAL = np.array([[-H2, H2, 0], [H2, H2, 0], [H2, -H2, 0], [-H2, -H2, 0]])


def pct(a, q):
    a = np.asarray(a, float)
    a = a[np.isfinite(a)]
    return np.percentile(a, q) if len(a) else float("nan")


# ------------------------------------------------------------------------------------------------
# Per match: calibrations, layout, mounts, robot.
MATCH = {}
for m in sorted(meta["info"]):
    mdir = os.path.join(args.root, m)
    cal, _ = common.calibrations(mdir)
    inf = meta["info"][m]
    z = np.load(os.path.join(mdir, "robot.npz"))
    MATCH[m] = dict(cal=cal, tags=g.load_layout(inf["layout"]), mounts=g.MOUNTS["cad"] if args.mounts == "cad" else inf["mounts"],
                    robot=g.Robot(os.path.join(mdir, "robot.npz"), mode="odom"), z={k: z[k] for k in z.files})


def mount_T(mount):
    """Camera-body (x fwd, y left, z up) to robot: rotation and translation."""
    return g.rot(*np.radians(mount[3:])), np.array(mount[:3])


CV2BODY = np.array([[0, 0, 1], [-1, 0, 0], [0, -1, 0]])  # body = CV2BODY @ cv


def robot_pose(rv, tv, mount):
    Rcf, _ = cv2.Rodrigues(rv)  # field -> camera (cv)
    Rfc = Rcf.T
    cam = (-Rfc @ tv).ravel()
    Rf_body = Rfc @ CV2BODY.T
    Rm, tm = mount_T(mount)
    Rfr = Rf_body @ Rm.T
    pos = cam - Rfr @ tm
    yaw = np.arctan2(Rfr[1, 0], Rfr[0, 0])
    pitch = -np.arcsin(np.clip(Rfr[2, 0], -1, 1))
    roll = np.arctan2(Rfr[2, 1], Rfr[2, 2])
    return pos, roll, pitch, yaw


def observations(v):
    """One observation per camera frame of variant v. Returns a dict of arrays plus, per sighting,
    the index of its observation."""
    r = R[v]
    n = len(r["id"])
    fk = np.array([k.rsplit("|", 1)[0] for k in r["key"]])
    order = np.lexsort((fk, r["match"]))
    obs = {k: [] for k in ("match", "camera", "t", "ntag", "x", "y", "z", "roll", "pitch", "yaw", "reproj", "dist", "amb",
                           "edge", "margin", "speed", "w", "enabled", "loo_med")}
    sobs = np.full(n, -1)
    i = 0
    while i < n:
        j = i
        while j < n and fk[order[j]] == fk[order[i]] and r["match"][order[j]] == r["match"][order[i]]:
            j += 1
        idx = order[i:j]
        i = j
        m = r["match"][idx[0]]
        cam = r["camera"][idx[0]]
        M = MATCH[m]
        idx = np.array([k for k in idx if int(r["id"][k]) in M["tags"]])
        if len(idx) == 0:
            continue
        K, dist, _ = M["cal"][cam]
        Km = np.array([[K[0], 0, K[2]], [0, K[1], K[3]], [0, 0, 1]])
        dc = np.array(dist, np.float64)
        det = (r["corners"][idx][:, PERM] - 0.5).reshape(-1, 2).astype(np.float64)
        obj = np.concatenate([M["tags"][int(t)] for t in r["id"][idx]]).astype(np.float64)
        try:
            if len(idx) == 1:
                _, rvs, tvs, errs = cv2.solvePnPGeneric(obj, det, Km, dc, flags=cv2.SOLVEPNP_IPPE)
                k0 = int(np.argmin(np.ravel(errs)))
                rv, tv = rvs[k0], tvs[k0]
                amb = float(r["amb"][idx[0]])
            else:
                ok, rv, tv = cv2.solvePnP(obj, det, Km, dc, flags=cv2.SOLVEPNP_SQPNP)
                if not ok:
                    continue
                amb = 0.0
            pr, _ = cv2.projectPoints(obj, rv, tv, Km, dc)
        except cv2.error:
            continue
        reproj = float(np.sqrt(np.mean(np.sum((pr.reshape(-1, 2) - det) ** 2, -1))))
        Rcf, _ = cv2.Rodrigues(rv)
        dists = [np.linalg.norm(Rcf @ M["tags"][int(t)].mean(0) + tv.ravel()) for t in r["id"][idx]]
        pos, roll, pitch, yaw = robot_pose(rv, tv, M["mounts"][cam])
        o = len(obs["t"])
        sobs[idx] = o
        for k, val in (("match", m), ("camera", cam), ("t", float(np.mean(r["robot_us"][idx]))), ("ntag", len(idx)),
                       ("x", pos[0]), ("y", pos[1]), ("z", pos[2]), ("roll", roll), ("pitch", pitch), ("yaw", yaw),
                       ("reproj", reproj), ("dist", float(np.mean(dists))), ("amb", amb),
                       ("edge", float(np.min(r["edge"][idx]))), ("margin", float(np.min(r["margin"][idx]))),
                       ("speed", float(r["speed"][idx[0]])), ("w", float(r["w"][idx[0]])),
                       ("enabled", bool(r["enabled"][idx[0]])), ("loo_med", float(np.nanmedian(r["loo"][idx])) if np.isfinite(r["loo"][idx]).any() else np.nan)):
            obs[k].append(val)
    obs = {k: np.array(a) for k, a in obs.items()}
    # Gates (robot-vision Gates.recommended(), less the innovation gate: see the filter).
    rej = np.full(len(obs["t"]), "", dtype=object)

    def g_(name, bad):
        rej[(rej == "") & bad] = name

    # Gyro heading: the odometry-mode robot heading (gyro, offset to the field by the fused pose).
    gh = np.zeros(len(obs["t"]))
    for m in MATCH:
        k = obs["match"] == m
        gh[k] = MATCH[m]["robot"].at(obs["t"][k])[2]
    hd = np.abs((obs["yaw"] - gh + np.pi) % (2 * np.pi) - np.pi)
    g_("insideField", (obs["x"] < -0.5) | (obs["x"] > FIELD_L + 0.5) | (obs["y"] < -0.5) | (obs["y"] > FIELD_W + 0.5))
    g_("maxHeight", np.abs(obs["z"]) > 0.3)
    g_("maxTilt", (np.abs(obs["roll"]) > np.radians(20)) | (np.abs(obs["pitch"]) > np.radians(20)))
    g_("maxAmbiguity", (obs["ntag"] == 1) & ((obs["amb"] < 0) | (obs["amb"] > 0.3) | ~np.isfinite(obs["amb"])))
    g_("maxDistance", obs["dist"] > np.where(obs["ntag"] > 1, 7.0, 4.5))
    g_("maxReprojection", obs["reproj"] > 3.0)
    g_("maxYawRate", np.abs(obs["w"]) > 3.5)
    g_("headingAgreesWithGyro", hd > np.radians(15))
    obs["rej"] = rej
    obs["pass"] = rej == ""
    obs["hdiff"] = hd
    obs["xy_sd"] = trust_xy(obs)
    return obs, sobs


def trust_xy(o):
    """TrustModel.recommended() xy std dev (camera factor 1)."""
    n = np.maximum(1, o["ntag"])
    d = np.where(np.isfinite(o["dist"]), o["dist"], 3.0)
    q = np.ones(len(d))
    e = o["edge"]
    q *= np.where(e < 60, 1 + 2.0 * (60 - np.maximum(0, e)) / 60, 1)
    q *= 1 + o["reproj"] / 1.5
    q *= np.where(o["margin"] < 40, 40 / np.maximum(5, o["margin"]), 1)
    q *= np.where((o["ntag"] <= 1) & (o["amb"] > 0), 1 + 4 * o["amb"], 1)
    mf = 1 + np.abs(o["speed"]) * 0.15 + np.abs(o["w"]) * 0.4
    return np.maximum(0.02, 0.02 * d * d / n) * q * mf


OBS, SOBS = {}, {}
for v in VARS:
    OBS[v], SOBS[v] = observations(v)
    o = OBS[v]
    P(f"{v}: {len(R[v]['id'])} sightings -> {len(o['t'])} frame observations ({(o['ntag'] > 1).sum()} multi-tag); "
      f"pass gates {o['pass'].sum()} ({100 * o['pass'].mean():.1f}%), enabled {(o['pass'] & o['enabled']).sum()}")


def describe(v, m, title):
    r = R[v]
    so = SOBS[v][m]
    o = OBS[v]
    alone = np.array([o["ntag"][k] == 1 if k >= 0 else False for k in so])
    li = np.isfinite(r["loo"][m])
    P(f"  {title}: {m.sum()}")
    P(f"    side px p10/p50/p90 {pct(r['side'][m], 10):.1f}/{pct(r['side'][m], 50):.1f}/{pct(r['side'][m], 90):.1f}; "
      f"range m p50/p90/max {pct(r['range'][m], 50):.2f}/{pct(r['range'][m], 90):.2f}/{pct(r['range'][m], 100):.2f}; "
      f"edge px p10/p50 {pct(r['edge'][m], 10):.0f}/{pct(r['edge'][m], 50):.0f}; margin p10/p50 {pct(r['margin'][m], 10):.0f}/{pct(r['margin'][m], 50):.0f}")
    P(f"    in-frame checked {li.sum()}: p50 {pct(r['loo'][m][li], 50):.2f} p90 {pct(r['loo'][m][li], 90):.2f} px, >{T_LOO:.2f} px {100 * np.mean(r['loo'][m][li] > T_LOO) if li.sum() else 0:.1f}%; "
      f"bad (analyze.py labels) {100 * r['bad'][m].sum() / max(r['known'][m].sum(), 1):.1f}% of {r['known'][m].sum()} known")
    P(f"    speed p50 {pct(r['speed'][m], 50):.2f} m/s; enabled {100 * np.mean(r['enabled'][m]):.0f}%; alone in frame {100 * np.mean(alone):.0f}%; "
      f"single-tag ambiguity p50 {pct(r['amb'][m], 50):.2f}")
    return dict(n=int(m.sum()), side50=pct(r["side"][m], 50), range50=pct(r["range"][m], 50), range90=pct(r["range"][m], 90),
                loo50=pct(r["loo"][m][li], 50), loobad=100 * np.mean(r["loo"][m][li] > T_LOO) if li.sum() else np.nan,
                bad=100 * r["bad"][m].sum() / max(r["known"][m].sum(), 1), en=100 * np.mean(r["enabled"][m]), alone=100 * np.mean(alone))


def passed(v, m):
    so = SOBS[v]
    return m & (so >= 0) & OBS[v]["pass"][np.maximum(so, 0)]


SUMMARY = {}
P(f"\nIn-frame bad threshold {T_LOO:.2f} px. Hamming isn't in the replay CSV (max_hamming is 1 for all but napa_h3); margin stands in.")
for pair in args.pairs.split(","):
    a, b = pair.split(":")
    if a not in R or b not in R:
        continue
    A, B = R[a], R[b]
    ext = ~np.isin(B["key"], A["key"])
    com = ~ext
    P(f"\n=== {b} not in {a} (extras) vs in both")
    s = {"extra": describe(b, ext, "extras"), "common": describe(b, com, "common")}
    # Gates.
    pe, pc = passed(b, ext), passed(b, com)
    P(f"  pass gates: extras {pe.sum()} / {ext.sum()} ({100 * pe.sum() / max(ext.sum(), 1):.1f}%), enabled {(pe & B['enabled']).sum()}; "
      f"common {pc.sum()} / {com.sum()} ({100 * pc.sum() / max(com.sum(), 1):.1f}%)")
    for nm, mm in (("extras passed", pe), ("common passed", pc), ("extras rejected", ext & ~pe)):
        li = mm & np.isfinite(B["loo"])
        P(f"    {nm}: {mm.sum()}; in-frame p50 {pct(B['loo'][li], 50):.2f} p90 {pct(B['loo'][li], 90):.2f} px (n={li.sum()}), "
          f">{T_LOO:.2f} {100 * np.mean(B['loo'][li] > T_LOO) if li.sum() else 0:.1f}%; bad {100 * B['bad'][mm].sum() / max(B['known'][mm].sum(), 1):.1f}% "
          f"of {B['known'][mm].sum()}; range p50 {pct(B['range'][mm], 50):.2f} m")
    so = SOBS[b]
    rj = OBS[b]["rej"][np.maximum(so, 0)]
    nt = OBS[b]["ntag"][np.maximum(so, 0)]
    for nm, mm in (("extras alone (single-tag obs)", ext & (so >= 0) & (nt == 1)), ("extras with other tags (multi-tag obs)", ext & (so >= 0) & (nt > 1))):
        u, c = np.unique(rj[mm], return_counts=True)
        P(f"    {nm}: {mm.sum()}; " + ", ".join(f"{(x or 'PASS')} {cc}" for x, cc in sorted(zip(u, c), key=lambda t: -t[1])))
    s["pass_extra"] = int(pe.sum())
    s["pass_extra_en"] = int((pe & B["enabled"]).sum())
    s["pass_common"] = int(pc.sum())
    li = pe & np.isfinite(B["loo"])
    s["pe_loo50"], s["pe_loobad"] = pct(B["loo"][li], 50), 100 * np.mean(B["loo"][li] > T_LOO) if li.sum() else np.nan
    s["pe_bad"] = 100 * B["bad"][pe].sum() / max(B["known"][pe].sum(), 1)
    li = pc & np.isfinite(B["loo"])
    s["pc_loo50"], s["pc_loobad"] = pct(B["loo"][li], 50), 100 * np.mean(B["loo"][li] > T_LOO) if li.sum() else np.nan
    s["pc_bad"] = 100 * B["bad"][pc].sum() / max(B["known"][pc].sum(), 1)
    s["single_alone"] = int((ext & (so >= 0) & (nt == 1)).sum())
    s["single_alone_pass"] = int((pe & (nt == 1)).sum())
    SUMMARY[pair] = s

# ------------------------------------------------------------------------------------------------
# 3a. Coverage: enabled time with at least one accepted observation, per camera and per robot.


def enabled_bins(m):
    z = MATCH[m]["z"]
    et, en = z["enabled_t"], z["enabled"]
    tf = MATCH[m]["robot"].t
    edges = []
    for k in range(len(et)):
        if en[k] > 0.5:
            t1 = et[k + 1] if k + 1 < len(et) else tf[-1]
            edges.append((et[k], t1))
    b = []
    w = args.bin_ms * 1000
    for t0, t1 in edges:
        b.extend(np.arange(t0, t1 - w, w))
    return np.array(b)


def covered(v, m, cam, bins):
    o = OBS[v]
    k = (o["match"] == m) & o["pass"] & ((o["camera"] == cam) if cam else True)
    t = np.sort(o["t"][k])
    i = np.searchsorted(t, bins)
    j = np.searchsorted(t, bins + args.bin_ms * 1000)
    return j > i


P(f"\n=== 3a. Coverage: share of enabled {args.bin_ms:.0f} ms bins with at least one accepted observation")
COV = {}
for m in MATCH:
    bins = enabled_bins(m)
    if len(bins) == 0:
        continue
    for cam in ("orin-left", "orin-right", None):
        line = []
        for v in VARS:
            c = covered(v, m, cam, bins)
            COV.setdefault((v, cam or "robot"), [0, 0])
            COV[(v, cam or "robot")][0] += c.sum()
            COV[(v, cam or "robot")][1] += len(c)
            line.append(f"{v} {100 * c.mean():.1f}%")
        P(f"  {m} {cam or 'robot (any camera)':20s} ({len(bins) * args.bin_ms / 1000:.0f} s): " + ", ".join(line))
P("  TOTAL: " + "; ".join(f"{v}/{c} {100 * a / max(n, 1):.1f}%" for (v, c), (a, n) in sorted(COV.items())))
for pair in args.pairs.split(","):
    a, b = pair.split(":")
    if a not in R or b not in R:
        continue
    gain = loss = tot = 0
    for m in MATCH:
        bins = enabled_bins(m)
        if len(bins) == 0:
            continue
        ca, cb = covered(a, m, None, bins), covered(b, m, None, bins)
        gain += (cb & ~ca).sum()
        loss += (ca & ~cb).sum()
        tot += len(bins)
    # Accepted observations made only of extras.
    ob = OBS[b]
    ext = ~np.isin(R[b]["key"], R[a]["key"])
    allext = np.zeros(len(ob["t"]), bool)
    anyc = np.zeros(len(ob["t"]), bool)
    so = SOBS[b]
    np.logical_or.at(anyc, so[(so >= 0) & ~ext], True)
    np.logical_or.at(allext, so[(so >= 0) & ext], True)
    only = allext & ~anyc & ob["pass"]
    P(f"  {b} vs {a}: robot bins gained {gain} ({100 * gain / max(tot, 1):.2f}% of enabled time, {gain * args.bin_ms / 1000:.1f} s), lost {loss}; "
      f"accepted observations made only of extras {only.sum()} ({(only & ob['enabled']).sum()} enabled) of {ob['pass'].sum()} accepted")
    SUMMARY[pair].update(cov_gain=100 * gain / max(tot, 1), cov_gain_s=gain * args.bin_ms / 1000, cov_loss=100 * loss / max(tot, 1),
                         only_extra_obs=int(only.sum()), only_extra_obs_en=int((only & ob["enabled"]).sum()), accepted=int(ob["pass"].sum()))

# ------------------------------------------------------------------------------------------------
# 3b. Multi-tag: frames where extras join other tags. The same frame without the extras (variant a)
# against with them (variant b): reprojection, std dev, and agreement between the two cameras.


def frame_ids(v):
    o = OBS[v]
    return {f"{m}|{c}|{t:.0f}": i for i, (m, c, t) in enumerate(zip(o["match"], o["camera"], o["t"]))}


P("\n=== 3b. Multi-tag: frames where extras join other tags")
for pair in args.pairs.split(","):
    a, b = pair.split(":")
    if a not in R or b not in R:
        continue
    ob, oa = OBS[b], OBS[a]
    so_b = SOBS[b]
    ext = ~np.isin(R[b]["key"], R[a]["key"])
    fe = np.zeros(len(ob["t"]), bool)
    np.logical_or.at(fe, so_b[(so_b >= 0) & ext], True)
    # Same frame in a: by session|camera|frame key of any common sighting.
    fk_b = np.array([k.rsplit("|", 1)[0] for k in R[b]["key"]])
    fk_a = np.array([k.rsplit("|", 1)[0] for k in R[a]["key"]])
    a_of = {}
    for k, o in zip(fk_a, SOBS[a]):
        if o >= 0:
            a_of[k] = o
    pairs_ = []
    for i in np.flatnonzero(fe & (ob["ntag"] > 1)):
        ks = set(fk_b[so_b == i])
        ia = next((a_of[k] for k in ks if k in a_of), -1)
        pairs_.append((i, ia))
    pairs_ = np.array(pairs_).reshape(-1, 2)
    i_b, i_a = pairs_[:, 0], pairs_[:, 1]
    had = i_a >= 0
    P(f"  {b} vs {a}: {len(i_b)} multi-tag frames with an extra; without the extras {(~had).sum()} had no tag, "
      f"{(had & (oa['ntag'][np.maximum(i_a, 0)] == 1)).sum()} one tag (single-tag), {(had & (oa['ntag'][np.maximum(i_a, 0)] > 1)).sum()} already multi-tag")
    pb = ob["pass"][i_b]
    pa = np.where(had, oa["pass"][np.maximum(i_a, 0)], False)
    P(f"    accepted: without {pa.sum()}, with {pb.sum()} (newly accepted {(pb & ~pa).sum()}, newly rejected {(pa & ~pb).sum()})")
    both = pa & pb
    if both.sum():
        ra, rb = oa["reproj"][i_a[both]], ob["reproj"][i_b[both]]
        sa, sb = oa["xy_sd"][i_a[both]], ob["xy_sd"][i_b[both]]
        dxy = np.hypot(oa["x"][i_a[both]] - ob["x"][i_b[both]], oa["y"][i_a[both]] - ob["y"][i_b[both]])
        P(f"    accepted both ways ({both.sum()}): reprojection p50 {np.median(ra):.2f} -> {np.median(rb):.2f} px; trust xy sd p50 {np.median(sa):.3f} -> {np.median(sb):.3f} m; "
          f"pose moved p50 {np.median(dxy):.3f} p90 {pct(dxy, 90):.3f} m")
        SUMMARY[pair].update(mt_frames=int(len(i_b)), mt_newacc=int((pb & ~pa).sum()), mt_newrej=int((pa & ~pb).sum()),
                             mt_sd=(float(np.median(sa)), float(np.median(sb))), mt_move=float(np.median(dxy)))
    # Camera agreement: left and right accepted observations within 10 ms, at least one with extras.
    for v, nm in ((a, "without"), (b, "with")):
        o = OBS[v]
        L = np.flatnonzero((o["camera"] == "orin-left") & o["pass"])
        Rr = np.flatnonzero((o["camera"] == "orin-right") & o["pass"])
        tr = o["t"][Rr]
        srt = np.argsort(tr)
        tr, Rr = tr[srt], Rr[srt]
        d = []
        for i in L:
            j = np.searchsorted(tr, o["t"][i])
            for jj in (j - 1, j):
                if 0 <= jj < len(tr) and abs(tr[jj] - o["t"][i]) < 10000 and o["match"][Rr[jj]] == o["match"][i]:
                    d.append(np.hypot(o["x"][i] - o["x"][Rr[jj]], o["y"][i] - o["y"][Rr[jj]]))
                    break
        d = np.array(d)
        P(f"    left/right agreement ({nm} extras, {v}): {len(d)} simultaneous accepted pairs, distance p50 {pct(d, 50):.3f} p90 {pct(d, 90):.3f} m")
        SUMMARY[pair][f"lr_{nm}"] = (len(d), pct(d, 50), pct(d, 90))

# ------------------------------------------------------------------------------------------------
# 3c. Pose filter: odometry + accepted vision (x, y; heading from the gyro), robot-vision's
# innovation gate on the filter's own estimate.


def run_filter(v, m):
    M = MATCH[m]
    z = M["z"]
    rob = M["robot"]
    ot, od = z["odom_t"].astype(float), z["odom"]
    oth = np.unwrap(od[:, 2])
    th_f = rob.at(ot)[2]  # field heading (gyro + offset)
    o = OBS[v]
    k = np.flatnonzero((o["match"] == m) & o["pass"])
    k = k[np.argsort(o["t"][k])]
    x0, y0, _, _ = rob.at(ot[0])
    X = np.array([float(x0), float(y0)])
    Pm = np.eye(2) * 1.0
    en = rob.is_enabled(ot)
    out = dict(nis=[], inn=[], jump=0, rej=0, upd=0, est=np.zeros((len(ot), 2)), last=np.full(len(ot), np.nan))
    pending = []
    last_t = np.nan
    vi = 0
    for i in range(len(ot)):
        if i:
            d = od[i, :2] - od[i - 1, :2]
            c, s = np.cos(-oth[i - 1]), np.sin(-oth[i - 1])
            dr = np.array([c * d[0] - s * d[1], s * d[0] + c * d[1]])  # robot frame
            c, s = np.cos(th_f[i - 1]), np.sin(th_f[i - 1])
            X = X + np.array([c * dr[0] - s * dr[1], s * dr[0] + c * dr[1]])
            q = 0.002 + 0.03 * np.linalg.norm(dr)
            Pm = Pm + np.eye(2) * q * q
        while vi < len(k) and o["t"][k[vi]] <= ot[i]:
            j = k[vi]
            vi += 1
            zv = np.array([o["x"][j], o["y"][j]])
            Rm = np.eye(2) * o["xy_sd"][j] ** 2
            inn = zv - X
            S = Pm + Rm
            enabled = bool(o["enabled"][j])
            if enabled and np.linalg.norm(inn) > 1.0:
                # Innovation gate: reset after 3 agreeing rejects within 1 s.
                pending = [p for p in pending if o["t"][j] - p[0] < 1e6 and np.linalg.norm(p[1] - zv) < 0.3] + [(o["t"][j], zv)]
                if len(pending) < 3:
                    out["rej"] += 1
                    continue
                pending = []
                X = zv.copy()
                Pm = Rm.copy()
                out["jump"] += 1
                last_t = o["t"][j]
                continue
            Kg = Pm @ np.linalg.inv(S)
            corr = Kg @ inn
            if enabled:
                out["nis"].append(float(inn @ np.linalg.solve(S, inn)))
                out["inn"].append(float(np.linalg.norm(inn)))
                out["upd"] += 1
                if np.linalg.norm(corr) > 0.25:
                    out["jump"] += 1
            X = X + corr
            Pm = (np.eye(2) - Kg) @ Pm
            last_t = o["t"][j]
        out["est"][i] = X
        out["last"][i] = (ot[i] - last_t) / 1e6
    out["en"] = en
    out["t"] = ot
    return out


P("\n=== 3c. Pose filter (odometry + accepted vision, innovation gate on its own estimate), enabled time")
FILT = {}
for v in VARS:
    nis, inn, jumps, rej, upd, last, dev, mins = [], [], 0, 0, 0, [], [], 0
    for m in MATCH:
        f = run_filter(v, m)
        rob = MATCH[m]["robot"]
        en = f["en"]
        if en.sum() < 100:
            continue
        nis += f["nis"]
        inn += f["inn"]
        jumps += f["jump"]
        rej += f["rej"]
        upd += f["upd"]
        last.append(f["last"][en])
        mins += en.sum() * np.median(np.diff(f["t"])) / 60e6
        # Still-robot consistency against the logged fused pose (weak reference); Q19 excluded.
        sp, _ = rob.motion(f["t"])
        z = MATCH[m]["z"]
        fx = np.interp(f["t"], z["fused_t"], z["fused"][:, 0])
        fy = np.interp(f["t"], z["fused_t"], z["fused"][:, 1])
        still = en & (sp < 0.3)
        dm = np.hypot(f["est"][still, 0] - fx[still], f["est"][still, 1] - fy[still])
        if "Q19" not in m:
            dev.append(dm)
        P(f"    {v} {m}: updates {f['upd']}, rejects {f['rej']}, jumps {f['jump']}, still-robot distance to the logged pose p50 {pct(dm, 50):.3f} p90 {pct(dm, 90):.3f} m, "
          f"time since last correction p90 {pct(f['last'][en], 90):.2f} s")
        FILT[(v, m)] = f
    last = np.concatenate(last)
    last = last[np.isfinite(last)]
    dev = np.concatenate(dev) if dev else np.array([np.nan])
    nis = np.array(nis)
    P(f"  {v:9s}: updates {upd} ({upd / max(mins, 1e-9):.0f}/min), innovation-gate rejects {rej}, jumps (>0.25 m or reset) {jumps} ({jumps / max(mins, 1e-9):.2f}/min); "
      f"NIS mean {nis.mean():.2f} (2 if the std devs were right), >9.21 {100 * np.mean(nis > 9.21):.1f}%; innovation p50 {pct(inn, 50):.3f} p95 {pct(inn, 95):.3f} m; "
      f"time since last correction p50 {pct(last, 50):.2f} p90 {pct(last, 90):.2f} p99 {pct(last, 99):.2f} max {pct(last, 100):.1f} s, >1 s {100 * np.mean(last > 1):.1f}%; "
      f"still-robot distance to the logged pose p50 {pct(dev, 50):.3f} p90 {pct(dev, 90):.3f} m (weak reference, Q19 out)")
    SUMMARY[f"filter {v}"] = dict(upd=upd, rej=rej, jumps_min=jumps / max(mins, 1e-9), nis=float(nis.mean()), nis_out=100 * np.mean(nis > 9.21),
                                  inn50=pct(inn, 50), inn95=pct(inn, 95), last50=pct(last, 50), last90=pct(last, 90), last99=pct(last, 99),
                                  lastmax=pct(last, 100), last1=100 * np.mean(last > 1), dev50=pct(dev, 50), dev90=pct(dev, 90))
# Filter against filter: where do with/without-extras estimates differ, and by how much.
for pair in args.pairs.split(","):
    a, b = pair.split(":")
    d = np.concatenate([np.hypot(*(FILT[(b, m)]["est"] - FILT[(a, m)]["est"])[FILT[(a, m)]["en"]].T) for m in MATCH if (a, m) in FILT and (b, m) in FILT])
    P(f"  {b} vs {a} filter estimates, enabled: differ p50 {pct(d, 50):.3f} p90 {pct(d, 90):.3f} p99 {pct(d, 99):.3f} m, >0.1 m {100 * np.mean(d > 0.1):.1f}% of the time")
    SUMMARY[pair].update(fdiff50=pct(d, 50), fdiff90=pct(d, 90), fdiff99=pct(d, 99))

P("\nSUMMARY " + json.dumps(SUMMARY, default=lambda x: float(x) if np.isscalar(x) else str(x)))
