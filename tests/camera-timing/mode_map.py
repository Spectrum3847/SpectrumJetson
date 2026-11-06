#!/usr/bin/env python3
"""How a camera mode maps onto the full sensor image: crop window or scaled (laptop: Pillow + numpy).

  mode_map.py FULL.mjpeg MODE.mjpeg [MODE.mjpeg ...]

For each mode, searches scale s (mode pixel = s full pixels) and offset (x0, y0) so that the mode image matches
the full-resolution image resampled to that window, using the median frame of each capture (the scene must be
static between captures). Prints the best (s, x0, y0), the window in full-res pixels and the match error. A
crop at full pixel pitch has s = 1; a binned/scaled mode has s = 2 or full/mode.
"""
import io
import sys

import numpy as np
from PIL import Image


def median_frame(path):
    data = open(path, "rb").read()
    ims, i = [], 0
    while len(ims) < 20:
        s = data.find(b"\xff\xd8", i)
        e = data.find(b"\xff\xd9", s + 2) if s >= 0 else -1
        if s < 0 or e < 0:
            break
        try:
            ims.append(np.asarray(Image.open(io.BytesIO(data[s:e + 2])).convert("L"), dtype=np.float32))
        except OSError:
            pass
        i = e + 2
    return np.median(np.stack(ims), axis=0)


def norm(a):
    a = a - a.mean()
    return a / (a.std() + 1e-6)


def main():
    full = median_frame(sys.argv[1])
    H, W = full.shape
    for path in sys.argv[2:]:
        m = median_frame(path)
        h, w = m.shape
        best = None
        cands = sorted(set([1.0, 2.0, W / w, H / h]))
        for s in cands:
            ww, hh = int(round(w * s)), int(round(h * s))
            if ww > W or hh > H:
                continue
            # The mode image brought to full-res pixel pitch.
            up = np.asarray(Image.fromarray(m).resize((ww, hh), Image.BILINEAR))
            # Compare on a coarse grid of offsets, then refine.
            step = 4
            for refine in (False, True):
                xs = range(0, W - ww + 1, step) if not refine else range(max(0, best[1] - 4), min(W - ww, best[1] + 4) + 1)
                ys = range(0, H - hh + 1, step) if not refine else range(max(0, best[2] - 4), min(H - hh, best[2] + 4) + 1)
                if refine and best[0] != s:
                    continue
                sub = norm(up[::4, ::4])
                for y0 in ys:
                    for x0 in xs:
                        win = norm(full[y0:y0 + hh:4, x0:x0 + ww:4][:sub.shape[0], :sub.shape[1]])
                        if win.shape != sub.shape:
                            continue
                        err = float(np.mean((win - sub) ** 2))
                        if best is None or err < best[3]:
                            best = (s, x0, y0, err)
        s, x0, y0, err = best
        print("%s %dx%d: scale %.3f, window x %d..%d, y %d..%d of %dx%d (error %.3f; 0 = identical, 2 = unrelated)"
              % (path.split("/")[-1].split("\\")[-1], w, h, s, x0, x0 + int(round(w * s)), y0,
                 y0 + int(round(h * s)), W, H, err))


if __name__ == "__main__":
    main()
