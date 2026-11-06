#!/usr/bin/env python3
"""Calibrate CPU accounting on this kernel: a pinned load that is busy BUSY_US then sleeps SLEEP_US, for SECS,
compared across its own CLOCK_THREAD_CPUTIME, /proc/self/schedstat, /proc/self/stat ticks and the core's
/proc/stat busy %. Tells which of the numbers the latency scripts use can be trusted for poll-style loops.

  python3 cpucal.py CORE BUSY_US SLEEP_US [SECS]
"""
import os
import sys
import time

core, busy_us, sleep_us = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
secs = float(sys.argv[4]) if len(sys.argv) > 4 else 8
os.sched_setaffinity(0, {core})
tick = os.sysconf("SC_CLK_TCK")


def core_stat():
    for ln in open("/proc/stat"):
        if ln.startswith(f"cpu{core} "):
            v = list(map(int, ln.split()[1:]))
            return sum(v), v[3] + v[4]


def self_stat():
    s = open("/proc/self/stat").read().rsplit(")", 1)[1].split()
    return int(s[11]) + int(s[12])


def sched():
    return int(open("/proc/self/schedstat").read().split()[0])


c0, ss0, st0, (ct0, ci0), w0 = time.thread_time(), sched(), self_stat(), core_stat(), time.monotonic()
while time.monotonic() - w0 < secs:
    e = time.perf_counter() + busy_us / 1e6
    while time.perf_counter() < e:
        pass
    time.sleep(sleep_us / 1e6)
w = time.monotonic() - w0
c, ss, st, (ct, ci) = time.thread_time() - c0, sched() - ss0, self_stat() - st0, core_stat()
print(f"busy {busy_us:.0f} us / sleep {sleep_us:.0f} us on core {core}, {w:.1f} s: "
      f"thread_time {100 * c / w:.1f}% | schedstat {100 * ss / 1e9 / w:.1f}% | /proc/self/stat {100 * st / tick / w:.1f}% | "
      f"/proc/stat core busy {100 * ((ct - ct0) - (ci - ci0)) / (ct - ct0):.1f}%")
