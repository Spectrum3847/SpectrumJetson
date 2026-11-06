#!/usr/bin/env python3
"""Frame time references against the first USB packet (tsref-compare.sh).

  tsref.py TRACE PROBE_CSV SHIFT_FILE

TRACE: run.sh's ftrace (xhci_urb_giveback, vb2_buf_done, v4l2_dqbuf; mono clock), one camera streaming.
PROBE_CSV: nt_probe's per-result CSV (NT_PROBE_CSV) for that camera; SHIFT_FILE: PhotonVision's "Frame timestamps
moved X ms earlier" log line (the shift back from its reference to the published mid-exposure capture time).

Per frame:
  first packet  completion of the URB holding the frame's first data packet, less the packets after it in that URB
                (x 125 us; sc-vision's convention). The LED test: exposure end = first packet - 0.41 ms.
  notice        vb2_buf_done's timestamp: the driver's stamp when it handled the first packet's URB
  V4L2 stamp    the dequeued buffer's timestamp (= notice with hwtimestamps=0; the camera's PTS through SCR with 1)
  watcher       the native publish's reference: published capture + shift (NT time; PhotonVision's NT offset to a
                server on the same SystemCore is ~0)
Prints each reference minus the first packet (mean, sd, p5/p50/p95, ms) and each series' own frame-to-frame jitter
(sd of the intervals).
"""
import bisect
import csv
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'latency-breakdown'))
import ktrace  # noqa: E402

HDR = 12
PSIZE = int(os.environ.get('KTRACE_PSIZE', '1600'))


def stats(v):
    if len(v) < 3:
        return 'n/a'
    s = sorted(v)
    q = lambda p: s[min(len(s) - 1, int(p * len(s)))]  # noqa: E731
    return (f'n={len(v):5d} mean {statistics.fmean(v):+7.3f} sd {statistics.pstdev(v):6.3f}  '
            f'p5/p50/p95 {q(.05):+7.3f} {q(.5):+7.3f} {q(.95):+7.3f} ms')


def interval_sd(ts):
    d = [(b - a) / 1e6 for a, b in zip(ts, ts[1:])]
    if len(d) < 3:
        return float('nan')
    med = statistics.median(d)
    d = [x for x in d if abs(x - med) < med / 2]  # drop gaps from dropped frames
    return statistics.pstdev(d)


urbs, dones, dqs = ktrace.parse(sys.argv[1])
iso = [u for u in urbs if u['length'] >= PSIZE]
slots = {}
for u in iso:
    slots.setdefault(u['slot'], []).append(u)
U = max(slots.values(), key=len) if slots else []  # the streaming camera
Ut = [u['t'] for u in U]
dones = [d for d in dones if d['bytes'] > 0]
dq_by_ts = {}
for q in dqs:
    dq_by_ts.setdefault(q['index'], []).append(q)

frames = []
prev_eof = None
for d in dones:
    je = bisect.bisect_right(Ut, d['t']) - 1  # the URB that completed the frame
    if je < 0:
        continue
    if prev_eof is not None:
        j = prev_eof + 1
        while j <= je and U[j]['actual'] <= (U[j]['length'] // PSIZE) * HDR:
            j += 1  # header-only URBs between frames
        if j <= je:
            u = U[j]
            npk = max(1, u['length'] // PSIZE)
            data = u['actual'] - npk * HDR
            # data packets in this URB: the frame continues to its end, so they are the last ones
            ndata = min(npk, max(1, -(-data // (PSIZE - HDR))))
            first = u['t'] - (ndata - 1) * 125_000
            f = dict(first=first, notice=d['ts'], done=d['t'])
            q = next((q for q in dq_by_ts.get(d['index'], []) if q['t'] >= d['t']), None)
            if q:
                f['v4l2'] = q['ts']
            frames.append(f)
    prev_eof = je
frames = frames[5:]

watch = []
shift_ns = 0
label = 'watcher'
if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
    line = open(sys.argv[3]).read()
    # the native publish's capture = (first sight, or camera clock + its long-run offset to the first sight) -
    # first-sight shift: adding that shift back gives the first-sight scale either way
    m = re.search(r'first-sight shift ([0-9.]+) ms', line)
    if m:
        shift_ns = int(float(m[1]) * 1e6)
        label = 'camclock' if 'camera clock shift' in line else 'watcher'
if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
    with open(sys.argv[2]) as fh:
        rows = list(csv.DictReader(fh))
    if rows and 't_first' in rows[0]:  # sc-vision's own CSV: its first-packet time
        label = 'sc-vision'
        watch = sorted((int(r['t_first']), 0) for r in rows if int(r['t_first']) > 0)
    else:
        watch = sorted((int(r['capture_ns']) + shift_ns, int(r['received_ns'])) for r in rows)
if not frames:  # no V4L2 frames in the trace (sc-vision): its own reference is its first data packet
    v = [(rec - w) / 1e6 for w, rec in watch if rec]
    print(f'{label}: {len(watch)} results (shift {shift_ns / 1e6} ms); first data packet -> received here: {stats(v)}')
    print(f'{label} interval sd {interval_sd([w for w, _ in watch]):.4f} ms')
    sys.exit(0)
firsts = [f['first'] for f in frames]
for w, rec in watch:
    i = bisect.bisect_left(firsts, w)
    best = min((j for j in (i - 1, i) if 0 <= j < len(frames)), key=lambda j: abs(firsts[j] - w), default=None)
    if best is not None and abs(firsts[best] - w) < 2_000_000:
        frames[best]['pub'] = w
        if rec:
            frames[best]['rec'] = rec

print(f'{len(frames)} frames traced, {len(watch)} results matched to '
      f'{sum("pub" in f for f in frames)} ({label}, shift {shift_ns / 1e6} ms)')
names = dict(first='first', notice='notice', v4l2='v4l2', pub=label)
for k in ('notice', 'v4l2', 'pub'):
    v = [(f[k] - f['first']) / 1e6 for f in frames if k in f]
    print(f'{names[k]:>9} - first packet: {stats(v)}')
v = [(f['pub'] - f['v4l2']) / 1e6 for f in frames if 'pub' in f and 'v4l2' in f]
print(f'{label:>9} - v4l2 stamp:  {stats(v)}')
v = [(f['rec'] - f['first']) / 1e6 for f in frames if 'rec' in f]
print(f'first data packet -> received here: {stats(v)}')
for k in ('first', 'notice', 'v4l2', 'pub'):
    ts = [f[k] for f in frames if k in f]
    print(f'{names[k]:>9} interval sd {interval_sd(ts):.4f} ms')
