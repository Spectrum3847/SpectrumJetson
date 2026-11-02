#!/usr/bin/env python3
"""Are two replay variants' detections identical? Compares DATA/replay/*/out/{A,B}/*.csv row by row
(camera, frame, id), corners to the printed precision.   same.py REPLAY A B"""
import csv
import sys
from pathlib import Path


def load(d):
    rows = {}
    for f in sorted(d.glob("*.csv")):
        for r in csv.DictReader(open(f)):
            rows[(f.stem, r["camera"], r["frame"], r["id"])] = [float(r[k]) for k in
                                                               ("x0", "y0", "x1", "y1", "x2", "y2", "x3", "y3")]
    return rows


def main():
    root, a, b = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    A, B = {}, {}
    for m in sorted(root.glob("TXMAN1_*")):
        A.update({(m.name,) + k: v for k, v in load(m / "out" / a).items()})
        B.update({(m.name,) + k: v for k, v in load(m / "out" / b).items()})
    both = A.keys() & B.keys()
    moved = [max(abs(x - y) for x, y in zip(A[k], B[k])) for k in both]
    nmoved = sum(d > 1e-4 for d in moved)
    print(f"{a}: {len(A)} sightings, {b}: {len(B)}; only {a} {len(A.keys() - B.keys())}, only {b} "
          f"{len(B.keys() - A.keys())}; common {len(both)}, corners moved > 1e-4 px: {nmoved}"
          + (f" (max {max(moved):.4f})" if nmoved else ""))
    print("IDENTICAL" if len(A) == len(B) == len(both) and not nmoved else "DIFFERENT")


if __name__ == "__main__":
    main()
