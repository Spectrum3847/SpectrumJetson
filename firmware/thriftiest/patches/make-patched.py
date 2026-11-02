#!/usr/bin/env python3
"""Build experimental Thriftiest Cam images from Thrifty Bot's published 5.13.

The published image is NOT kept in this repo; pass your own copy (thriftiest-flash.sh downloads it).
Every patch checks the old bytes first. See docs/THRIFTIEST-FIRMWARE-ANALYSIS.md.

  make-patched.py IN.bin OUT.bin PATCH [PATCH...]      patches: see PATCHES below
  make-patched.py --list
"""
import hashlib
import sys

PUBLISHED_513 = "79bfebdb731dff2439ff333abc86cd905d857ad604f869af9fb9a6a19d59616c"

# name -> (description, [(offset, old bytes, new bytes), ...])
PATCHES = {
    "usbrecov": ("the coach's usbrecov patch (two JNZ -> NOP)", [
        (0x15037, "701e", "0000"),
        (0x1503D, "7018", "0000"),
    ]),
    "bwreport": ("lower default USB bandwidth request", [
        (0x1A1D7, "27099a", "240500"),
    ]),
    # Binned 640x400 (OV9281 2x2, sensor table 0x19E4) runs at 120 fps with HTS 0x05B0, twice the
    # full-res line time, so the 400 rows still take ~7.4 ms to read out. Halve HTS for the 120 fps
    # and slower settings (fps index 2..7) and double VTS (0x01CA -> 0x0394): same frame rates,
    # half the readout (~3.7 ms). Index 0/1 (238/208 fps, not advertised) are left alone and drop
    # to ~119/104 fps. Exposure in lines then lasts half as long (see the analysis doc).
    "binned-fast-readout": ("640x400: half the readout time at the same frame rate", [
        (0x1AC7, "01", "03"), (0x1ACB, "ca", "94"),   # VTS 0x01CA -> 0x0394
        (0x1E83, "05", "02"), (0x1E87, "b0", "d8"),   # idx2 (120 fps) HTS 0x05B0 -> 0x02D8
        (0x1E9F, "0b", "05"), (0x1EA3, "60", "b0"),   # idx3 HTS 0x0B60 -> 0x05B0
        (0x1EBB, "16", "0b"), (0x1EBF, "c0", "60"),   # idx4 HTS 0x16C0 -> 0x0B60
        (0x1ED7, "2d", "16"), (0x1EDB, "80", "c0"),   # idx5 HTS 0x2D80 -> 0x16C0
        (0x1EF3, "44", "22"), (0x1EF7, "40", "20"),   # idx6 HTS 0x4440 -> 0x2220
        (0x1F0F, "88", "44"), (0x1F13, "80", "40"),   # idx7 HTS 0x8880 -> 0x4440
    ]),
}


def main(argv):
    if argv[:1] == ["--list"]:
        for k, (desc, edits) in PATCHES.items():
            print("%-20s %2d edits  %s" % (k, len(edits), desc))
        return 0
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, dst, names = argv[0], argv[1], argv[2:]
    img = bytearray(open(src, "rb").read())
    h = hashlib.sha256(img).hexdigest()
    if h != PUBLISHED_513:
        print("warning: input is not the published 5.13 (%s); old bytes are still checked" % h[:16])
    for n in names:
        if n not in PATCHES:
            print("unknown patch %s (--list)" % n)
            return 2
        for off, old, new in PATCHES[n][1]:
            o, nw = bytes.fromhex(old), bytes.fromhex(new)
            cur = bytes(img[off:off + len(o)])
            if cur == nw:
                continue
            if cur != o:
                print("%s: 0x%05X has %s, expected %s" % (n, off, cur.hex(), old))
                return 1
            img[off:off + len(nw)] = nw
    open(dst, "wb").write(img)
    print("%s  %s" % (hashlib.sha256(img).hexdigest(), dst))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
