#!/usr/bin/env python3
"""Measure the camera's rolling-shutter line time from mains-light flicker, no special target needed.

  python rollshutter.py CAPTURE.mjpeg [--fps 123.6] [--flicker-hz 120] [--cols 0:1280]

With a short exposure under AC lighting each row's brightness follows the light at the moment that row was
exposed: b(row, frame) = mean(row) * (1 + a * cos(2 pi f (t_frame + row * L) + phi)). A static scene's per-row
mean over all frames is divided out; the remaining modulation is fitted for the line time L (grid search, then
least squares on the phase slope). Compare L * height with the USB transfer time of a frame (~8.1 ms): equal means
the camera streams rows as they are read out (tagCaptureNanos-style per-row timing from USB arrival is valid).
"""
import argparse

import cv2
import numpy as np


def frames(path):
    d = open(path, "rb").read()
    i = 0
    while True:
        s = d.find(b"\xff\xd8", i)
        if s < 0:
            return
        e = d.find(b"\xff\xd9", s)
        if e < 0:
            return
        yield cv2.imdecode(np.frombuffer(d[s:e + 2], np.uint8), 0)
        i = e + 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--fps", type=float, default=0, help="frame rate (default: assume 1/8.09 ms)")
    ap.add_argument("--flicker-hz", type=float, default=120.0)
    ap.add_argument("--cols", default="0:1280")
    a = ap.parse_args()
    c0, c1 = (int(x) for x in a.cols.split(":"))
    rows = np.array([f[:, c0:c1].astype(np.float64).mean(axis=1) for f in frames(a.capture)])  # frames x rows
    nf, h = rows.shape
    rel = rows / rows.mean(axis=0, keepdims=True) - 1.0  # per-row modulation
    w = 2 * np.pi * a.flicker_hz
    rs = rel[:, ::8]  # every 8th row is plenty
    hr = np.arange(0, h, 8)
    periods = [1.0 / a.fps] if a.fps else np.linspace(1 / 126.0, 1 / 117.0, 451)

    def fit(period, L):
        ph = w * (np.arange(nf)[:, None] * period + hr[None, :] * L)
        A = np.stack([np.cos(ph).ravel(), np.sin(ph).ravel()], 1)
        coef, *_ = np.linalg.lstsq(A, rs.ravel(), rcond=None)
        return float(((A @ coef - rs.ravel()) ** 2).sum()), np.hypot(*coef)

    best = None
    for period in periods:  # coarse: frame period with L = 10 us
        r, amp = fit(period, 10e-6)
        if best is None or r < best[0]:
            best = (r, period)
    period = best[1]
    best = None
    for L in np.linspace(-30e-6, 30e-6, 1201):  # line time -30..30 us (negative: bottom row first)
        r, amp = fit(period, L)
        if best is None or r < best[0]:
            best = (r, L, amp)
    for period2 in np.linspace(period * 0.999, period * 1.001, 41):  # refine period at that L
        r, amp = fit(period2, best[1])
        if r < best[0]:
            best, period = (r, best[1], amp), period2
    print(f"frame period {period * 1e3:.4f} ms ({1 / period:.2f} fps)")
    tot = float((rs ** 2).sum())
    r, L, amp = best
    print(f"{nf} frames x {h} rows; flicker amplitude {100 * amp:.1f}%, variance explained {100 * (1 - r / tot):.1f}%")
    print(f"line time {L * 1e6:.2f} us -> rows 0..{h - 1} span {L * h * 1e3:.2f} ms of exposure start times")
    for Lt in (8.1e-3 / h, -8.1e-3 / h, 4e-3 / h):  # a rolling shutter read out over the USB transfer time (or half)
        r2, _ = fit(period, Lt)
        print(f"  if rows spanned {Lt * h * 1e3:+.1f} ms: variance explained {100 * (1 - r2 / tot):.1f}%")


if __name__ == "__main__":
    main()
