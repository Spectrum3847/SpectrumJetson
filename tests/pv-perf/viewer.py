#!/usr/bin/env python3
"""A dashboard-like MJPEG stream viewer: reads URL for SECS seconds, reports frames/s and bytes/s.
  viewer.py URL SECS"""
import sys
import time
import urllib.request

url, secs = sys.argv[1], float(sys.argv[2])
t0 = time.monotonic()
n = 0
frames = 0
while True:
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            while time.monotonic() - t0 < secs:
                b = r.read(65536)
                if not b:
                    break
                n += len(b)
                frames += b.count(b'\xff\xd8\xff')
            break
    except Exception as e:  # PV not ready yet
        if time.monotonic() - t0 > secs:
            break
        print('retry', e)
        time.sleep(0.5)
dt = time.monotonic() - t0
print(f'{url}: {frames / dt:.1f} frames/s, {n / dt / 1e6:.2f} MB/s, {n / max(frames, 1) / 1e3:.1f} KB/frame')
