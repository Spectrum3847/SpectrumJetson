#!/usr/bin/env python3
"""Mean luma of MJPEG captures, for exposure-control linearity (run on the laptop: needs Pillow + numpy).

  brightness.py DIR [--exposure-unit-ms 0.1]

DIR holds eN.mjpeg files (N = the exposure_time_absolute setting, as sweep.sh writes them). Prints, per setting:
mean luma (frames p50), the fraction of pixels at 255, and luma per ms of the nominal exposure. With a fixed
scene and gain, a linear exposure control gives a constant luma-per-ms column (until highlights clip).
"""
import glob
import io
import os
import re
import sys

import numpy as np
from PIL import Image


def frames(data):
    i = 0
    while True:
        s = data.find(b"\xff\xd8", i)
        e = data.find(b"\xff\xd9", s + 2) if s >= 0 else -1
        if s < 0 or e < 0:
            return
        yield data[s:e + 2]
        i = e + 2


def main():
    d = sys.argv[1]
    unit = 0.1
    if "--exposure-unit-ms" in sys.argv:
        unit = float(sys.argv[sys.argv.index("--exposure-unit-ms") + 1])
    rows = []
    for f in glob.glob(os.path.join(d, "e*.mjpeg")):
        m = re.match(r"e(\d+)\.mjpeg$", os.path.basename(f))
        if not m:
            continue
        means, sat = [], []
        for fr in frames(open(f, "rb").read()):
            try:
                y = np.asarray(Image.open(io.BytesIO(fr)).convert("L"), dtype=np.float32)
            except OSError:
                continue
            means.append(y.mean())
            sat.append((y >= 254).mean())
        if means:
            rows.append((int(m.group(1)), np.median(means), np.median(sat), len(means)))
    print("setting  nominal_ms  mean_luma  sat%  luma/ms  frames")
    for e, mean, s, n in sorted(rows):
        print("%7d  %10.2f  %9.2f  %4.1f  %7.1f  %6d" % (e, e * unit, mean, 100 * s, mean / (e * unit), n))


if __name__ == "__main__":
    main()
