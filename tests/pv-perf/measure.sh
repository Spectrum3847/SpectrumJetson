#!/bin/bash
# PhotonVision cost profile, one camera (Thriftiest SJ-05 by default), ON THE SYSTEMCORE (docs/PHOTONVISION-PERF.md).
#   tests/pv-perf/measure.sh NAME SECS [ENV=VAL ...]
# Holds /tmp/camera.lock for the whole run; refuses while PhotonVision runs or the builder's "PV BOTH READY" hand-off
# is open. Backs the settings DB up (SQLite backup API, integrity-checked), makes the camera the only active one,
# loads our uvcvideo (urb_packets 2), starts PhotonVision with the given extra environment (drop-in zz-pvperf.conf)
# and optional jar (PVPERF_JAR) / JVM flags (PVPERF_JVM), waits WARM s (default 30), then records SECS s of: JFR
# (profile + CPU-time sampling), GC log, per-thread CPU and context switches (named from Thread.print), bytes
# written, nt_probe latency, and optionally runs VIEWER (e.g. tests/pv-perf/viewer.py on a stream) meanwhile.
# Everything is restored on exit; START/DONE lines go to ~/shared/PVPERF-LOG.md. Results in OUT (default
# ~/pvperf/out)/NAME.*
set -uo pipefail
name=$1; secs=$2; shift 2
WARM=${WARM:-30}
CAM=${CAM:-SJ-05}; NICK=${NICK:-thrifty}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$HOME/pvperf/out}; mkdir -p "$OUT"
L=$HERE/scripts/systemcore/uvcvideo-load.sh
DB=/opt/photonvision/photonvision_config/photon.sqlite
DROPIN=/etc/systemd/system/photonvision.service.d/zz-pvperf.conf
PROBE=/opt/sc-vision/bin/nt_probe
# The lock is held on fd 9 by this shell for the whole run (PV start -> measure -> stop -> restore).
exec 9>/tmp/camera.lock
flock -w "${LOCK_WAIT:-120}" 9 || { echo "camera busy"; exit 1; }
export SC_VISION_HAVE_LOCK=1
[[ $(systemctl is-active photonvision) == active ]] && { echo "PV is running (someone else's run?): not touching it"; exit 1; }
# the builder's "PV BOTH READY" hand-off to the tester: hands off until the tester's DONE in FINDINGS (newer file)
if tail -3 "$HOME/shared/BUILDER-LOG.md" | grep -q "PV BOTH READY" &&
  ! [[ $HOME/shared/FINDINGS.md -nt $HOME/shared/BUILDER-LOG.md ]]; then
  echo "builder posted PV BOTH READY (tester's turn): not starting"; exit 1
fi
log() { echo "$(date +%H:%M:%S) pvperf: $*" >> "$HOME/shared/PVPERF-LOG.md"; }
# this run's own DB backup, taken under the lock with sqlite's backup API, checked
BACKUP=$OUT/photon.sqlite.run-$$
sudo -n python3 - "$DB" "$BACKUP" <<'PY' || { echo "settings DB not ok: refusing to run"; exit 1; }
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
if src.execute('pragma integrity_check').fetchone()[0] != 'ok':
    sys.exit(1)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
PY
log "START $name (PV + $CAM${CAM2:++$CAM2}, drop-in zz-pvperf.conf, DB backup $BACKUP)"
# RESTORE_FILES: files this run may change (e.g. Rewind's settings.json): put back as they were (or removed again)
declare -A saved=()
for f in ${RESTORE_FILES:-}; do
  if sudo -n test -e "$f"; then sudo -n cp -p "$f" "$OUT/restore.$$.$(basename "$f")"; saved[$f]=1; else saved[$f]=0; fi
