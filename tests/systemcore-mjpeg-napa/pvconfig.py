#!/usr/bin/env python3
"""Read-only dump of what PhotonVision will run with: global settings, and per camera the video mode,
exposure / gain and every pipeline's settings (calibration observations left out). The DB is copied first and
never written.

  sudo python3 pvconfig.py [/opt/photonvision/photonvision_config/photon.sqlite]
"""
import json
import shutil
import sqlite3
import sys
import tempfile

src = sys.argv[1] if len(sys.argv) > 1 else "/opt/photonvision/photonvision_config/photon.sqlite"
tmp = tempfile.mktemp(suffix=".sqlite")
shutil.copy(src, tmp)
db = sqlite3.connect(tmp)
for name, contents in db.execute("select * from global"):
    print(f"global {name}: {contents[:600]}")


def short(v):
    s = json.dumps(v)
    return s if len(s) < 200 else s[:200] + "..."


for uniq, contents in db.execute("select * from cameras"):
    c = json.loads(contents)
    print(f"camera {uniq} nickname {c.get('nickname')} path {c.get('matchedCameraInfo', {}).get('uniquePath')}")
    for k, v in c.items():
        if k in ("calibrations", "matchedCameraInfo", "cameraQuirks"):
            continue
        if k == "pipelineSettings" or (isinstance(v, list) and v and isinstance(v[0], (list, dict))):
            continue
        print(f"  {k}: {short(v)}")
    print(f"  calibrations: {[ (x['resolution']['width'], x['resolution']['height']) for x in c.get('calibrations', [])]}")
    for p in c.get("pipelineSettings", c.get("pipelines", [])):
        if isinstance(p, list) and len(p) == 2:
            p = p[1]
        if isinstance(p, str):
            p = json.loads(p)
        print(f"  pipeline {p.get('pipelineIndex')} {p.get('pipelineNickname')} ({p.get('pipelineType')}):")
        print("    " + ", ".join(f"{k}={short(v)}" for k, v in sorted(p.items()) if k not in ("pipelineNickname",)))
