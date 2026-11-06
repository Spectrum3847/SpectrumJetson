#!/usr/bin/env bash
# EXTRA_CMD for nativecam.sh: the frame policy's half scale vs full scale on one camera in the same PV session:
# /photonvision/CAMERA/input/scale published 1 then 2 (nt_check --pub, SECS each) with per-thread CPU meanwhile.
#   EXTRA_CMD="bash scale-cpu.sh CAMERA [SECS]"   (ORDER="2 1": half scale first)
set -uo pipefail
CAM=${1:?camera}
SECS=${2:-8}
for s in ${ORDER:-1 2}; do
  echo "== input/scale = $s"
  sudo python3 "$HOME/bench/scmn/topcpu.py" $((SECS - 1)) 5 >"/dev/shm/scale-cpu.$s" &
  "$HOME/bench/bin/nt_check" --camera "$CAM" --secs "$SECS" --dump 0 --pub scale="$s" 2>&1 |
    grep -E "results in|capture ->|health/scale|scaledFrames"
  wait
  sed -n 2,5p "/dev/shm/scale-cpu.$s" | sed 's/, irq.*//'
  rm -f "/dev/shm/scale-cpu.$s"
done
