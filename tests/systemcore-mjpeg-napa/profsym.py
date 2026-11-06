#!/usr/bin/env python3
"""Symbolize scmn_prof output on the laptop: per function, % of samples.

  python profsym.py SAMPLES.txt LIBDIR [--nm PATH-TO-aarch64-nm] [--top 40]

LIBDIR holds copies of the mapped files (same basenames as in the "map" lines; copy them from the Pi). Assumes
the usual layout where a text segment's file offset equals its virtual address offset (true for the
toolchain's executables and shared libraries), so the symbol address is ip - map_start + map_offset (+ the
load base 0 for non-PIE executables, where the map start already is the virtual address).
"""
import argparse
import bisect
import collections
import os
import subprocess

NM = "C:/Users/Public/wpilib/2027_alpha7/systemcore/bin/aarch64-systemcore2027-linux-gnu-nm.exe"


def syms(nm, path):
    try:
        out = subprocess.run([nm, "-C", "--defined-only", "-n", path], capture_output=True, text=True).stdout
        if not out.strip():
            out = subprocess.run([nm, "-C", "-D", "--defined-only", "-n", path], capture_output=True, text=True).stdout
    except OSError:
        return [], []
    addrs, names = [], []
    for ln in out.splitlines():
        p = ln.split(" ", 2)
        if len(p) == 3 and p[1] in "tTwW":
            addrs.append(int(p[0], 16))
            names.append(p[2])
    return addrs, names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("samples")
    ap.add_argument("libdir")
    ap.add_argument("--nm", default=NM)
    ap.add_argument("--top", type=int, default=40)
    a = ap.parse_args()
    maps, ips, head = [], [], ""
    for ln in open(a.samples):
        if ln.startswith("map "):
            p = ln.split()
            s, e = (int(x, 16) for x in p[1].split("-"))
            maps.append((s, e, int(p[3], 16), p[6] if len(p) > 6 else "?"))
        elif ln.startswith("ip "):
            _, ip, n = ln.split()
            ips.append((int(ip, 16), int(n)))
        elif ln.startswith("samples"):
            head = ln.strip()
    cache = {}
    per_fn = collections.Counter()
    per_obj = collections.Counter()
    total = sum(n for _, n in ips)
    for ip, n in ips:
        m = next((m for m in maps if m[0] <= ip < m[1]), None)
        if not m:
            per_fn["[unknown]"] += n
            continue
        base = os.path.basename(m[3])
        per_obj[base] += n
        if base not in cache:
            local = os.path.join(a.libdir, base)
            cache[base] = syms(a.nm, local) if os.path.exists(local) else ([], [])
        addrs, names = cache[base]
        exe_nonpie = m[0] >= 0x400000 and m[2] == 0 and addrs and addrs[0] >= 0x400000
        addr = ip if exe_nonpie else ip - m[0] + m[2]
        i = bisect.bisect_right(addrs, addr) - 1
        per_fn[f"{names[i]}  [{base}]" if i >= 0 else f"? [{base}]"] += n
    print(head)
    print("by object: " + ", ".join(f"{k} {100 * v / total:.1f}%" for k, v in per_obj.most_common(8)))
    for k, v in per_fn.most_common(a.top):
        print(f"  {100 * v / total:5.1f}%  {k}")


if __name__ == "__main__":
    main()
