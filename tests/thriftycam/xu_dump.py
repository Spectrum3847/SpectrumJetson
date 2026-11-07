#!/usr/bin/env python3
"""Read-only UVC extension-unit dump: GET_INFO/GET_LEN/GET_CUR/MIN/MAX/DEF per selector via UVCIOC_CTRL_QUERY.
   xu_dump.py /dev/videoN UNIT:SEL1-SELn [...]   (only GET requests are sent)"""
import ctypes, fcntl, json, os, sys

UVCIOC_CTRL_QUERY = 0xC0107521
Q = dict(cur=0x81, min=0x82, max=0x83, res=0x84, len=0x85, info=0x86, dflt=0x87)


class Query(ctypes.Structure):
    _fields_ = [("unit", ctypes.c_uint8), ("selector", ctypes.c_uint8), ("query", ctypes.c_uint8),
                ("size", ctypes.c_uint16), ("data", ctypes.c_void_p)]


def q(fd, unit, sel, query, size):
    buf = ctypes.create_string_buffer(size)
    x = Query(unit, sel, query, size, ctypes.cast(buf, ctypes.c_void_p))
    try:
        fcntl.ioctl(fd, UVCIOC_CTRL_QUERY, x)
    except OSError as e:
        return "err%d" % e.errno
    return buf.raw.hex()


def main():
    fd = os.open(sys.argv[1], os.O_RDWR)
    for spec in sys.argv[2:]:
        unit, sels = spec.split(":")
        a, b = map(int, sels.split("-"))
        for sel in range(a, b + 1):
            r = dict(unit=int(unit), sel=sel)
            ln = q(fd, int(unit), sel, Q["len"], 2)
            if ln.startswith("err"):
                r["len"] = ln
            else:
                n = int.from_bytes(bytes.fromhex(ln), "little"); r["len"] = n
                r["info"] = q(fd, int(unit), sel, Q["info"], 1)
                if 0 < n <= 64:
                    for k in ("cur", "min", "max", "dflt"):
                        r[k] = q(fd, int(unit), sel, Q[k], n)
            print(json.dumps(r), flush=True)
    os.close(fd)


main()
