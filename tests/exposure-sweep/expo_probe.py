#!/usr/bin/env python3
# Stdlib-only NT4 probe for the exposure sweep: subscribes to /photonvision/<cam>/rawBytes and tagQuality for the
# given cameras, decodes PhotonPipelineResult, and prints per camera per tag: detection rate, decision margin,
# corner jitter (sd of each corner coordinate, px), range sd (mm), plus latency (capture -> received) and fps.
#   expo_probe.py SECS cam1 [cam2 ...]   -> JSON on stdout
import base64, json, os, socket, struct, sys, time, statistics as st

def mp_unpack(b, i=0):
    t = b[i]
    if t <= 0x7f: return t, i + 1
    if t >= 0xe0: return t - 256, i + 1
    if 0x80 <= t <= 0x8f:
        n = t & 15; d = {}; i += 1
        for _ in range(n):
            k, i = mp_unpack(b, i); v, i = mp_unpack(b, i); d[k] = v
        return d, i
    if 0x90 <= t <= 0x9f:
        n = t & 15; a = []; i += 1
        for _ in range(n):
            v, i = mp_unpack(b, i); a.append(v)
        return a, i
    if 0xa0 <= t <= 0xbf:
        n = t & 31; return b[i+1:i+1+n].decode(), i + 1 + n
    simple = {0xc0: None, 0xc2: False, 0xc3: True}
    if t in simple: return simple[t], i + 1
    fmt = {0xcc: 'B', 0xcd: '>H', 0xce: '>I', 0xcf: '>Q', 0xd0: 'b', 0xd1: '>h', 0xd2: '>i', 0xd3: '>q', 0xca: '>f', 0xcb: '>d'}
    if t in fmt:
        s = struct.calcsize(fmt[t]); return struct.unpack_from(fmt[t], b, i + 1)[0], i + 1 + s
    if t in (0xc4, 0xd9): n = b[i+1]; o = i + 2
    elif t in (0xc5, 0xda): n = struct.unpack_from('>H', b, i+1)[0]; o = i + 3
    elif t in (0xc6, 0xdb): n = struct.unpack_from('>I', b, i+1)[0]; o = i + 5
    elif t in (0xdc, 0xdd):
        n = struct.unpack_from('>H' if t == 0xdc else '>I', b, i+1)[0]; i += 3 if t == 0xdc else 5; a = []
        for _ in range(n):
            v, i = mp_unpack(b, i); a.append(v)
        return a, i
    elif t in (0xde, 0xdf):
        n = struct.unpack_from('>H' if t == 0xde else '>I', b, i+1)[0]; i += 3 if t == 0xde else 5; d = {}
        for _ in range(n):
            k, i = mp_unpack(b, i); v, i = mp_unpack(b, i); d[k] = v
        return d, i
    else: raise ValueError(hex(t))
    raw = bytes(b[o:o+n])
    return (raw if t in (0xc4, 0xc5, 0xc6) else raw.decode()), o + n

class WS:
    def __init__(s, host, port, path):
        s.k = socket.create_connection((host, port)); key = base64.b64encode(os.urandom(16)).decode()
        s.k.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                     f"Sec-WebSocket-Protocol: v4.1.networktables.first.wpi.edu, networktables.first.wpi.edu\r\n\r\n").encode())
        h = b""
        while b"\r\n\r\n" not in h: h += s.k.recv(1)
        if b" 101 " not in h.split(b"\r\n")[0]: raise RuntimeError(h)
        s.buf = bytearray()
    def send(s, data, op=1):
        if isinstance(data, str): data = data.encode()
        m = os.urandom(4); n = len(data)
        hdr = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else bytes([0xfe]) + struct.pack('>H', n) if n < 65536 else bytes([0xff]) + struct.pack('>Q', n))
        s.k.sendall(hdr + m + bytes(c ^ m[i & 3] for i, c in enumerate(data)))
    def _need(s, n):
        while len(s.buf) < n:
            d = s.k.recv(1 << 16)
            if not d: raise EOFError
            s.buf += d
    def recv(s):
        msg = bytearray(); op0 = None
        while True:
            s._need(2); b0, b1 = s.buf[0], s.buf[1]; n = b1 & 127; o = 2
            if n == 126: s._need(4); n = struct.unpack_from('>H', s.buf, 2)[0]; o = 4
            elif n == 127: s._need(10); n = struct.unpack_from('>Q', s.buf, 2)[0]; o = 10
            s._need(o + n); payload = bytes(s.buf[o:o+n]); del s.buf[:o+n]
            op = b0 & 15
            if op == 9: s.send(payload, 10); continue
            if op in (1, 2): op0 = op
            msg += payload
            if b0 & 0x80: return op0, bytes(msg)

