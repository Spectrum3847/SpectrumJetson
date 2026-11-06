#!/usr/bin/env bash
# Independent CPU-governor A/B for sc-vision, ON THE PI, under /tmp/camera.lock (runtime only; restores the
# governor it found). Per run: sc-vision CSV (latency, frame CPU), exact per-thread CPU (topcpu.py), sysmon
# (temperature, MHz, throttle flags) and the under-voltage count before/after.
#   govab.sh OUT [SECS] [MIN_TAG] [GOVERNORS]       e.g. govab.sh ~/bench/results/gov 30 16 "ondemand performance"
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
SECS=${2:-30}
MIN=${3:-16}
GOVS=${4:-"ondemand performance"}
SCV=${SCV:-/opt/sc-vision/bin/sc-vision}
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
orig=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
trap 'echo "$orig" | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor >/dev/null; echo "governor restored: $orig"' EXIT
v4l2-ctl -d /dev/video0 -c sharpness=1 -c gamma=100 -c backlight_compensation=0 2>/dev/null
for g in $GOVS; do
  echo "$g" | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor >/dev/null
  uv0=$(sudo dmesg | grep -c "Undervoltage detected")
  sudo "$SCV" --cpu 3 --fifo 40 --exposure 2 --gain 128 --min-tag "$MIN" --calib /opt/sc-vision/etc/calib.json \
    --secs "$SECS" --csv "$OUT/$g.csv" >"$OUT/$g.log" 2>&1 </dev/null &
  sleep 3
  sudo python3 "$HERE/sysmon.py" "$OUT/$g.sysmon.csv" --secs "$((SECS - 6))" >/dev/null &
  sudo python3 "$HERE/topcpu.py" "$((SECS - 6))" 5 >"$OUT/$g.cpu"
  wait
  uv1=$(sudo dmesg | grep -c "Undervoltage detected")
  python3 - "$OUT/$g.csv" "$OUT/$g.sysmon.csv" "$g" "$((uv1 - uv0))" "$(head -3 "$OUT/$g.cpu" | tail -2 | tr -s ' ' | tr '\n' ';')" <<'EOF'
import csv, sys
r = list(csv.DictReader(open(sys.argv[1])))[30:]
s = list(csv.DictReader(open(sys.argv[2])))
def p(v, q):
    v = sorted(v); return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")
lat = [(int(x["t_pose"]) - int(x["t_first"])) / 1e6 for x in r]
tail = [(int(x["t_pose"]) - int(x["t_eof_reap"])) / 1e6 for x in r]
cpu = [float(x["frame_cpu_us"]) / 1e3 for x in r]
print(f"{sys.argv[3]:12s} {len(r)} frames  first->pose {p(lat,.5):.2f}/{p(lat,.95):.2f}/{p(lat,.99):.2f}  tail {p(tail,.5):.3f}/{p(tail,.95):.3f}/{p(tail,.99):.3f}"
      f"  frame CPU {p(cpu,.5):.2f}/{p(cpu,.95):.2f}/{p(cpu,.99):.2f} ms  temp max {max(float(x['temp_c']) for x in s):.1f} C"
      f"  MHz cpu3 p50 {p([float(x['mhz3']) for x in s],.5):.0f}  throttle {sorted(set(x['throttled'] for x in s))}  under-voltage +{sys.argv[4]}")
print("   ", sys.argv[5])
EOF
done