done
# CLEAN_NEW_IN: a directory whose entries made during the run are deleted afterwards (e.g. Rewind's sessions)
before=""
[[ -n ${CLEAN_NEW_IN:-} ]] && before=$(sudo -n ls -1 "$CLEAN_NEW_IN" 2>/dev/null)
cleanup() {
  [[ -n ${POST_CMD:-} ]] && { sudo -n systemctl stop photonvision 2>/dev/null; bash -c "$POST_CMD"; }
  sudo -n systemctl stop photonvision 2>/dev/null
  for f in "${!saved[@]}"; do
    if [[ ${saved[$f]} == 1 ]]; then sudo -n cp -p "$OUT/restore.$$.$(basename "$f")" "$f"; sudo -n rm -f "$OUT/restore.$$.$(basename "$f")"
    else sudo -n rm -f "$f"; fi
  done
  if [[ -n ${CLEAN_NEW_IN:-} ]]; then
    for e in $(sudo -n ls -1 "$CLEAN_NEW_IN" 2>/dev/null); do
      grep -qxF "$e" <<< "$before" || sudo -n rm -rf -- "${CLEAN_NEW_IN:?}/$e"
    done
  fi
  sudo -n cp "$BACKUP" "$DB.pvperf-tmp" && sudo -n mv "$DB.pvperf-tmp" "$DB" && sudo -n rm -f "$BACKUP"
  sudo -n rm -f "$DROPIN"; sudo -n systemctl daemon-reload
  [[ ${KEEP_URB:-0} == 1 ]] || "$L" stock >/dev/null
  log "DONE $name (PV stopped, DB + drop-in restored$([[ ${KEEP_URB:-0} == 1 ]] && echo ', urb 2 driver left loaded' || echo ', stock uvcvideo'))"
  echo "restored: settings DB, drop-in, driver"
}
trap cleanup EXIT
# PRE_CMD / POST_CMD: run (bash -c) before PhotonVision starts / after it stopped, under the lock
[[ -n ${PRE_CMD:-} ]] && bash -c "$PRE_CMD"
sudo -n python3 "$HERE/tests/systemcore-latency/pv-camera-config.py" only "$CAM" "$NICK" ${PVCFG:-} >/dev/null
# CAM2/NICK2: a second camera active at the same time (the probe reads NICK's results)
[[ -n ${CAM2:-} ]] && sudo -n python3 "$HERE/tests/systemcore-latency/pv-camera-config.py" add "$CAM2" "${NICK2:?}" \
  >/dev/null
[[ $(cat /sys/module/uvcvideo/parameters/urb_packets 2>/dev/null) == 2 ]] || "$L" urb 2 >/dev/null
# PVPERF_LIB: a directory with our own libspectrum-napa-apriltag.so + libspectrum-stream.so instead of /opt's
LIB=${PVPERF_LIB:-/opt/photonvision/lib}
{ printf '[Service]\n'; for v in "$@"; do printf 'Environment=%s\n' "$v"; done
  printf 'Environment=LD_LIBRARY_PATH=%s\n' "$LIB"
  if [[ -n ${PVPERF_EXEC:-} ]]; then  # a whole ExecStart (e.g. a run.sh wrapper under test)
    printf 'ExecStart=\nExecStart=%s\n' "$PVPERF_EXEC"
  elif [[ -n ${PVPERF_JVM:-} || -n ${PVPERF_JAR:-} || -n ${PVPERF_LIB:-} ]]; then
    printf 'ExecStart=\nExecStart=/usr/bin/java %s -XX:-CreateCoredumpOnCrash -Djava.library.path=%s -jar %s -n\n' \
      "${PVPERF_JVM:--Xmx512m}" "$LIB" "${PVPERF_JAR:-/opt/photonvision/photonvision.jar}"
  fi
} | sudo -n tee "$DROPIN" >/dev/null
sudo -n systemctl daemon-reload; sudo -n systemctl start photonvision
sleep "$WARM"
pid=$(systemctl show -p MainPID --value photonvision)
[[ $pid != 0 ]] || { echo "PV not running"; exit 1; }
threads() { sudo -n sh -c "for t in /proc/$1/task/*; do echo \$(basename \$t) \$(tr ' ' _ < \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat) \$(awk '/voluntary_ctxt_switches/{s+=\$2} END{print s}' \$t/status); done" 2>/dev/null; }
J=(sudo -n jcmd "$pid")
if [[ ${NOJFR:-0} != 1 ]]; then
  "${J[@]}" JFR.start name=pvperf settings=profile "jdk.CPUTimeSample#enabled=true" "jdk.CPUTimeSample#throttle=10ms" \
    duration="${secs}s" filename=/tmp/pvperf-$name.jfr >/dev/null
fi
[[ ${NOJFR:-0} == 1 ]] || "${J[@]}" VM.log output=/tmp/pvperf-$name.gc.log what=gc=info,gc+phases=debug,safepoint=info decorators=uptime >/dev/null
netstat -tn 2>/dev/null | grep -E ":5880 |:118[0-9] " | grep ESTABLISHED > "$OUT/$name.conns"
vp=
if [[ -n ${VIEWER:-} ]]; then  # e.g. a stream viewer: curl -s http://127.0.0.1:1181/stream.mjpg -o FILE
  bash -c "$VIEWER" > "$OUT/$name.viewer" 2>&1 &
  vp=$!
  sleep 3
