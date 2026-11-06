#!/bin/bash
# PhotonVision's fast path (SPECTRUM_NATIVE_PUBLISH=1: each camera's streaming thread publishes its own results)
# with one camera vs several at once in one PhotonVision. Our uvcvideo (urb_packets 2), the cameras' saved
# pipeline settings, the governor as it is. Each camera's results are read by its own PhotonLib-style subscriber
# (nt_probe: capture timestamp -> received, results/s, health) and PhotonVision's CPU is split per thread.
#   multicam-native.sh [SECS] [RUNS]
#     SECS  default 20
#     RUNS  default "SJ-SW01:swyft SJ-05:thrifty shared:SJ-05:thrifty+SJ-SW01:swyft SJ-05:thrifty+SJ-SW01:swyft
#           pin:SJ-05:thrifty+SJ-SW01:swyft"
#           each run: cameras NAME_SUBSTRING:NICKNAME joined by "+" (any number), all others deactivated;
#           prefix "pin:" also pins each camera thread to its own core (SPECTRUM_PIN_CAMERAS=1, cores PIN_CORES,
#           default 1-3) with its watcher on the same core (SPECTRUM_STREAM_CPUS=camera); no SCHED_FIFO.
#           Prefix "shared:" publishes every camera on PhotonVision's own NT connection
#           (SPECTRUM_NATIVE_NT_CLIENT=0) instead of one client per camera.
# Needs PhotonVision stopped; changes its settings DB (backup: ~/builder/photon.sqlite.before-multicam, restored
# on exit) and a drop-in (removed on exit).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/../../scripts/systemcore/uvcvideo-load.sh
secs=${1:-20}
runs=${2:-SJ-SW01:swyft SJ-05:thrifty shared:SJ-05:thrifty+SJ-SW01:swyft SJ-05:thrifty+SJ-SW01:swyft pin:SJ-05:thrifty+SJ-SW01:swyft}
OUT=${OUT:-$HOME/shared/latency/multicam}
PIN_CORES=${PIN_CORES:-1-3}
mkdir -p "$OUT"
DB=/opt/photonvision/photonvision_config/photon.sqlite
BACKUP=$HOME/builder/photon.sqlite.before-multicam
DROPIN=/etc/systemd/system/photonvision.service.d/zz-multicam.conf
PROBE=/opt/sc-vision/bin/nt_probe
exec 9>/tmp/camera.lock
flock -w 120 9 || { echo "camera busy"; exit 1; }
export SC_VISION_HAVE_LOCK=1   # uvcvideo-load.sh: we hold the lock
sudo -n systemctl stop photonvision
sudo -n cp "$DB" "$BACKUP"
cleanup() {
  sudo -n systemctl stop photonvision 2>/dev/null
  sudo -n cp "$BACKUP" "$DB"
  sudo -n rm -f "$DROPIN"; sudo -n systemctl daemon-reload
  "$L" stock >/dev/null
  echo "restored: settings DB, drop-in, stock uvcvideo"
}
trap cleanup EXIT
# per-thread CPU ticks: "tid comm ticks" (comm without spaces)
threads() { sudo -n sh -c "for t in /proc/$1/task/*; do echo \$(basename \$t) \$(tr ' ' _ < \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat); done" 2>/dev/null; }
"$L" urb 2
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec SPECTRUM_NATIVE_PUBLISH=1"
for r in $runs; do
  pin=0; shared=0; spec=$r
  while [[ $spec == pin:* || $spec == shared:* ]]; do
    [[ $spec == pin:* ]] && { pin=1; spec=${spec#pin:}; }
    [[ $spec == shared:* ]] && { shared=1; spec=${spec#shared:}; }
  done
  name=$(echo "$r" | tr ':+' '_-')
  first=1; cams=()
  for c in ${spec//+/ }; do
    sub=${c%%:*}; nick=${c#*:}; cams+=("$nick")
    if ((first)); then sudo -n python3 "$HERE/pv-camera-config.py" only "$sub" "$nick" >/dev/null
    else sudo -n python3 "$HERE/pv-camera-config.py" add "$sub" "$nick" >/dev/null; fi
    first=0
  done
  { printf '[Service]\n'; for v in $S; do printf 'Environment=%s\n' "$v"; done
    ((pin)) && printf 'Environment=SPECTRUM_PIN_CAMERAS=1\nEnvironment=SPECTRUM_PIN_CAMERA_CORES=%s\nEnvironment=SPECTRUM_PIN_SHARED_CORE=-1\nEnvironment=SPECTRUM_STREAM_CPUS=camera\n' "$PIN_CORES"
    ((shared)) && printf 'Environment=SPECTRUM_NATIVE_NT_CLIENT=0\n'
  } | sudo -n tee "$DROPIN" >/dev/null
  sudo -n systemctl daemon-reload; sudo -n systemctl start photonvision
  sleep 45
  pid=$(systemctl show -p MainPID --value photonvision)
  threads "$pid" > "$OUT/$name.t0"
  for n in "${cams[@]}"; do "$PROBE" 127.0.0.1 "$n" "$secs" > "$OUT/$name.$n.probe" 2>&1 & done
  wait
  threads "$pid" > "$OUT/$name.t1"
  journalctl -u photonvision --since "-$((secs + 50))s" --no-pager |
    grep -o -E "NAPA streaming: .*|watcher on cores.*|Frame timestamps moved.*|pinned.*" | sort | uniq -c | tail -12 > "$OUT/$name.journal"
  sudo -n systemctl stop photonvision
  # PhotonVision's CPU (% of one core) and its top threads
  { awk -v s="$secs" 'NR==FNR{a[$1]=$3; next} {tot+=$3-a[$1]} END{printf "proc %.1f%% of a core;", tot/s}' \
      "$OUT/$name.t0" "$OUT/$name.t1"
    awk -v s="$secs" 'NR==FNR{a[$1]=$3; next} {by[$2]+=$3-a[$1]} END{for (k in by) printf "%.1f %s\n", by[k]/s, k}' \
      "$OUT/$name.t0" "$OUT/$name.t1" | sort -rn | head -6 | awk '{printf " %s %s%%", $2, $1}'; echo; } > "$OUT/$name.cpu"
done
for r in $runs; do
  name=$(echo "$r" | tr ':+' '_-')
  echo "== $r: $(cat "$OUT/$name.cpu")"
  for p in "$OUT/$name".*.probe; do
    printf '  %s: ' "$(basename "$p" .probe | sed "s/^$name\.//")"
    grep -E "^rawBytes|^health" "$p" | tr '\n' ' '; echo
  done
done
