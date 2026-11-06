#!/usr/bin/env python3
"""Two free-running cameras in one process: does one camera's frame timing hurt the other's latency?

  multicam_phase.py A.csv B.csv

The CSVs are nt_probe's per-result lines (NT_PROBE_CSV; multicam-native.sh writes them). The cameras free-run at
slightly different rates, so in a 20 s run their phase sweeps through every offset. For each of A's frames: the
offset to B's nearest capture (B - A, ms), A's capture -> publish (processing on the SystemCore) and capture ->
received. Binned by |offset|: if contention mattered, the bins near 0 (both frames arriving together) would be
slower and staggering the cameras would help. Also how often both publish within 1 ms of each other.
"""
import bisect
import csv
import sys


def load(p):
    with open(p) as f:
        return [(int(r['capture_ns']), int(r['publish_ns']), int(r['received_ns'])) for r in csv.DictReader(f)]


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')


def report(name, a, b):
    bc = [x[0] for x in b]
    bp = sorted(x[1] for x in b)
    bins = {}
    together = 0
    for cap, pub, rec in a:
        i = bisect.bisect_left(bc, cap)
        cand = [bc[j] for j in (i - 1, i) if 0 <= j < len(bc)]
        if not cand:
            continue
        d = min((c - cap for c in cand), key=abs) / 1e6
        k = min(int(abs(d)), 4)  # 0-1, 1-2, 2-3, 3-4, >=4 ms
        bins.setdefault(k, []).append(((pub - cap) / 1e6, (rec - cap) / 1e6))
        j = bisect.bisect_left(bp, pub - 1_000_000)
        if j < len(bp) and bp[j] <= pub + 1_000_000:
            together += 1
    print(f'{name}: {len(a)} frames; published within 1 ms of the other camera: {100 * together / max(1, len(a)):.1f}%')
    print('  |offset to other camera| ms   frames   capture->publish p50/p95/p99   capture->received p50/p95/p99')
    for k in sorted(bins):
        p = [x[0] for x in bins[k]]
        r = [x[1] for x in bins[k]]
        lab = f'{k}-{k + 1}' if k < 4 else '>=4'
        print(f'  {lab:>27}   {len(p):6d}   {pct(p, .5):5.2f} / {pct(p, .95):5.2f} / {pct(p, .99):5.2f}'
              f'          {pct(r, .5):5.2f} / {pct(r, .95):5.2f} / {pct(r, .99):5.2f}')


a, b = load(sys.argv[1]), load(sys.argv[2])
report(sys.argv[1].rsplit('/', 1)[-1], a, b)
report(sys.argv[2].rsplit('/', 1)[-1], b, a)
