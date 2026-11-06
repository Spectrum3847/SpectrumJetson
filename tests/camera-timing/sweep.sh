#!/usr/bin/env bash
# Camera characterization runs on the SystemCore/Pi (or a Jetson), each one inside flock /tmp/camera.lock.
#   sweep.sh exposure DEV VID:PID WxH FPS OUTDIR GAIN EXPOSURE...   4 s per exposure setting: eN.csv + eN.mjpeg
#   sweep.sh modes    VID:PID TAG OUTDIR FPS:WxH...                 2 s per mode: TAG-WxH-FPS.csv/.mjpeg
# DEV: the camera's V4L2 node, best /dev/v4l/by-id/... (node numbers swap across reboots). GAIN "-" leaves it.
# Env: UVC_TIMING (default: uvc_timing next to this script, else ~/fw/uvc_timing), NSAVE frames kept per
# exposure (480), ALT streaming alt setting (default: the camera's request), LOCK (/tmp/camera.lock).
# Only standard V4L2 controls and UVC probe/commit are used. Camera controls are left as the last run set them.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
UT=${UVC_TIMING:-$HERE/out/uvc_timing}
[[ -x $UT ]] || UT=$HOME/fw/uvc_timing
LOCK=${LOCK:-/tmp/camera.lock}
alt=()
[[ -n ${ALT:-} ]] && alt=(--alt "$ALT")

exposure() {
  local dev=$1 id=$2 wh=$3 fps=$4 out=$5 gain=$6
  shift 6
  mkdir -p "$out"
  v4l2-ctl -d "$dev" -c auto_exposure=1
  [[ $gain != - ]] && v4l2-ctl -d "$dev" -c gain="$gain"
  for e in "$@"; do
    v4l2-ctl -d "$dev" -c exposure_time_absolute="$e"
    sudo "$UT" "$id" "$wh" "$fps" 4 "$out/e$e.csv" --frames "${NSAVE:-480}" "$out/e$e.mjpeg" "${alt[@]}" 2>&1 | tail -1
    sleep 1
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e $dev ]] && break; sleep 0.5; done
  done
}

modes() {
  local id=$1 tag=$2 out=$3
  shift 3
  mkdir -p "$out"
  for m in "$@"; do
    local fps=${m%%:*} wh=${m#*:}
    sudo "$UT" "$id" "$wh" "$fps" 2 "$out/$tag-$wh-$fps.csv" --frames 20 "$out/$tag-$wh-$fps.mjpeg" "${alt[@]}" 2>&1 |
      grep -E "uvc:|uvc_timing" || true
    sleep 1
  done
}

cmd=${1:-}
shift || true
case $cmd in
  exposure | modes)
    exec 9>"$LOCK"
    flock -w 180 9 || { echo "camera lock busy" >&2; exit 1; }
    "$cmd" "$@"
    ;;
  *)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
