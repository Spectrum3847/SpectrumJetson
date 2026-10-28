"""Reading a Rewind recording (docs/REWIND.md), in either form it reaches a laptop:

* the session folder itself (rewind-pull.sh, or scp): <session>_session.json plus, per camera,
  <session>_<camera>_NNNN.mjpeg (JPEG frames back to back) and the same name .csv (frame, offset,
  size, width, height, jetson_us, robot_us). Recordings before photonvision-75 have session.json,
  NNNN.mjpeg and NNNN.csv;
* the browser download (Settings → Rewind), unzipped: session.json, <Camera>.avi (MJPEG, with
  <Camera>.part2.avi etc. past 1.9 GB) and <Camera>.frames.csv (frame, video_s, jetson_us, robot_us,
  robot_s). rewind-export.py's export/ folder is the same.
"""

from __future__ import annotations

import csv
import json
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import cv2
import numpy as np

from .camera import Camera


@dataclass
class Source:
    """One camera's frames in a recording."""

    name: str
    kind: str  # "raw" (NNNN.mjpeg + NNNN.csv) or "avi"
    path: Path  # the camera's folder (raw) or its first .avi


def load_session(session_dir: Path) -> dict:
    d = Path(session_dir)
    p = d / f"{d.resolve().name}_session.json"
    if not p.exists():
        p = d / "session.json"
    return json.loads(p.read_text()) if p.exists() else {}


def cameras_from_photon_db(db_path: Path) -> dict[str, list[Camera]]:
    """Every camera's lens calibrations (one per resolution), by nickname, from PhotonVision's
    photon.sqlite (in /opt/photonvision/photonvision_config/ on the Jetson, and in SSD backups)."""
    import sqlite3

    out: dict[str, list[Camera]] = {}
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        for (cfg_json,) in con.execute("select config_json from cameras"):
            cfg = json.loads(cfg_json)
            name = cfg.get("nickname") or cfg.get("uniqueName")
            out[name] = [Camera.from_settings(name, c) for c in cfg.get("calibrations") or []]
    finally:
        con.close()
    return out


def cameras_from_session(session: dict) -> dict[str, Camera]:
    """Each camera's lens calibration, from the settings snapshot photonvision-24 writes."""
    cams = {}
    for name, snap in (session.get("settings", {}).get("cameras", {}) or {}).items():
        cal = snap.get("calibration")
        if cal:
            cams[name] = Camera.from_settings(name, cal)
    return cams


def sources(session_dir: Path) -> list[Source]:
    """Every camera in the recording, whichever form it's in."""
    d = Path(session_dir)
    raw = sorted(x for x in d.iterdir() if x.is_dir() and any(x.glob("[0-9]*.csv")))
    if raw:
        return [Source(x.name, "raw", x) for x in raw]
    for folder in (d, d / "export"):
        avis = sorted(p for p in folder.glob("*.avi") if ".part" not in p.name) if folder.is_dir() else []
        if avis:
            return [Source(p.stem, "avi", p) for p in avis if (p.parent / f"{p.stem}.frames.csv").exists()]
    return []


def _rows(idx: Path) -> Iterator[dict]:
    with idx.open() as f:
        r = csv.reader(f)
        head = [h.strip().lstrip("#").strip() for h in next(r)]  # the Jetson writes "# frame,offset,..."
        for row in r:
            if row:
                yield dict(zip(head, row))


def _avi_jpegs(first: Path) -> Iterator[bytes]:
    """The JPEG frames of an MJPEG .avi (and its .partN.avi continuations), in order, as stored."""
    parts = [first] + sorted(first.parent.glob(f"{first.stem}.part*.avi"),
                             key=lambda p: int(p.stem.rsplit("part", 1)[1]))
    for p in parts:
        data = p.read_bytes()
        i = data.find(b"movi")
        if i < 0:
            continue
        i += 4
        while i + 8 <= len(data):
            tag, size = data[i : i + 4], struct.unpack("<I", data[i + 4 : i + 8])[0]
            if tag == b"idx1":
                break
            if tag[2:] == b"dc":
                yield data[i + 8 : i + 8 + size]
            i += 8 + size + (size & 1)


def frame_size(src: Source) -> tuple[int, int] | None:
    """(width, height) of the camera's first recorded frame."""
    if src.kind == "raw":
        for idx in sorted(src.path.glob("[0-9]*.csv")):
            for row in _rows(idx):
                return int(row["width"]), int(row["height"])
        return None
    for jpg in _avi_jpegs(src.path):
        img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
        if img is not None:
            return img.shape[1], img.shape[0]
    return None


def frames(src: Source, every: int = 1, start: int = 0) -> Iterator[tuple[float, np.ndarray]]:
    """(time in seconds on the Jetson's clock, gray image) for frames start, start + every, ..."""
    if src.kind == "raw":
        stream = _raw_jpegs(src.path)
    else:
        times = [int(r["jetson_us"]) for r in _rows(src.path.parent / f"{src.path.stem}.frames.csv")]
        stream = zip(times, _avi_jpegs(src.path))
    for n, (us, jpg) in enumerate(stream):
        if n < start or (n - start) % every:
            continue
        img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
        if img is not None:
            yield us / 1e6, img


def _raw_jpegs(cam_dir: Path) -> Iterator[tuple[int, bytes]]:
    for idx in sorted(Path(cam_dir).glob("[0-9]*.csv")):
        mj = idx.with_suffix(".mjpeg")
        if not mj.exists():
            continue
        data = mj.read_bytes()
        for row in _rows(idx):
            off, size = int(row["offset"]), int(row["size"])
            if off + size > len(data):  # the Jetson stopped mid-write
                break
            yield int(row["jetson_us"]), data[off : off + size]