def decode_result(b):
    seq, cap, pub = struct.unpack_from('<qqq', b, 0)
    n = struct.unpack_from('<b', b, 32)[0]; i = 33; tg = []
    for _ in range(n):
        yaw, pitch, area, skew = struct.unpack_from('<4d', b, i); i += 32
        fid, = struct.unpack_from('<i', b, i); i += 12  # id, objDetectId, objDetectConf
        best = struct.unpack_from('<7d', b, i); i += 56
        i += 56 + 8  # alt pose, ambiguity
        k = struct.unpack_from('<b', b, i)[0]; i += 1 + 16 * k
        k = struct.unpack_from('<b', b, i)[0]; c = struct.unpack_from(f'<{2*k}d', b, i + 1); i += 1 + 16 * k
        tg.append((fid, best[:3], c))
    return seq, cap, tg

def main():
    secs = float(sys.argv[1]); cams = sys.argv[2:]
    ws = WS("127.0.0.1", 5810, "/nt/expo_probe")
    subs = [f"/photonvision/{c}/{t}" for c in cams for t in ("rawBytes", "tagQuality")]
    ws.send(json.dumps([{"method": "subscribe", "params": {"topics": subs, "subuid": 1, "options": {"all": True, "periodic": 0.005}}}]))
    ids = {}; S = {c: {"n": 0, "lat": [], "tags": {}, "q": {}} for c in cams}
    t0 = time.monotonic(); end = t0 + secs + 1.0; start_collect = t0 + 1.0
    while time.monotonic() < end:
        op, m = ws.recv()
        if op == 1:
            for a in json.loads(m):
                if a.get("method") == "announce": ids[a["params"]["id"]] = a["params"]["name"]
            continue
        now = time.monotonic_ns(); i = 0
        while i < len(m):
            arr, i = mp_unpack(m, i)
            if time.monotonic() < start_collect: continue
            name = ids.get(arr[0]);
            if not name: continue
            _, cam, topic = name.split("/")[1:4] if name.count("/") >= 3 else (None, None, None)
            if cam not in S: continue
            s = S[cam]
            if topic == "tagQuality":
                v = arr[3]
                if len(v) >= 2:
                    s["q"][int(v[0])] = [(int(v[2+6*j]), v[3+6*j]) for j in range(int(v[1]))]
            elif topic == "rawBytes":
                seq, cap, tg = decode_result(arr[3]); s["n"] += 1; s["lat"].append((now - cap) / 1e6)
                for fid, t, c in tg:
                    d = s["tags"].setdefault(fid, {"n": 0, "r": [], "c": [], "seqs": []})
                    d["n"] += 1; d["r"].append((t[0]**2 + t[1]**2 + t[2]**2) ** .5); d["c"].append(c); d["seqs"].append(seq)
    out = {}
    for cam, s in S.items():
        lat = sorted(s["lat"]); n = s["n"]
        o = {"results": n, "fps": n / secs,
             "lat_p50": lat[len(lat)//2] if lat else None, "lat_p95": lat[int(.95*len(lat))] if lat else None, "tags": {}}
        for fid, d in sorted(s["tags"].items()):
            margins = [mm for q in (s["q"].get(x) for x in d["seqs"]) if q for (f, mm) in q if f == fid]
            cs = [c for c in d["c"] if len(c) == 8]
            jit = st.mean(st.pstdev(col) for col in zip(*cs)) if len(cs) > 2 else None
            o["tags"][fid] = {"rate": d["n"] / max(n, 1), "range_m": st.mean(d["r"]),
                              "range_sd_mm": 1000 * st.pstdev(d["r"]) if len(d["r"]) > 2 else None,
                              "margin": st.mean(margins) if margins else None, "jitter_px": jit,
                              "side_px": (((cs[0][0]-cs[0][2])**2 + (cs[0][1]-cs[0][3])**2) ** .5) if cs else None}
        out[cam] = o
    print(json.dumps(out))

if __name__ == "__main__":
    main()
