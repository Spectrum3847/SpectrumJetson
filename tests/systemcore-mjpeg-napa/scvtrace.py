#!/usr/bin/env python3
"""Cross-check a native app's own per-frame timestamps against the kernel's xhci trace (mono clock).

  python3 scvtrace.py APP.csv TRACE [--t-first COL --t-eof COL --t-pose COL]   (defaults: sc-vision's columns)

For each frame: the last iso URB giveback at or before the app's "EOF reap" time (the kernel finished the URB
holding the frame's last packet then); reap delay = app EOF time - that giveback; and the first data URB of the
frame (first giveback with length > 0 after the previous frame's EOF giveback) to check the app's first-packet
estimate. Then the latency the kernel sees: first data URB giveback -> pose, last URB giveback -> pose.
"""
import argparse
import bisect
import csv
import re

RX = re.compile(r"\s(\d+\.\d+): xhci_urb_giveback: \S+ ep\d+in-isoc: urb \S+ pipe \d+ slot \d+ length (\d+)/(\d+)")


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")


def line(name, v):
    print(f"  {name:46s} p50 {pct(v, .5):7.3f} p95 {pct(v, .95):7.3f} p99 {pct(v, .99):7.3f} max {max(v):7.3f} (n {len(v)})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("trace")
    ap.add_argument("--t-first", default="t_first")
    ap.add_argument("--t-eof", default="t_eof_reap")
    ap.add_argument("--t-pose", default="t_pose")
    ap.add_argument("--skip", type=int, default=20)
    a = ap.parse_args()
    ev = []
    for ln in open(a.trace):
        m = RX.search(ln)
        if m:
            ev.append((float(m.group(1)) * 1e3, int(m.group(2))))
    ts = [e[0] for e in ev]
    rows = list(csv.DictReader(open(a.csv)))[a.skip :]
    reap, first_err, k_first_pose, k_last_pose, app_first_pose = [], [], [], [], []
    prev_eof_i = None
    for r in rows:
        eof = int(r[a.t_eof]) / 1e6
        i = bisect.bisect_right(ts, eof) - 1
        if i < 0:
            continue
        reap.append(eof - ts[i])
        pose = int(r[a.t_pose]) / 1e6
        k_last_pose.append(pose - ts[i])
        app_first_pose.append(pose - int(r[a.t_first]) / 1e6)
        if prev_eof_i is not None:
            j = prev_eof_i + 1
            while j <= i and ev[j][1] == 0:
                j += 1
            if j <= i:
                # first data URB: its first packet is up to one URB (0.5 ms here) before its giveback
                first_err.append(int(r[a.t_first]) / 1e6 - ts[j])
                k_first_pose.append(pose - ts[j])
        prev_eof_i = i
    print(f"{a.csv}: {len(rows)} frames, {len(ev)} iso URB givebacks")
    line("app EOF reap - kernel giveback of last URB ms", reap)
    line("app t_first - kernel giveback of first data URB", first_err)
    line("kernel last-URB giveback -> pose ms", k_last_pose)
    line("kernel first-data-URB giveback -> pose ms", k_first_pose)
    line("app t_first -> pose ms (app's own)", app_first_pose)


if __name__ == "__main__":
    main()
