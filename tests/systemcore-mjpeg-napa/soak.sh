#!/usr/bin/env bash
# Soak a vision program under /tmp/camera.lock: CPU, RSS, fds, threads, temperature, throttle flags per second
# (sysmon.py), plus the program's own per-frame CSV. Run ON THE PI.
#   soak.sh OUT_DIR MINUTES CMD...      e.g. soak.sh ~/bench/results/soak1 30 sudo ~/builder/sc-vision/sc-vision --cpu 3
# The command gets --secs and --csv OUT_DIR/frames.csv appended. Afterwards, if ${SCMN_THR:-/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0} is missing
# (a usbfs app that didn't give the camera back), uvcvideo is re-bound through sysfs (no USB reset).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT_DIR}
MIN=${2:?MINUTES}
shift 2
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
secs=$((MIN * 60))
"$@" --secs "$secs" --csv "$OUT/frames.csv" >"$OUT/app.log" 2>&1 </dev/null &
sleep 3
# the app itself (not its sudo wrapper): the process whose args hold our CSV path and whose comm isn't sudo
pid=$(ps -o pid,comm,args | awk -v k="$OUT/frames.csv" 'index($0, k) && $2 != "sudo" && $2 != "awk" {print $1}' | tail -1)
echo "app pid $pid" | tee "$OUT/summary.txt"
sudo python3 "$HERE/sysmon.py" "$OUT/sysmon.csv" --secs "$((secs - 5))" --pid "$pid" | tee -a "$OUT/summary.txt"
wait
tail -3 "$OUT/app.log" | tee -a "$OUT/summary.txt"
if [[ ! -e ${SCMN_THR:-/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0} ]]; then
  echo "${SCMN_THR:-/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0} missing after the run: re-binding uvcvideo" | tee -a "$OUT/summary.txt"
  for d in /sys/bus/usb/devices/*:1.0; do
    [[ $(cat "${d%:*}/idVendor" 2>/dev/null) == 1bcf ]] && basename "$d" | sudo tee /sys/bus/usb/drivers/uvcvideo/bind
  done
fi
