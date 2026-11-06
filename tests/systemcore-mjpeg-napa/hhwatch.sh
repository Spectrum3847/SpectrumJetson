#!/usr/bin/env bash
# Attach independent measurements to the builder's head-to-head runs, ON THE PI, without touching the camera:
# for every new "HH-RUN <name> START <time> <secs>" line in ~/shared/BUILDER-LOG.md, run (for secs - 2 s)
# nt_check (rawBytes as a PhotonLib client sees it) and topcpu.py (exact per-thread CPU), plus pvconfig.py.
#   hhwatch.sh OUT [CAMERA]        stops after 2 h or when ~/shared/HH-DONE exists
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
CAM=${2:-thrifty}
LOG=$HOME/shared/BUILDER-LOG.md
mkdir -p "$OUT"
seen=$(grep -c "HH-RUN .* START" "$LOG")
end=$(($(date +%s) + 7200))
while [[ $(date +%s) -lt $end && ! -e $HOME/shared/HH-DONE ]]; do
  n=$(grep -c "HH-RUN .* START" "$LOG")
  if ((n > seen)); then
    line=$(grep "HH-RUN .* START" "$LOG" | sed -n "${n}p")
    seen=$n
    name=$(echo "$line" | awk '{for (i = 1; i <= NF; i++) if ($i == "HH-RUN") print $(i + 1)}')
    secs=$(echo "$line" | awk '{print $NF}')
    [[ $secs =~ ^[0-9]+$ ]] || secs=20
    m=$((secs > 6 ? secs - 3 : secs))
    echo "$(date +%T) attach $name for $m s" | tee -a "$OUT/watch.log"
    "$HOME/bench/bin/nt_check" --camera "$CAM" --secs "$m" >"$OUT/$name.nt" 2>&1 &
    sudo python3 "$HERE/topcpu.py" "$m" 15 >"$OUT/$name.cpu" 2>&1 &
    sudo python3 "$HERE/pvconfig.py" >"$OUT/$name.pvconfig" 2>&1
    v4l2-ctl -d ${SCMN_THR:-/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0} -C exposure_time_absolute,gain,sharpness,gamma,backlight_compensation,brightness \
      >"$OUT/$name.camera" 2>&1
    wait
    { echo "== $name"; grep -E "results in|capture ->|bestCameraToTarget\.(x|y|z) |targets\[0\]\.(yaw|pitch|area|fiducialId) " "$OUT/$name.nt"; head -3 "$OUT/$name.cpu"; } >>"$OUT/summary.txt"
  fi
  sleep 1
done
