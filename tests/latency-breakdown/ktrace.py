#!/usr/bin/env python3
"""Parse an ftrace capture (trace_clock mono) of xhci_urb_giveback, vb2_buf_done and v4l2_dqbuf
into per-frame kernel stages. Usage: ktrace.py trace.txt [--dump N]  (prints a JSON-ish summary)
or import parse() / frames().

Per isochronous URB: completion time, slot, endpoint, bytes (actual) and the packet count
(length / packet size). Idle packets carry only the 12-byte UVC header.
Per frame (matched by slot = camera, in order): the URBs since the previous frame's EOF,
first data URB, first-packet time estimate, EOF URB and the vb2 done / dequeue events.
"""
import re, sys, statistics as st, json

URB = re.compile(r'\s(\d+\.\d+): xhci_urb_giveback: ep(\d+)in-isoc: urb \S+ pipe \d+ slot (\d+) length (\d+)/(\d+)')
DONE = re.compile(r'\[(\d+)\].*\s(\d+\.\d+): vb2_buf_done: owner = \S+, queued = \d+, owned_by_drv = \d+, index = (\d+), type = \d+, bytesused = (\d+), timestamp = (\d+)')
DQ = re.compile(r'\s(\d+\.\d+): v4l2_dqbuf: minor = (\d+), index = (\d+), .*bytesused = (\d+), .*timestamp = (\d+), .*sequence = (\d+)')
HDR = 12

def ns(s):
    a, b = s.split('.')
    return int(a) * 1_000_000_000 + int(b.ljust(9, '0'))

def parse(path):
    urbs, dones, dqs = [], [], []
    for line in open(path, errors='replace'):
        m = URB.search(line)
        if m:
            urbs.append(dict(t=ns(m[1]), ep=int(m[2]), slot=int(m[3]), actual=int(m[4]), length=int(m[5])))
            continue
        m = DONE.search(line)
        if m:
            dones.append(dict(cpu=int(m[1]), t=ns(m[2]), index=int(m[3]), bytes=int(m[4]), ts=int(m[5])))
            continue
        m = DQ.search(line)
        if m:
            dqs.append(dict(t=ns(m[1]), minor=int(m[2]), index=int(m[3]), bytes=int(m[4]), ts=int(m[5]) * 1, seq=int(m[6])))
    return urbs, dones, dqs

def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))] if v else float('nan')

def summ(v):
    return dict(n=len(v), p50=pct(v, .5), p95=pct(v, .95), p99=pct(v, .99))

