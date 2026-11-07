#!/bin/bash
# Software camera-reset recovery timing, both cameras, on the SystemCore / Pi 5. Copy this folder and
# tests/exposure-sweep/expo_probe.py to ~/bench/exposure on the target, then:
#   ~/bench/exposure/run.sh [REPS]          (default 5)
# 1. PhotonVision stopped: reopen, usbreset, rebind, authorize on each camera, captured with v4l2-ctl here.
# 2. PhotonVision running natively: usbreset, rebind, authorize, timed from its NT results.
# Holds /tmp/camera.lock throughout. Only generic USB/sysfs resets: no vendor or firmware requests. Afterwards
# the exposures are set back (Thriftiest 12/128, Swyft 5/96; a control is written only if it differs, since the
# Swyft stores them in flash) and PhotonVision is left running. Output: /dev/shm/camreset/<stamp>.jsonl
set -u
REPS=${1:-5}
H=$(cd "$(dirname "$0")" && pwd)
O=/dev/shm/camreset; mkdir -p "$O"; OUT=$O/$(date +%Y%m%d-%H%M%S).jsonl
T=/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0
S=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0
get() { v4l2-ctl -d "$1" -C "$2" | awk '{print $2}'; }
setc() { [ "$(get "$1" "$2")" = "$3" ] || v4l2-ctl -d "$1" -c "$2=$3"; }
restore() {
  setc $T exposure_time_absolute 12; setc $T gain 128
  setc $S exposure_time_absolute 5; setc $S gain 96
}
exec 9>/tmp/camera.lock
flock -w 120 9 || { echo "lock busy"; exit 1; }
sudo systemctl stop photonvision
for cam in thrifty swyft; do
  for m in reopen usbreset rebind authorize; do
    sudo python3 "$H/reset_timing.py" $cam $m "$REPS" | tee -a "$OUT"
    restore >/dev/null
  done
done
restore
sudo systemctl start photonvision
sleep 25
for cam in thrifty swyft; do
  for m in usbreset rebind authorize; do
    sudo python3 "$H/reset_timing.py" $cam $m "$REPS" --pv | tee -a "$OUT"
  done
done
sleep 3
restore
echo "restored: T $(get $T exposure_time_absolute)/$(get $T gain) S $(get $S exposure_time_absolute)/$(get $S gain)"
systemctl is-active photonvision
flock -u 9
echo "output $OUT"
