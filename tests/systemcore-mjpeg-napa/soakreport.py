#!/usr/bin/env python3
"""Summarize a soak.sh run: per 5-minute window, latency / tail / CPU per frame / frame gaps, plus RSS, fds,
threads, temperature and throttle flags from sysmon.csv. Columns default to sc-vision's CSV.

  python3 soakreport.py SOAK_DIR [--t-first t_first --t-eof t_eof_reap --t-pose t_pose --cpu frame_cpu_us]
"""
import argparse
import csv
import os


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--t-first", default="t_first")
    ap.add_argument("--t-eof", default="t_eof_reap")
    ap.add_argument("--t-pose", default="t_pose")
    ap.add_argument("--cpu", default="frame_cpu_us")
    ap.add_argument("--window-s", type=float, default=300)
    a = ap.parse_args()
    rows = list(csv.DictReader(open(os.path.join(a.dir, "frames.csv"))))
    t0 = int(rows[0][a.t_first])
    per = sorted((int(b[a.t_first]) - int(x[a.t_first])) / 1e6 for x, b in zip(rows, rows[1:]))[len(rows) // 2]
    print(f"{a.dir}: {len(rows)} frames, frame period p50 {per:.3f} ms")
    print(" window   frames  first->pose p50/p95/p99/max     tail p50/p95/p99    cpu ms p50/p95   gaps(missing)  tags%")
    w = 0
    while True:
        lo, hi = t0 + w * a.window_s * 1e9, t0 + (w + 1) * a.window_s * 1e9
        rs = [r for r in rows if lo <= int(r[a.t_first]) < hi]
        if not rs:
            break
        lat = [(int(r[a.t_pose]) - int(r[a.t_first])) / 1e6 for r in rs]
        tail = [(int(r[a.t_pose]) - int(r[a.t_eof])) / 1e6 for r in rs]
        cpu = [float(r[a.cpu]) / 1e3 for r in rs if r.get(a.cpu)]
        iv = [(int(b[a.t_first]) - int(x[a.t_first])) / 1e6 for x, b in zip(rs, rs[1:])]
        gaps = [x for x in iv if x > 1.5 * per]
        missing = sum(round(x / per) - 1 for x in gaps)
        tags = 100 * sum(1 for r in rs if r.get("ntags", "1") not in ("0", "")) / len(rs)
        print(f" {w * a.window_s / 60:4.0f}min {len(rs):7d}  {pct(lat, .5):6.2f} {pct(lat, .95):6.2f} {pct(lat, .99):6.2f} "
              f"{max(lat):6.2f}   {pct(tail, .5):5.2f} {pct(tail, .95):5.2f} {pct(tail, .99):5.2f}   "
              f"{pct(cpu, .5):5.2f} {pct(cpu, .95):5.2f}   {len(gaps):4d}({missing})   {tags:5.1f}")
        w += 1
    sm = os.path.join(a.dir, "sysmon.csv")
    if os.path.exists(sm):
        s = list(csv.DictReader(open(sm)))
        rss = [k for k in s[0] if k.endswith("_rss_mib")]
        fds = [k for k in s[0] if k.endswith("_fds")]
        thr = [k for k in s[0] if k.endswith("_threads")]

        def col(k):
            return [float(r[k]) for r in s if r.get(k)]
        print(f"sysmon {len(s)} s: temp start {s[0]['temp_c']} max {max(col('temp_c')):.1f} C; throttle flags "
              f"{sorted(set(r['throttled'] for r in s))}; MHz cpu3 p5/p50 {pct(col('mhz3'), .05):.0f}/{pct(col('mhz3'), .5):.0f}")
        for k in rss + fds + thr:
            v = col(k)
            print(f"  {k}: first {v[0]:.1f} last {v[-1]:.1f} max {max(v):.1f}")


if __name__ == "__main__":
    main()
