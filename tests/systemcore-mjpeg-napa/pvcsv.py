#!/usr/bin/env python3
"""Stage table from PhotonVision's SPECTRUM_LATENCY_TRACE CSV alone (no kernel trace needed), for the SystemCore.

  python3 pvcsv.py LATENCY.csv [--skip-s 2]

Columns as tests/latency-breakdown/analyze.py FIELDS (fork photonvision-103). All times are ns on the NT clock
(== CLOCK_MONOTONIC, offset in nt_minus_mono). published_nt is mid-exposure as PhotonVision publishes it
(hw timestamp - exposure/2 - SPECTRUM_CAMERA_DELAY_US), raw_nt the driver's timestamp. A 0 means the stage
didn't run for that frame (e.g. det0/det1 when streaming NAPA already had the tags). Also prints the frame
interval (jitter) and gaps (> 1.5 periods: frames PhotonVision never processed).
"""
import argparse
import csv

FIELDS = ('camera,published_nt,raw_nt,grab_ret,decode_end,take,det0,det1,pose1,pipe_end,'
          'nt_flushed,consumers_end,nt_minus_mono').split(',')
STAGES = [
    ('mid-exposure -> hw timestamp (assumed)', 'published_nt', 'raw_nt'),
    ('hw timestamp -> cscore grab returned', 'raw_nt', 'grab_ret'),
    ('grab -> decoded', 'grab_ret', 'decode_end'),
    ('decoded -> camera thread takes it', 'decode_end', 'take'),
    ('take -> detect start', 'take', 'det0'),
    ('tag detection (whole-frame only)', 'det0', 'det1'),
    ('take -> pose solved', 'take', 'pose1'),
    ('pose -> pipeline result', 'pose1', 'pipe_end'),
    ('pipeline result -> NT flushed', 'pipe_end', 'nt_flushed'),
    ('TOTAL mid-exposure -> pipeline result', 'published_nt', 'pipe_end'),
    ('TOTAL mid-exposure -> NT flushed', 'published_nt', 'nt_flushed'),
    ('TOTAL hw timestamp -> NT flushed', 'raw_nt', 'nt_flushed'),
]


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('csv')
    ap.add_argument('--skip-s', type=float, default=2.0, help='drop the first seconds (start-up)')
    a = ap.parse_args()
    with open(a.csv) as f:
        first = f.readline()
        f.seek(0)
        rows = list(csv.DictReader(f, fieldnames=None if first.startswith('camera,') else FIELDS))
    for r in rows:
        for k in FIELDS[1:]:
            try:
                r[k] = int(r[k])
            except (ValueError, TypeError):
                r[k] = 0
    rows = [r for r in rows if r['raw_nt'] > 0]
    if not rows:
        print('no rows')
        return
    t0 = rows[0]['raw_nt']
    rows = [r for r in rows if r['raw_nt'] - t0 > a.skip_s * 1e9]
    for cam in sorted({r['camera'] for r in rows}):
        rs = [r for r in rows if r['camera'] == cam]
        print(f'{cam}: {len(rs)} frames over {(rs[-1]["raw_nt"] - rs[0]["raw_nt"]) / 1e9:.1f} s')
        print(f'  {"stage":44s} {"p50":>7s} {"p95":>7s} {"p99":>7s} {"max":>7s}   n')
        for name, x, y in STAGES:
            v = [(r[y] - r[x]) / 1e6 for r in rs if r[x] > 0 and r[y] > 0]
            if v:
                print(f'  {name:44s} {pct(v, .5):7.3f} {pct(v, .95):7.3f} {pct(v, .99):7.3f} {max(v):7.3f} {len(v):5d}')
        iv = [(b['raw_nt'] - a_['raw_nt']) / 1e6 for a_, b in zip(rs, rs[1:])]
        per = pct(iv, .5)
        gaps = sum(1 for x in iv if x > 1.5 * per)
        missed = sum(round(x / per) - 1 for x in iv if x > 1.5 * per)
        print(f'  frame interval ms p50 {per:.3f} p1 {pct(iv, .01):.3f} p99 {pct(iv, .99):.3f}; '
              f'gaps {gaps} ({missed} frames not processed, {100 * missed / (len(rs) + missed):.1f}%)')


if __name__ == '__main__':
    main()
