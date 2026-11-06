#!/usr/bin/env python3
"""How a baseline MJPEG frame's entropy-coded bits split between Y, Cb and Cr (pure Python, slow: a few frames).

  python3 jpegbits.py SESSION_CAMERA_DIR [--frames 5]      (a Rewind camera folder: 0000.mjpeg + 0000.csv)

Prints the frame layout (SOF0 sampling, DRI, DQT/DHT present), then per component: bits, % of the scan,
blocks, bits per block, DC-only blocks (no AC: just the DC code + EOB), and the restart-marker count.
"""
import argparse
import csv
import os
import struct


def parse(j):
    i, info, dht = 2, {"dht": [], "dqt": 0}, {}
    while i < len(j):
        m = j[i + 1]
        ln = struct.unpack(">H", j[i + 2 : i + 4])[0]
        seg = j[i + 4 : i + 2 + ln]
        if m == 0xC0:
            h, w, nc = struct.unpack(">HHB", seg[1:6])
            info["sof"] = (w, h, [(seg[6 + 3 * k], seg[7 + 3 * k] >> 4, seg[7 + 3 * k] & 15, seg[8 + 3 * k]) for k in range(nc)])
        elif m == 0xDD:
            info["dri"] = struct.unpack(">H", seg[:2])[0]
        elif m == 0xDB:
            info["dqt"] += 1
        elif m == 0xC4:
            p = 0
            while p < len(seg):
                tc, th = seg[p] >> 4, seg[p] & 15
                counts = seg[p + 1 : p + 17]
                syms = seg[p + 17 : p + 17 + sum(counts)]
                code, k, table = 0, 0, {}
                for L in range(1, 17):
                    for _ in range(counts[L - 1]):
                        table[(L, code)] = syms[k]
                        k += 1
                        code += 1
                    code <<= 1
                dht[(tc, th)] = table
                info["dht"].append((tc, th))
                p += 17 + sum(counts)
        elif m == 0xDA:
            ns = seg[0]
            info["scan"] = [(seg[1 + 2 * k], seg[2 + 2 * k] >> 4, seg[2 + 2 * k] & 15) for k in range(ns)]
            return info, dht, i + 2 + ln
        i += 2 + ln
    raise ValueError("no SOS")


class Bits:
    def __init__(self, d, p):
        self.d, self.p, self.acc, self.n, self.used, self.rst = d, p, 0, 0, 0, 0

    def fill(self):
        while self.n <= 24:
            b = self.d[self.p]
            if b == 0xFF:
                nx = self.d[self.p + 1]
                if nx == 0:
                    self.p += 2
                else:  # marker: feed zeros
                    b = 0
            else:
                self.p += 1
            self.acc = (self.acc << 8) | b
            self.n += 8

    def get(self, k):
        if k == 0:
            return 0
        if self.n < k:
            self.fill()
        self.n -= k
        self.used += k
        return (self.acc >> self.n) & ((1 << k) - 1)

    def huff(self, table):
        code = 0
        for L in range(1, 17):
            code = (code << 1) | self.get(1)
            if (L, code) in table:
                return table[(L, code)]
        raise ValueError("bad code")

    def restart(self):
        self.n = 0
        self.acc = 0
        while not (self.d[self.p] == 0xFF and 0xD0 <= self.d[self.p + 1] <= 0xD7):
            self.p += 1
        self.p += 2
        self.rst += 1


def frame_bits(j):
    info, dht, p = parse(j)
    w, h, comps = info["sof"]
    hmax = max(c[1] for c in comps)
    vmax = max(c[2] for c in comps)
    mcux = -(-w // (8 * hmax))
    mcuy = -(-h // (8 * vmax))
    tabs = {c[0]: (dht[(0, c[1])], dht[(1, c[2])]) for c in info["scan"]}
    samp = {c[0]: (c[1], c[2]) for c in comps}
    dri = info.get("dri", 0)
    B = Bits(j, p)
    stat = {c[0]: [0, 0, 0] for c in comps}  # bits, blocks, dc-only blocks
    for m in range(mcux * mcuy):
        if dri and m and m % dri == 0:
            B.restart()
        for cid, _, _ in info["scan"]:
            hs, vs = samp[cid]
            dct, act = tabs[cid]
            for _ in range(hs * vs):
                u0 = B.used
                s = B.huff(dct)
                B.get(s)
                k, dc_only = 1, True
                while k < 64:
                    rs = B.huff(act)
                    r, s = rs >> 4, rs & 15
                    if s == 0:
                        if r == 15:
                            k += 16
                            continue
                        break
                    dc_only = False
                    k += r
                    B.get(s)
                    k += 1
                st = stat[cid]
                st[0] += B.used - u0
                st[1] += 1
                st[2] += dc_only
    return info, stat, B.rst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cam_dir")
    ap.add_argument("--frames", type=int, default=5)
    a = ap.parse_args()
    data = open(os.path.join(a.cam_dir, "0000.mjpeg"), "rb").read()
    rows = [r for r in csv.reader(open(os.path.join(a.cam_dir, "0000.csv"))) if r and not r[0].startswith("#")]
    tot = {}
    for r in rows[: a.frames]:
        o, n = int(r[1]), int(r[2])
        info, stat, rst = frame_bits(data[o : o + n])
        for k, v in stat.items():
            t = tot.setdefault(k, [0, 0, 0])
            for i in range(3):
                t[i] += v[i]
    w, h, comps = info["sof"]
    print(f"{a.cam_dir}: {w}x{h}, components (id, h, v, q) {comps}, DRI {info.get('dri', 0)} MCUs, "
          f"DQT {info['dqt']}, DHT tables {info['dht'] or 'NONE (MJPEG default tables)'}, restarts/frame {rst}, "
          f"{len(rows[: a.frames])} frames, {n} bytes last")
    allb = sum(v[0] for v in tot.values())
    for cid, (bits, blocks, dco) in sorted(tot.items()):
        print(f"  comp {cid}: {100 * bits / allb:5.1f}% of bits, {bits / blocks:6.2f} bits/block, "
              f"{100 * dco / blocks:5.1f}% DC-only blocks, {blocks // len(rows[: a.frames])} blocks/frame")


if __name__ == "__main__":
    main()
