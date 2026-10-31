"""Tag corners from the 971 CUDA detector, on the Jetson: the same detector and settings
PhotonVision uses in matches, at a few hundred frames per second.

detector/fieldcal_detect.cc replays one camera's Rewind frames through it and writes a CSV. Build
it on the Jetson with scripts/jetson/13-build-fieldcal-detect.sh.
"""

from __future__ import annotations

import csv
import os
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

from .camera import Camera
from .rewind import Source

DEFAULT_BINARY = Path.home() / "build" / "fieldcal-detect" / "fieldcal_detect"
# PhotonVision's detector settings, from 08-select-detector.sh.
DROPIN = Path("/etc/systemd/system/photonvision.service.d/detector.conf")
OLD_DROPIN = Path("/etc/systemd/system/photonvision.service.d/971.conf")  # before 2026-10-31
# The 971 detector's corners come from AprilTag's code: pixel centres at +0.5 (see tags.py).
PIXEL_OFFSET = 0.5


def binary() -> Path | None:
    p = Path(os.environ.get("FIELDCAL_971_DETECT", DEFAULT_BINARY))
    return p if p.is_file() and os.access(p, os.X_OK) else None


def photonvision_env() -> dict[str, str]:
    """The SPECTRUM_DETECTOR_* settings PhotonVision runs with, so the replay matches it."""
    out = {}
    try:
        text = (DROPIN if DROPIN.exists() else OLD_DROPIN).read_text()
        # SPECTRUM_971_* is the old name of SPECTRUM_DETECTOR_*.
        for m in re.finditer(r"Environment=SPECTRUM_(?:DETECTOR|971)_(\w+)=(\S+)", text):
            out["SPECTRUM_DETECTOR_" + m.group(1)] = m.group(2)
    except OSError:
        pass
    return out


def detect(src: Source, every: int, cam: Camera | None, min_margin: float, out_csv: Path) -> list:
    """[(t, {tag id: 4x2 corners TL TR BR BL, OpenCV pixel convention})] for every analysed frame."""
    exe = binary()
    if exe is None:
        raise RuntimeError(f"fieldcal_detect isn't built ({DEFAULT_BINARY}); see scripts/jetson/13-build-fieldcal-detect.sh")
    if src.kind != "raw":
        raise RuntimeError(f"{src.name}: the 971 replay reads Rewind session folders, not .avi exports")
    args = [str(exe), str(src.path), str(out_csv), "--every", str(every)]
    if cam is not None:
        k = [cam.fx, cam.fy, cam.cx, cam.cy, *cam.dist8()]
        args += ["--calib", ",".join(f"{v:.12g}" for v in k)]
    env = {**photonvision_env(), **os.environ}  # an explicit environment setting wins
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(args, env=env, stderr=subprocess.PIPE, text=True)
    if r.stderr:
        print("  " + r.stderr.strip(), file=sys.stderr)
    if r.returncode != 0:
        raise RuntimeError(f"fieldcal_detect failed on {src.name} ({r.returncode})")
    frames: dict[int, tuple[float, dict[int, np.ndarray]]] = {}
    with out_csv.open() as f:
        for row in csv.DictReader(f):
            i = int(row["frame"])
            t, tags = frames.setdefault(i, (int(row["jetson_us"]) / 1e6, {}))
            tid = int(row["id"])
            if tid < 0 or float(row["margin"]) < min_margin or int(row["hamming"]) > 0:
                continue
            c = np.array([[float(row[f"x{j}"]), float(row[f"y{j}"])] for j in range(4)]) - PIXEL_OFFSET
            tags[tid] = c[[3, 2, 1, 0]]  # AprilTag's order (BL BR TR TL as seen) -> TL TR BR BL
    return [frames[i] for i in sorted(frames)]
