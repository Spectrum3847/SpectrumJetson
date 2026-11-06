#!/usr/bin/env python3
"""Summarize a JFR file: allocation by stack (weight MB/s), CPU-time samples by thread/stack, parks/sleeps.
  jfrsum.py FILE.jfr [SECONDS] [DEPTH]"""
import collections
import json
import subprocess
import sys

f = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30
depth = int(sys.argv[3]) if len(sys.argv) > 3 else 6


def events(names):
    out = subprocess.run(['jfr', 'print', '--json', '--stack-depth', '12', '--events', names, f],
                         capture_output=True, text=True).stdout
    return json.loads(out)['recording']['events']


def frames(ev, n=depth):
    st = ev['values'].get('stackTrace')
    if not st:
        return '(no stack)'
    out = []
    for fr in st['frames'][:n]:
        m = fr['method']
        cls = m['type']['name'].split('.')[-1]
        out.append(f"{cls}.{m['name']}:{fr.get('lineNumber', '')}")
    return ' < '.join(out)


def thread(ev, key='eventThread'):
    t = ev['values'].get(key) or ev['values'].get('sampledThread')
    return (t or {}).get('javaName') or (t or {}).get('osName') or '?'


alloc = collections.Counter()
alloc_t = collections.Counter()
for e in events('jdk.ObjectAllocationSample'):
    w = e['values'].get('weight', 0)
    alloc[(thread(e), frames(e))] += w
    alloc_t[thread(e)] += w
tot = sum(alloc.values())
print(f'== allocation: {tot / secs / 1e6:.2f} MB/s sampled total')
for t, w in alloc_t.most_common(12):
    print(f'  {w / secs / 1e6:7.3f} MB/s  {t}')
print('-- top stacks')
for (t, s), w in alloc.most_common(25):
    print(f'  {w / secs / 1e6:7.3f} MB/s  [{t[:28]}] {s}')

for name in ('jdk.CPUTimeSample', 'jdk.ExecutionSample', 'jdk.NativeMethodSample'):
    ev = events(name)
    c = collections.Counter()
    ct = collections.Counter()
    for e in ev:
        c[(thread(e), frames(e, depth))] += 1
        ct[thread(e)] += 1
    print(f'== {name}: {len(ev)} samples')
    for t, n in ct.most_common(10):
        print(f'  {n:6d}  {t}')
    for (t, s), n in c.most_common(20 if name != 'jdk.NativeMethodSample' else 12):
        print(f'  {n:6d}  [{t[:28]}] {s}')
