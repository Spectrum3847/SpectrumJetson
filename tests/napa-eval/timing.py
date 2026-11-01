"""Summarise timing.sh's per-frame times: median / p95 / max ms per frame, and frames a second.

  python3 tests/napa-eval/timing.py OUT_DIR
"""
import csv
import glob
import os
import sys

import numpy as np

for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.csv"))):
    ms = np.array([float(r["ms"]) for r in csv.DictReader(open(f))])
    if not len(ms):
        continue
    name = os.path.basename(f)[:-4]
    par = 4 if name.endswith("_p4") else 1
    print(f"{name:12s} n {len(ms):5d}  median {np.median(ms):6.2f}  p95 {np.percentile(ms, 95):6.2f}  "
          f"max {ms.max():6.2f} ms   ~{1000 * par / ms.mean():5.0f} frames/s on 4 cores")
