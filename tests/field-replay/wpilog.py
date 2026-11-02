"""Minimal WPILib .wpilog reader: entries and records (no dependencies)."""
import struct


def read(path, want=None):
    """Returns (entries {id: (name, type, metadata)}, data {name: [(t_us, bytes)]}).
    want: optional predicate on the entry name; only those entries' records are kept."""
    b = open(path, "rb").read()
    assert b[:6] == b"WPILOG", "not a wpilog"
    hl = struct.unpack_from("<I", b, 8)[0]
    p = 12 + hl
    entries, data = {}, {}
    n = len(b)
    while p < n:
        h = b[p]; p += 1
        il = (h & 3) + 1; sl = ((h >> 2) & 3) + 1; tl = ((h >> 4) & 7) + 1
        eid = int.from_bytes(b[p:p + il], "little"); p += il
        size = int.from_bytes(b[p:p + sl], "little"); p += sl
        t = int.from_bytes(b[p:p + tl], "little"); p += tl
        if p + size > n:  # truncated at the end (the robot lost power mid-write)
            break
        pl = b[p:p + size]; p += size
        if eid == 0:
            if not pl:
                continue
            if pl[0] == 0:  # start
                e = struct.unpack_from("<I", pl, 1)[0]
                q = 5; out = []
                for _ in range(3):
                    ln = struct.unpack_from("<I", pl, q)[0]; q += 4
                    out.append(pl[q:q + ln].decode("utf-8", "replace")); q += ln
                entries[e] = tuple(out)
                if want is None or want(out[0]):
                    data.setdefault(out[0], [])
            continue
        e = entries.get(eid)
        if e and e[0] in data:
            data[e[0]].append((t, bytes(pl)))
    return entries, data
