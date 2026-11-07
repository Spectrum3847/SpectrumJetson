#!/bin/bash
# apply.sh: back up PhotonVision's database and store the chosen exposures (Thriftiest 12/128, Swyft 5/96), then restart it.
set -e
exec 9>/tmp/camera.lock; flock -w 120 9
DB=/opt/photonvision/photonvision_config/photon.sqlite
BK=/opt/photonvision/photonvision_config/photon.sqlite.before-exposure-$(date +%Y%m%d-%H%M%S)
sudo systemctl stop photonvision
sudo cp -a $DB $BK; echo "backup $BK"
sudo python3 - <<P
import sqlite3,json
c=sqlite3.connect("$DB")
new={"thrifty":(12.0,128),"swyft":(5.0,96)}
for n,v in list(c.execute("select unique_name, contents from cameras")):
    j=json.loads(v); e,g=new[j["nickname"]]
    for p in j["pipelineSettings"]:
        if p.get("pipelineType")=="AprilTag": p["cameraExposureRaw"]=e; p["cameraGain"]=g; p["cameraAutoExposure"]=False
        print(j["nickname"], p["pipelineNickname"], p["cameraExposureRaw"], p["cameraGain"], p["napaMinTagPx"])
    c.execute("update cameras set contents=? where unique_name=?", (json.dumps(j), n))
c.commit()
P
sudo systemctl start photonvision
