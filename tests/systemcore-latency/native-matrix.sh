#!/bin/bash
# A set of sc-vision live runs on the SystemCore (run.sh native for each), summarized in one table.
#   native-matrix.sh SECS NAME:ARGS... e.g.  native-matrix.sh 20 "base:--cpu 3" "whole:--cpu 3 --whole"
# Each NAME:ARGS is one run; EXPOSURE_MS (default 5.0) for the mid-exposure estimate. Results under OUT (run.sh).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
secs=${1:?secs}; shift
CAL=${CAL:-$HOME/builder/sc-vision/cal.json}
for spec in "$@"; do
  name=${spec%%:*}; args=${spec#*:}
  # shellcheck disable=SC2086
  "$HERE/run.sh" native "$secs" "$name" $args --calib "$CAL" > /tmp/native-matrix-$name.txt 2>&1
  t=$(grep -E "^TOTAL mid-exposure -> pose" /tmp/native-matrix-$name.txt | awk '{print $(NF-2)"/"$(NF-1)"/"$NF}')
  tail_=$(grep -E "^TAIL last packet -> pose" /tmp/native-matrix-$name.txt | awk '{print $(NF-2)"/"$(NF-1)"/"$NF}')
  cpu=$(grep -E "^vision thread CPU" /tmp/native-matrix-$name.txt | sed 's/vision thread CPU: //')
  sys=$(grep -o -E "cpu_busy_pct_of_4 [0-9.]+" /tmp/native-matrix-$name.txt | awk '{print $2}')
  tags=$(grep -E "^frames with a tag" /tmp/native-matrix-$name.txt | sed 's/frames with a tag: //')
  fps=$(grep -o -E "\([0-9.]+ fps processed\)" /tmp/native-matrix-$name.txt)
  printf '%-14s mid->pose %-22s tail %-20s %s | sys %s%% of 4 | tags %s %s\n' "$name" "$t" "$tail_" "$cpu" "$sys" "$tags" "$fps"
done
