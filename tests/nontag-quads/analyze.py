#!/usr/bin/env python3
"""Non-tag quads per frame from run.sh's output, by match/session and camera.

  analyze.py OUT_DIR [--replay /data/scratch/txman1/replay]

Each detector (one per camera) is matched to its camera by comparing its per-frame tag counts with
detector-replay's detections per frame (det.csv). A busy frame: one with at least one quad.
CPU columns are the decode workers' CPU time (sum over quads, not wall): RefineEdges (with
undistortion) and decode, all quads and non-tag quads; early = decoding each quad on its unrefined
corners first (no slack), the stand-in for a cheap early decode.
"""
import argparse
import collections
import csv
import glob
import os
import statistics

ap = argparse.ArgumentParser()
ap.add_argument("out")
args = ap.parse_args()

F = ["det", "quads", "sane", "tags", "early_ok", "tag_early_ok", "refine", "decode", "refine_nt", "decode_nt",
     "early", "wall"]


def load(path):
    rows = []
    for r in csv.reader(open(path)):
        if len(r) != len(F):
            continue
        d = dict(zip(F, r))
        for k in F[1:]:
            d[k] = float(d[k])
        rows.append(d)
    return rows


def camera_map(rows, det_csv):
    per_det = collections.defaultdict(list)
    for r in rows:
        per_det[r["det"]].append(r["tags"])
    per_cam = collections.defaultdict(lambda: collections.Counter())
    frames = collections.defaultdict(set)
    if os.path.exists(det_csv):
        for r in csv.DictReader(open(det_csv)):
            per_cam[r["camera"]][int(r["frame"])] += 1
            frames[r["camera"]].add(int(r["frame"]))
    cams = sorted(per_cam)
    out = {}
    for d, seq in per_det.items():
        best, score = "?", -1
        for c in cams:
            n = max(per_cam[c].keys(), default=0) + 1
            cs = [per_cam[c].get(i, 0) for i in range(n)]
            m = min(len(cs), len(seq))
            # detections per frame <= tags decoded per frame (margin filter); count frames where both are zero
            # or both nonzero
            s = sum((cs[i] > 0) == (seq[i] > 0) for i in range(m)) / max(1, m)
            if s > score:
                best, score = c, s
        out[d] = best
    return out


tot = collections.defaultdict(lambda: collections.defaultdict(float))
print("%-36s %-10s %6s %6s %6s %6s %6s %7s %7s %7s %7s" % ("session", "camera", "frames", "busy%", "quads",
      "tags", "nontag", "cpu_us", "nt_us", "early", "keep%"))
for qs in sorted(glob.glob(os.path.join(args.out, "*", "*.qs.csv"))):
    rows = load(qs)[1:]  # first frame: warm-up
    if not rows:
        continue
    cmap = camera_map(rows, qs.replace(".qs.csv", ".det.csv"))
    match = os.path.basename(os.path.dirname(qs))
    sess = os.path.basename(qs).replace(".qs.csv", "")
    by = collections.defaultdict(list)
    for r in rows:
        by[cmap.get(r["det"], "?")].append(r)
    for cam, rs in sorted(by.items()):
        a = collections.defaultdict(float)
        for r in rs:
            for k in F[1:]:
                a[k] += r[k]
            a["busy"] += r["quads"] > 0
            a["frames"] += 1
        for key in (cam, "ALL"):
            for k, v in a.items():
                tot[key][k] += v
            tot[key]["sessions"] += 1
        busy = max(1, a["busy"])
        print("%-36s %-10s %6d %5.0f%% %6.1f %6.2f %5.0f%% %7.0f %7.0f %7.0f %6.1f%%" % (
            (match + "/" + sess)[:36], cam, a["frames"], 100 * a["busy"] / a["frames"], a["quads"] / busy,
            a["tags"] / busy, 100 * (1 - a["tags"] / max(1, a["sane"])), (a["refine"] + a["decode"]) / busy,
            (a["refine_nt"] + a["decode_nt"]) / busy, a["early"] / busy, 100 * a["tag_early_ok"] / max(1, a["tags"])))

print()
print("Totals (per busy frame; CPU = decode workers' CPU, us)")
for key in ["ALL"] + sorted(k for k in tot if k != "ALL"):
    a = tot[key]
    busy = max(1, a["busy"])
    nt = a["sane"] - a["tags"]
    saved = (a["refine_nt"] + a["decode_nt"]) - a["early"]
    print(f"  {key}: {int(a['frames'])} frames, {100 * a['busy'] / a['frames']:.0f}% busy; quads {a['quads'] / busy:.1f}"
          f" (after the sanity check {a['sane'] / busy:.1f}), tags {a['tags'] / busy:.2f}, non-tag {nt / busy:.1f}"
          f" ({100 * nt / max(1, a['sane']):.1f}% of quads)")
    print(f"    CPU: RefineEdges {a['refine'] / busy:.0f} us (non-tag {a['refine_nt'] / busy:.0f}),"
          f" decode {a['decode'] / busy:.0f} us (non-tag {a['decode_nt'] / busy:.0f}); wall {a['wall'] / busy:.0f} us")
    print(f"    early decode on unrefined corners: {a['early'] / busy:.0f} us; passes {a['early_ok'] / busy:.2f} quads"
          f" ({100 * (a['early_ok'] - a['tag_early_ok']) / max(1, nt):.2f}% of non-tags);"
          f" keeps {100 * a['tag_early_ok'] / max(1, a['tags']):.1f}% of tags (no slack)")
    print(f"    saved if non-tags stopped at the early decode: {saved / busy:.0f} us CPU per busy frame"
          f" ({100 * saved / max(1, a['refine'] + a['decode']):.0f}% of refine + decode)")
