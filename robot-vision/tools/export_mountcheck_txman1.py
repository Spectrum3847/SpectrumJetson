"""TXMAN1 sightings for robot-vision's MountCheckTxman1Test: every base-variant detection with
the robot's logged pose (odometry placed by the fused pose), speed and turn rate, plus each match's
calibrations, field layout and the mounts 8515's robot code had. CPU only; reads the replay.

On the Jetson (nice 19), then copy the folder back:
  FIELD_REPLAY=<repo>/tests/field-replay nice -n 19 python3 export_mountcheck_txman1.py \
      /data/scratch/txman1/replay OUT_DIR
  MOUNTCHECK_TXMAN1=OUT_DIR ./build.sh wpilib2026     (robot-vision; the test is skipped without it)
"""
import csv, glob, os, sys
import numpy as np
sys.path.insert(0, os.environ.get("FIELD_REPLAY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../tests/field-replay")))
import common, fieldgt as g
root, out = sys.argv[1], sys.argv[2]
# Field layouts that fit best, and Friday's placeholder vs Saturday's CAD mounts (RESULTS.md).
LAYOUT = {"TXMAN1_Q32": "welded", "TXMAN1_Test_r19": "welded"}
meta = {}
with open(os.path.join(out, "sightings.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["match", "camera", "t_us", "id"] + [f"c{i}" for i in range(8)] + ["x", "y", "th", "speed", "w", "enabled"])
    for mdir in sorted(glob.glob(os.path.join(root, "TXMAN1_*"))):
        m = os.path.basename(mdir)
        frames = common.load_frames(mdir)
        cal, _ = common.calibrations(mdir)
        robot = g.Robot(os.path.join(mdir, "robot.npz"), mode="odom")
        ds = [common.load_dets(p, os.path.basename(p)[:-4], frames) for p in sorted(glob.glob(os.path.join(mdir, "out", "base", "*.csv")))]
        d = common.concat(ds)
        if d is None:
            continue
        x, y, th, ok = robot.at(d["robot_us"])
        sp, om = robot.motion(d["robot_us"])
        en = robot.is_enabled(d["robot_us"])
        c = d["corners"].reshape(-1, 8) - 0.5
        for i in np.flatnonzero(ok):
            w.writerow([m, d["camera"][i], int(d["robot_us"][i]), int(d["id"][i])] + [f"{v:.3f}" for v in c[i]] +
                       [f"{x[i]:.4f}", f"{y[i]:.4f}", f"{th[i]:.5f}", f"{sp[i]:.3f}", f"{om[i]:.3f}", int(en[i])])
        meta[m] = {"layout": LAYOUT.get(m, "andymark"),
                   "code_mounts": "cad" if m in LAYOUT else "placeholder",
                   "cal": {k: {"K": list(v[0]), "dist": list(v[1]), "res": list(v[2])} for k, v in cal.items()}}
# meta.csv (plain, so the Java test needs no JSON library):
#   match,<match>,<layout>,<code mounts>   cal,<match>,<camera>,fx,fy,cx,cy,d0..   mount,<name>,<camera>,x,y,z,roll,pitch,yaw
with open(os.path.join(out, "meta.csv"), "w") as f:
    for m, v in meta.items():
        f.write(f"match,{m},{v['layout']},{v['code_mounts']}\n")
        for c, cal in v["cal"].items():
            f.write(",".join(["cal", m, c] + [repr(float(x)) for x in cal["K"] + cal["dist"]]) + "\n")
    for name, cams in g.MOUNTS.items():
        for c, a in cams.items():
            f.write(",".join(["mount", name, c] + [repr(float(x)) for x in a]) + "\n")
print("done")
