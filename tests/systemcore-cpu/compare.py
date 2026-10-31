"""Compare Bench.java's detections with a reference detector's (the GPU detector's replay CSVs).

  compare.py REF_DIR OUT_DIR

REF_DIR holds <session>.csv in detector-replay's format (a field-replay match's out/base, say);
OUT_DIR is a run.sh output with <variant>/<session>.csv. Matches rows by (session, camera, frame
jetson_us, id); only frames the bench looked at count. Per variant: reference tags found / missed,
extra tags, and per-corner differences (px, full resolution): mean offset (x, y), median and p90 of
the corner distance, by tag size. Both sides use the same corner convention, so a constant offset
is a convention or scaling error, not noise.
"""
import csv
import glob
import os
import sys

import numpy as np


def load(path):
    out = {}
    with open(path) as f:
        r = csv.reader(f)
        next(r)
        for v in r:
            if len(v) < 15 or v[6] != "normal":
                continue
            k = (v[0], int(v[2]), int(v[3]))
            out.setdefault(k, (np.array([float(x) for x in v[7:15]]).reshape(4, 2), float(v[5]), float(v[4])))
    return out


def main():
    ref_dir, out_dir = sys.argv[1], sys.argv[2]
    looked = set()
    with open(os.path.join(out_dir, "frames.csv")) as f:
        r = csv.reader(f)
        next(r)
        for v in r:
            looked.add((v[0], v[1], int(v[2])))
    for vdir in sorted(glob.glob(os.path.join(out_dir, "*/"))):
        variant = os.path.basename(vdir.rstrip("/"))
        if variant == "classes":
            continue
        found = missed = extra = 0
        diffs, sides = [], []
        for f in sorted(glob.glob(os.path.join(vdir, "*.csv"))):
            rf = os.path.join(ref_dir, os.path.basename(f))
            if not os.path.exists(rf):
                continue
            session = os.path.basename(f)[:-4]
            mine, ref = load(f), load(rf)
            for k, (c, side, _) in ref.items():
                if (session, k[0], k[1]) not in looked:
                    continue
                if k in mine:
                    found += 1
                    diffs.append(mine[k][0] - c)
                    sides.append(side)
                else:
                    missed += 1
            extra += sum(1 for k in mine if k not in ref)
        if not found + missed:
            print(f"{variant}: no overlap with the reference")
            continue
        d = np.array(diffs)
        dist = np.linalg.norm(d, axis=2)  # (n, 4)
        sides = np.array(sides)
        print(f"{variant}: reference tags found {found}/{found + missed} ({100 * found / (found + missed):.1f}%), "
              f"extra {extra}")
        if found:
            print(f"  corner offset mean x {d[..., 0].mean():+.3f} y {d[..., 1].mean():+.3f} px; "
                  f"distance median {np.median(dist):.3f} p90 {np.percentile(dist, 90):.3f} px")
            for lo, hi in ((0, 20), (20, 40), (40, 80), (80, 1e9)):
                m = (sides >= lo) & (sides < hi)
                if m.sum():
                    print(f"  side {lo:>3}-{hi if hi < 1e9 else 'up':<3} px: n {m.sum():5d}  median {np.median(dist[m]):.3f}"
                          f"  p90 {np.percentile(dist[m], 90):.3f}")


if __name__ == "__main__":
    main()
