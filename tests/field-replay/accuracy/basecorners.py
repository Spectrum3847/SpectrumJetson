"""A variant's sightings with the base's corners wherever the base found the same tag in the frame.

  basecorners.py REPLAY_DIR VARIANT [--base a_base] [--out NAME]   (default NAME: VARIANT_bc)

Writes <match>/out/NAME/<session>.{csv,log}: VARIANT's rows, with x0..y3 and side_px taken from the
base's row for the same (camera, frame, id, source) where it has one; the logs are VARIANT's (its
timings). Judged against the base, the common sightings are then identical by construction and only
what VARIANT finds or loses counts: it separates "finds more tags" from "moves the corners" (e.g.
detector-replay --scale, whose corners are refined on an interpolated frame).
"""
import argparse
import csv
import glob
import os
import shutil

ap = argparse.ArgumentParser()
ap.add_argument("root")
ap.add_argument("variant")
ap.add_argument("--base", default="a_base")
ap.add_argument("--out", default="")
args = ap.parse_args()
out_name = args.out or args.variant + "_bc"
total = swapped = 0
for vdir in sorted(glob.glob(os.path.join(args.root, "TXMAN1_*", "out", args.variant))):
    odir = os.path.join(os.path.dirname(vdir), out_name)
    os.makedirs(odir, exist_ok=True)
    for f in sorted(glob.glob(os.path.join(vdir, "*.csv"))):
        name = os.path.basename(f)
        base = {}
        bf = os.path.join(os.path.dirname(vdir), args.base, name)
        with open(bf) as fh:
            for r in csv.DictReader(fh):
                base.setdefault((r["camera"], r["frame"], r["id"], r["source"]), r)
        with open(f) as fh, open(os.path.join(odir, name), "w", newline="") as oh:
            rd = csv.DictReader(fh)
            w = csv.DictWriter(oh, rd.fieldnames)
            w.writeheader()
            for r in rd:
                total += 1
                b = base.get((r["camera"], r["frame"], r["id"], r["source"]))
                if b:
                    swapped += 1
                    for k in ("side_px",) + tuple(f"{a}{i}" for i in range(4) for a in "xy"):
                        r[k] = b[k]
                w.writerow(r)
        shutil.copy(f[:-4] + ".log", os.path.join(odir, name[:-4] + ".log"))
print(f"{out_name}: {total} rows, {swapped} with the base's corners")
