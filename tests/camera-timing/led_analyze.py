#!/usr/bin/env python3
"""Camera delay from an LED sweep (uvc_timing --led ... --frames N F.mjpeg). Laptop: Pillow + numpy.

  led_analyze.py F.mjpeg PULSES.csv [--roi X0 Y0 X1 Y1] [--clock HZ]

1. Decodes every saved frame. The LED region is found automatically: pixels that get much brighter than their
   median in a few frames (or give --roi in full-frame pixels).
2. LED signal per frame = mean over the region minus its median.
3. For every pulse, frames trigger+1 .. trigger+3 are candidates. Its on-interval (measured times around the
   sysfs writes) is taken relative to each candidate's first data packet: x = on - t_first(frame).
4. Signal vs x is the overlap of the pulse with the exposure window. A fit of a trapezoid (exposure E, pulse
   width w) gives the exposure window [end - E, end] relative to the first data packet:
   camera delay = -end (exposure end -> first packet), and exposure E as the camera really does it.
The same is done relative to the frame's PTS mapped through the camera clock (--clock, the SCR rate), when
the index has PTS: then the delay is PTS-referenced and free of host jitter.
"""
import csv
import io
import sys

import numpy as np
from PIL import Image


def frames(mjpeg, idx):
    data = open(mjpeg, "rb").read()
    out, i = [], 0
    for r in idx:
        s = data.find(b"\xff\xd8", i)
        n = int(r["bytes"])
        try:
            out.append(np.asarray(Image.open(io.BytesIO(data[s:s + n])).convert("L"), dtype=np.float32)[::2, ::2])
        except OSError:
            out.append(None)
        i = s + n
    return out


def overlap(x, w, a, b):
    """Length of [x, x+w] intersected with [a, b]."""
    return np.clip(np.minimum(x + w, b) - np.maximum(x, a), 0, None)


def fit_window(x, y, w):
    best = None
    for E in np.arange(0.05, 1.5, 0.01):
        for end in np.arange(-6.0, 1.0, 0.005):
            o = overlap(x, w, end - E, end)
            if o.max() <= 0:
                continue
            k = (o @ y) / (o @ o)
            err = float(np.sum((y - k * o) ** 2))
            if best is None or err < best[0]:
                best = (err, end, E, k)
    return best


def main():
    mjpeg, pulses = sys.argv[1], sys.argv[2]
    clock = 48e6
    if "--clock" in sys.argv:
        clock = float(sys.argv[sys.argv.index("--clock") + 1])
    idx = list(csv.DictReader(open(mjpeg + ".idx")))
    P = list(csv.DictReader(open(pulses)))
    ims = frames(mjpeg, idx)
    ok = [k for k, im in enumerate(ims) if im is not None]
    stack = np.stack([ims[k] for k in ok])
    med = np.median(stack, axis=0)
    if "--roi" in sys.argv:
        x0, y0, x1, y1 = (int(v) // 2 for v in sys.argv[sys.argv.index("--roi") + 1:][:4])
        roi = np.zeros_like(med, dtype=bool)
        roi[y0:y1, x0:x1] = True
    else:
        peak = np.percentile(stack - med, 99.5, axis=0)
        roi = peak >= max(20.0, np.percentile(peak, 99.9) * 0.5)
    ys, xs = np.nonzero(roi)
    if ys.size == 0:
        print("no LED region found")
        return
    print("LED region: %d px (half-res), x %d..%d, y %d..%d (full-res x2)" %
          (ys.size, xs.min() * 2, xs.max() * 2, ys.min() * 2, ys.max() * 2))
    sig = np.full(len(ims), np.nan)
    for k in ok:
        sig[k] = float((ims[k] - med)[roi].mean())
    tf = np.array([int(r["t_first_ns"]) for r in idx], dtype=float)
    pts = np.array([int(r["pts"]) for r in idx], dtype=float)
    stc = np.array([int(r["scr_stc"]) for r in idx], dtype=float)
    # PTS in host time: first-data host time minus the camera-clock interval PTS -> first data packet's SCR.
    pts_host = tf - ((stc - pts) % 2 ** 32) / clock * 1e9
    xs_h, xs_p, ys_ = [], [], []
    w = []
    for p in P:
        f = int(p["frame"])
        on = (int(p["on_before_ns"]) + int(p["on_after_ns"])) / 2
        off = (int(p["off_before_ns"]) + int(p["off_after_ns"])) / 2
        w.append((off - on) / 1e6)
        for c in (f + 1, f + 2, f + 3):
            if c < len(ims) and np.isfinite(sig[c]):
                xs_h.append((on - tf[c]) / 1e6)
                xs_p.append((on - pts_host[c]) / 1e6)
                ys_.append(sig[c])
    w = float(np.median(w))
    xs_h, xs_p, ys_ = np.array(xs_h), np.array(xs_p), np.array(ys_)
    print("pulses %d, width %.3f ms (on-write duration p50 %.1f us)" %
          (len(P), w, np.median([(int(p["on_after_ns"]) - int(p["on_before_ns"])) / 1e3 for p in P])))
    print("scheduling error (on - target) p50/p99 us: %.1f / %.1f" % tuple(
        np.percentile([(int(p["on_before_ns"]) - int(p["target_ns"])) / 1e3 for p in P], [50, 99])))
    for name, x in (("first data packet", xs_h), ("PTS (camera clock)", xs_p)):
        m = (x > -12) & (x < 4)
        err, end, E, k = fit_window(x[m], ys_[m], w)
        res = ys_[m] - k * overlap(x[m], w, end - E, end)
        print("relative to %s: exposure window %.3f .. %.3f ms (E = %.3f ms); exposure end -> %s = %.3f ms; "
              "residual rms %.1f of peak %.1f" % (name, end - E, end, E, name, -end, res.std(), k * min(w, E)))
    np.savetxt(mjpeg + ".led.csv", np.vstack([xs_h, xs_p, ys_]).T, delimiter=",", header="x_first_ms,x_pts_ms,signal",
               comments="")


if __name__ == "__main__":
    main()
