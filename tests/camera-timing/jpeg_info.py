#!/usr/bin/env python3
"""JPEG structure of an MJPEG capture (concatenated frames, e.g. v4l2-ctl --stream-to or uvc_timing --frames).

  jpeg_info.py FILE.mjpeg [--frames N]

Prints, for the first frame: markers (DQT/DHT/DRI/SOF0/SOS), SOF component sampling, DQT tables, restart
interval in MCUs and pixel rows; then over N frames: bytes per frame (p5/p50/p95), restart markers per frame,
and bytes per restart interval.
Standard library only.
"""
import struct
import sys


def frames(data):
    i = 0
    n = len(data)
    while True:
        s = data.find(b"\xff\xd8", i)
        if s < 0:
            return
        e = data.find(b"\xff\xd9", s + 2)
        if e < 0:
            return
        # An EOI can appear inside entropy data only as FF D9 (stuffing makes FF 00), so this is the frame end.
        yield data[s:e + 2]
        i = e + 2
        if i >= n:
            return


def parse(f):
    """Header segments up to SOS, then the entropy-coded part split at RSTn markers."""
    info = {"markers": [], "dqt": {}, "dht": [], "dri": 0, "sof": None, "sos": None}
    i = 2
    while i + 4 <= len(f):
        if f[i] != 0xFF:
            raise ValueError("bad marker at %d" % i)
        m = f[i + 1]
        if m == 0xFF:
            i += 1
            continue
        ln = struct.unpack(">H", f[i + 2:i + 4])[0]
        seg = f[i + 4:i + 2 + ln]
        info["markers"].append("%02X" % m)
        if m == 0xDB:
            j = 0
            while j < len(seg):
                pq, tq = seg[j] >> 4, seg[j] & 15
                sz = 128 if pq else 64
                info["dqt"][tq] = list(seg[j + 1:j + 1 + sz])
                j += 1 + sz
        elif m == 0xC4:
            j = 0
            while j < len(seg):
                tc, th = seg[j] >> 4, seg[j] & 15
                cnt = sum(seg[j + 1:j + 17])
                info["dht"].append((tc, th, cnt))
                j += 17 + cnt
        elif m == 0xDD:
            info["dri"] = struct.unpack(">H", seg[:2])[0]
        elif m in (0xC0, 0xC1, 0xC2):
            p, h, w, nc = seg[0], struct.unpack(">H", seg[1:3])[0], struct.unpack(">H", seg[3:5])[0], seg[5]
            comps = [(seg[6 + 3 * k], seg[7 + 3 * k] >> 4, seg[7 + 3 * k] & 15, seg[8 + 3 * k]) for k in range(nc)]
            info["sof"] = (m, p, w, h, comps)
        elif m == 0xDA:
            info["sos"] = seg[0]
            i = i + 2 + ln
            break
        i += 2 + ln
    body = f[i:-2]
    # split at RSTn (FF D0..D7)
    pieces = []
    s = 0
    k = body.find(b"\xff", 0)
    while 0 <= k < len(body) - 1:
        if 0xD0 <= body[k + 1] <= 0xD7:
            pieces.append(k - s)
            s = k + 2
        k = body.find(b"\xff", k + 2)
    pieces.append(len(body) - s)
    info["hdr_bytes"] = i
    info["intervals"] = pieces
    return info


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p / 100 * len(v)))]


def main():
    path = sys.argv[1]
    nmax = 1000
    if "--frames" in sys.argv:
        nmax = int(sys.argv[sys.argv.index("--frames") + 1])
    data = open(path, "rb").read()
    sizes, nint, ibytes = [], [], []
    first = None
    for k, f in enumerate(frames(data)):
        if k >= nmax:
            break
        try:
            inf = parse(f)
        except (ValueError, struct.error, IndexError):
            continue
        first = first or inf
        sizes.append(len(f))
        nint.append(len(inf["intervals"]))
        ibytes.extend(inf["intervals"])
    if not first:
        print("no frames")
        return
    m, p, w, h, comps = first["sof"]
    hmax = max(c[1] for c in comps)
    vmax = max(c[2] for c in comps)
    mcu_w, mcu_h = 8 * hmax, 8 * vmax
    mcus_row = (w + mcu_w - 1) // mcu_w
    print("file", path)
    print("markers (first frame):", " ".join(first["markers"]), " header bytes", first["hdr_bytes"])
    print("SOF%X %dx%d precision %d, components %s (id,H,V,Tq) -> MCU %dx%d, %d MCUs per row" %
          (m - 0xC0, w, h, p, comps, mcu_w, mcu_h, mcus_row))
    print("DHT tables (class,id,symbols):", first["dht"])
    dri = first["dri"]
    if dri:
        print("DRI %d MCUs = %.2f MCU rows = %d pixel rows per restart interval" %
              (dri, dri / mcus_row, int(dri / mcus_row * mcu_h)))
    else:
        print("no DRI (no restart markers)")
    for t, q in sorted(first["dqt"].items()):
        print("DQT %d: first 8 (zigzag) %s ... sum %d" % (t, q[:8], sum(q)))
    print("frames %d: bytes p5/p50/p95 %d/%d/%d; restart intervals per frame p50 %d; bytes per interval p50 %d"
          % (len(sizes), pct(sizes, 5), pct(sizes, 50), pct(sizes, 95), pct(nint, 50), pct(ibytes, 50)))


if __name__ == "__main__":
    main()
