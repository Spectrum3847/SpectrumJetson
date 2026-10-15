#!/usr/bin/env bash
# Camera delay (exposure end to frame timestamp) from an LED on a GPIO pin. Run ON THE JETSON, with
# the LED pointed at the camera; stops PhotonVision for a few minutes and starts it again. See
# delay.py for what is measured and how.
#   tests/camera-delay/run.sh <video-device> <gpio-chip> <gpio-line> [trials] [exposure-ms]
# e.g. tests/camera-delay/run.sh /dev/video0 gpiochip0 105 100 2   (find a free line with gpioinfo)
# trials is the number of usable switch-ons (default 100), exposure-ms defaults to 2. Prints
# SPECTRUM_CAMERA_DELAY_US with its spread. Needs python3-opencv, python3-gpiod and v4l-utils.
# Deadline: 10 min.
set -euo pipefail
[[ $# -ge 3 ]] || { sed -n '5,6p' "$0" | sed 's/^# \?//'; exit 2; }
DEV=$1 CHIP=$2 LINE=$3 TRIALS=${4:-100} EXPOSURE_MS=${5:-2}
HERE=$(cd "$(dirname "$0")" && pwd)
if [[ -z ${CAMERA_DELAY_UNDER_TIMEOUT:-} ]]; then
  rc=0
  CAMERA_DELAY_UNDER_TIMEOUT=1 timeout --kill-after=10 600 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the camera delay test didn't finish in 10 min" >&2
  exit "$rc"
fi
# exposure_time_absolute counts 100 us units
RAW=$(awk -v ms="$EXPOSURE_MS" 'BEGIN { r = int(ms * 10 + 0.5); print (r < 1 ? 1 : r) }')

was_active=$(systemctl is-active photonvision || true)
restore() { if [[ $was_active == active ]]; then sudo systemctl start photonvision; fi; }  # delay.py switches the LED off itself
trap restore EXIT
sudo systemctl stop photonvision
sleep 2
v4l2-ctl -d "$DEV" --set-ctrl=auto_exposure=1 2>/dev/null || true   # manual mode; the name varies by camera
v4l2-ctl -d "$DEV" --set-ctrl=exposure_time_absolute="$RAW"
python3 "$HERE/delay.py" "$DEV" "$CHIP" "$LINE" $((RAW * 100)) --trials "$TRIALS"
