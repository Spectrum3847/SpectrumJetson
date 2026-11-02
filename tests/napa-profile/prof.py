#!/usr/bin/env python3
"""Summarise tests/napa-profile/profile.sh's --profile CSVs: mean per-frame time by stage and by pyramid
level, and mean candidates per stage per level.   prof.py OUT [CASE...]   (default prof32 prof16 proffar)"""
import csv
import statistics
import sys
from pathlib import Path

STAGES = [("rake", "rake (sampling)"), ("floors", "noise floors (+ box re-rake)"),
          ("threshold", "tile min/max + threshold"), ("runs", "dark bits + run extraction"),
          ("union", "union-find (row linking)"), ("resolve", "component resolve"),
          ("blobs", "blob filter + extreme points + loop tail"), ("quad", "rough quad + fill/area filter"),
          ("probe", "border probe (s <= 2)"), ("fit1", "first edge fit"), ("decode1", "early decode (+ rescue)"),
          ("refine", "refine fits"), ("decode2", "final decode"), ("repair", "repairs (side/clip)")]
COUNTS = ["runs", "roots", "cands", "covered", "quad", "probe", "fit1", "failskip", "early", "rescue", "refine",
          "final", "tags"]


def summarise(path):
    rows = list(csv.DictReader(open(path)))
    n = len(rows)
    if not n:
        return
    ms = [float(r["ms"]) for r in rows]
    print(f"\n## {path.stem}: {n} frames, wall ms/frame mean {statistics.mean(ms):.3f}, "
          f"median {statistics.median(ms):.3f}, p95 {sorted(ms)[int(0.95 * n)]:.3f}")
    tot = {k: sum(float(r["ns_" + k]) for r in rows) / n / 1e6 for k, _ in STAGES}
    s = sum(tot.values())
    print(f"timed stages sum {s:.3f} ms/frame\n")
    print("| Stage | ms/frame | share |\n|---|---|---|")
    for k, name in STAGES:
        print(f"| {name} | {tot[k]:.3f} | {100 * tot[k] / s:.1f}% |")
    levels = [l for l in range(8) if any(float(r[f"ns_L{l}"]) for r in rows)]
    print("\n| Level (stride x base) | ms/frame | " + " | ".join(COUNTS) + " |")
    print("|---|---|" + "---|" * len(COUNTS))
    for l in levels:
        t = sum(float(r[f"ns_L{l}"]) for r in rows) / n / 1e6
        c = [sum(float(r[f"L{l}_{k}"]) for r in rows) / n for k in COUNTS]
        print(f"| L{l} (x{2 ** l}) | {t:.3f} | " + " | ".join(f"{v:.1f}" if v < 1000 else f"{v:,.0f}" for v in c) + " |")
    allc = [sum(float(r[f"L{l}_{k}"]) for r in rows for l in levels) / n for k in COUNTS]
    print("| all | | " + " | ".join(f"{v:.1f}" if v < 1000 else f"{v:,.0f}" for v in allc) + " |")


def main():
    out = Path(sys.argv[1])
    for c in sys.argv[2:] or ["prof32", "prof16", "proffar"]:
        p = out / f"{c}.csv"
        if p.exists():
            summarise(p)


if __name__ == "__main__":
    main()