fi
w0=$(sudo -n awk '/^wchar/{print $2}' /proc/$pid/io)
threads "$pid" > "$OUT/$name.t0"
mpstat_0=$(head -1 /proc/stat)
disk_0=$(cat "/sys/block/${DISK:-mmcblk0}/stat" 2>/dev/null)
NT_PROBE_CSV=$OUT/$name.csv "$PROBE" 127.0.0.1 "$NICK" "$secs" > "$OUT/$name.probe" 2>&1
threads "$pid" > "$OUT/$name.t1"
w1=$(sudo -n awk '/^wchar/{print $2}' /proc/$pid/io); echo "PV bytes written (sockets+files) $(( (w1 - w0) / secs / 1000 )) KB/s" > "$OUT/$name.wchar"
mpstat_1=$(head -1 /proc/stat)
DISK=${DISK:-mmcblk0}
disk_1=$(cat "/sys/block/$DISK/stat" 2>/dev/null)
# the storage device over the window: writes (stat fields 5 ios, 7 sectors, 8 ms busy writing) and flushes (16)
echo "$disk_0" "$disk_1" | awk -v s="$secs" -v d="$DISK" 'NF >= 34 { n = NF / 2; w = $(n + 5) - $5; mb = ($(n + 7) - $7) * 512 / 1e6;
  printf "%s writes %.2f MB/s, %.1f writes/s, %.0f KB a write, %.0f ms/s busy writing, %.2f flushes/s\n", d, mb / s,
  w / s, (w ? mb * 1000 / w : 0), ($(n + 8) - $8) / s, ($(n + 16) - $16) / s }' > "$OUT/$name.disk"
[[ -n $vp ]] && wait "$vp"
# whole-machine busy CPU over the window, % of one core (4 cores = 400%)
echo "$mpstat_0" "$mpstat_1" | awk '{b0=$2+$3+$4+$7+$8+$9; t0=b0+$5+$6; b1=$13+$14+$15+$18+$19+$20; t1=b1+$16+$17;
  printf "machine busy %.1f%% of one core\n", 400*(b1-b0)/(t1-t0)}' > "$OUT/$name.machine"
"${J[@]}" Thread.print > "$OUT/$name.jstack" 2>&1
"${J[@]}" VM.log disable >/dev/null 2>&1
"${J[@]}" GC.heap_info > "$OUT/$name.heap" 2>&1
"${J[@]}" VM.flags > "$OUT/$name.flags" 2>&1
sleep 2
sudo -n cp /tmp/pvperf-$name.gc.log "$OUT/" 2>/dev/null; sudo -n chown "$USER" "$OUT/pvperf-$name.gc.log" 2>/dev/null
if [[ ${NOJFR:-0} != 1 ]]; then
  sudo -n cp /tmp/pvperf-$name.jfr "$OUT/$name.jfr"; sudo -n chown "$USER" "$OUT/$name.jfr"
fi
journalctl -u photonvision --since "-$((secs + WARM + 10))s" --no-pager -o short-precise > "$OUT/$name.journal"
# start-up milestones, seconds after systemd started PhotonVision (short-precise timestamps)
awk '/Started PhotonVision/ && !t0 { t0 = ts($3) } t0 && /Started Server@/ && !a { a = ts($3) - t0 }
  t0 && /Capture format: MJPEG decoded/ && !b { b = ts($3) - t0 } t0 && /band sink attached/ && !c { c = ts($3) - t0 }
  function ts(s,  p) { split(s, p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
  END { printf "startup: web server %.2f s, first decoded frame %.2f s, streaming NAPA attached %.2f s\n", a, b, c }' \
  "$OUT/$name.journal" > "$OUT/$name.startup"
sudo -n systemctl stop photonvision
# per-thread CPU (% of a core) and wakeups (context switches/s), by thread name
awk -v s="$secs" 'NR==FNR{a[$1]=$3; c[$1]=$4; next} {tot+=$3-a[$1]; cs+=$4-c[$1]; by[$2]+=$3-a[$1]; w[$2]+=$4-c[$1]}
  END{printf "TOTAL %.1f %.0f\n", tot/s, cs/s; for (k in by) printf "%s %.1f %.0f\n", k, by[k]/s, w[k]/s}' \
  "$OUT/$name.t0" "$OUT/$name.t1" | sort -k2 -rn > "$OUT/$name.cpu"
python3 "$HERE/tests/pv-perf/threadcpu.py" "$OUT/$name" "$secs" > "$OUT/$name.tcpu"
echo "== $name"; head -22 "$OUT/$name.tcpu"
grep -E "^rawBytes|^health" "$OUT/$name.probe"
echo "UI/stream connections at start: $(wc -l < "$OUT/$name.conns")"
cat "$OUT/$name.machine" "$OUT/$name.wchar" "$OUT/$name.disk" "$OUT/$name.startup"
