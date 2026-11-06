#!/usr/bin/env python3
"""Per-run summary of sc-vision CSVs for the decode-scale comparison (scale-compare.sh).

  scale_summary.py CSV [CSV ...]

Per CSV (start-up frames dropped): processed frames, CPU per frame (decode, NAPA, whole frame; us, mean / p95),
frames with a tag, tags per frame, the first tag's id, pose noise (sd of tx/ty/tz, mm) and corner noise (sd of
c0x, c0y, px) over frames that see the most common first tag (static scene).
"""
import csv
import statistics
import sys
from collections import Counter


def p(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')


for path in sys.argv[1:]:
    rows = list(csv.DictReader(open(path)))[60:]
    if not rows:
        print(f'{path}: no frames')
        continue
    dec = [float(r['dec_cpu_us']) for r in rows]
    nap = [float(r['napa_cpu_us']) for r in rows]
    fr = [float(r['frame_cpu_us']) for r in rows]
    nt = [int(r['ntags']) for r in rows]
    ids = Counter(r['id'] for r in rows if int(r['ntags']) > 0)
    top = ids.most_common(1)[0][0] if ids else None
    same = [r for r in rows if int(r['ntags']) > 0 and r['id'] == top and r['tz']]
    sd = lambda k: statistics.pstdev(float(r[k]) for r in same) if len(same) > 2 else float('nan')  # noqa: E731
    print(f'{path.rsplit("/", 1)[-1]}: {len(rows)} frames; CPU us mean/p95: decode {statistics.fmean(dec):.0f}/'
          f'{p(dec, .95):.0f} NAPA {statistics.fmean(nap):.0f}/{p(nap, .95):.0f} frame {statistics.fmean(fr):.0f}/'
          f'{p(fr, .95):.0f}; with a tag {100 * sum(n > 0 for n in nt) / len(nt):.1f}%, tags/frame '
          f'{statistics.fmean(nt):.2f} (max {max(nt)}); first tag {top} ({len(same)} frames): sd tx/ty/tz '
          f'{1000 * sd("tx"):.2f}/{1000 * sd("ty"):.2f}/{1000 * sd("tz"):.2f} mm, c0 {sd("c0x"):.3f}/{sd("c0y"):.3f} px, '
          f'mean tz {statistics.fmean(float(r["tz"]) for r in same) if same else float("nan"):.4f} m')
