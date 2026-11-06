#!/usr/bin/env python3
"""Summary of sc-vision per-frame CSVs (branch sc/mjpeg-napa), for comparing camera modes/firmware.

  napa_stats.py RUN.csv [RUN.csv ...]

Per run (ms, p50/p95/p99): frame period, transfer (first packet -> EOF URB reaped), first packet -> pose,
EOF -> pose (tail), decode and NAPA CPU per frame, bytes; detection rate, decision margin, tag corner
spread (pixels), pose tz mean and std (mm) of the most common tag id.
"""
import csv
import sys

import numpy as np


def pct(a):
    a = np.asarray(a, dtype=float)
    if a.size == 0:
        return "n/a"
    return "/".join("%.2f" % np.percentile(a, p) for p in (50, 95, 99))


def main():
    for path in sys.argv[1:]:
        rows = list(csv.DictReader(open(path)))
        if not rows:
            print(path, "empty")
            continue
        g = lambda k: np.array([float(r[k]) for r in rows])  # noqa: E731
        t0, teof, tpose = g("t_first"), g("t_eof_reap"), g("t_pose")
        ntags = g("ntags")
        print("== %s: %d frames, tags in %.1f%%" % (path, len(rows), 100 * np.mean(ntags > 0)))
        print("  period ms            ", pct(np.diff(t0) / 1e6))
        print("  transfer ms          ", pct((teof - t0) / 1e6))
        print("  first packet->pose ms", pct((tpose - t0) / 1e6))
        print("  EOF->pose ms         ", pct((tpose - teof) / 1e6))
        print("  decode / NAPA us     ", pct(g("dec_cpu_us")), "/", pct(g("napa_cpu_us")))
        print("  bytes                ", pct(g("bytes")))
        det = [r for r in rows if int(r["ntags"]) > 0 and r["id"] not in ("", "-1")]
        if det:
            ids = [r["id"] for r in det]
            top = max(set(ids), key=ids.count)
            d = [r for r in det if r["id"] == top]
            m = np.array([float(r["margin"]) for r in d])
            tz = np.array([float(r["tz"]) for r in d]) * 1000
            side = np.array([np.hypot(float(r["c1x"]) - float(r["c0x"]), float(r["c1y"]) - float(r["c0y"]))
                             for r in d])
            print("  tag %s: margin p5/p50 %.1f/%.1f, side %.1f px, tz %.1f mm (std %.2f mm)" %
                  (top, np.percentile(m, 5), np.median(m), np.median(side), tz.mean(), tz.std()))


if __name__ == "__main__":
    main()
