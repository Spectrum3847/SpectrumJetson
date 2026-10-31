"""Loading replay outputs and joining them with frame times and calibrations."""
import json
import os

import numpy as np


def load_frames(match_dir):
    """{(session, camera, frame): (jetson_us, robot_us)} as arrays keyed by session+camera."""
    out = {}
    import csv
    with open(os.path.join(match_dir, "frames.csv")) as f:
        r = csv.reader(f)
        next(r)
        for s, c, fr, j, rb in r:
            out.setdefault((s, c), []).append((int(fr), int(j), int(rb)))
    return {k: np.array(v, dtype=np.int64) for k, v in out.items()}


def load_dets(path, session, frames):
    """detector-replay's CSV, with robot_us joined from the frame table. Returns a dict of arrays."""
    import csv
    rows = []
    with open(path) as f:
        r = csv.reader(f)
        next(r)
        for v in r:
            if len(v) >= 15:  # a replay cut short can leave a partial last row
                rows.append(v)
    if not rows:
        return None
    cam = np.array([v[0] for v in rows])
    d = {
        "session": np.array([session] * len(rows)),
        "camera": cam,
        "frame": np.array([int(v[1]) for v in rows]),
        "jetson_us": np.array([int(v[2]) for v in rows], dtype=np.int64),
        "id": np.array([int(v[3]) for v in rows]),
        "margin": np.array([float(v[4]) for v in rows]),
        "side": np.array([float(v[5]) for v in rows]),
        "far": np.array([v[6] == "far" for v in rows]),
        "corners": np.array([[float(x) for x in v[7:15]] for v in rows]).reshape(-1, 4, 2),
    }
    rb = np.zeros(len(rows), dtype=np.int64)
    for c in np.unique(cam):
        ft = frames[(session, c)]
        m = cam == c
        idx = np.searchsorted(ft[:, 0], d["frame"][m])
        idx = np.clip(idx, 0, len(ft) - 1)
        assert np.all(ft[idx, 1] == d["jetson_us"][m]), "frame index mismatch"
        rb[m] = ft[idx, 2]
    d["robot_us"] = rb
    return d


def concat(ds):
    ds = [d for d in ds if d is not None]
    return {k: np.concatenate([d[k] for d in ds]) for k in ds[0]} if ds else None


def calibrations(match_dir):
    cams = json.load(open(os.path.join(match_dir, "cameras.json")))
    out = {}
    for c, v in cams.items():
        cal = v["calibration"]
        out[c] = ((cal["fx"], cal["fy"], cal["cx"], cal["cy"]), cal["distCoeffs"],
                  tuple(int(x) for x in cal["resolution"].split("x")))
    return out, cams


def edge_dist(corners, w, h):
    x, y = corners[..., 0], corners[..., 1]
    return np.min(np.minimum(np.minimum(x, w - x), np.minimum(y, h - y)), -1)
