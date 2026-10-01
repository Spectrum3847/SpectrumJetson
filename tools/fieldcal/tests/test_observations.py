"""The solver against synthetic observations (exact corners plus pixel noise) with a known answer.

    tests/test_observations.py [SEED ...]
"""
import sys, time
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fieldcal import geometry as g, synth, solve as solver
from fieldcal.__main__ import load_layout

layout_json, official = load_layout(Path(__file__).resolve().parents[1] / "layouts" / "2026-rebuilt-andymark.json")


def run(seed: int, big: bool = False) -> bool:
    print(f"--- seed {seed}" + (" with big layout errors" if big else ""))
    truth = synth.make_truth(official, layout_json["field"]["length"], layout_json["field"]["width"], seed=seed, spots=16)
    if big:
        # A practice field built by hand: a whole element 15 cm off (tags 29-32 together), one tag
        # 25 cm along its wall, one turned 5 degrees.
        shift = g.make(g.rpy(0, 0, np.radians(1.0)), [0.0, 0.15, 0.0])
        for t in (29, 30, 31, 32):
            truth.layout[t] = shift @ truth.official[t]
        T = truth.official[26]
        truth.layout[26] = g.make(T[:3, :3], T[:3, 3] + 0.25 * T[:3, 1])
        T = truth.official[21]
        truth.layout[21] = g.make(T[:3, :3] @ g.rpy(0, 0, np.radians(5)), T[:3, 3])
    return check(truth)


def check(truth) -> bool:
    obs = synth.observations(truth, pixel_noise=0.3)
    print(f"{len(truth.spots)} spots, {len(obs)} observations, tags seen {sorted({o.tag for o in obs})}")
    t0 = time.time()
    res = solver.solve(truth.cameras, obs, truth.official)
    print(f"solved in {time.time() - t0:.1f} s; reference camera {res.ref_camera}; spots {len(res.segments)}/{len(truth.spots)}; dropped {len(res.dropped)}")
    pos, ang, moved, bad = [], [], [], []
    for t, T in res.tags.items():
        A = truth.layout[t]
        e = np.linalg.norm(T[:3, 3] - A[:3, 3]) * 100
        a = np.degrees(g.angle_between(A[:3, :3], T[:3, :3]))
        off = np.linalg.norm(A[:3, 3] - truth.official[t][:3, 3]) * 100
        pos.append(e); ang.append(a); moved.append(off)
        # Every tag within 3 sigma of its reported uncertainty.
        if e > 3 * res.tag_sigma[t][0] * 100 or a > 3 * res.tag_sigma[t][1]:
            bad.append(f"tag {t} outside 3 sigma")
        if res.obs_by_tag[t] >= 3 and a > 1.5:
            bad.append(f"tag {t} (seen {res.obs_by_tag[t]}) turned {a:.2f} deg")
        print(f"  tag {t:2d}: seen {res.obs_by_tag[t]:3d}  truth offset {off:4.1f} cm -> solve error {e:4.2f} cm, {a:4.2f} deg  (sigma {res.tag_sigma[t][0]*100:.2f} cm, relative {res.tag_rel_sigma[t]*100:.2f} cm, {res.tag_sigma[t][1]:.2f} deg)")
    print(f"tag error: median {np.median(pos):.2f} cm / {np.median(ang):.2f} deg, max {np.max(pos):.2f} cm / {np.max(ang):.2f} deg")
    # The map's shape alone: after the best rigid fit (x, y, z, yaw) of solved to true tag centres.
    ids = sorted(res.tags)
    A = np.array([truth.layout[t][:3, 3] for t in ids]); B = np.array([res.tags[t][:3, 3] for t in ids])
    ca, cb = A.mean(0), B.mean(0)
    H = (B - cb)[:, :2].T @ (A - ca)[:, :2]
    U, _, Vt = np.linalg.svd(H)
    R2 = Vt.T @ U.T
    B2 = (B - cb)[:, :2] @ R2.T + ca[:2]
    shape = np.linalg.norm(np.c_[B2 - A[:, :2], (B - cb)[:, 2] - (A - ca)[:, 2]], axis=1) * 100
    shift, turn = np.linalg.norm(cb - ca) * 100, np.degrees(np.arctan2(R2[1, 0], R2[0, 0]))
    print(f"map shape error (after best x/y/z/yaw fit): median {np.median(shape):.2f} cm, max {np.max(shape):.2f} cm; "
          f"whole map shifted {shift:.2f} cm, turned {turn:.2f} deg")
    # Shape: well-seen tags within 1.5 cm of where they should be relative to the others. Placement:
    # the whole map within 1 cm and 0.3 deg (the layout prior's job, with some tags really moved).
    for t, e in zip(ids, shape):
        if res.obs_by_tag[t] >= 3 and e > 1.5:
            bad.append(f"tag {t} (seen {res.obs_by_tag[t]}) {e:.2f} cm out of shape")
    if shift > 1.0 or abs(turn) > 0.3:
        bad.append(f"whole map shifted {shift:.2f} cm, turned {turn:.2f} deg")
    # Mounts: height/roll/pitch directly; x/y/yaw after anchoring at the first spot with its true robot pose.
    k = min(res.segments)
    T0 = truth.spots[k]
    T_robot_rig = solver.anchor_reference_spot(res, k, T0[0, 3], T0[1, 3], np.degrees(g.to_rpy(T0[:3, :3])[2]))
    for c, T in res.cameras.items():
        M = T_robot_rig @ T
        A = truth.mounts[c]
        dp = np.linalg.norm(M[:3, 3] - A[:3, 3]) * 100
        da = np.degrees(g.angle_between(A[:3, :3], M[:3, :3]))
        if dp > 2.0 or da > 0.5:
            bad.append(f"{c} mount off by {dp:.2f} cm / {da:.2f} deg")
        print(f"  {c}: mount error {dp:.2f} cm, {da:.2f} deg (height {T[2,3]:.3f} vs {A[2,3]:.3f})")
    if len(res.segments) < len(truth.spots):
        bad.append(f"only {len(res.segments)} of {len(truth.spots)} spots solved")
    for b in bad:
        print("  !", b)
    ok = not bad
    print("PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    big = "--big" in sys.argv
    seeds = [int(a) for a in sys.argv[1:] if not a.startswith("--")] or [1]
    results = {sd: run(sd, big) for sd in seeds}
    print("all passed" if all(results.values()) else f"failed: {[k for k, v in results.items() if not v]}")
    sys.exit(0 if all(results.values()) else 1)
