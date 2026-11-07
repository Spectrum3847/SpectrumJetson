#!/bin/bash
# PhotonVision CPU knobs on the SystemCore / Pi 5 (native cameras, stored settings: min tag 22, exposures from
# tests/exposure-sweep). For each condition: a temporary systemd drop-in (90-cpu-knobs.conf) with its environment,
# PhotonVision restart, 25 s warm-up, then SECS of tests/exposure-sweep/expo_probe.py on both cameras (rate, margin,
# corner jitter, range sd per tag, latency), with per-thread CPU of PhotonVision, per-core load, robot.service's CPU
# (cgroup) and the image mean/saturation (grab.py). The camera lock is held per condition and released in between.
#   scripts/systemcore/pv-cpu-knobs.sh SECS "name[:VAR=V[,VAR=V...]]" ...
#   e.g. pv-cpu-knobs.sh 30 default maxcell4:SPECTRUM_TAGFIT_MAX_CELL=4 off:SPECTRUM_TAGFIT=0
# The PV database is backed up and not changed. Afterwards the drop-in is removed and PhotonVision restarted on its
# defaults. Probe scripts are read from ~/bench/exposure. Output: /dev/shm/cpuknobs/<stamp>/<name>.*
set -u
SECS=${1:?SECS}; shift
O=/dev/shm/cpuknobs/$(date +%Y%m%d-%H%M%S); mkdir -p "$O"
P=$HOME/bench/exposure
DB=/opt/photonvision/photonvision_config/photon.sqlite
sudo cp "$DB" "$O/photon.sqlite.bak"
DROP=/etc/systemd/system/photonvision.service.d/90-cpu-knobs.conf
cg() { echo "/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$1")/cpu.stat"; }
usec() { awk '$1=="usage_usec"{print $2}' "$(cg "$1")" 2>/dev/null || echo 0; }
threads() { for t in /proc/"$1"/task/*; do echo "${t##*/} $(tr ' ' '_' < "$t/comm") $(awk '{print $14+$15}' "$t/stat" 2>/dev/null)"; done; }
for c in "$@"; do
  name=${c%%:*}
  if [ "$name" = "$c" ]; then env=""; else env=${c#*:}; fi
  if [ -n "$env" ]; then
    { echo "[Service]"; for kv in ${env//,/ }; do echo "Environment=$kv"; done; } | sudo tee "$DROP" >/dev/null
  else
    sudo rm -f "$DROP"
  fi
  sudo systemctl daemon-reload
  exec 9>/tmp/camera.lock
  flock -w 120 9 || { echo "lock busy"; exit 1; }
  T0=$(date "+%Y-%m-%d %H:%M:%S")
  sudo systemctl restart photonvision
  sleep 25
  PID=$(systemctl show -p MainPID --value photonvision)
  sudo cat /proc/"$PID"/environ | tr "\0" "\n" | grep '^SPECTRUM_TAGFIT' > "$O/$name.env"
  sudo bash -c "$(declare -f threads); threads $PID" | tee "$O/$name.t0" >/dev/null
  grep '^cpu[0-9]' /proc/stat > "$O/$name.cpu0"
  pv0=$(usec photonvision); rb0=$(usec robot); t1=$(date +%s.%N)
  python3 "$P/expo_probe.py" "$SECS" thrifty swyft > "$O/$name.probe"
  pv1=$(usec photonvision); rb1=$(usec robot); t2=$(date +%s.%N)
  sudo bash -c "$(declare -f threads); threads $PID" | tee "$O/$name.t1" >/dev/null
  grep '^cpu[0-9]' /proc/stat > "$O/$name.cpu1"
  python3 "$P/grab.py" 1183 8 > "$O/$name.imgT" 2>/dev/null
  python3 "$P/grab.py" 1181 8 > "$O/$name.imgS" 2>/dev/null
  flock -u 9; exec 9>&-
  echo "$pv0 $pv1 $rb0 $rb1 $t1 $t2" | awk '{d=($6-$5)*1e6; printf "pv %.1f robot %.1f\n", 100*($2-$1)/d, 100*($4-$3)/d}' > "$O/$name.cpu"
  sudo journalctl -u photonvision --since "$T0" --no-pager | grep -E 'tagfit:|Loop timing' > "$O/$name.journal"
  echo "$name ($env): $(cat "$O/$name.cpu")"
done
sudo rm -f "$DROP"; sudo systemctl daemon-reload; sudo systemctl restart photonvision
echo "output $O"
