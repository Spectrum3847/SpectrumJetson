#!/usr/bin/env bash
# PhotonVision with native publish, both cameras in one PV, measured as PhotonLib clients see each camera, ON THE PI:
#   pvmulti.sh OUT [SECS]
# Holds /tmp/camera.lock. Loads the small-URB uvcvideo (urb 2) as the builder's runs do, adds a TEMPORARY drop-in
# (stream decoder + mjdec + streaming NAPA + native publish; removed afterwards, PV's DB untouched), starts PV,
# then for SECS: nt_check per camera (--csv: capture/publish/received per result), exact per-thread CPU and an
# xhci trace; then tsresid.py per camera (published capture vs first USB packet). Restores stock uvcvideo + PV state.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
SECS=${2:-20}
T=/sys/kernel/tracing
LOAD=${UVC_LOAD:-$HOME/builder/scripts/systemcore/uvcvideo-load.sh}
DROP=/etc/systemd/system/photonvision.service.d/zz-tester.conf
mkdir -p "$OUT"
if [[ ${SCMN_HAVE_LOCK:-0} != 1 ]]; then  # pvboth.sh holds it around the DB edit + this run
  exec 9>/tmp/camera.lock
  flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
fi
was=$(systemctl is-active photonvision)
# Our uvcvideo may already be loaded at boot (sc-uvcvideo.service): then leave the driver alone.
ours_at_start=0
[[ -e /sys/module/uvcvideo/parameters/urb_packets ]] && ours_at_start=1
cleanup() {
  sudo systemctl stop photonvision
  sudo rm -f "$DROP"
  sudo systemctl daemon-reload
  sudo sh -c "echo 0 > $T/tracing_on; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
  ((ours_at_start)) || SC_VISION_HAVE_LOCK=1 bash "$LOAD" stock
  [[ $was == active ]] && sudo systemctl start photonvision
}
trap cleanup EXIT
sudo systemctl stop photonvision
((ours_at_start)) || SC_VISION_HAVE_LOCK=1 bash "$LOAD" urb 2
# MODE: native = PV as installed (native cameras, no tester drop-in) | fast = SPECTRUM_NATIVE_CAMERA=0 + stream
# decoder + mjdec + streaming NAPA + native publish (NATIVE=0: Java publish) | java = native camera and publish off
case ${MODE:-fast} in
  native) DROPTXT="" ;;
  fast) DROPTXT=$(printf '[Service]\nEnvironment=SPECTRUM_NATIVE_CAMERA=0\nEnvironment=SPECTRUM_JPEG_DECODER=stream\nEnvironment=SPECTRUM_NAPA_STREAM=1\nEnvironment=SPECTRUM_STREAM_DECODER=mjdec\nEnvironment=SPECTRUM_NATIVE_PUBLISH=%s\n' "${NATIVE:-1}") ;;
  java) DROPTXT=$(printf '[Service]\nEnvironment=SPECTRUM_NATIVE_CAMERA=0\nEnvironment=SPECTRUM_NATIVE_PUBLISH=0\n') ;;
  *) echo "MODE native|fast|java" >&2; exit 2 ;;
esac
[[ -n $DROPTXT ]] && echo "$DROPTXT" | sudo tee "$DROP" >/dev/null
echo "MODE ${MODE:-fast}; uvcvideo urb_packets $(cat /sys/module/uvcvideo/parameters/urb_packets 2>/dev/null || echo stock)"
sudo systemctl daemon-reload
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor); under-voltage $(sudo dmesg | grep -c 'Undervoltage detected'); drop-ins: $(ls /etc/systemd/system/photonvision.service.d/ | tr '\n' ' ')"
grep -h Environment /etc/systemd/system/photonvision.service.d/*.conf | tr '\n' ' '
echo
sudo systemctl start photonvision
sleep 50
for c in /dev/v4l/by-id/*-video-index0; do echo "$(basename "$c"): $(v4l2-ctl -d "$c" -C exposure_time_absolute,gain | tr '\n' ' ')"; done
sudo sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 32768 > $T/buffer_size_kb;
  echo 0 > $T/events/enable; echo 1 > $T/events/xhci-hcd/xhci_urb_giveback/enable; echo 1 > $T/tracing_on"
sudo python3 "$HERE/topcpu.py" "$SECS" 8 >"$OUT/cpu.txt" &
for cam in thrifty swyft; do
  "$HOME/bench/bin/nt_check" --camera "$cam" --secs "$SECS" --dump 0 --csv "$OUT/$cam.csv" 2>&1 |
    grep -v -E '^NT:|topic /photon' >"$OUT/$cam.nt" &
done
wait
sudo sh -c "echo 0 > $T/tracing_on; cat $T/trace > /tmp/pvmulti.trace"
mv /tmp/pvmulti.trace "$OUT/xhci.trace"
sudo journalctl -u photonvision --since "-3 min" --no-pager | grep -i -E "moved|delay|stamp lag|native" | tail -6 | cut -c1-220 >"$OUT/pv.journal"
for cam in thrifty swyft; do
  echo "== $cam"
  grep -E "results in|capture ->|per tag id|^  id |latencyMillis" "$OUT/$cam.nt"
done
head -8 "$OUT/cpu.txt"
python3 "$HERE/tsresid.py" "$OUT/thrifty.csv" "$OUT/xhci.trace" 3-1
python3 "$HERE/tsresid.py" "$OUT/swyft.csv" "$OUT/xhci.trace" 1-1
cat "$OUT/pv.journal"
# SCALES="4 2 1": the robot's /photonvision/swyft/input/scale published by nt_check, 10 s each, in this PV session
for s in ${SCALES:-}; do
  sudo python3 "$HERE/topcpu.py" 9 4 >"$OUT/scale$s.cpu" &
  "$HOME/bench/bin/nt_check" --camera swyft --secs 10 --dump 0 --pub scale="$s" 2>&1 |
    grep -v -E '^NT:|topic /photon' >"$OUT/scale$s.nt"
  wait
  echo "== swyft input/scale = $s"
  grep -E "publishing|results in|capture ->|^  id |tagQuality|health/" "$OUT/scale$s.nt"
  sed -n 2,4p "$OUT/scale$s.cpu"
done
[[ -n ${SCALES:-} ]] && sudo journalctl -u photonvision --since "-60 s" --no-pager | grep -i -E "scale|policy" | tail -5 | cut -c1-220
echo "under-voltage after $(sudo dmesg | grep -c 'Undervoltage detected')"
