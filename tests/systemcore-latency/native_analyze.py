#!/usr/bin/env python3
"""Per-frame stage table for sc-vision's CSV (native/sc-vision), in the same terms as analyze.py.

  native_analyze.py CSV [--exposure-ms 5.0] [--delay-ms 0.4] [--skip 60]

Times are ms p50/p95/p99. 'first packet' is the reap time of the URB holding the frame's first payload, less
the packets after it in that URB (0.5 ms URBs: within ~0.125 ms). Mid-exposure is ESTIMATED as first packet -
exposure/2 - camera delay (the same constants PhotonVision uses for its published timestamp; the camera delay is
0.4 ms: LED test 0.41 +- 0.04 ms on the Thriftiest). Pose jitter: standard deviation of the tag translation (static scene).
"""
import argparse
import csv
import statistics


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))] if v else float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('csv')
    ap.add_argument('--exposure-ms', type=float, default=5.0)
    ap.add_argument('--delay-ms', type=float, default=0.4)
    ap.add_argument('--skip', type=int, default=60, help='start-up frames to drop')
    a = ap.parse_args()
    rows = list(csv.DictReader(open(a.csv)))[a.skip:]
    if not rows:
        print('no frames')
        return
    off = (a.exposure_ms / 2 + a.delay_ms) * 1e6

    def col(name):
        return [float(r[name]) for r in rows if r.get(name) not in (None, '')]

    def d(x, y, add=0.0):
        return [(int(r[y]) - int(r[x]) + add) / 1e6 for r in rows if r[x] and r[y]]

    stages = [
        ('mid-exposure -> first USB packet (est.)', [off / 1e6] * len(rows)),
        ('first -> last packet (URB reaped)', d('t_first', 't_eof_reap')),
        ('last packet -> decoded', d('t_eof_reap', 't_dec')),
        ('decoded -> tags (NAPA finish)', d('t_dec', 't_det')),
        ('tags -> pose', d('t_det', 't_pose')),
        ('pose -> published', d('t_pose', 't_pub')),
        ('TAIL last packet -> tags', d('t_eof_reap', 't_det')),
        ('TAIL last packet -> pose', d('t_eof_reap', 't_pose')),
        ('first USB packet -> pose', d('t_first', 't_pose')),
        ('TOTAL mid-exposure -> pose (est.)', d('t_first', 't_pose', off)),
        ('TOTAL mid-exposure -> published (est.)', d('t_first', 't_pub', off)),
    ]
    seqs = [int(r['seq']) for r in rows]
    gaps = sum(max(0, b - a_ - 1) for a_, b in zip(seqs, seqs[1:]))
    span = (int(rows[-1]['t_eof_reap']) - int(rows[0]['t_eof_reap'])) / 1e9
    print(f"{a.csv}: {len(rows)} frames in {span:.1f} s ({len(rows) / span:.1f} fps processed), seq gaps {gaps}")
    print(f"{'stage':44s} {'p50':>7s} {'p95':>7s} {'p99':>7s}")
    for name, v in stages:
        if v:
            print(f"{name:44s} {pct(v, .5):7.3f} {pct(v, .95):7.3f} {pct(v, .99):7.3f}")
    for name in ('dec_cpu_us', 'napa_cpu_us', 'pose_us', 'frame_cpu_us'):
        v = col(name)
        print(f"CPU {name:40s} {pct(v, .5) / 1e3:7.3f} {pct(v, .95) / 1e3:7.3f} {pct(v, .99) / 1e3:7.3f}")
    fc = col('frame_cpu_us')
    if fc:
        print(f"vision thread CPU: {statistics.mean(fc) / 1e3 * len(rows) / span / 10:.1f}% of one core "
              f"(mean {statistics.mean(fc) / 1e3:.3f} ms/frame)")
    tagged = [r for r in rows if r['ntags'] not in ('', '0')]
    print(f"frames with a tag: {len(tagged)} of {len(rows)} ({100 * len(tagged) / len(rows):.1f}%)")
    if tagged:
        m = [float(r['margin']) for r in tagged]
        print(f"decision margin p5/p50/p95: {pct(m, .05):.1f} / {pct(m, .5):.1f} / {pct(m, .95):.1f}")
        for k in ('tx', 'ty', 'tz'):
            v = [float(r[k]) for r in tagged if r[k]]
            if len(v) > 2:
                print(f"pose {k}: mean {statistics.mean(v):+.4f} m, std {statistics.pstdev(v) * 1000:.3f} mm")
        cx = [float(r['c0x']) for r in tagged]
        cy = [float(r['c0y']) for r in tagged]
        print(f"corner 0 jitter std: x {statistics.pstdev(cx):.4f} px, y {statistics.pstdev(cy):.4f} px")


if __name__ == '__main__':
    main()
