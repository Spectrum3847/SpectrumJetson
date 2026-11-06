#!/bin/bash
# Rewind's recording cost on the SystemCore's fast path, one camera (docs/PHOTONVISION-PERF.md), ON THE SYSTEMCORE:
# recording off vs on (FPS, default 30) for each build in RUNS, with the recordings in RAM (/dev/shm: Rewind's
# sessions folder is swapped for a link while the run holds the camera lock) so the SD card isn't written.
# Rewind's settings.json and session counter are put back afterwards.
#   RUNS="inst:off inst:on perf5:on" FPS=30 [CAM= NICK= SECS= WARM=] rewind-ab.sh
HERE=$(cd "$(dirname "$0")" && pwd)
R=/opt/photonvision/rewind
export OUT=${OUT:-/dev/shm/pvperf-out} JARS=${JARS:-/dev/shm/pvperf}
mkdir -p "$OUT"
export RESTORE_FILES="$R/settings.json $R/next-session-number"
export PRE_CMD="sudo -n mv $R/sessions $R/sessions.pvperf && mkdir -p /dev/shm/rw && sudo -n ln -s /dev/shm/rw $R/sessions"
export POST_CMD="sudo -n rm -f $R/sessions; [ -d $R/sessions.pvperf ] && sudo -n mv $R/sessions.pvperf $R/sessions; \
sudo -n rm -rf /dev/shm/rw"
for spec in ${RUNS:-inst:off inst:on perf5:on}; do
  b=${spec%%:*}; mode=${spec#*:}
  V=""
  [[ $mode == on ]] && V="python3 $HERE/rewind_rec.py ${PORT:-5881} ${FPS:-30} $(( ${SECS:-25} + 2 ))"
  VIEWER=$V TAG=rw-$mode RUNS=$b SECS=${SECS:-25} "$HERE/ab.sh"
done
