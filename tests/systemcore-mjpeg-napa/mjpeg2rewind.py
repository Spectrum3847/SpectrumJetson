#!/usr/bin/env python3
"""Concatenated MJPEG (v4l2-ctl --stream-to) -> a Rewind camera folder (docs/REWIND.md) for scmn_bench.

  python3 mjpeg2rewind.py CAPTURE.mjpeg SESSION_DIR [--cam Thriftiest] [--fps 120] [--width 1280 --height 800]

Frames are split at SOI .. EOI (the camera never puts FFD9 inside entropy data: byte stuffing). Also
prints the JPEG structure of the first frame (components, sampling, restart interval, size).
"""
import argparse
import os
import struct


def split(data):
    out, i = [], 0
    while True:
        s = data.find(b"\xff\xd8", i)
        if s < 0:
            return out
        e = data.find(b"\xff\xd9", s)
        if e < 0:
            return out
        out.append(data[s : e + 2])
        i = e + 2


def describe(j):
    i, info = 2, {}
    while i + 4 <= len(j):
        if j[i] != 0xFF:
            break
        m = j[i + 1]
        ln = struct.unpack(">H", j[i + 2 : i + 4])[0]
        seg = j[i + 4 : i + 2 + ln]
        if m == 0xC0 or m == 0xC1:
            h, w, nc = struct.unpack(">HHB", seg[1:6])
            comps = [(seg[6 + 3 * k], seg[7 + 3 * k] >> 4, seg[7 + 3 * k] & 15) for k in range(nc)]
            info.update(w=w, h=h, comps=comps)
        elif m == 0xDD:
            info["dri_mcus"] = struct.unpack(">H", seg[:2])[0]
        elif m == 0xDA:
            break
        i += 2 + ln
    info["bytes"] = len(j)
    return info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("session")
    ap.add_argument("--cam", default="Thriftiest")
    ap.add_argument("--fps", type=float, default=120)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=800)
    a = ap.parse_args()
    frames = split(open(a.capture, "rb").read())
    d = os.path.join(a.session, a.cam)
    os.makedirs(d, exist_ok=True)
    off = 0
    with open(os.path.join(d, "0000.mjpeg"), "wb") as fj, open(os.path.join(d, "0000.csv"), "w") as fc:
        fc.write("# frame,offset,size,width,height,jetson_us,robot_us\n")
        for k, f in enumerate(frames):
            fj.write(f)
            us = int(1e6 + k * 1e6 / a.fps)
            fc.write(f"{k},{off},{len(f)},{a.width},{a.height},{us},{us}\n")
            off += len(f)
    sizes = sorted(len(f) for f in frames)
    print(f"{len(frames)} frames, KiB p50 {sizes[len(sizes) // 2] / 1024:.1f} max {sizes[-1] / 1024:.1f}; first: {describe(frames[0])}")


if __name__ == "__main__":
    main()
