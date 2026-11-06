#!/bin/bash
# CPU governor A/B for sc-vision on the SystemCore (Pi 5: one cpufreq policy for all 4 cores, so the governor is
# system-wide). Runtime sysfs only; restores the original governor on exit. Short runs.
#   governor-ab.sh [SECS] [MINTAGS]     default 30 s, "16 32"
# Per run: sc-vision's own per-frame CSV (latency, per-frame thread CPU), the process's CPU (run.sh), max temperature,
# cpu0 frequency samples, and the under-voltage count in dmesg before/after.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
secs=${1:-30}
mins=${2:-16 32}
P=/sys/devices/system/cpu/cpufreq/policy0
orig=$(cat $P/scaling_governor)
trap 'echo "$orig" | sudo -n tee $P/scaling_governor >/dev/null; echo "governor restored: $(cat $P/scaling_governor)"' EXIT
export SC_VISION_BIN=${SC_VISION_BIN:-/opt/sc-vision/bin/sc-vision} EXPOSURE_MS=${EXPOSURE_MS:-0.2}
NAT=${NAT:---cpu 3 --fifo 40 --pkts 2 --exposure 2 --gain 128 --gamma 100 --backlight 0}
CAL=${CAL:-/opt/sc-vision/etc/calib.json}
uv() { dmesg | grep -ci undervoltage; }
for m in $mins; do
  for g in ondemand performance; do
    echo "$g" | sudo -n tee $P/scaling_governor >/dev/null
    name=gov-$g-m$m
    u0=$(uv)
    (for _ in $(seq 1 $((secs + 8))); do cat $P/scaling_cur_freq; cat /sys/class/thermal/thermal_zone0/temp; sleep 1; done) \
      > "/tmp/$name.mon" 2>/dev/null &
    mon=$!
    # shellcheck disable=SC2086
    "$HERE/run.sh" native "$secs" "$name" $NAT --min-tag "$m" --calib "$CAL" > "/tmp/$name.txt" 2>&1
    kill "$mon" 2>/dev/null
    u1=$(uv)
    t=$(grep -E "^first USB packet -> pose" "/tmp/$name.txt" | awk '{print $(NF-2)"/"$(NF-1)"/"$NF}')
    tl=$(grep -E "^TAIL last packet -> pose" "/tmp/$name.txt" | awk '{print $(NF-2)"/"$(NF-1)"/"$NF}')
    fc=$(grep -E "^CPU frame_cpu_us" "/tmp/$name.txt" | awk '{print $(NF-2)"/"$(NF-1)"/"$NF}')
    core=$(grep -E "^vision thread CPU" "/tmp/$name.txt" | sed 's/vision thread CPU: //; s/ (mean.*//')
    proc=$(grep -o -E "proc_pct_of_1 [0-9.]+" "/tmp/$name.txt" | awk '{print $2}')
    freqs=$(awk 'NR%2==1' "/tmp/$name.mon" | sort -n | uniq -c | awk '{printf "%sx%d ", $1, $2/1000}')
    tmax=$(awk 'NR%2==0' "/tmp/$name.mon" | sort -n | tail -1 | awk '{printf "%.1f", $1/1000}')
    printf '%-22s first->pose %s | tail %s | frame CPU ms %s | thread %s | proc %s%% | max %s C | cpu0 MHz %s| under-voltage +%d\n' \
      "$name" "$t" "$tl" "$fc" "$core" "$proc" "$tmax" "$freqs" $((u1 - u0))
  done
done
