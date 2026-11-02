#!/usr/bin/env python3
"""Per-frame time of each build in exp.sh's timing A/B, pooled over rounds.  abtime.py WORK/timing-ab"""
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ms = defaultdict(list)
for f in sorted(Path(sys.argv[1]).glob("*/*/*.csv")):
    build, case = f.parent.name, f.stem
    ms[(case, build)] += [float(r["ms"]) for r in csv.DictReader(open(f))]
print("| Case | Build | frames | mean ms | median | p95 | vs base (mean) |\n|---|---|---|---|---|---|---|")
for (case, build), v in sorted(ms.items(), key=lambda kv: (kv[0][0], kv[0][1] != "base", kv[0][1])):
    v.sort()
    base = ms.get((case, "base"))
    rel = f"{100 * (statistics.mean(v) / statistics.mean(base) - 1):+.1f}%" if base and build != "base" else ""
    print(f"| {case} | {build} | {len(v)} | {statistics.mean(v):.3f} | {statistics.median(v):.3f} | "
          f"{v[int(0.95 * len(v))]:.3f} | {rel} |")
