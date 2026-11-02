#!/usr/bin/env python3
"""tests/pin-cameras: one condition's summary line(s) from run.sh's files. summary.py OUT NAME SECS HZ"""
import collections, re, statistics, sys

out, name, secs, hz = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
P = f"{out}/{name}"


def threads(f):
    d = {}
    for l in open(f):
        parts = l.rstrip("\n").split("|")
        if len(parts) < 5:
            continue
        tid, comm, st, allowed, ctx = parts
        if len(st.split()) != 2:
            continue  # the thread exited while being read
        t, psr = st.split()
        v = [int(x) for x in ctx.split()] or [0, 0]
        d[tid] = (comm, float(t), allowed, v)
    return d


t0, t1 = threads(P + ".threads0"), threads(P + ".threads1")
print(f"== {name}")
# Latency per camera: median / p95 / max (and p99) per 10 s window -> mean of p50/p95/p99, max of max
lat = collections.defaultdict(list)
for l in open(P + ".journal"):
    m = re.search(r"VisionRunner - ([^\]]*).*over (\d+) frames.*latency median ([\d.]+) p95 ([\d.]+) max ([\d.]+) ms(?:, p99 ([\d.]+))?", l)
    if m:
        lat[m.group(1)].append([float(x) if x else float("nan") for x in m.groups()[1:]])
for cam, rows in sorted(lat.items()):
    rows = rows[1:] or rows  # the first window may straddle the start
    f = statistics.mean(r[0] for r in rows) / 10
    print(f"  {cam}: {f:.1f} fps, latency p50 {statistics.mean(r[1] for r in rows):.2f} p95 {statistics.mean(r[2] for r in rows):.2f}"
          f" p99 {statistics.mean(r[4] for r in rows):.2f} max {max(r[3] for r in rows):.2f} ms ({len(rows)} windows)")
trt = [l.split("] ", 1)[-1].strip() for l in open(P + ".journal") if re.search(r"TensorRT .*frames in", l)]
if trt:
    print("  " + trt[-1][:200])
# Per thread CPU, cores visited, allowed list, context switches
psr = collections.defaultdict(collections.Counter)
try:
    for l in open(P + ".psr"):
        p = l.split()
        if len(p) == 2:
            psr[p[0]][p[1]] += 1
except FileNotFoundError:
    pass
perf = {}
try:
    for l in open(P + ".perf"):
        m = re.search(r"-(\d+)\s+([\d,]+)\s+(cpu-migrations|context-switches)", l)
        if m:
            perf.setdefault(m.group(1), {})[m.group(3)] = int(m.group(2).replace(",", ""))
except FileNotFoundError:
    pass
rows, total = [], 0.0
for tid, (comm, t, allowed, v) in t1.items():
    if tid not in t0:
        continue
    cpu = (t - t0[tid][1]) / hz / secs
    total += cpu
    vol = v[0] - t0[tid][3][0]
    inv = v[1] - t0[tid][3][1] if len(v) > 1 else 0
    rows.append((cpu, tid, comm, allowed, vol, inv))
rows.sort(reverse=True)
print(f"  PhotonVision CPU {total:.2f} cores (threads alive the whole window)")
for cpu, tid, comm, allowed, vol, inv in rows:
    if cpu < 0.02 and tid not in psr:
        continue
    cores = " ".join(f"{c}:{n}" for c, n in sorted(psr[tid].items())) if tid in psr else "-"
    pf = perf.get(tid, {})
    print(f"  {comm:<16} tid {tid}: {cpu:.2f} cores, allowed {allowed}, ran on (0.5 s samples) {cores},"
          f" ctx vol/invol {vol}/{inv}, migrations {pf.get('cpu-migrations', '-')}")
# tegrastats
g, p, r, tj = [], [], [], 0.0
for l in open(P + ".tegra"):
    m = re.search(r"GR3D_FREQ (\d+)%", l); g += [int(m.group(1))] if m else []
    m = re.search(r"VDD_IN (\d+)mW", l); p += [int(m.group(1))] if m else []
    m = re.search(r"VDD_CPU_GPU_CV (\d+)mW", l); r += [int(m.group(1))] if m else []
    m = re.search(r"tj@([\d.]+)C", l); tj = max(tj, float(m.group(1))) if m else tj
if p:
    print(f"  GPU {statistics.mean(g):.0f}% | VDD_IN {statistics.mean(p)/1000:.2f} W | CPU_GPU_CV {statistics.mean(r)/1000:.2f} W | tj max {tj:.0f} C")
