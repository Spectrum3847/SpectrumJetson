#!/usr/bin/env python3
"""Lets WPILib 2027's desktop (simulation) libraries load on Ubuntu 22.04 (glibc 2.35).

WPILib 2027 alpha's linuxx86-64 libraries were built against glibc 2.38, but use only a few functions
that need it: fmod and fmodf (re-versioned in 2.38) and the C23 variants of strtol, strtoll,
strtoul, strtoull, sscanf and fscanf (__isoc23_*: the same as the classic ones apart from C23
additions such as 0b literals). glibc 2.35 has all of them under their older names. This rewrites a
copy of each library so those references bind to the older names:

  - each __isoc23_NAME symbol is renamed NAME (its string ends in NAME: only the offset changes),
  - their symbol versions become "any" (the default version libc provides),
  - the GLIBC_2.38 requirement, now unused, is taken out of the library's list of required
    versions. Where it's the only entry for that library, it's marked weak instead: the loader
    then doesn't insist on it, but programs print a "weak version ... not found" line at start.

Nothing else in the file changes (same size, same layout). Each function is first looked up in
this system's own libc or libm: a library that needs a 2.38 function this system doesn't have
(strlcpy, say) is left alone and reported, so it fails at load with the loader's usual message
instead of later. A library that needs nothing from 2.38 is left alone silently, and running it
again on a patched library changes nothing, so it's safe to run on a whole folder every time.
It's for simulation on a laptop that can't run Ubuntu 24.04 yet, never for a robot.

  glibc238_compat.py FILE.so...      patches in place (make copies first), prints what changed
  glibc238_compat.py --check FILE... reports, changes nothing
Exits 1 if a library couldn't be fixed.
"""
import os
import struct
import sys

VER_FLG_WEAK = 0x2
SHT_DYNSYM, SHT_GNU_VERSYM, SHT_GNU_VERNEED = 11, 0x6FFFFFFF, 0x6FFFFFFE
C23 = b"__isoc23_"


def sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not a 64-bit little-endian ELF")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    out = []
    for i in range(shnum):
        name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", data, shoff + i * shentsize)
        out.append(dict(type=typ, off=off, size=size, link=link, entsize=entsize))
    return out


def cstr(data, off):
    end = data.index(b"\0", off)
    return bytes(data[off:end])


def dynamic(data):
    secs = sections(data)
    dynsym = next((s for s in secs if s["type"] == SHT_DYNSYM), None)
    versym = next((s for s in secs if s["type"] == SHT_GNU_VERSYM), None)
    verneed = next((s for s in secs if s["type"] == SHT_GNU_VERNEED), None)
    return secs, dynsym, versym, verneed


_provided = {}


