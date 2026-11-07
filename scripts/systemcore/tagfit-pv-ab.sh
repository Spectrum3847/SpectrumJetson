#!/bin/bash
# tagfit live A/B under PhotonVision on the SystemCore / Pi 5 (native cameras): SPECTRUM_TAGFIT=0 vs the default (on),
# 40 s each after 25 s of warm-up, with PhotonVision's stored settings (min tag: napaMinTagPx in its database, read
# and reported, not changed) and the installed libspectrum-napa-apriltag.so. Run on the target with the camera lock:
#   flock -n /tmp/camera.lock scripts/systemcore/tagfit-pv-ab.sh
# The off condition uses a temporary systemd drop-in (90-tagfit-ab.conf), removed afterwards. Each camera is measured
# with nt_probe (capture -> received latency, results, health), PhotonVision's CPU from /proc, and the journal is kept.
# Output in /dev/shm/tfab/pv. Afterwards PhotonVision runs again with its default (tagfit on); exposures are set back
# by camera name (Thriftiest 2, Swyft 10).
set -u
cpu() { python3 -c "import os,sys,time;s=open('/proc/$1/stat').read().rsplit(')',1)[1].split();print((int(s[11])+int(s[12]))/os.sysconf('SC_CLK_TCK'),time.time())"; }
O=/dev/shm/tfab/pv; mkdir -p $O; cd $O
DB=/opt/photonvision/photonvision_config/photon.sqlite
DROP=/etc/systemd/system/photonvision.service.d/90-tagfit-ab.conf
sudo python3 - <<P > $O/stored.txt
import sqlite3,json
c=sqlite3.connect("file:$DB?mode=ro", uri=True)
for n,v in c.execute("select unique_name, contents from cameras"):
    j=json.loads(v); print(j.get("nickname"), "napaMinTagPx", sorted(set(p.get("napaMinTagPx") for p in j.get("pipelineSettings",[]) if isinstance(p,dict) and "napaMinTagPx" in p)) or v.count('"napaMinTagPx":22'))
P
cat $O/stored.txt
for cond in off on; do
  if [ $cond = off ]; then printf "[Service]\nEnvironment=SPECTRUM_TAGFIT=0\n" | sudo tee $DROP >/dev/null; else sudo rm -f $DROP; fi
  sudo systemctl daemon-reload
  T0=$(date "+%Y-%m-%d %H:%M:%S")
  sudo systemctl restart photonvision
  sleep 25
  PID=$(systemctl show -p MainPID --value photonvision)
  sudo cat /proc/$PID/environ | tr "\0" "\n" | grep TAGFIT > $cond.env || echo "(unset: default on)" > $cond.env
  read -r a t1 < <(cpu $PID)
  /opt/sc-vision/bin/nt_probe 127.0.0.1 thrifty 40 > $cond-thrifty.probe 2>&1 &
  /opt/sc-vision/bin/nt_probe 127.0.0.1 swyft 40 > $cond-swyft.probe 2>&1 &
  wait
  read -r b t2 < <(cpu $PID)
  python3 -c "print('PV CPU %.1f%% of one core' % (100*($b-$a)/($t2-$t1)))" > $cond.cpu
  sudo journalctl -u photonvision --since "$T0" --no-pager > $cond.journal
done
# PhotonVision stays up from the last (default) condition; the drop-in is already gone
sudo systemctl daemon-reload
for d in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do c=$(v4l2-ctl -d $d --info 2>/dev/null | grep "Card type"); case "$c" in *Thrifty*) v4l2-ctl -d $d -c exposure_time_absolute=2 2>/dev/null && echo "$d thrifty 2";; *"USB Camera"*) v4l2-ctl -d $d -c exposure_time_absolute=10 2>/dev/null && echo "$d swyft 10";; esac; done
echo done
