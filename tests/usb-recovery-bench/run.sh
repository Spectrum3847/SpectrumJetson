#!/usr/bin/env bash
# How fast do the cameras come back from each kind of USB drop? Runs tests/usb-port-glitch on each
# camera (disable, remove, reset) and tests/usb-hub-reset, ROUNDS times, and prints one line per
# drop with the seconds until the camera streamed again ("never" if it didn't within 60 s).
# Run ON THE JETSON with PhotonVision running. For tuning PhotonVision's watchdog (photonvision-84):
# a camera that doesn't come back here needs a replug before the next round.
#
# Usage: tests/usb-recovery-bench/run.sh [ROUNDS] [PORTS...]   (default: 1 round, 2.1 and 2.3)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-1}
shift || true
ports=("$@")
[[ $# -gt 0 ]] || ports=(2.1 2.3)
settle() { sleep 4; }
for r in $(seq 1 "$rounds"); do
  for kind in disable remove reset; do
    for p in "${ports[@]}"; do
      out=$("$HERE/usb-port-glitch/run.sh" "$p" "$kind" 60 2>&1)
      t=$(sed -nE 's/^ *([0-9.]+) s  streaming again by itself.*/\1/p' <<<"$out")
      echo "round $r  $kind  $p  ${t:-never}"
      settle
    done
  done
  out=$("$HERE/usb-hub-reset/run.sh" 2>&1)
  for p in "${ports[@]}"; do
    t=$(sed -nE "s/^ *([0-9.]+) s  .* \(1-$p\) streaming again.*/\1/p" <<<"$out")
    echo "round $r  hub      $p  ${t:-never}"
  done
  settle
done
