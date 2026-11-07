#!/usr/bin/env python3
"""Summarize an sc-vision per-frame CSV (--csv): fps, first USB packet -> pose and EOF reap -> pose, frame bytes,
tags per frame and per-tag decision margin / side (median).
   scv_stats.py RUN.csv [LABEL]"""
import csv
import statistics
import sys


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float("nan")


def main():
    rows = list(csv.DictReader(open(sys.argv[1])))[30:]
    label = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
    if len(rows) < 10:
        print(f"{label}: too few frames ({len(rows)})")
        return
    frames = {}
    for r in rows:
        frames.setdefault(r["seq"], []).append(r)
    seqs = sorted(frames, key=int)
    f0 = [frames[s][0] for s in seqs]
    t = [int(r["t_first"]) for r in f0]
    fps = (len(t) - 1) / ((t[-1] - t[0]) / 1e9)
    fp = [(int(r["t_pose"]) - int(r["t_first"])) / 1e6 for r in f0 if int(r["t_pose"]) > 0]
    ep = [(int(r["t_pose"]) - int(r["t_eof_reap"])) / 1e6 for r in f0 if int(r["t_pose"]) > 0]
    kb = [int(r["bytes"]) / 1024 for r in f0]
    ntags = [int(r["ntags"]) for r in f0]
    by_id = {}
    for s in seqs:
        for r in frames[s]:
            if r["id"]:
                xs = [float(r[f"c{k}x"]) for k in range(4)]
                ys = [float(r[f"c{k}y"]) for k in range(4)]
                side = sum(((xs[k] - xs[k - 1]) ** 2 + (ys[k] - ys[k - 1]) ** 2) ** 0.5 for k in range(4)) / 4
                by_id.setdefault(int(r["id"]), []).append((float(r["margin"]), side))
    print(f"{label}: {len(seqs)} frames {fps:.2f} fps; first pkt->pose p50/p99 {pct(fp, .5):.2f}/{pct(fp, .99):.2f} ms; "
          f"EOF->pose p50/p99 {pct(ep, .5):.2f}/{pct(ep, .99):.2f} ms; KB p50 {pct(kb, .5):.0f}; "
          f"tags/frame {statistics.mean(ntags):.2f}")
    for i in sorted(by_id):
        v = by_id[i]
        print(f"  tag {i}: in {len(v) / len(seqs):.0%} margin p50 {statistics.median(m for m, _ in v):.1f} "
              f"side {statistics.median(s for _, s in v):.1f} px")


main()
