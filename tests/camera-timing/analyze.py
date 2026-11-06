#!/usr/bin/env python3
"""Per-frame timing from a uvc_timing CSV (one row per non-empty isochronous packet).

  analyze.py RUN.csv [--clock HZ] [--exposure-ms E]

Prints (ms, p5/p50/p95):
  - frame period, bytes per frame, data packets per frame, bytes per packet
  - first -> last data packet of a frame ("transfer"), last packet -> next frame's first packet ("gap")
  - UVC header fields: whether PTS/SCR are present, how often SCR changes inside a frame
  - the camera clock: SCR source clock vs host time (slope = clock rate; compared with --clock, the
    descriptor's dwClockFrequency)
  - PTS -> first packet: the camera's own timestamp of the frame mapped to host time through the SCR fit, vs
    when its first packet arrived. What the PTS marks (exposure start, end, or readout start) is firmware
    defined; compare runs at different exposures: if PTS -> first packet grows by the exposure change, PTS
    marks exposure start.
With 1-packet URBs (uvc_timing's default) a packet's host time is its reap time: completion plus interrupt and
wake-up latency (tens of us), never earlier than the bus time.
"""
import sys

import numpy as np


def pct(a, ps=(5, 50, 95)):
    a = np.asarray(a, dtype=float)
    if a.size == 0:
        return "n/a"
    return "/".join("%.3f" % np.percentile(a, p) for p in ps)


def load(path):
    rows = np.loadtxt(path, delimiter=",", skiprows=1, dtype=np.int64, ndmin=2)
    t = rows[:, 0] - rows[:, 1] * 125000  # packet time ~ reap time minus later packets of its URB
    return t, rows[:, 2], rows[:, 3], rows[:, 4], rows[:, 5], rows[:, 6]


def main():
    path = sys.argv[1]
    clock = None
    expo = None
    if "--clock" in sys.argv:
        clock = float(sys.argv[sys.argv.index("--clock") + 1])
    if "--exposure-ms" in sys.argv:
        expo = float(sys.argv[sys.argv.index("--exposure-ms") + 1])
    t, ln, fl, pts, stc, sof = load(path)
    fid = fl & 1
    eof = (fl & 2) != 0
    err = (fl & 0x40) != 0
    # Frame boundaries: FID toggles, or the packet after an EOF.
    start = np.zeros(len(t), dtype=bool)
    start[0] = True
    start[1:] = (fid[1:] != fid[:-1]) | eof[:-1]
    fidx = np.cumsum(start) - 1
    nf = fidx[-1] + 1
    data = ln > 0
    frames = []
    for k in range(1, nf - 1):  # drop the partial first and last frames
        m = (fidx == k) & data
        if not m.any():
            continue
        tt = t[m]
        # The PTS of the first data packet: some cameras (the Thriftiest) toggle FID on header-only packets
        # that still carry the previous frame's PTS.
        md = m & ((fl & 4) != 0)
        p = pts[md]
        s_m = (fidx == k) & ((fl & 8) != 0)
        first = np.argmax(m)
        frames.append(dict(t0=tt[0], t1=tt[-1], bytes=int(ln[m].sum()), npk=int(m.sum()),
                           pts=int(p[0]) if p.size else None, pts_n=len(set(pts[(fidx == k) & ((fl & 4) != 0)].tolist())),
                           stc_first=int(stc[first]) if fl[first] & 8 else None,
                           stc_last=int(stc[np.nonzero(m)[0][-1]]) if fl[first] & 8 else None,
                           scr_n=len(set(stc[s_m].tolist())), err=bool(err[fidx == k].any())))
    if not frames:
        print("no frames")
        return
    t0 = np.array([f["t0"] for f in frames], dtype=float)
    t1 = np.array([f["t1"] for f in frames], dtype=float)
    print("file %s: %d packets, %d frames, %d with ERR, flags seen %s" %
          (path, len(t), len(frames), sum(f["err"] for f in frames), sorted(set((fl & 0xFC).tolist()))))
    print("frame period ms        ", pct(np.diff(t0) / 1e6))
    print("bytes per frame        ", pct([f["bytes"] for f in frames]))
    print("data packets per frame ", pct([f["npk"] for f in frames]))
    print("bytes per data packet  ", pct(ln[data]), " max", ln.max())
    print("first->last packet ms  ", pct((t1 - t0) / 1e6))
    print("last->next first ms    ", pct((t0[1:] - t1[:-1]) / 1e6))
    print("distinct PTS per frame ", pct([f["pts_n"] for f in frames]),
          " distinct SCR per frame", pct([f["scr_n"] for f in frames]))
    sm = (fl & 8) != 0
    if sm.sum() < 50:
        print("no SCR: camera clock not measurable")
        return
    # Fit the camera's source clock against host time. Unwrap the 32-bit counter.
    ts = t[sm].astype(float)
    sc = np.unwrap(stc[sm].astype(float), period=2.0 ** 32)
    A = np.vstack([ts - ts[0], np.ones_like(ts)]).T
    slope, icpt = np.linalg.lstsq(A, sc, rcond=None)[0]
    hz = slope * 1e9
    res_ns = (sc - (slope * (ts - ts[0]) + icpt)) / slope
    print("SCR clock %.4f MHz (descriptor %s), fit residual p5/p50/p95 us %s" %
          (hz / 1e6, "%.4f MHz" % (clock / 1e6) if clock else "?", pct(res_ns / 1e3)))
    # A packet is never seen before it was sent: host time >= device time. Anchor the map on the earliest
    # packets (lowest host-minus-device residual): host = ts0 + (stc - icpt)/slope + lo.
    lo = np.percentile(-res_ns, 1)
    sofs = sof[sm] & 0x7FF
    dsof = np.diff(sofs.astype(float)) % 2048
    dst = np.diff(sc)
    ok = dsof > 0
    if ok.any():
        print("SCR source clock ticks per SOF (1 ms frame): p50 %.1f" % np.median(dst[ok] / dsof[ok]))
    pf = [f for f in frames if f["pts"] is not None]
    if not pf:
        print("no PTS")
        return
    # PTS is in the same clock as SCR's source time. Unwrap near the fitted value at the frame's first packet.
    cam = [((f["stc_first"] - f["pts"]) % 2 ** 32, (f["stc_last"] - f["pts"]) % 2 ** 32) for f in pf
           if f["stc_first"] is not None]
    if cam:
        cam = np.array(cam, dtype=float) / hz * 1e3
        print("camera clock: PTS -> first data packet's SCR ms", pct(cam[:, 0]), "  -> last", pct(cam[:, 1]))
    out = []
    for f in pf:
        sc_at = slope * (f["t0"] - ts[0]) + icpt
        p = float(f["pts"])
        p += np.round((sc_at - p) / 2.0 ** 32) * 2.0 ** 32
        host = ts[0] + (p - icpt) / slope + lo
        out.append((f["t0"] - host, f["t1"] - host))
    out = np.array(out) / 1e6
    print("PTS -> first packet ms ", pct(out[:, 0]), "  PTS -> last packet ms", pct(out[:, 1]))
    pp = np.diff(np.unwrap(np.array([f["pts"] for f in pf], dtype=float), period=2.0 ** 32)) / hz * 1e3
    print("PTS period ms          ", pct(pp))
    if expo is not None:
        print("exposure %.3f ms: if PTS = exposure start, exposure end -> first packet ~ %.3f ms (camera clock %s)"
              % (expo, np.median(out[:, 0]) - expo, "%.3f" % (np.median(cam[:, 0]) - expo) if len(cam) else "n/a"))


if __name__ == "__main__":
    main()
