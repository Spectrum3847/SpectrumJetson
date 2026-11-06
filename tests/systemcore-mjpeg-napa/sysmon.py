#!/usr/bin/env python3
"""Per-second system sampler for the SystemCore bench (no vcgencmd on LimelightOS, no psutil).

  sudo python3 sysmon.py OUT.csv [--secs N] [--pid PID ...]

Columns: t (CLOCK_MONOTONIC s), busy% per core and total (from /proc/stat), MHz per core, SoC temp C,
firmware throttle flags (the mailbox's GET_THROTTLED, as `vcgencmd get_throttled`; needs root for
/dev/vcio), xhci IRQ/s, and for each --pid its CPU % (of one core), threads' total, RSS MiB, open fds
(leak checks in the soak). Stops after --secs or on SIGTERM/SIGINT; prints a summary.
"""
from __future__ import annotations

import argparse
import array
import fcntl
import os
import signal
import sys
import time

TICK = os.sysconf("SC_CLK_TCK")
NCPU = os.cpu_count() or 4


def cpu_times():
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu"):
                break
            p = line.split()
            v = list(map(int, p[1:]))
            idle = v[3] + v[4]
            out[p[0]] = (sum(v), idle)
    return out


def throttled(fd):
    if fd is None:
        return -1
    buf = array.array("I", [7 * 4, 0, 0x00030046, 4, 0, 0, 0])
    try:
        fcntl.ioctl(fd, 0xC0086400, buf, True)
        return buf[5]
    except OSError:
        return -1


def irqs():
    n = 0
    with open("/proc/interrupts") as f:
        for line in f:
            if "xhci" in line:
                p = line.split()
                n += sum(int(x) for x in p[1 : 1 + NCPU] if x.isdigit())
    return n


def proc(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            s = f.read().rsplit(")", 1)[1].split()
        ut, st, nthr, rss = int(s[11]), int(s[12]), int(s[17]), int(s[21])
        nfd = len(os.listdir(f"/proc/{pid}/fd"))
        return ut + st, nthr, rss * os.sysconf("SC_PAGE_SIZE") / 2**20, nfd
    except (OSError, IndexError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--secs", type=float, default=1e9)
    ap.add_argument("--pid", type=int, nargs="*", default=[])
    a = ap.parse_args()
    stop = [False]
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__(0, True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__(0, True))
    try:
        vcio = os.open("/dev/vcio", os.O_RDWR)
    except OSError:
        vcio = None
    cores = [f"cpu{i}" for i in range(NCPU)]
    hdr = ["t"] + [f"busy{i}" for i in range(NCPU)] + ["busy_all"] + [f"mhz{i}" for i in range(NCPU)]
    hdr += ["temp_c", "throttled", "xhci_irq_s"]
    for p in a.pid:
        hdr += [f"p{p}_cpu", f"p{p}_threads", f"p{p}_rss_mib", f"p{p}_fds"]
    f = open(a.out, "w")
    f.write(",".join(hdr) + "\n")
    prev, pirq, pp = cpu_times(), irqs(), {p: proc(p) for p in a.pid}
    t0 = time.monotonic()
    rows = []
    thr_any = 0
    while not stop[0] and time.monotonic() - t0 < a.secs:
        time.sleep(1.0)
        now, nirq = cpu_times(), irqs()
        row = [f"{time.monotonic():.3f}"]
        busy = []
        for c in cores + ["cpu"]:
            dt = now[c][0] - prev[c][0]
            di = now[c][1] - prev[c][1]
            busy.append(100.0 * (dt - di) / dt if dt else 0.0)
        row += [f"{b:.1f}" for b in busy]
        for i in range(NCPU):
            try:
                row.append(open(f"/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq").read().strip()[:-3])
            except OSError:
                row.append("")
        temp = int(open("/sys/class/thermal/thermal_zone0/temp").read()) / 1000
        th = throttled(vcio)
        thr_any |= max(th, 0)
        row += [f"{temp:.1f}", hex(th) if th >= 0 else "", str(nirq - pirq)]
        for p in a.pid:
            q = proc(p)
            if q and pp.get(p):
                row += [f"{100.0 * (q[0] - pp[p][0]) / TICK:.1f}", str(q[1]), f"{q[2]:.1f}", str(q[3])]
            else:
                row += ["", "", "", ""]
            pp[p] = q
        f.write(",".join(row) + "\n")
        f.flush()
        rows.append((busy[-1], temp, row))
        prev, pirq = now, nirq
    if rows:
        b = sorted(r[0] for r in rows)
        print(f"sysmon: {len(rows)} s, busy all cores p50 {b[len(b) // 2]:.1f}% max {b[-1]:.1f}%, "
              f"temp max {max(r[1] for r in rows):.1f} C, throttle flags seen {hex(thr_any)}")


if __name__ == "__main__":
    sys.exit(main())
