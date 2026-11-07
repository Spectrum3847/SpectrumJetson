#!/bin/bash
# tagfit live A/B under PhotonVision on the SystemCore / Pi 5 (native cameras): SPECTRUM_TAGFIT unset vs 1, 40 s each
# after 25 s of warm-up, both cameras at NAPA min tag 22. Run on the target, holding the camera lock:
#   flock -n /tmp/camera.lock scripts/systemcore/tagfit-pv-ab.sh [NEW_LIB]
# NEW_LIB: the tagfit build of libspectrum-napa-apriltag.so (scripts/systemcore/build-napa.sh), copied over.
# Backs up and restores the PV database and the installed library, sets min tag 22 only for the test, applies the
# switch through a temporary systemd drop-in (removed afterwards), measures each camera with nt_probe (capture ->
# received latency, results, health) and PV's CPU (/proc), keeps the journal. Output in /dev/shm/tfab/pv.
# Afterwards PhotonVision runs again with the original library, tagfit off; exposures back (Thriftiest 2, Swyft 10).
set -u
cpu() { python3 -c "import os,sys,time;s=open('/proc/$1/stat').read().rsplit(')',1)[1].split();print((int(s[11])+int(s[12]))/os.sysconf('SC_CLK_TCK'),time.time())"; }
NEW=${1:-/dev/shm/tfab/libspectrum-napa-apriltag.so.tagfit}
O=/dev/shm/tfab/pv; mkdir -p $O; cd $O
DB=/opt/photonvision/photonvision_config/photon.sqlite
LIB=/opt/photonvision/lib/libspectrum-napa-apriltag.so
DROP=/etc/systemd/system/photonvision.service.d/90-tagfit-ab.conf
sudo systemctl stop photonvision
sudo cp -p $DB $O/photon.sqlite.orig; sha256sum $DB > $O/db.sha
sudo cp -p $LIB $O/lib.orig.so
sudo install -m 755 "$NEW" $LIB
# min tag 22 for the test (the backup is restored afterwards)
sudo python3 - <<P
import sqlite3,json
c=sqlite3.connect("$DB")
for n,v in list(c.execute("select unique_name, contents from cameras")):
    c.execute("update cameras set contents=? where unique_name=?", (v.replace("\"napaMinTagPx\":32","\"napaMinTagPx\":22"), n))
c.commit()
print([ (json.loads(v)["nickname"], v.count("\"napaMinTagPx\":22")) for n,v in c.execute("select unique_name, contents from cameras")])
P
for cond in off on; do
  if [ $cond = on ]; then printf "[Service]\nEnvironment=SPECTRUM_TAGFIT=1\n" | sudo tee $DROP >/dev/null; else sudo rm -f $DROP; fi
  sudo systemctl daemon-reload
  T0=$(date "+%Y-%m-%d %H:%M:%S")
  sudo systemctl start photonvision
  sleep 25
  PID=$(systemctl show -p MainPID --value photonvision)
  sudo cat /proc/$PID/environ | tr "\0" "\n" | grep TAGFIT > $cond.env || echo "(unset)" > $cond.env
  read -r a t1 < <(cpu $PID)
  /opt/sc-vision/bin/nt_probe 127.0.0.1 thrifty 40 > $cond-thrifty.probe 2>&1 &
  /opt/sc-vision/bin/nt_probe 127.0.0.1 swyft 40 > $cond-swyft.probe 2>&1 &
  wait
  read -r b t2 < <(cpu $PID)
  python3 -c "print('PV CPU %.1f%% of one core' % (100*($b-$a)/($t2-$t1)))" > $cond.cpu
  sudo journalctl -u photonvision --since "$T0" --no-pager > $cond.journal
  sudo systemctl stop photonvision
done
# restore: drop-in, library, database; then PhotonVision as it was (old library, tagfit off)
sudo rm -f $DROP; sudo systemctl daemon-reload
sudo install -m 755 $O/lib.orig.so $LIB
sudo cp -p $O/photon.sqlite.orig $DB; sha256sum -c $O/db.sha
for d in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do c=$(v4l2-ctl -d $d --info 2>/dev/null | grep "Card type"); case "$c" in *Thrifty*) v4l2-ctl -d $d -c exposure_time_absolute=2 && echo "$d thrifty 2";; *"USB Camera"*) v4l2-ctl -d $d -c exposure_time_absolute=10 && echo "$d swyft 10";; esac; done
sudo systemctl start photonvision
echo done