def frames(urbs, dones, dqs, slotmap=None):
    """One dict per frame: slot (camera), hw (dequeued buffer timestamp: the camera's PTS on the
    host clock with hwtimestamps=1), notice (vb2's buffer timestamp), first_data (completion of the
    URB holding the frame's first packet less the packets after it, from its bytes), eof
    (completion of the URB holding the last packet), done (vb2_buf_done), dq (VIDIOC_DQBUF
    returned to user space), minor (the video device), bytes, seq.
    With several cameras the slot is first guessed per frame (the slot whose URB completed just
    before the frame was done), then fixed per video device by majority (second pass): with short
    URBs another camera's URB can complete closer to a frame's done than its own."""
    import bisect
    byslot = {}
    for u in urbs:
        byslot.setdefault(u['slot'], []).append(u)
    keys = {k: [u['t'] for u in v] for k, v in byslot.items()}
    pending = {}
    for q in dqs:
        pending.setdefault((q['index'], q['bytes']), []).append(q)
    out = []
    for d in dones:
        if d['bytes'] == 0:
            continue
        qq = None
        q = pending.get((d['index'], d['bytes']))
        while q and q[0]['t'] < d['t']:
            q.pop(0)
        if q:
            qq = q.pop(0)
        forced = slotmap.get(qq['minor']) if (slotmap and qq) else None
        best = None
        for k, ts in keys.items():
            if forced is not None and k != forced:
                continue
            j = bisect.bisect_right(ts, d['t']) - 1
            if j >= 0 and (best is None or d['t'] - ts[j] < best[0]):
                best = (d['t'] - ts[j], k, j)
        if best is None or best[0] > 300_000:
            continue
        _, k, je = best
        L = byslot[k]
        ts = keys[k]
        # the URB holding the frame's first packet: nearest the frame's timestamp
        i = bisect.bisect_left(ts, d['ts'])
        j0 = min((j for j in (i - 1, i) if 0 <= j <= je), key=lambda j: abs(ts[j] - d['ts']), default=None)
        if j0 is None or ts[je] - ts[j0] > 20_000_000:
            continue
        npk = max(1, L[j0]['length'] // 1280)
        # first data packet: count the new frame's packets in that URB from its bytes (~1 KB each)
        hdr_only = npk * HDR
        head_pk = 0
        if L[j0]['actual'] > hdr_only:
            head_pk = min(npk, round((L[j0]['actual'] - hdr_only) / 1000))
        first = L[j0]['t'] - head_pk * 125_000 if head_pk else (L[j0 + 1]['t'] - npk * 125_000 if j0 + 1 < len(L) else L[j0]['t'])
        f = dict(slot=k, notice=d['ts'], first_data=first, eof=L[je]['t'], done=d['t'], bytes=d['bytes'], npk=npk)
        if qq:
            f.update(dq=qq['t'], hw=qq['ts'], seq=qq['seq'], minor=qq['minor'])
        out.append(f)
    if slotmap is None and len(keys) > 1:
        votes = {}
        for f in out:
            if 'minor' in f:
                votes.setdefault(f['minor'], {}).setdefault(f['slot'], 0)
                votes[f['minor']][f['slot']] += 1
        return frames(urbs, dones, dqs, {m: max(v, key=v.get) for m, v in votes.items()})
    return out


def drops(dqs):
    """Frames lost per video device: gaps in the V4L2 sequence numbers of the dequeued buffers
    (straight from the trace, not from the per-frame join, which can miss frames)."""
    last, gaps = {}, {}
    for q in dqs:
        m = q['minor']
        gaps.setdefault(m, 0)
        if m in last and q['seq'] > last[m] + 1:
            gaps[m] += q['seq'] - last[m] - 1
        last[m] = q['seq']
    return gaps


def table(fr, ref='hw'):
    rows = [('hw -> first data packet', 'hw', 'first_data'), ('hw -> driver notice (first)', 'hw', 'notice'),
            ('first data -> last packet URB', 'first_data', 'eof'), ('last URB -> frame done', 'eof', 'done'),
            ('done -> dequeued (DQBUF)', 'done', 'dq'), ('hw -> dequeued', 'hw', 'dq')]
    res = {}
    for name, a, b in rows:
        v = [(f[b] - f[a]) / 1e6 for f in fr if a in f and b in f]
        res[name] = summ(v)
    return res

if __name__ == '__main__' and len(sys.argv) > 2 and sys.argv[2] == '--frames':
    u, d, q = parse(sys.argv[1])
    fr = frames(u, d, q)[5:]  # skip stream start
    for k, v in table(fr).items():
        print(f"{k:32s} n={v['n']:4d} p50 {v['p50']:7.3f}  p95 {v['p95']:7.3f}  p99 {v['p99']:7.3f} ms")
    print('drops', drops(q), 'bytes p50', pct([f['bytes'] for f in fr], .5))
    sys.exit(0)

if __name__ == '__main__':
    urbs, dones, dqs = parse(sys.argv[1])
    psize = 1280
    print('urbs', len(urbs), 'dones', len(dones), 'dqbufs', len(dqs))
    n = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == '--dump' else 0
    ev = [('U', u['t'], u) for u in urbs] + [('D', d['t'], d) for d in dones]
    ev.sort(key=lambda e: e[1])
    for k, t, e in ev[200:200 + n]:
        if k == 'U':
            npk = e['length'] // psize
            print(f"{t/1e6:.3f} URB slot{e['slot']} ep{e['ep']} {e['actual']:6d} B  data-pkts~{max(0,(e['actual']-npk*HDR)+psize-HDR-1)//(psize-HDR)}")
        else:
            print(f"{t/1e6:.3f} DONE idx{e['index']} {e['bytes']} B  ts {e['ts']/1e6:.3f}  cpu{e['cpu']}")
