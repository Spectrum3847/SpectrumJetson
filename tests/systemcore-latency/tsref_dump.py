#!/usr/bin/env python3
"""Print the URBs around a few frame boundaries of a run.sh trace (tsref.py's input), with each frame's driver
stamp, to see where a frame's first packets fall.   tsref_dump.py TRACE [FRAMES]"""
import bisect
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'latency-breakdown'))
import ktrace  # noqa: E402

urbs, dones, dqs = ktrace.parse(sys.argv[1])
n = int(sys.argv[2]) if len(sys.argv) > 2 else 3
iso = [u for u in urbs if u['length'] >= 1600]
slots = {}
for u in iso:
    slots.setdefault(u['slot'], []).append(u)
U = max(slots.values(), key=len)
Ut = [u['t'] for u in U]
dones = [d for d in dones if d['bytes'] > 0][50:50 + n]
for d in dones:
    print(f"--- frame done {d['t'] / 1e6:.3f}, driver stamp {d['ts'] / 1e6:.3f}, {d['bytes']} B")
    i = bisect.bisect_left(Ut, d['ts'])
    for u in U[max(0, i - 6):i + 8]:
        mark = '  <- stamp' if abs(u['t'] - d['ts']) < 130_000 else ''
        print(f"  {u['t'] / 1e6:.3f} ({(u['t'] - d['ts']) / 1e3:+7.1f} us) {u['actual']:5d}/{u['length']}{mark}")
