#!/usr/bin/env python3
"""Relative exposure timing of two cameras from mains flicker (laptop: Pillow + numpy). No test gear.

  flicker_phase.py A.mjpeg DELAY_A_MS EXP_A_MS B.mjpeg DELAY_B_MS EXP_B_MS

Both captures must run AT THE SAME TIME under the same lights (uvc_timing --frames N F.mjpeg on each camera in
parallel; each writes F.mjpeg.idx with every saved frame's first-data-packet time). For each frame, the
estimated mid-exposure time is t_first - DELAY - EXP/2, where DELAY is the assumed exposure end -> first data
packet. Each camera's mean luma is fitted to a + b*cos(2*pi*f*t) + c*sin(2*pi*f*t) at the shared flicker
frequency f (scanned near 120 Hz, the best joint fit). If both DELAYs are right, the two flicker phases agree;
the phase difference, as time, is the error in DELAY_A - DELAY_B (modulo 1/f = 8.33 ms).
"""
import csv
import io
import sys

import numpy as np
from PIL import Image


def load(mjpeg):
    idx = list(csv.DictReader(open(mjpeg + ".idx")))
    data = open(mjpeg, "rb").read()
    lum, i = [], 0
    while len(lum) < len(idx):
        s = data.find(b"\xff\xd8", i)
        e = data.find(b"\xff\xd9", s + 2) if s >= 0 else -1
        if s < 0 or e < 0:
            break
        # Each saved frame is one JPEG; find EOI from the frame's own length to skip FF D9 inside entropy data.
        n = int(idx[len(lum)]["bytes"])
        fr = data[s:s + n]
        try:
            lum.append(np.asarray(Image.open(io.BytesIO(fr)).convert("L"), dtype=np.float32).mean())
        except OSError:
            lum.append(np.nan)
        i = s + n
    t = np.array([int(r["t_first_ns"]) for r in idx[:len(lum)]], dtype=float) / 1e9
    return t, np.array(lum)


def fit(t, y, f):
    m = np.isfinite(y)
    A = np.vstack([np.ones(m.sum()), np.cos(2 * np.pi * f * t[m]), np.sin(2 * np.pi * f * t[m])]).T
    coef, res, _, _ = np.linalg.lstsq(A, y[m], rcond=None)
    amp = np.hypot(coef[1], coef[2])
    phase = np.arctan2(-coef[2], coef[1])  # y ~ a + amp*cos(2 pi f t + phase)
    return amp, phase, coef[0]


def main():
    a, da, ea, b, db, eb = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], float(sys.argv[5]), \
        float(sys.argv[6])
    ta, ya = load(a)
    tb, yb = load(b)
    t0 = min(ta[0], tb[0])
    ta = ta - t0 - (da + ea / 2) / 1e3
    tb = tb - t0 - (db + eb / 2) / 1e3
    best = None
    for f in np.arange(119.80, 120.20, 0.0005):
        s = fit(ta, ya, f)[0] / np.nanstd(ya) + fit(tb, yb, f)[0] / np.nanstd(yb)
        if best is None or s > best[0]:
            best = (s, f)
    f = best[1]
    am, pa, ma = fit(ta, ya, f)
    bm, pb, mb = fit(tb, yb, f)
    dphi = (pa - pb + np.pi) % (2 * np.pi) - np.pi
    # Fitted phase = true phase - 2 pi f * (estimated - true time), so the phase difference gives how much later
    # A's estimated mid-exposure times are than B's, relative to the truth.
    late = -dphi / (2 * np.pi * f) * 1e3
    print("flicker %.4f Hz; A: %d frames, mean %.1f, amplitude %.1f (%.0f%%); B: %d frames, mean %.1f, "
          "amplitude %.1f (%.0f%%)" % (f, len(ya), ma, am, 100 * am / ma, len(yb), mb, bm, 100 * bm / mb))
    print("A's estimated mid-exposure is %+.3f ms vs B's error (modulo %.3f ms); positive: A's assumed delay is "
          "too small by that much" % (late, 1e3 / f))


if __name__ == "__main__":
    main()
