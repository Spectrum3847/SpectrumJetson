#!/usr/bin/env python3
"""Where uvcvideo's frame timestamp sits relative to the camera's PTS (= end of exposure + 0.045 ms, LED-measured
on the Thriftiest), from a v4l2_ts run with the metadata node (OUT.csv + OUT.csv.scr). numpy.

  ts_vs_pts.py OUT.csv [--clock 48e6] [--exposure-end-to-pts-ms 0.045]

1. Fits the camera's source clock (SCR) to host time from the metadata: each header's host time is when uvcvideo
   processed its URB (late by up to one URB), so the map is anchored on the earliest headers (lower envelope).
2. Maps each new PTS to host time, matches it to the video frame whose buffer timestamp is nearest, and prints
   buffer timestamp - PTS (ms).
3. The camera delay to configure for that timestamp (mid-exposure = timestamp - exposure/2 - D) is
   D = (timestamp - PTS) + (exposure end -> PTS).
"""
import sys

import numpy as np


def pct(a):
    return "/".join("%.3f" % np.percentile(a, p) for p in (5, 50, 95))


def main():
    path = sys.argv[1]
    clock = 48e6
    e2p = 0.045
    if "--clock" in sys.argv:
        clock = float(sys.argv[sys.argv.index("--clock") + 1])
    if "--exposure-end-to-pts-ms" in sys.argv:
        e2p = float(sys.argv[sys.argv.index("--exposure-end-to-pts-ms") + 1])
    fr = np.genfromtxt(path, delimiter=",", names=True, dtype=np.int64)
    sc = np.genfromtxt(path + ".scr", delimiter=",", names=True, dtype=np.int64)
    stc = np.unwrap(sc["scr_stc"].astype(float), period=2.0 ** 32)
    host = sc["host_ns"].astype(float)
    # Linear fit, then shift to the lower envelope (headers seen with the least delay).
    A = np.vstack([stc - stc[0], np.ones_like(stc)]).T
    k, c = np.linalg.lstsq(A, host, rcond=None)[0]
    res = host - (k * (stc - stc[0]) + c)
    lo = np.percentile(res, 0.5)
    print("SCR clock %.4f MHz (expected %.4f); host lag over the envelope p50 %.3f ms, p95 %.3f ms"
          % (1e3 / k, clock / 1e6, np.percentile(res - lo, 50) / 1e6, np.percentile(res - lo, 95) / 1e6))
    pts = sc["pts"]
    m = pts != 0
    # New PTS values in order, with the stc of the first header carrying each (unwrap PTS near that stc).
    first = {}
    for p, s in zip(pts[m], stc[m]):
        if p not in first:
            first[p] = s
    ph = []
    for p, s in first.items():
        pu = float(p) + np.round((s - float(p)) / 2.0 ** 32) * 2.0 ** 32
        ph.append(k * (pu - stc[0]) + c + lo)
    ph = np.sort(np.array(ph))
    ts = fr["ts_ns"][2:].astype(float)
    j = np.searchsorted(ph, ts)
    cand = np.stack([ph[np.clip(j - 1, 0, len(ph) - 1)], ph[np.clip(j, 0, len(ph) - 1)]])
    best = cand[np.argmin(np.abs(cand - ts), axis=0), np.arange(len(ts))]
    d = (ts - best) / 1e6
    print("frames %d; buffer timestamp - PTS (ms) p5/p50/p95: %s" % (len(d), pct(d)))
    print("=> camera delay for this timestamp: D = %.3f ms (exposure end -> PTS %.3f ms added)" %
          (np.median(d) + e2p, e2p))
    dq = (fr["dq_ns"][2:] - fr["ts_ns"][2:]) / 1e6
    print("DQBUF - buffer timestamp (ms) p5/p50/p95: %s" % pct(dq))


if __name__ == "__main__":
    main()