def provided(lib):
    """The functions this system's LIB (libc.so.6, libm.so.6) exports under its default version."""
    if lib not in _provided:
        names = set()
        for d in ("/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib64", "/usr/lib64"):
            f = os.path.join(d, lib)
            if os.path.exists(f):
                data = open(f, "rb").read()
                secs, dynsym, versym, _ = dynamic(data)
                dynstr = secs[dynsym["link"]]["off"]
                for i in range(dynsym["size"] // dynsym["entsize"]):
                    st_name, _, _, st_shndx = struct.unpack_from("<IBBH", data, dynsym["off"] + i * dynsym["entsize"])
                    hidden = versym and struct.unpack_from("<H", data, versym["off"] + 2 * i)[0] & 0x8000
                    if st_shndx and not hidden:
                        names.add(cstr(data, dynstr + st_name))
                break
        _provided[lib] = names
    return _provided[lib]


class Unfixable(Exception):
    pass


def patch(path, check=False):
    original = open(path, "rb").read()
    data = bytearray(original)
    secs, dynsym, versym, verneed = dynamic(data)
    if not (dynsym and versym and verneed):
        return []
    dynstr = secs[dynsym["link"]]["off"]
    # Version indexes that mean GLIBC_2.38, and the library each is in (libc.so.6, libm.so.6).
    targets = {}
    for off, _, a in auxes(data, verneed["off"]):
        if is_238(data, dynstr, a):
            vn_file, = struct.unpack_from("<I", data, off + 4)
            vna_other, = struct.unpack_from("<H", data, a + 6)
            targets[vna_other] = cstr(data, dynstr + vn_file).decode()
    if not targets:
        return []
    changes, edits, missing = [], [], []
    n = dynsym["size"] // dynsym["entsize"]
    for i in range(n):
        so = dynsym["off"] + i * dynsym["entsize"]
        st_name, = struct.unpack_from("<I", data, so)
        vo = versym["off"] + 2 * i
        ver, = struct.unpack_from("<H", data, vo)
        if (ver & 0x7FFF) not in targets:
            continue
        lib = targets[ver & 0x7FFF]
        name = cstr(data, dynstr + st_name)
        new = name[len(C23):] if name.startswith(C23) else name
        if new not in provided(lib):
            missing.append(f"{name.decode()} ({lib})")
            continue
        changes.append(f"{name.decode()} -> {new.decode()} (any version)")
        edits.append((so, st_name + (len(C23) if new != name else 0), vo))
    if missing:
        raise Unfixable("needs " + ", ".join(missing) + " from GLIBC_2.38, which this system doesn't have")
    if not check:
        for so, st_name, vo in edits:
            struct.pack_into("<I", data, so, st_name)
            struct.pack_into("<H", data, vo, 1)  # VER_NDX_GLOBAL: the library's default version
        while unlink_one(data, verneed["off"], dynstr):
            pass
        for _, _, a in auxes(data, verneed["off"]):  # the ones left: a library's only entry
            if is_238(data, dynstr, a):
                flags, = struct.unpack_from("<H", data, a + 4)
                struct.pack_into("<H", data, a + 4, flags | VER_FLG_WEAK)
        if data != original:
            open(path, "wb").write(data)
    return changes


def auxes(data, verneed_off):
    """(verneed entry offset, previous aux offset or None, aux offset) for every required version.

    Elf64_Verneed: vn_version, vn_cnt (H), vn_file, vn_aux, vn_next (I). Elf64_Vernaux: vna_hash (I),
    vna_flags, vna_other (H), vna_name, vna_next (I). The offsets are relative."""
    off = verneed_off
    while True:
        _, vn_cnt, _, vn_aux, vn_next = struct.unpack_from("<HHIII", data, off)
        a, prev = off + vn_aux, None
        for _ in range(vn_cnt):
            yield off, prev, a
            vna_next, = struct.unpack_from("<I", data, a + 12)
            if not vna_next:
                break
            prev, a = a, a + vna_next
        if not vn_next:
            return
        off += vn_next


def is_238(data, dynstr, aux):
    vna_name, = struct.unpack_from("<I", data, aux + 8)
    return cstr(data, dynstr + vna_name) == b"GLIBC_2.38"


def unlink_one(data, verneed_off, dynstr):
    """Takes one GLIBC_2.38 entry out of its library's list (if it isn't the only one). True if it did."""
    for off, prev, a in auxes(data, verneed_off):
        if not is_238(data, dynstr, a):
            continue
        vn_cnt, = struct.unpack_from("<H", data, off + 2)
        if vn_cnt < 2:
            continue
        vna_next, = struct.unpack_from("<I", data, a + 12)
        if prev is None:  # the first: the list starts at the next one
            vn_aux, = struct.unpack_from("<I", data, off + 8)
            struct.pack_into("<I", data, off + 8, vn_aux + vna_next)
        else:  # skip over it (0 if it was the last)
            prev_next, = struct.unpack_from("<I", data, prev + 12)
            struct.pack_into("<I", data, prev + 12, prev_next + vna_next if vna_next else 0)
        struct.pack_into("<H", data, off + 2, vn_cnt - 1)
        return True
    return False


def main():
    check = "--check" in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not files:
        sys.exit(__doc__)
    failed = False
    for f in files:
        try:
            ch = patch(f, check)
        except (ValueError, struct.error, IsADirectoryError):
            continue  # not a 64-bit ELF file
        except Unfixable as e:
            print(f"{f}: NOT CHANGED, {e}")
            failed = True
            continue
        if ch:
            print(f"{f}: {'would change' if check else 'changed'} {', '.join(ch)}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
