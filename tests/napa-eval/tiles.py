"""Summarise tiles.sh: the share of tiles that are not flat on real field frames.

  python3 tests/napa-eval/tiles.py OUT_DIR

gpu_active: 4x4 tiles of the half-res frame (8x8 px) whose 3x3-tile neighbourhood spans >= 20 grey levels
(the GPU detector's mwbd 20 threshold test). napa_active0/1: NAPA's own test at its first two pyramid
levels (stride 3 and 6 px for min_tag_px 32: tiles of 12x12 and 24x24 px, noise-adaptive floor >= 20).
"""
import csv
import glob
import os
import sys

import numpy as np

rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.csv"))):
    for r in csv.DictReader(open(f)):
        rows.append((float(r["gpu_active"]), float(r["napa_active0"]), float(r["napa_active1"]), int(r["ntags"]), os.path.basename(f)))
a = np.array([r[:4] for r in rows])
print(f"frames {len(a)}")
for i, name in enumerate(["GPU test (8x8 px tiles, mwbd 20)", "NAPA level 0 (12x12 px)", "NAPA level 1 (24x24 px)"]):
    x = a[:, i]
    x = x[x >= 0]
    print(f"{name:34s} active mean {100 * x.mean():5.1f}%  p10 {100 * np.percentile(x, 10):5.1f}%  "
          f"p50 {100 * np.median(x):5.1f}%  p90 {100 * np.percentile(x, 90):5.1f}%  min {100 * x.min():5.1f}%")
busy = a[:, 3] > 0
print(f"frames with a tag: {busy.mean() * 100:.0f}%; GPU-test active on those {100 * a[busy, 0].mean():.1f}%, "
      f"on the others {100 * a[~busy, 0].mean():.1f}%")
