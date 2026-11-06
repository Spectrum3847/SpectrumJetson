#!/usr/bin/env python3
"""Per-thread CPU (% of one core) and context switches/s between two /proc snapshots, named by the JVM's
Thread.print where it knows the thread (Java threads), else by the OS name (native threads).
  threadcpu.py OUT/NAME SECS     reads NAME.t0, NAME.t1 ("tid comm ticks ctxsw"), NAME.jstack"""
import collections
import re
import sys

base, secs = sys.argv[1], float(sys.argv[2])
names = {}
try:
    for line in open(base + '.jstack', errors='replace'):
        m = re.match(r'^"(.*)" .*\[(\d+)\]', line) or re.match(r'^"(.*)" .*nid=(\d+)', line)
        if m:
            names[m.group(2)] = m.group(1)
except FileNotFoundError:
    pass


def load(p):
    d = {}
    for line in open(p):
        f = line.split()
        if len(f) >= 4:
            d[f[0]] = (f[1], int(f[2]), int(f[3]))
    return d


a, b = load(base + '.t0'), load(base + '.t1')
by = collections.defaultdict(lambda: [0.0, 0.0])
tot = [0.0, 0.0]
for tid, (comm, t, c) in b.items():
    t0, c0 = (a[tid][1], a[tid][2]) if tid in a else (0, 0)
    n = names.get(tid, comm + ' (native)' if comm in ('java', 'SpectrumStream') else comm)
    n = re.sub(r'-\d+$', '-N', n)  # pool threads
    by[n][0] += (t - t0) / secs
    by[n][1] += (c - c0) / secs
    tot[0] += (t - t0) / secs
    tot[1] += (c - c0) / secs
print(f'TOTAL {tot[0]:.1f}% {tot[1]:.0f}/s')
for n, (cpu, cs) in sorted(by.items(), key=lambda x: -x[1][0]):
    if cpu >= 0.05 or cs >= 20:
        print(f'{cpu:5.1f}% {cs:6.0f}/s  {n}')
