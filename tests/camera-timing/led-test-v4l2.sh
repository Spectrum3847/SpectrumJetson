#!/usr/bin/env bash
# LED camera-delay test through uvcvideo (the Jetson / PhotonVision path): measures end of exposure -> the frame's
# V4L2 buffer timestamp, i.e. exactly what SPECTRUM_CAMERA_DELAY_US must be (with hwtimestamps=1 or =0).
#   led-test-v4l2.sh /dev/videoN LED OUTDIR [SECS]
#     LED: /dev/gpiochipN:LINE (an LED + 330 ohm on a header GPIO; `gpioinfo` lists lines), or a sysfs file taking
#          1/0 (/sys/class/leds/X/brightness with its trigger set to none, /sys/class/gpio/gpioN/value).
#     Env: EXPOSURE (default 10 = ~1 ms), GAIN (64), INVERT=1 if writing 1 turns the LED off.
#   Then (laptop, Pillow): led_analyze.py OUTDIR/frames.mjpeg OUTDIR/pulses.csv [--invert if INVERT=1]
#     "exposure end -> first data packet" in its output is here exposure end -> BUFFER TIMESTAMP (= the delay).
# PhotonVision must be stopped (it holds the cameras). The camera must see the LED, still, ~10-20 cm away.
# Holds /tmp/camera.lock if that file exists (the SystemCore bench convention).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
V4=${V4L2_TS:-$HERE/out/v4l2_ts}
[[ -x $V4 ]] || V4=$HERE/v4l2_ts
dev=${1:?/dev/videoN} led=${2:?LED} out=${3:?OUTDIR} secs=${4:-15}
mkdir -p "$out"
if [[ -e /tmp/camera.lock ]]; then
  exec 9>/tmp/camera.lock
  flock -w 180 9 || { echo "camera lock busy" >&2; exit 1; }
fi
v4l2-ctl -d "$dev" -c auto_exposure=1,exposure_time_absolute="${EXPOSURE:-10}",gain="${GAIN:-64}"
echo "uvcvideo hwtimestamps=$(cat /sys/module/uvcvideo/parameters/hwtimestamps 2>/dev/null || echo ?)" | tee "$out/driver.txt"
inv=()
[[ ${INVERT:-0} == 1 ]] && inv=(--led-invert)
sudo "$V4" "$dev" 1280x800 120 "$secs" "$out/frames.csv" --frames $((secs * 125)) "$out/frames.mjpeg" \
  --led "$led" 0 0.05 166 4 300 "$out/pulses.csv" "${inv[@]}"
echo "done: $out (analyze with led_analyze.py; the camera can move)"
