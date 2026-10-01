"""Field calibration from a Rewind recording of the robot pushed by hand to still spots.

    tools/fieldcal/fieldcal.sh solve SESSION_DIR --layout LAYOUT.json [--out DIR]
        [--reference-spot N=x,y,yawDeg | --anchor-camera NAME=x,y,yawDeg] [--every 2]
    tools/fieldcal/fieldcal.sh synth OUT_DIR --layout LAYOUT.json [--images] [--spots 16]
    tools/fieldcal/fieldcal.sh evaluate SOLVE_OUT_DIR TRUTH.json
    tools/fieldcal/fieldcal.sh compare SOLVE_A SOLVE_B     (repeatability of two runs)

See tools/fieldcal/README.md and docs/FIELD-CALIBRATION-PLAN.md.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

from . import geometry as g
from . import gpu971, rewind, segments, solve as solver, report, synth
from .camera import Camera
from .tags import Detector


def load_layout(path: Path) -> tuple[dict, dict[int, np.ndarray]]:
    j = json.loads(Path(path).read_text())
    return j, {t["ID"]: g.from_wpilib_pose(t["pose"]) for t in j["tags"]}


def load_cad(path: Path) -> dict[str, np.ndarray]:
    """{camera: {x, y, z, rollDeg, pitchDeg, yawDeg}}: robotToCamera from CAD or robot code."""
    out = {}
    for c, m in json.loads(Path(path).read_text()).items():
        R = g.rpy(*np.radians([m.get("rollDeg", 0.0), m.get("pitchDeg", 0.0), m.get("yawDeg", 0.0)]))
        out[c] = g.make(R, [m["x"], m["y"], m.get("z", 0.0)])
    return out


def _parse_anchor(s: str) -> tuple[str, float, float, float]:
    k, v = s.split("=")
    x, y, yaw = (float(a) for a in v.split(","))
    return k, x, y, yaw


def _detect_part(task):
    src, every, start, min_margin = task
    det = Detector(min_margin=min_margin)
    return src.name, [(t, {d.id: d.corners for d in det.detect(img)}) for t, img in rewind.frames(src, every, start)]


def detect_session(session_dir: Path, every: int, min_margin: float, cache: Path | None, only: list[str] | None,
                   workers: int | None = None, detector: str = "cpu", cams: dict[str, Camera] | None = None):
    """Tag corners in every ``every``-th frame of every camera: WPILib's detector on all CPU cores
    ("cpu"), or the 971 GPU detector on the Jetson ("971"). Cached in ``cache`` (redone if the
    settings change)."""
    key = {"every": every, "minMargin": min_margin, "detector": detector,
           # Which recording: without it, a cache left in the same output folder by another
           # session's solve was reused (audit 2026-10-01). Path plus the frame indexes' sizes.
           "session": str(Path(session_dir).resolve()),
           "frames": sum(p.stat().st_size for p in sorted(Path(session_dir).glob("*/*.csv")))}
    if detector == "cpu":
        key.pop("detector")  # caches from before the 971 option
    if cache and cache.exists():
        raw = json.loads(cache.read_text())
        if raw.get("settings") == key:
            return {c: [(t, {int(k): np.array(v) for k, v in d.items()}) for t, d in fr]
                    for c, fr in raw["cameras"].items() if not only or c in only}
    srcs = [s_ for s_ in rewind.sources(session_dir) if not only or s_.name in only]
    out: dict[str, list] = {src.name: [] for src in srcs}
    if detector == "971":
        for src in srcs:  # one camera at a time: they share the GPU
            csv_path = (cache.parent if cache else Path(session_dir)) / f"971-{src.name}.csv"
            out[src.name] = gpu971.detect(src, every, (cams or {}).get(src.name), min_margin, csv_path)
    else:
        workers = workers or os.cpu_count() or 1
        parts = max(1, -(-workers // max(1, len(srcs))))  # split each camera across the cores
        tasks = [(src, every * parts, k * every, min_margin) for src in srcs for k in range(parts)]
        with ProcessPoolExecutor(max_workers=workers) as ex:
            for name, fr in ex.map(_detect_part, tasks):
                out[name] += fr
    for src in srcs:
        out[src.name].sort(key=lambda f: f[0])
        print(f"  {src.name}: {len(out[src.name])} frames analysed, tags in "
              f"{sum(1 for _, d in out[src.name] if d)}", file=sys.stderr)
    if cache:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps({"settings": key, "cameras": {
            c: [(t, {str(k): v.tolist() for k, v in d.items()}) for t, d in fr] for c, fr in out.items()}}))
    return out


def cmd_solve(a) -> int:
    layout_json, layout = load_layout(a.layout)
    session = rewind.load_session(a.session)
    cams = rewind.cameras_from_session(session)
    srcs = rewind.sources(a.session)
    if not srcs:
        print(f"No camera recordings in {a.session} (expected Camera/0000.mjpeg + .csv, or Camera.avi + "
              "Camera.frames.csv)", file=sys.stderr)
        return 2
    sizes = {src.name: rewind.frame_size(src) for src in srcs}
    jetson_db = Path("/opt/photonvision/photonvision_config/photon.sqlite")
    if not a.photon_db and set(sizes) - set(cams) and jetson_db.exists() and os.access(jetson_db, os.R_OK):
        a.photon_db = jetson_db  # on the Jetson: PhotonVision's own calibrations
    if a.photon_db:
        for name, cals in rewind.cameras_from_photon_db(a.photon_db).items():
            if name in sizes and name not in cams:
                match = [c for c in cals if (c.width, c.height) == sizes[name]]
                if match:
                    cams[name] = match[0]
                elif cals:
                    cams[name] = cals[0]
    if a.calibration:
        for p in a.calibration:
            name, path = p.split("=")
            cams[name] = Camera.from_settings(name, json.loads(Path(path).read_text()))
    if not cams:
        print("No camera calibrations: the recording's session.json has none (recorded before photonvision-24?). "
              "Pass --photon-db photon.sqlite or --calibration NAME=calibration.json.", file=sys.stderr)
        return 2
    # The calibration has to be for the recorded resolution. Same aspect ratio: scale it (a binned mode).
    for name, cam in list(cams.items()):
        size = sizes.get(name)
        if size is None or size == (cam.width, cam.height):
            continue
        if abs(size[0] / size[1] - cam.width / cam.height) < 1e-3:
            print(f"  {name}: recorded at {size[0]}x{size[1]}, calibrated at {cam.width}x{cam.height}: scaling the "
                  "calibration (better: calibrate at the recorded resolution)", file=sys.stderr)
            cams[name] = cam.scaled_to(*size)
        else:
            print(f"  {name}: recorded at {size[0]}x{size[1]} but calibrated at {cam.width}x{cam.height}: skipped",
                  file=sys.stderr)
            del cams[name]
    warnings = [w for cam in cams.values() for w in cam.check()]
    for w in warnings:
        print("  note: " + w, file=sys.stderr)
    missing = sorted(set(sizes) - set(cams))
    if missing:
        print(f"  no calibration for {', '.join(missing)}: skipped", file=sys.stderr)
    out = Path(a.out) if a.out else Path(a.session) / "fieldcal"
    if not a.out and not os.access(a.session, os.W_OK):  # the Jetson's sessions belong to root
        out = Path.home() / "fieldcal" / Path(a.session).resolve().name
    every = a.every or max(1, round(float(session.get("fps") or 30.0) / 5.0))  # ~5 fps is plenty when still
    detector = a.detector
    if detector == "auto":
        detector = "971" if gpu971.binary() and all(s_.kind == "raw" for s_ in srcs) else "cpu"
    print(f"Detecting tags with the {'971 GPU' if detector == '971' else 'CPU'} detector "
          f"(every {every} frame(s))...", file=sys.stderr)
    dets = detect_session(Path(a.session), every, a.min_margin, out / "detections.json", a.cameras,
                          detector=detector, cams=cams)
    dets = {c: v for c, v in dets.items() if c in cams}
    segs = segments.find_still_segments(dets, max_motion_px=a.max_motion_px, min_still_s=a.min_still_s)
    obs = segments.observations(dets, segs)
    print(f"{len(segs)} still spots, {len(obs)} observations", file=sys.stderr)
    for s in segs:
        print(f"  spot {s.index}: {s.start - segs[0].start:6.1f} s to {s.end - segs[0].start:6.1f} s", file=sys.stderr)
    opt = solver.Options(tag_size=a.tag_size, pixel_sigma=a.pixel_sigma, prior_translation_m=a.prior_cm / 100,
                         prior_rotation_deg=a.prior_deg)
    if not obs:
        seen = {c: sum(1 for _, d in fr if d) for c, fr in dets.items()}
        print(f"Nothing to solve: no camera saw a tag while the robot was held still ({len(segs)} still stretches; "
              f"frames with any tag, per camera: {seen}). Record again with the robot held still for 2 s or more "
              "at each spot, where the cameras can see tags.", file=sys.stderr)
        return 1
    try:
        res = solver.solve(cams, obs, layout, opt, verbose=a.verbose)
    except RuntimeError as e:
        print(f"Can't solve: {e}", file=sys.stderr)
        return 1
    T_robot_rig, note = None, "No anchor: camera x, y and yaw are relative to the reference camera."
    cad = load_cad(a.cad) if a.cad else None
    if cad and not (a.reference_spot or a.anchor_camera):
        T_robot_rig = solver.anchor_cad(res, cad)
        note = f"x, y and yaw anchored to CAD ({', '.join(c for c in res.cameras if c in cad)} as a whole)."
    if a.reference_spot:
        k, x, y, yaw = _parse_anchor(a.reference_spot)
        T_robot_rig = solver.anchor_reference_spot(res, int(k), x, y, yaw)
        note = f"Anchored at spot {k} (robot at x {x} m, y {y} m, heading {yaw}°)."
    elif a.anchor_camera:
        k, x, y, yaw = _parse_anchor(a.anchor_camera)
        T_robot_rig = solver.anchor_camera(res, k, x, y, yaw)
        note = f"Anchored by {k}'s x, y and yaw from CAD ({x}, {y}, {yaw}°)."
    if not res.converged:
        # The numbers are wherever the solver stopped: usually close, but not checked.
        warnings.append("The solver stopped at its evaluation limit before it converged: the tag positions and "
                        "mounts may be off. Check each camera's fit (px RMS) below; record again with longer still spots.")
        print(f"WARNING: {warnings[-1]}", file=sys.stderr)
    report.write(res, layout_json, layout, out, T_robot_rig, note, notes=warnings, cams=cams, cad=cad)
    print(f"Wrote {out}/report.md, corrected-layout.json, mounts.json", file=sys.stderr)
    return 0


def cmd_synth(a) -> int:
    layout_json, layout = load_layout(a.layout)
    truth = synth.make_truth(layout, layout_json["field"]["length"], layout_json["field"]["width"], seed=a.seed,
                             spots=a.spots, half_field=not a.full_field)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    cad = {}
    for c, T in truth.mounts.items():
        r, p_, y = np.degrees(g.to_rpy(T[:3, :3]))
        cad[c] = {"x": T[0, 3], "y": T[1, 3], "z": T[2, 3], "rollDeg": r, "pitchDeg": p_, "yawDeg": y}
    # CAD mistakes the solve should catch: one camera's pitch, another's height.
    names = sorted(cad)
    cad[names[0]]["pitchDeg"] += 1.5
    cad[names[1]]["z"] += 0.01
    (out / "cad.json").write_text(json.dumps(cad, indent=2, default=float))
    if a.images:
        synth.write_session(truth, out, fps=a.fps)
        print(f"Wrote a Rewind-format recording to {out} ({len(truth.spots)} spots)", file=sys.stderr)
    else:
        (out / "truth.json").write_text(json.dumps(truth.to_json(), indent=2))
        print(f"Wrote {out}/truth.json", file=sys.stderr)
    return 0


def cmd_evaluate(a) -> int:
    res = json.loads((Path(a.results) / "results.json").read_text())
    truth = json.loads(Path(a.truth).read_text())
    solved = {t["ID"]: g.from_wpilib_pose(t["pose"]) for t in json.loads((Path(a.results) / "corrected-layout.json").read_text())["tags"]}
    pos, ang = [], []
    for t, e in res["tags"].items():
        if str(t) not in truth["tags"] or int(t) not in solved:
            continue
        T, S = g.from_wpilib_pose(truth["tags"][str(t)]), solved[int(t)]
        pos.append(np.linalg.norm(T[:3, 3] - S[:3, 3]) * 100)
        ang.append(np.degrees(g.angle_between(T[:3, :3], S[:3, :3])))
    print(f"Tags: {len(pos)} solved. Position error cm: median {np.median(pos):.2f}, max {np.max(pos):.2f}. "
          f"Angle error deg: median {np.median(ang):.2f}, max {np.max(ang):.2f}")
    bad = []
    if len(truth["spots"]) != res["spots"]:
        bad.append(f"{res['spots']} of {len(truth['spots'])} spots found")
    if np.median(pos) > 1.0:
        bad.append(f"median tag error {np.median(pos):.2f} cm")
    for c, m in res["mounts"].items():
        tm = truth["mounts"].get(c)
        f = m.get("robotToCamera")
        if tm is None:
            continue
        line = f"{c}: height {m['rigFrame']['z']:.3f} (truth {tm[2]:.3f}), pitch {m['rigFrame']['pitchDeg']:.2f} (truth {tm[4]:.2f}), roll {m['rigFrame']['rollDeg']:.2f} (truth {tm[3]:.2f})"
        if abs(m["rigFrame"]["z"] - tm[2]) > 0.01 or abs(m["rigFrame"]["pitchDeg"] - tm[4]) > 0.3 \
                or abs(m["rigFrame"]["rollDeg"] - tm[3]) > 0.3:
            bad.append(f"{c} height/pitch/roll")
        if f:
            line += f"; x {f['x']:.3f} ({tm[0]:.3f}), y {f['y']:.3f} ({tm[1]:.3f}), yaw {f['yawDeg']:.2f} ({tm[5]:.2f})"
            dyaw = (f["yawDeg"] - tm[5] + 180) % 360 - 180
            if np.hypot(f["x"] - tm[0], f["y"] - tm[1]) > 0.02 or abs(dyaw) > 0.5:
                bad.append(f"{c} x/y/yaw")
        print(line)
    for b in bad:
        print("  !", b)
    print("PASS" if not bad else "FAIL")
    return 0 if not bad else 1


def cmd_compare(a) -> int:
    """Two solves of the same field and robot (say, the procedure done twice): how much they differ
    is how repeatable the calibration is, with no tape measure needed."""
    def load(d):
        res = json.loads((Path(d) / "results.json").read_text())
        tags = {t: g.from_wpilib_pose(e["solvedPose"]) for t, e in res["tags"].items()
                if "solvedPose" in e and e["observations"] >= 2}
        return res, tags
    ra, ta = load(a.a)
    rb, tb = load(a.b)
    common = sorted(set(ta) & set(tb), key=int)
    print(f"Tags seen well in both: {len(common)}")
    dp = []
    for t in common:
        d = np.linalg.norm(ta[t][:3, 3] - tb[t][:3, 3]) * 100
        ang = np.degrees(g.angle_between(ta[t][:3, :3], tb[t][:3, :3]))
        dp.append(d)
        print(f"  tag {t:>2}: {d:5.2f} cm, {ang:4.2f} deg apart")
    if dp:
        print(f"  median {np.median(dp):.2f} cm, max {np.max(dp):.2f} cm")
    print("Mounts (b minus a):")
    for c, ma in ra["mounts"].items():
        mb = rb["mounts"].get(c)
        if not mb:
            continue
        fa, fb = ma.get("robotToCamera", ma["rigFrame"]), mb.get("robotToCamera", mb["rigFrame"])
        line = (f"  {c}: height {100 * (fb['z'] - fa['z']):+.1f} cm, pitch {fb['pitchDeg'] - fa['pitchDeg']:+.2f} deg, "
                f"roll {fb['rollDeg'] - fa['rollDeg']:+.2f} deg")
        if "robotToCamera" in ma and "robotToCamera" in mb:
            dyaw = (fb["yawDeg"] - fa["yawDeg"] + 180) % 360 - 180
            line += (f", x {100 * (fb['x'] - fa['x']):+.1f} cm, y {100 * (fb['y'] - fa['y']):+.1f} cm, "
                     f"yaw {dyaw:+.2f} deg")
        print(line)
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="fieldcal", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("solve", help="Solve tag positions and camera mounts from a Rewind recording")
    s.add_argument("session", type=Path)
    s.add_argument("--layout", type=Path, required=True)
    s.add_argument("--out", type=Path)
    s.add_argument("--every", type=int, help="analyse every Nth frame (default: about 5 per second)")
    s.add_argument("--detector", choices=["auto", "cpu", "971"], default="auto",
                   help="971: PhotonVision's GPU detector (on the Jetson, the default there); cpu: WPILib's")
    s.add_argument("--cameras", type=lambda v: v.split(","), help="only these cameras")
    s.add_argument("--photon-db", type=Path, help="PhotonVision's photon.sqlite, for the lens calibrations if session.json has none")
    s.add_argument("--calibration", action="append", help="NAME=calibration.json (PhotonVision's export), if session.json has none")
    s.add_argument("--tag-size", type=float, default=0.1651)
    s.add_argument("--min-margin", type=float, default=15.0)
    s.add_argument("--max-motion-px", type=float, default=1.5)
    s.add_argument("--min-still-s", type=float, default=1.0)
    s.add_argument("--pixel-sigma", type=float, default=0.5)
    s.add_argument("--prior-cm", type=float, default=5.0, help="how far tags may move from the layout (1 sigma)")
    s.add_argument("--prior-deg", type=float, default=2.0)
    s.add_argument("--reference-spot", help="N=x,y,yawDeg: the robot's pose on the field at spot N")
    s.add_argument("--anchor-camera", help="NAME=x,y,yawDeg: one camera's x, y and yaw on the robot (CAD)")
    s.add_argument("--cad", type=Path, help="cad.json, every camera's robotToCamera from CAD: anchors x, y and yaw "
                   "(unless a reference spot is given) and compares each mount with CAD")
    s.add_argument("--verbose", action="store_true")
    s.set_defaults(func=cmd_solve)
    y = sub.add_parser("synth", help="Make synthetic test data with a known answer")
    y.add_argument("out", type=Path)
    y.add_argument("--layout", type=Path, required=True)
    y.add_argument("--images", action="store_true", help="render a whole Rewind-format recording")
    y.add_argument("--spots", type=int, default=16)
    y.add_argument("--fps", type=float, default=15.0)
    y.add_argument("--seed", type=int, default=1)
    y.add_argument("--full-field", action="store_true")
    y.set_defaults(func=cmd_synth)
    c = sub.add_parser("compare", help="Compare two solves (repeatability)")
    c.add_argument("a", type=Path)
    c.add_argument("b", type=Path)
    c.set_defaults(func=cmd_compare)
    e = sub.add_parser("evaluate", help="Compare a solve's results with synthetic truth")
    e.add_argument("results", type=Path)
    e.add_argument("truth", type=Path)
    e.set_defaults(func=cmd_evaluate)
    a = p.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
