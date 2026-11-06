#!/usr/bin/env bash
# LED camera-delay test on the SystemCore/Pi: pulses the Pi's green ACT LED (SoC GPIO, gpio-521 "2712_STAT_LED")
# at swept delays after each frame's first USB packet while the camera, facing the LED, streams 1280x800.
#   led-test.sh thr|swyft OUTDIR [SECS]         then on the laptop: led_analyze.py OUTDIR/frames.mjpeg OUTDIR/pulses.csv
# Shortest real exposure: Thriftiest setting 3 (~0.3 ms), Swyft 2 (~0.2 ms); gain 128. Sweep: 0..8.3 ms after a
# frame's first packet in 0.05 ms steps, a 100 us pulse every 4th frame. The ACT LED's trigger is set to none for
# the run and restored after. Holds /tmp/camera.lock.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
UT=${UVC_TIMING:-$HERE/out/uvc_timing}
[[ -x $UT ]] || UT=$HOME/fw/uvc_timing
cam=${1:?thr or swyft} out=${2:?OUTDIR} secs=${3:-20}
case $cam in
  thr) id=1bcf:28c5 dev=/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0 exp=${EXPOSURE:-3} ;;
  swyft) id=0bda:3035 dev=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0 exp=${EXPOSURE:-2} ;;
  *) echo "camera: thr or swyft" >&2; exit 2 ;;
esac
led=/sys/class/leds/ACT
mkdir -p "$out"
exec 9>/tmp/camera.lock
flock -w 180 9 || { echo "camera lock busy" >&2; exit 1; }
trig=$(grep -o '\[[^]]*\]' "$led/trigger" | tr -d '[]')
restore() { echo "$trig" | sudo tee "$led/trigger" >/dev/null; }
trap restore EXIT
echo none | sudo tee "$led/trigger" >/dev/null
v4l2-ctl -d "$dev" -c auto_exposure=1,exposure_time_absolute="$exp",gain=128
if [[ ${LOCATE:-0} == 1 ]]; then
  # Aiming aid: 1 s with the LED steadily on, 1 s off (on.mjpeg / off.mjpeg); led_analyze.py --locate finds it.
  echo 1 | sudo tee "$led/brightness" >/dev/null
  sudo "$UT" "$id" 1280x800 120 1 "$out/on.csv" --frames 30 "$out/on.mjpeg" 2>&1 | tail -1
  echo 0 | sudo tee "$led/brightness" >/dev/null
  sleep 1
  sudo "$UT" "$id" 1280x800 120 1 "$out/off.csv" --frames 30 "$out/off.mjpeg" 2>&1 | tail -1
  exit 0
fi
nframes=$((secs * 125))
sudo "$UT" "$id" 1280x800 120 "$secs" "$out/packets.csv" --frames "$nframes" "$out/frames.mjpeg" \
  --led "$led/brightness" 0 0.05 166 4 100 "$out/pulses.csv" 2>&1 | tail -2
echo "camera $cam exposure $exp; trigger restored to $trig"
