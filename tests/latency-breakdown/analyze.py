#!/usr/bin/env python3
"""Join a run.sh condition's PhotonVision latency CSV (fork photonvision-103) with its ftrace
capture (ktrace.py) per frame, on CLOCK_MONOTONIC, and print the stage table.

  analyze.py DIR NAME [--exposure-ms 5.0 --delay-ms 2.5]

Stage times are p50/p95/p99 ms. The reference point is mid-exposure: the frame's published
timestamp (the driver's hardware timestamp less half the exposure and SPECTRUM_CAMERA_DELAY_US),
exactly what robot code fuses at. The camera delay is a constant (it was Team 100's 2.5 ms; LED-measured
2026-11-05: 0.18 ms to the camera-clock timestamp, tests/camera-timing), so 'mid-exposure -> first USB packet'
is only as right as the constant the run used (--delay-ms).
"""
import argparse, bisect, csv, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ktrace  # noqa: E402

STAGES = [  # (label, from, to)
    ('mid-exposure -> first USB packet', 'mid', 'first'),
    ('frame streams over USB (first -> last packet)', 'first', 'eof'),
    ('last packet -> V4L2 dequeue', 'eof', 'dq'),
    ('dequeue -> decoder has it (cscore handoff)', 'dq', 'grab'),
    ('JPEG decode (NVJPG, to gray)', 'grab', 'dec'),
    ('decoded -> camera thread takes it', 'dec', 'take'),
    ('take -> detect start (settings, pre-steps)', 'take', 'det0'),
    ('tag detection', 'det0', 'det1'),
    ('pose solve + targets', 'det1', 'pose'),
    ('pose -> pipeline result', 'pose', 'pipe'),
    ('NT publish + flush', 'pipe', 'nt'),
    ('TAIL last packet -> tags detected', 'eof', 'det1'),
    ('TOTAL mid-exposure -> pose ready', 'mid', 'pose'),
    ('TOTAL mid-exposure -> NT flushed', 'mid', 'nt'),
    ('(hw timestamp -> first USB packet)', 'hw', 'first'),
]


FIELDS = ('camera,published_nt,raw_nt,grab_ret,decode_end,take,det0,det1,pose1,pipe_end,'
          'nt_flushed,consumers_end,nt_minus_mono').split(',')


def rows(path):
    out = []
    with open(path) as f:
        first = f.readline(); f.seek(0)
        # run.sh truncates the file after start-up, which drops the header PhotonVision wrote once
        names = None if first.startswith('camera,') else FIELDS
        for r in csv.DictReader(f, fieldnames=names):
            try:
                v = {k: int(r[k]) for k in r if k != 'camera'}
            except (TypeError, ValueError):
                continue
            m = v['nt_minus_mono']
            if not v['raw_nt'] or not v['grab_ret']:
                continue
            out.append(dict(camera=r['camera'], mid=v['published_nt'] - m, hw=v['raw_nt'] - m,
                            grab=v['grab_ret'], dec=v['decode_end'], take=v['take'],
                            det0=v['det0'] or None, det1=v['det1'] or None, pose=v['pose1'] or None,
                            pipe=v['pipe_end'], nt=v['nt_flushed'] or None))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir'); ap.add_argument('name')
    a = ap.parse_args()
    pv = rows(os.path.join(a.dir, a.name + '.csv'))
    u, d, q = ktrace.parse(os.path.join(a.dir, a.name + '.trace'))
    fr = ktrace.frames(u, d, q)
    by_hw = sorted((f['hw'], f) for f in fr if 'hw' in f)
    keys = [k for k, _ in by_hw]
    matched = 0
    for r in pv:
        i = bisect.bisect_left(keys, r['hw'])
        best = min((j for j in (i - 1, i) if 0 <= j < len(keys)), key=lambda j: abs(keys[j] - r['hw']), default=None)
        if best is not None and abs(keys[best] - r['hw']) < 200_000:  # same frame (stamps are us)
            f = by_hw[best][1]
            r.update(first=f['first_data'], eof=f['eof'], dq=f['dq'], bytes=f['bytes'])
            matched += 1
    pv = [r for r in pv if 'dq' in r]
    cams = sorted({r['camera'] for r in pv})
    print(f"{a.name}: {len(pv)} frames joined ({matched} PV rows matched to the kernel trace), cameras {len(cams)}")
    print(f"{'stage':48s} {'p50':>7s} {'p95':>7s} {'p99':>7s}")
    for label, x, y in STAGES:
        v = [(r[y] - r[x]) / 1e6 for r in pv if r.get(x) and r.get(y)]
        s = ktrace.summ(v)
        if s['n']:
            print(f"{label:48s} {s['p50']:7.3f} {s['p95']:7.3f} {s['p99']:7.3f}")
    if pv:
        print('drops (V4L2 sequence gaps)', ktrace.drops(q), ' frame bytes p50', ktrace.pct([r['bytes'] for r in pv], .5))


if __name__ == '__main__':
    main()
