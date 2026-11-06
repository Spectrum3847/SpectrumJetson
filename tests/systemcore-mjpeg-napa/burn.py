#!/usr/bin/env python3
"""CPU load stand-in for robot code: one spinning process per listed core, for SECS seconds, then exits.

  python3 burn.py CORES SECS      e.g. burn.py 0,1 12   (CORES 'any' = unpinned, one per core)
"""
import os
import sys
import time

cores = sys.argv[1]
secs = float(sys.argv[2])
targets = list(range(os.cpu_count())) if cores == "any" else [int(c) for c in cores.split(",")]
kids = []
for c in targets:
    pid = os.fork()
    if pid == 0:
        if cores != "any":
            os.sched_setaffinity(0, {c})
        end = time.monotonic() + secs
        while time.monotonic() < end:
            pass
        os._exit(0)
    kids.append(pid)
for p in kids:
    os.waitpid(p, 0)
