#!/usr/bin/env python3
"""Which threads (kernel ones included) used the CPU over an interval, from /proc/*/task/*/schedstat (ns exact),
with the core each last ran on. busybox top has no per-thread or per-core view.

  sudo python3 topcpu.py [SECS] [N]
"""
import glob
import sys
import time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5
n = int(sys.argv[2]) if len(sys.argv) > 2 else 15


def snap():
    out = {}
    for t in glob.glob("/proc/[0-9]*/task/[0-9]*"):
        try:
            ns = int(open(t + "/schedstat").read().split()[0])
            st = open(t + "/stat").read()
            comm = st[st.index("(") + 1 : st.rindex(")")]
            cpu = int(st.rsplit(")", 1)[1].split()[36])
            out[t] = (ns, comm, cpu)
        except (OSError, ValueError, IndexError):
            pass
    return out


a = snap()
time.sleep(secs)
b = snap()
rows = []
for t, (ns, comm, cpu) in b.items():
    d = ns - a.get(t, (ns, 0, 0))[0]
    if d > 0:
        rows.append((d, t.split("/")[2], t.split("/")[4], comm, cpu))
rows.sort(reverse=True)
percore = {}
for d, *_x, cpu in rows:
    percore[cpu] = percore.get(cpu, 0) + d
ncpu = len(glob.glob("/sys/devices/system/cpu/cpu[0-9]*"))
print(f"{secs:.0f} s; ALL threads {100 * sum(percore.values()) / 1e9 / secs / ncpu:.1f}% of {ncpu} cores; per core (by last CPU, threads can move): " +
      ", ".join(f"cpu{c} {100 * v / 1e9 / secs:.1f}%" for c, v in sorted(percore.items())))
for d, pid, tid, comm, cpu in rows[:n]:
    print(f"  {100 * d / 1e9 / secs:6.1f}%  pid {pid:>6} tid {tid:>6} cpu{cpu}  {comm}")
