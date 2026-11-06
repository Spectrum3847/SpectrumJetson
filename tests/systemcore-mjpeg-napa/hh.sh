#!/usr/bin/env bash
# Head-to-head: native sc-vision vs PhotonVision on the same camera settings, ON THE PI.
#   hh.sh OUT SECS native MIN_TAG [sc-vision args...]
#   hh.sh OUT SECS pv NAME [VAR=value ...]          (uses the builder's tests/systemcore-latency/run.sh pv)
# Camera settings (both): CAM_EXPOSURE (0.1 ms units, default 2), CAM_GAIN (128), sharpness 1 (lowest),
# gamma 100, backlight_compensation 0 - applied with v4l2-ctl before the run (the camera keeps them while
# powered; sc-vision's --exposure/--gain are passed too). CPU: exact per-thread schedstat over the whole system
# during the run (topcpu.py: ALL threads % of 4 cores, per core, top threads), not /proc/stat (it aliases).
# Native latency: the app's CSV; first packet -> pose, + the kernel xhci trace cross-check (scvtrace.py).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
SECS=${2:?SECS}
MODE=${3:?native|pv}
shift 3
mkdir -p "$OUT"
EXP=${CAM_EXPOSURE:-2}
GAIN=${CAM_GAIN:-128}
SCV=${SCV:-$HOME/builder/sc-vision/sc-vision}
CAL=${SCV_CAL:-$HOME/builder/sc-vision/cal.json}
T=/sys/kernel/tracing
setcam() {
  [[ -e /dev/video0 ]] || return 0
  v4l2-ctl -d /dev/video0 -c auto_exposure=1 -c exposure_time_absolute="$EXP" -c gain="$GAIN" -c sharpness=1 \
    -c gamma=100 -c backlight_compensation=0 2>&1 | grep -v '^$'
  v4l2-ctl -d /dev/video0 -C exposure_time_absolute,gain,sharpness,gamma,backlight_compensation,brightness |
    tr '\n' ' ' >"$OUT/camera.txt"
}
if [[ $MODE == native ]]; then
  MIN=${1:?MIN_TAG}
  shift
  name=native-min$MIN
  exec 9>/tmp/camera.lock
  flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
  setcam
  sudo sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 65536 > $T/buffer_size_kb;
    echo 0 > $T/events/enable; echo 1 > $T/events/xhci-hcd/xhci_urb_giveback/enable; echo 1 > $T/tracing_on"
  sudo "$SCV" --secs "$SECS" --csv "$OUT/$name.csv" --cpu 3 --calib "$CAL" --exposure "$EXP" --gain "$GAIN" \
    --min-tag "$MIN" "$@" >"$OUT/$name.log" 2>&1 </dev/null &
  sleep 4
  sudo python3 "$HERE/topcpu.py" "$((SECS - 8))" 12 >"$OUT/$name.cpu"
  wait
  sudo sh -c "echo 0 > $T/tracing_on; cat $T/trace > /tmp/hh.trace; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
  mv /tmp/hh.trace "$OUT/$name.trace"
  [[ -e /dev/video0 ]] || for d in /sys/bus/usb/devices/*:1.0; do
    [[ $(cat "${d%:*}/idVendor" 2>/dev/null) == 1bcf ]] && basename "$d" | sudo tee /sys/bus/usb/drivers/uvcvideo/bind >/dev/null
  done
  {
    echo "== $name camera: $(cat "$OUT/camera.txt")"
    tail -1 "$OUT/$name.log"
    python3 "$HERE/scvtrace.py" "$OUT/$name.csv" "$OUT/$name.trace" | tail -4
    head -4 "$OUT/$name.cpu"
  } | tee "$OUT/$name.summary"
else
  NAME=${1:?NAME}
  shift
  RUN=${PV_RUN:-$HOME/builder/tests/systemcore-latency/run.sh}
  # PV applies its pipeline's own camera settings at start: they must be set in PV (builder) to match.
  # run.sh waits 45 s for PV to start, then records SECS: measure exact CPU inside that window.
  (sleep 50 && sudo python3 "$HERE/topcpu.py" "$((SECS - 10))" 12 >"$OUT/$NAME.cpu") &
  OUT=$OUT "$RUN" pv "$SECS" "$NAME" "$@" 2>&1 | tail -25 | tee "$OUT/$NAME.summary"
  wait
  python3 "$HERE/pvcsv.py" "$OUT/$NAME.csv" | tee -a "$OUT/$NAME.summary"
  head -4 "$OUT/$NAME.cpu" | tee -a "$OUT/$NAME.summary"
fi
