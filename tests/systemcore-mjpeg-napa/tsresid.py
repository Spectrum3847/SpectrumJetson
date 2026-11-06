#!/usr/bin/env python3
"""Published capture timestamp vs the frame's first USB packet, from the kernel's xhci trace (mono clock).

  python3 tsresid.py NT.csv TRACE BUSDEV [--urb-ms 0.25] [--expect-ms 0.5]

NT.csv: nt_check --csv (capture_ns per published result). TRACE: ftrace with xhci_urb_giveback, trace_clock mono.
BUSDEV: the camera's device as the trace prints it (e.g. 3-1 Thriftiest, 1-1 Swyft). A frame's first packet is
estimated from the first data-carrying URB after an idle stretch (frames are separated by URBs with no payload):
first packet ~= that URB's giveback - URB length (the packet may be anywhere in the URB: +-urb/2 uncertainty,
taken as the middle). For each published capture time, the next frame start at or after it is its frame:
residual = first packet - capture, which should equal camera delay + exposure / 2.
"""
import argparse
import bisect
import csv
import re

RX = re.compile(r"\s(\d+\.\d+): xhci_urb_giveback: (\S+) ep\d+in-isoc: urb \S+ pipe \d+ slot \d+ length (\d+)/(\d+)")


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("nt_csv")
    ap.add_argument("trace")
    ap.add_argument("busdev")
    ap.add_argument("--urb-ms", type=float, default=0.25)
    ap.add_argument("--idle-bytes", type=int, default=200, help="URBs with at most this payload count as idle")
    ap.add_argument("--max-ms", type=float, default=6.0, help="ignore matches farther than this")
    a = ap.parse_args()
    ev = []
    for ln in open(a.trace):
        m = RX.search(ln)
        if m and m.group(2) == a.busdev:
            ev.append((float(m.group(1)) * 1e3, int(m.group(3))))
    starts, idle = [], True
    for t, n in ev:
        if n <= a.idle_bytes:
            idle = True
        elif idle:
            starts.append(t - a.urb_ms / 2)
            idle = False
    res = []
    for r in csv.DictReader(open(a.nt_csv)):
        c = int(r["capture_ns"]) / 1e6
        i = bisect.bisect_left(starts, c)
        if i < len(starts) and starts[i] - c < a.max_ms:
            res.append(starts[i] - c)
    per = pct([b - x for x, b in zip(starts, starts[1:])], .5)
    print(f"{a.busdev}: {len(ev)} URBs, {len(starts)} frame starts (period {per:.3f} ms), {len(res)} published frames matched")
    print(f"  first packet - published capture ms p5/p50/p95: {pct(res, .05):.3f} / {pct(res, .5):.3f} / {pct(res, .95):.3f}"
          f"  (+-{a.urb_ms / 2:.3f} ms URB uncertainty)")


if __name__ == "__main__":
    main()
