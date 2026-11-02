#!/usr/bin/env python3
"""Compares tests/early-reject/run.sh's variants with the base (or BASE_nocal with base_nocal).

  analyze.py [OUT] [--lost N]      OUT default ~/build/early-reject/out; lists up to N lost sightings (50)

Per variant: sightings (camera x frame x tag x source) vs its base: lost, gained, matched with moved corners;
quads reaching decode, survivors of the early check, non-tags passed (survivors that didn't decode / the
base's quads that didn't); worker thread CPU per frame (early check, RefineEdges, decode) and DecodeTags wall
per frame; detect wall per frame (the log's Time line, frames weighted).
"""
import csv
import glob
import os
import re
import sys


def load(vdir):
    sights, stats, frames, detect_ms = {}, [0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0], 0, 0.0
    for log in sorted(glob.glob(os.path.join(vdir, "*", "*.log"))):
        base = log[:-4]
        sess = os.path.relpath(base, vdir)
        txt = open(log).read()
        m = re.search(r"cameras, (\d+) frames", txt)
        t = re.search(r"^Time: detect ([\d.]+) ms", txt, re.M)
        if not m or not t:
            continue
        n = int(m.group(1))
        frames += n
        detect_ms += float(t.group(1)) * n
        with open(base + ".det.csv") as f:
            for r in csv.DictReader(f):
                k = (sess, r["camera"], int(r["frame"]), int(r["id"]), r["source"])
                sights[k] = (float(r["margin"]), float(r["side_px"]), [float(r[f"{a}{i}"]) for i in range(4) for a in "xy"])
        with open(base + ".stats.csv") as f:
            for row in csv.reader(f):
                q, p, d = int(row[1]), int(row[2]), int(row[3])
                e, rf, dc, w = map(float, row[4:8])
                s = stats
                s[0] += q; s[1] += p; s[2] += d; s[3] += e; s[4] += rf; s[5] += dc; s[6] += w; s[7] += q > 0
    return sights, stats, frames, detect_ms


def main():
    args = [a for a in sys.argv[1:]]
    nlost = 50
    if "--lost" in args:
        i = args.index("--lost")
        nlost = int(args[i + 1])
        del args[i:i + 2]
    out = args[0] if args else os.path.expanduser("~/build/early-reject/out")
    variants = sorted(os.path.basename(d) for d in glob.glob(os.path.join(out, "*")) if os.path.isdir(d))
    data = {v: load(os.path.join(out, v)) for v in variants}
    print(f"{'variant':12} {'frames':>7} {'sightings':>9} {'lost':>5} {'gained':>6} {'moved':>5} {'kept%':>8} "
          f"{'quads/f':>7} {'pass%':>6} {'nontag_pass%':>12} {'early_us':>8} {'refine_us':>9} {'decode_us':>9} "
          f"{'sum_us':>7} {'saved_us':>8} {'dtwall_us':>9} {'detect_ms':>9}")
    lost_all = {}
    for v in variants:
        b = "base_nocal" if v.endswith("_nocal") else "base"
        if b not in data:
            continue
        S, st, n, dms = data[v]
        BS, bst, bn, _ = data[b]
        if not n:
            continue
        common = [k for k in S if k in BS]
        lost = [k for k in BS if k not in S] if n == bn else []
        gained = [k for k in S if k not in BS] if n == bn else []
        moved = sum(1 for k in common if max(abs(a - c) for a, c in zip(S[k][2], BS[k][2])) > 1e-3)
        lost_all[v] = lost
        nontag_base = bst[0] - bst[2]
        nontag_pass = (st[1] - st[2]) / nontag_base * 100 if nontag_base else 0
        cpu = (st[3] + st[4] + st[5]) / n
        bcpu = (bst[3] + bst[4] + bst[5]) / bn
        print(f"{v:12} {n:7d} {len(S):9d} {len(lost):5d} {len(gained):6d} {moved:5d} "
              f"{100 * (1 - len(lost) / max(1, len(BS))):8.3f} {st[0] / n:7.2f} {100 * st[1] / max(1, st[0]):6.2f} "
              f"{nontag_pass:12.2f} {st[3] / n:8.1f} {st[4] / n:9.1f} {st[5] / n:9.1f} {cpu:7.1f} {bcpu - cpu:8.1f} "
              f"{st[6] / n:9.1f} {dms / n:9.3f}" + ("" if n == bn else "   (incomplete)"))
    for v, lost in lost_all.items():
        if not lost:
            continue
        b = "base_nocal" if v.endswith("_nocal") else "base"
        BS = data[b][0]
        print(f"\n{v}: {len(lost)} lost sightings (session camera frame id source margin side_px)")
        for k in sorted(lost, key=lambda k: BS[k][1])[:nlost]:
            print(f"  {k[0]} {k[1]} {k[2]} {k[3]} {k[4]} {BS[k][0]:.1f} {BS[k][1]:.1f}")


if __name__ == "__main__":
    main()
