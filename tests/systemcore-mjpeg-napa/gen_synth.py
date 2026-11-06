#!/usr/bin/env python3
"""Rendered Rewind sessions with real AprilTags for the SystemCore MJPEG + NAPA bench.

The TXMAN1 recordings lived on the bench Jetson's SSD and are gone, so the offline bench uses
fieldcal's renderer (official tag images, the OV9281 lens model, blur, noise) and encodes the frames
the way a Thriftiest Cam does: 3-component YCbCr (Cb = Cr = 128, mono sensor), 4:2:2, a restart
marker every MCU row (8 pixel rows), at a quality that gives about the camera's frame size.

  python gen_synth.py OUT_DIR [--cams 2] [--frames 600] [--fps 60] [--quality 85] [--seed 1]
     [--sampling 422|420|444] [--rst-rows 8]

The robot drives a path between random spots (moving every frame, so tag sizes and positions change),
so each camera sees near and far tags. Writes OUT_DIR/<cam>/0000.mjpeg + 0000.csv (Rewind format).
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools" / "fieldcal"))
from fieldcal import geometry as g  # noqa: E402
from fieldcal import synth  # noqa: E402
from fieldcal.__main__ import load_layout  # noqa: E402

SAMPLING = {"422": cv2.IMWRITE_JPEG_SAMPLING_FACTOR_422, "420": cv2.IMWRITE_JPEG_SAMPLING_FACTOR_420,
            "444": cv2.IMWRITE_JPEG_SAMPLING_FACTOR_444}
MCU_W = {"422": 16, "420": 16, "444": 8}
MCU_H = {"422": 8, "420": 16, "444": 8}


def _tag_cells_opencv(tag_id: int) -> np.ndarray:
    """fieldcal's official_tag_cells needs robotpy_apriltag's Linux libapriltag; OpenCV's 36h11 is the
    same code rotated 180 degrees (tools/fieldcal/README.md), so this works on Windows too."""
    d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11)
    return np.rot90(cv2.aruco.generateImageMarker(d, tag_id, 8, borderBits=1), 2).copy()


try:
    import importlib

    importlib.import_module("robotpy_apriltag")
except ImportError:
    synth.official_tag_cells = _tag_cells_opencv


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--cams", type=int, default=2)
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--fps", type=float, default=60.0)
    ap.add_argument("--quality", type=int, default=85)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--sampling", choices=SAMPLING, default="422")
    ap.add_argument("--rst-rows", type=int, default=8, help="pixel rows per restart interval (a multiple of the MCU height)")
    ap.add_argument("--layout", type=Path,
                    default=HERE.parents[1] / "tools/fieldcal/layouts/2026-rebuilt-andymark.json")
    a = ap.parse_args()

    layout_json, layout = load_layout(a.layout)
    truth = synth.make_truth(layout, layout_json["field"]["length"], layout_json["field"]["width"], seed=a.seed,
                             spots=12, moved_fraction=0.0)
    cams = list(truth.cameras)[: a.cams]
    rng = np.random.default_rng(a.seed + 7)
    # Path: slide between the spots, a.frames frames in all, so tags change size and position every frame.
    spots = truth.spots
    poses = []
    per = max(1, -(-a.frames // (len(spots) - 1)))
    for i in range(len(spots) - 1):
        A, B = spots[i], spots[i + 1]
        ya, yb = g.to_rpy(A[:3, :3])[2], g.to_rpy(B[:3, :3])[2]
        dy = (yb - ya + np.pi) % (2 * np.pi) - np.pi
        for j in range(per):
            f = j / per
            poses.append(g.planar(A[0, 3] + f * (B[0, 3] - A[0, 3]), A[1, 3] + f * (B[1, 3] - A[1, 3]), ya + f * dy))
    poses = poses[: a.frames]
    mcu_w, mcu_h = MCU_W[a.sampling], MCU_H[a.sampling]
    params = [cv2.IMWRITE_JPEG_QUALITY, a.quality, cv2.IMWRITE_JPEG_SAMPLING_FACTOR, SAMPLING[a.sampling],
              cv2.IMWRITE_JPEG_RST_INTERVAL, (1280 // mcu_w) * (a.rst_rows // mcu_h)]  # 0: no restart markers
    a.out.mkdir(parents=True, exist_ok=True)
    for c in cams:
        cam = truth.cameras[c]
        r = synth._Renderer(cam, 0.1651)
        d = a.out / c
        d.mkdir(exist_ok=True)
        sizes = []
        with (d / "0000.mjpeg").open("wb") as fj, (d / "0000.csv").open("w", newline="") as fc:
            w = csv.writer(fc)
            fc.write("# frame,offset,size,width,height,jetson_us,robot_us\n")
            off = 0
            for i, T in enumerate(poses):
                img = r.render(T @ truth.mounts[c], truth.layout, rng)
                ok, jpg = cv2.imencode(".jpg", cv2.cvtColor(img, cv2.COLOR_GRAY2BGR), params)
                assert ok
                b = jpg.tobytes()
                fj.write(b)
                us = int(1_000_000 + i * 1e6 / a.fps)
                w.writerow([i, off, len(b), cam.width, cam.height, us, us])
                off += len(b)
                sizes.append(len(b))
        print(f"{c}: {len(poses)} frames, JPEG {np.median(sizes) / 1024:.0f} KiB median", flush=True)
    (a.out / "session.json").write_text(json.dumps({"name": a.out.name, "synthetic": True, "fps": a.fps,
                                                    "quality": a.quality, "sampling": a.sampling,
                                                    "rst_rows": a.rst_rows}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
