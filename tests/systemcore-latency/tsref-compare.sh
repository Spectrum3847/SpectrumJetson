#!/bin/bash
# Which time reference should a frame's capture time come from, and PhotonVision vs sc-vision on the same one.
# The Thriftiest, our uvcvideo (urb_packets 2), PhotonVision's fast path (native publish) with hwtimestamps 0 / 1
# under a kernel trace of the USB packets, and sc-vision; a PhotonLib-style subscriber logs every result.
# tsref.py then compares, frame by frame, against the frame's first USB DATA packet (the LED test's reference:
# exposure end = first data packet - 0.41 ms):
#   notice     uvcvideo's own stamp (its first packet with the new frame ID: header-only packets ~0.75 ms early)
#   v4l2       the dequeued buffer's timestamp (= notice with hwtimestamps=0; the camera's PTS via SCR with 1)
#   watcher    the native publish's first sight of the frame's bytes (hwtimestamps=0)
#   camclock   the native publish's camera-clock stamp (hwtimestamps=1: the V4L2 stamps Java sees, carried by the
#              camera's period to the frames published before Java sees them)
# and "first data packet -> received" for each (sc-vision: from its own first data packet).
#   tsref-compare.sh [SECS] [MODES]     default 20 s, modes "0 1 scv" (0/1: PhotonVision with hwtimestamps 0/1)
# Holds /tmp/camera.lock for the whole run. PhotonVision's settings DB is backed up with SQLite's backup API and
# restored the same way (PhotonVision stopped).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/../../scripts/systemcore/uvcvideo-load.sh
secs=${1:-20}
shift || true
modes=${*:-0 1 scv}
OUT=${OUT:-$HOME/shared/latency/tsref}
export OUT
mkdir -p "$OUT"
DB=/opt/photonvision/photonvision_config/photon.sqlite
BACKUP=$HOME/builder/photon.sqlite.before-tsref
PROBE=/opt/sc-vision/bin/nt_probe
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera busy"; exit 1; }
export SC_VISION_HAVE_LOCK=1
dbcopy() { sudo -n python3 -c 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); print(sys.argv[2], d and sqlite3.connect(sys.argv[2]).execute("pragma integrity_check").fetchone()[0])' "$1" "$2"; }
sudo -n systemctl stop photonvision
dbcopy "$DB" "$BACKUP" || { echo "settings DB unreadable: not touching it"; exit 1; }
trap 'sudo -n systemctl stop photonvision; dbcopy "$BACKUP" "$DB"; "$L" stock >/dev/null; echo "restored: settings DB, stock uvcvideo"' EXIT
sudo -n python3 "$HERE/pv-camera-config.py" only SJ-05 thrifty >/dev/null
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec SPECTRUM_NATIVE_PUBLISH=1"
for h in $modes; do
  name=hw$h
  if [[ $h == scv ]]; then
    "$L" stock >/dev/null
    name=scv
    # Thriftiest exposure setting 2 = really ~1.1 ms: mid offset 0.55 + 0.4; logged as the shift back to the packet
    sudo -n /opt/sc-vision/bin/sc-vision --serial SJ-05 --cpu 3 --fifo 40 --pkts 2 --exposure 2 --gain 128 --gamma 100 \
      --backlight 0 --sharpness 1 --min-tag 32 --calib /opt/sc-vision/etc/calib.json --nt 127.0.0.1 --name thrifty \
      --secs $((secs + 8)) > "$OUT/scv.log" 2>&1 &
    sleep 4
    NT_PROBE_CSV=$OUT/scv.probe.csv "$PROBE" 127.0.0.1 thrifty $((secs - 4)) > "$OUT/scv.probe" 2>&1
    wait
    echo "first-sight shift 0.95 ms" > "$OUT/scv.shift"
    python3 "$HERE/tsref.py" /dev/null "$OUT/scv.probe.csv" "$OUT/scv.shift" | sed 's/^watcher/sc-vision/' | tee "$OUT/scv.tsref"
    continue
  fi
  HWTS=$h "$L" urb 2
  # run.sh starts PhotonVision, waits 45 s, then traces for SECS (under our lock)
  # shellcheck disable=SC2086
  KTRACE_PSIZE=1600 "$HERE/run.sh" pv "$secs" "$name" $S > "$OUT/$name.runlog" 2>&1 &
  rpid=$!
  sleep 47
  NT_PROBE_CSV=$OUT/$name.probe.csv "$PROBE" 127.0.0.1 thrifty $((secs - 4)) > "$OUT/$name.probe" 2>&1
  wait "$rpid"
  sudo -n journalctl -u photonvision --since "-$((secs + 60))s" --no-pager | grep -o "Frame timestamps moved.*" | tail -1 \
    > "$OUT/$name.shift"
  sudo -n journalctl -u photonvision --since "-$((secs + 60))s" --no-pager | grep -o "NAPA native publish:.*" | tail -1 \
    >> "$OUT/$name.shift"
  python3 "$HERE/tsref.py" "$OUT/$name.trace" "$OUT/$name.probe.csv" "$OUT/$name.shift" | tee "$OUT/$name.tsref"
  tail -1 "$OUT/$name.shift"
done
