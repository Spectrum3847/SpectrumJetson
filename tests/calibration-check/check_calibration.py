#!/usr/bin/env python3
"""Summarize a PhotonVision camera calibration: reprojection error, outliers, and how well
the snapshots covered the image (edges and corners matter most for lens distortion).

PhotonVision's UI doesn't always show the reprojection error; this reads the saved
calibration straight from the PhotonVision REST API.

  python3 check_calibration.py --host 192.168.55.1 --width 1280 --height 800
  python3 check_calibration.py --file calibration.json
"""
import argparse
import collections
import json
import math
import os
import statistics
import subprocess
import urllib.error
import urllib.request


def camera_names(host):
    """Unique names of configured cameras, via the Jetson's config DB over SSH."""
    key = os.environ.get("KEY", os.path.expanduser("~/.ssh/jetson_ed25519"))
    user = os.environ.get("JETSON_USER", "spectrum3847")
    cmd = ["ssh", "-i", key, "-o", "BatchMode=yes", f"{user}@{host}",
           "sqlite3 /opt/photonvision/photonvision_config/photon.sqlite "
           "'select unique_name from cameras;'"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def fetch(host, name, w, h):
    url = (f"http://{host}:5800/api/settings/camera/getCalibration"
           f"?cameraUniqueName={name}&width={w}&height={h}")
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    return json.loads(body) if body.strip() else None


def summarize(label, d, w, h):
    obs = d["observations"]
    # cornersUsed = which of the board's corners were detected (length = all corners);
    # reprojectionErrors = one entry per corner mrcal KEPT (inliers), so
    # outliers = detected - kept.
    errs, per, pts, detected, kept, dropped_snaps = [], [], [], 0, 0, 0
    for o in obs:
        e = [math.hypot(p["x"], p["y"]) for p in (o.get("reprojectionErrors") or []) if p]
        n_det = len(o.get("locationInImageSpace") or [])
        detected += n_det
        kept += len(e)
        if n_det and not e:
            dropped_snaps += 1
        errs += e
        per.append((statistics.mean(e) if e else float("inf"), len(e), n_det))
        pts += [(p["x"], p["y"]) for p in o.get("locationInImageSpace") or []]
    k = d["cameraIntrinsics"]["data"]
    fx, cx, fy, cy = k[0], k[2], k[4], k[5]
    s = sorted(errs)
    print(f"== {label}  ({w}x{h}, {d.get('lensmodel', '?')})")
    print(f"snapshots {len(obs)} ({dropped_snaps} fully rejected), corners detected {detected}, "
          f"kept {kept} ({100 * kept / max(detected, 1):.0f}%), outliers {detected - kept}")
    print(f"reprojection error: mean {statistics.mean(errs):.3f} px, median {statistics.median(errs):.3f}, "
          f"95th {s[int(0.95 * len(s))]:.3f}, max {s[-1]:.2f}")
    print(f"fx {fx:.1f}  fy {fy:.1f}  cx {cx:.1f} (center {w / 2:.0f})  cy {cy:.1f} (center {h / 2:.0f})")
    print(f"board warp {d.get('calobjectWarp')}, spacing {d.get('calobjectSpacing')} m, "
          f"inner corners {d.get('calobjectSize')}")

    grid = collections.Counter((min(3, int(x / w * 4)), min(2, int(y / h * 3)))
                               for x, y in pts if 0 <= x < w and 0 <= y < h)
    print("coverage, corners per region (4 columns x 3 rows):")
    for r, name in enumerate(("top", "middle", "bottom")):
        print(f"  {name:7s}" + "".join(f"{grid[(c, r)]:6d}" for c in range(4)))
    xs = sorted(x for x, _ in pts)
    ys = sorted(y for _, y in pts)
    print(f"reached x {xs[0]:.0f}..{xs[-1]:.0f} of 0..{w}, y {ys[0]:.0f}..{ys[-1]:.0f} of 0..{h}")
    worst = sorted(range(len(per)), key=lambda i: -per[i][0])[:5]
    print("worst snapshots (index: mean px / corners kept of detected):",
          ", ".join(f"{i}: {per[i][0]:.2f}/{per[i][1]} of {per[i][2]}" for i in worst))

    mean = statistics.mean(errs)
    corners = [grid[(0, 0)], grid[(3, 0)], grid[(0, 2)], grid[(3, 2)]]
    verdict = []
    # Handheld calibrations of these MJPEG USB cameras land around 0.8-0.9 px with clean
    # data (few outliers); under ~1 px is fine for FRC. Outliers are the better quality flag.
    outlier_pct = 100 * (detected - kept) / max(detected, 1)
    verdict.append("error good" if mean < 0.5 else ("error OK" if mean < 1.0 else "error HIGH"))
    verdict.append(f"outliers {outlier_pct:.0f}%" + (" (clean)" if outlier_pct < 10 else " (check blur/partial boards)"))
    verdict.append("corners covered" if min(corners) >= 100 else f"corners thin ({min(corners)} min)")
    print("verdict:", "; ".join(verdict))
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.55.1")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=800)
    ap.add_argument("--file")
    args = ap.parse_args()
    if args.file:
        summarize(args.file, json.load(open(args.file)), args.width, args.height)
        return
    for name in camera_names(args.host):
        d = fetch(args.host, name, args.width, args.height)
        if d is None:
            print(f"== {name}: no {args.width}x{args.height} calibration yet\n")
        else:
            summarize(name, d, args.width, args.height)


if __name__ == "__main__":
    main()
