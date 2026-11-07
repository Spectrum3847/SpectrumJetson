#!/bin/bash
# On the target, under the camera lock: BenchEkf live under PhotonVision's full-tag fit settings (list 'g'):
#   flock -n /tmp/camera.lock ~/tagekf/bench-ab.sh [SECONDS]
# Conditions: off (SPECTRUM_TAGFIT=0), max cell 4 px (SPECTRUM_TAGFIT_MAX_CELL=4), default (on, all sizes). Each:
# a temporary systemd drop-in (90-tagekf-ab.conf), PhotonVision restart, 25 s warm-up, BenchEkf for SECONDS (default
# 30) after a 5 s survey, PhotonVision's CPU over the run. The PV database is backed up first and not changed.
# Afterwards: drop-in removed, PhotonVision restarted on its defaults (tagfit on), exposures set back by camera name
# (Thriftiest 2, Swyft 10). Output: /dev/shm/tagekf/ab-<stamp>/<condition>/.
set -u
SECS=${1:-30}
O=/dev/shm/tagekf/ab-$(date +%Y%m%d-%H%M%S); mkdir -p "$O"
DB=/opt/photonvision/photonvision_config/photon.sqlite
sudo cp "$DB" "$HOME/tagekf/photon.sqlite.bak-$(date +%Y%m%d-%H%M%S)"
DROP=/etc/systemd/system/photonvision.service.d/90-tagekf-ab.conf
W=/home/systemcore/wpilib
CP=""
for j in "$W"/classpath/*.jar; do [[ $j == *DIYsystemcore* ]] || CP="$CP$j:"; done
cpu() { python3 -c "import os,time;s=open('/proc/$1/stat').read().rsplit(')',1)[1].split();print((int(s[11])+int(s[12]))/os.sysconf('SC_CLK_TCK'),time.time())"; }
for cond in off maxcell4 on; do
  case $cond in
    off) printf "[Service]\nEnvironment=SPECTRUM_TAGFIT=0\n" | sudo tee $DROP >/dev/null ;;
    maxcell4) printf "[Service]\nEnvironment=SPECTRUM_TAGFIT_MAX_CELL=4\n" | sudo tee $DROP >/dev/null ;;
    on) sudo rm -f $DROP ;;
  esac
  sudo systemctl daemon-reload
  sudo systemctl restart photonvision
  sleep 25
  PID=$(systemctl show -p MainPID --value photonvision)
  sudo cat /proc/"$PID"/environ | tr "\0" "\n" | grep TAGFIT > "$O/$cond.env" || echo "(default)" > "$O/$cond.env"
  read -r a t1 < <(cpu "$PID")
  java -XX:+UseZGC -Djava.library.path=$W/third-party/lib --enable-native-access=ALL-UNNAMED \
    -cp "$HOME/tagekf/tagekf-bench.jar:$CP" org.spectrum3847.tagekf.BenchEkf live --seconds "$SECS" --out "$O/$cond" \
    > "$O/$cond.txt" 2>&1
  read -r b t2 < <(cpu "$PID")
  python3 -c "print('PV CPU %.1f%% of one core' % (100*($b-$a)/($t2-$t1)))" >> "$O/$cond.txt"
  echo "== $cond $(cat "$O/$cond.env")"; grep -E "pose over|accepted|PV CPU|:[0-9]+ " "$O/$cond.txt"
done
sudo systemctl daemon-reload
for d in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do c=$(v4l2-ctl -d $d --info 2>/dev/null | grep "Card type"); case "$c" in *Thrifty*) v4l2-ctl -d $d -c exposure_time_absolute=2 2>/dev/null && echo "$d thrifty 2";; *"USB Camera"*) v4l2-ctl -d $d -c exposure_time_absolute=10 2>/dev/null && echo "$d swyft 10";; esac; done
echo "done: $O"
