"""Prepares one TXMAN1 match folder for replay and ground truth.

  prep.py MATCH_DIR OUT_DIR

MATCH_DIR: robotlog's download (NNNN_<label>_<date>_{session.json,<cam>_NNNN.{mjpeg,csv}} and the
robot's .wpilog). Writes into OUT_DIR:
  sessions/<NNNN_...>/<cam>/  symlinks, the folder-per-camera layout far_replay reads
  sessions/<NNNN_...>/calib.args  "--calib cam=fx,fy,cx,cy,k1..k8 ..." from session.json
  frames.csv   session,camera,frame,jetson_us,robot_us (frame = far_replay's frame index)
  cameras.json per camera: calibration, resolution, exposure setting
  robot.npz    from the wpilog: fused pose (t_us,x,y,theta), gyro yaw rate, odometry pose,
               the Jetson's own logged outputs if any
"""
import glob
import json
import os
import re
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wpilog  # noqa: E402

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
cams = {}
rows = []
for sj in sorted(glob.glob(os.path.join(src, "*_session.json"))):
    name = os.path.basename(sj)[: -len("_session.json")]
    js = json.load(open(sj))
    sdir = os.path.join(out, "sessions", name)
    args = []
    for cam, cs in js["settings"]["cameras"].items():
        files = sorted(glob.glob(os.path.join(src, f"{name}_{cam}_*.csv")))
        files = [f for f in files if os.path.exists(f[:-4] + ".mjpeg")]
        if not files:
            continue
        cdir = os.path.join(sdir, cam)
        os.makedirs(cdir, exist_ok=True)
        n = 0
        for f in files:
            for ext in (".csv", ".mjpeg"):
                link = os.path.join(cdir, os.path.basename(f)[:-4] + ext)
                if not os.path.lexists(link):
                    os.symlink(os.path.abspath(f[:-4] + ext), link)
            # As rewind_reader.h's ReadIndex: a frame past the end of its .mjpeg ends the segment.
            length = os.path.getsize(f[:-4] + ".mjpeg")
            for line in open(f):
                if not line[:1].isdigit():
                    continue
                v = line.strip().split(",")
                if int(v[1]) + int(v[2]) > length:
                    break
                # robot_us is empty while the robot isn't connected: filled in below.
                rows.append((name, cam, n, int(v[5]), int(v[6]) if v[6].strip() else None))
                n += 1
        # Frames without the robot's time: the offset (robot - jetson) interpolated from the
        # frames that have it, else the session's.
        mine = [i for i in range(len(rows)) if rows[i][0] == name and rows[i][1] == cam]
        have = [i for i in mine if rows[i][4] is not None]
        if len(have) < len(mine):
            jt = np.array([rows[i][3] for i in have], dtype=float)
            off = np.array([rows[i][4] - rows[i][3] for i in have], dtype=float)
            for i in mine:
                if rows[i][4] is None:
                    o = np.interp(rows[i][3], jt, off) if len(have) else js.get("robotOffsetUs", 0)
                    rows[i] = rows[i][:4] + (int(rows[i][3] + o),)
            print(f"{name} {cam}: {len(mine) - len(have)} of {len(mine)} frames without robot time (offset interpolated)")
        cal = cs.get("calibration")
        if cal:
            k = [cal["fx"], cal["fy"], cal["cx"], cal["cy"]] + list(cal["distCoeffs"])
            args.append("--calib " + cam + "=" + ",".join(repr(x) for x in k))
        ctl = cs.get("controls", {})
        pipe = cs.get("pipeline", {})
        cams.setdefault(cam, {"sessions": []})
        cams[cam]["sessions"].append(name)
        cams[cam].update({
            "calibration": cal,
            "videoMode": cs.get("videoMode"),
            "exposure_time_absolute": ctl.get("exposure_time_absolute"),
            "cameraExposureRaw": pipe.get("cameraExposureRaw"),
            "robotOffsetUs": js.get("robotOffsetUs"),
        })
        for key in ("decimate", "threads", "refineEdges", "numIterations", "decisionMargin", "hammingDist"):
            if key in pipe:
                cams[cam]["pipeline_" + key] = pipe[key]
    if args:
        open(os.path.join(sdir, "calib.args"), "w").write(" ".join(args) + "\n")

with open(os.path.join(out, "frames.csv"), "w") as f:
    f.write("session,camera,frame,jetson_us,robot_us\n")
    for r in rows:
        f.write(",".join(map(str, r)) + "\n")
json.dump(cams, open(os.path.join(out, "cameras.json"), "w"), indent=1)

logs = glob.glob(os.path.join(src, "*.wpilog"))
if logs:
    want = {
        "/RealOutputs/Localization/FusedPose": "fused",
        "/RealOutputs/Localization/OdometryPose": "odom",
        "/Swerve/GyroYawRateRadPerSec": "yawrate",
        "/DriverStation/Enabled": "enabled",
    }
    keep = lambda n: n in want or n.startswith("/RealMetadata/") or re.match(
        r"/RealOutputs/Localization/Sources/orin-(left|right)/(AcceptedCount|RejectedCount)$", n) or (
        "FieldMap" in n or "fieldMap" in n or "TagField" in n)
    entries, data = wpilog.read(logs[0], want=keep)
    arrs = {}
    for name, key in want.items():
        recs = data.get(name, [])
        if not recs:
            continue
        typ = next(e[1] for e in entries.values() if e[0] == name)
        t = np.array([r[0] for r in recs], dtype=np.int64)
        if typ.startswith("struct:Pose2d"):
            v = np.array([struct.unpack("<3d", r[1][:24]) for r in recs])
        elif typ == "double":
            v = np.array([struct.unpack("<d", r[1])[0] for r in recs])
        elif typ == "boolean":
            v = np.array([r[1][0] for r in recs], dtype=float)
        else:
            continue
        arrs[key + "_t"] = t
        arrs[key] = v
    meta = {n: data[n][-1][1].decode("utf-8", "replace") for n in data
            if data[n] and (n.startswith("/RealMetadata/") or "ield" in n)
            and next(e[1] for e in entries.values() if e[0] == n) == "string"}
    arrs["meta"] = np.array(json.dumps(meta))
    np.savez(os.path.join(out, "robot.npz"), **arrs)
    print(f"{os.path.basename(logs[0])}: fused {len(arrs.get('fused_t', []))} records; meta {meta}")
print(f"{len(rows)} frames, cameras {sorted(cams)}")
