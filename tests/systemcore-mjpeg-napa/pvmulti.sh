#!/usr/bin/env bash
# PhotonVision with native publish, both cameras in one PV, measured as PhotonLib clients see each camera, ON THE PI:
#   pvmulti.sh OUT [SECS]
# Holds /tmp/camera.lock. Loads the small-URB uvcvideo (urb 2) as the builder's runs do, adds a TEMPORARY drop-in
# (MODE fast/java; removed afterwards, PV's DB untouched), starts PV,
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
# decoder + mjdec + streaming NAPA (native publish always on since ab94fb8) | java = SPECTRUM_NATIVE_CAMERA=0 with
# the turbo decoder: frames are not streamed natively, so the whole Java pipeline publishes
case ${MODE:-fast} in
  native) DROPTXT="" ;;
  fast) DROPTXT=$(printf '[Service]\nEnvironment=SPECTRUM_NATIVE_CAMERA=0\nEnvironment=SPECTRUM_JPEG_DECODER=stream\nEnvironment=SPECTRUM_NAPA_STREAM=1\nEnvironment=SPECTRUM_STREAM_DECODER=mjdec\n') ;;
  java) DROPTXT=$(printf '[Service]\nEnvironment=SPECTRUM_NATIVE_CAMERA=0\nEnvironment=SPECTRUM_JPEG_DECODER=turbo\nEnvironment=SPECTRUM_NAPA_STREAM=0\n') ;;
  *) echo "MODE native|fast|java" >&2; exit 2 ;;
esac
[[ -n $DROPTXT ]] && echo "$DROPTXT" | sudo tee "$DROP" >/dev/null
echo "MODE ${MODE:-fast}; uvcvideo urb_packets $(cat /sys/module/uvcvideo/parameters/urb_packets 2>/dev/null || echo stock)"
sudo systemctl daemon-reload
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor); under-voltage (journal -k -b) $(sudo journalctl -k -b --no-pager | grep -ci undervolt); lcrit_alarm $(cat /sys/class/hwmon/hwmon3/in0_lcrit_alarm 2>/dev/null); drop-ins: $(ls /etc/systemd/system/photonvision.service.d/ | tr '\n' ' ')"
grep -h Environment /etc/systemd/system/photonvision.service.d/*.conf | tr '\n' ' '
echo
sudo systemctl start photonvision
sleep 50
for c in /dev/v4l/by-id/*-video-index0; do echo "$(basename "$c"): $(v4l2-ctl -d "$c" -C exposure_time_absolute,gain | tr '\n' ' ')"; done
sudo sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 32768 > $T/buffer_size_kb;
  echo 0 > $T/events/enable; echo 1 > $T/events/xhci-hcd/xhci_urb_giveback/enable; echo 1 > $T/tracing_on"
sudo python3 "$HERE/topcpu.py" "$SECS" 8 >"$OUT/cpu.txt" &
# power/thermal once a second: per-core cur freq (MHz), under-voltage alarm, SoC temp (mC)
(for _ in $(seq "$SECS"); do
  echo "$(cat /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_cur_freq | awk '{printf "%d ", $1/1000}')$(cat /sys/class/hwmon/hwmon3/in0_lcrit_alarm) $(cat /sys/class/thermal/thermal_zone0/temp)"
  sleep 1
done >"$OUT/power.txt") &
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
echo "power: $(awk '{for(i=1;i<=4;i++){if(!m||$i<m)m=$i; if($i>M)M=$i}; a+=$5; if($6>t)t=$6} END{printf "freq %d-%d MHz, lcrit alarm samples %d/%d, max temp %.1f C", m, M, a, NR, t/1000}' "$OUT/power.txt")"
echo "under-voltage after (journal -k -b) $(sudo journalctl -k -b --no-pager | grep -ci undervolt); lcrit_alarm $(cat /sys/class/hwmon/hwmon3/in0_lcrit_alarm 2>/dev/null)"
