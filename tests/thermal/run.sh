#!/usr/bin/env bash
# Thermal soak: how hot does the Jetson get at its real load? Run ON THE JETSON with the cameras
# running as they would in a match. Every 10 s it logs the temperatures, board power, fan speed and
# each camera's frame rate to a CSV, and at the end prints where the temperature levelled off.
#
#   tests/thermal/run.sh [minutes] [label]    (default 40 min)  ->  ~/thermal-<label>-<time>.csv
#
# Stops early if the hottest sensor reaches STOP_C (default 92; the chip throttles at 99, and with
# FAN=off the fan guard turns the fan on at 90). The deadline is the soak plus 2 min.
set -uo pipefail
MIN=${1:-40}
LABEL=${2:-soak}
STOP_C=${STOP_C:-92}
CSV=$HOME/thermal-$LABEL-$(date +%Y%m%d-%H%M).csv
TS=/tmp/thermal-tegrastats.log

sudo -n true || { echo "needs passwordless sudo (tegrastats)"; exit 1; }
sudo tegrastats --stop 2>/dev/null
sudo rm -f "$TS"
sudo tegrastats --interval 1000 --logfile "$TS" >/dev/null 2>&1 &
trap 'sudo tegrastats --stop 2>/dev/null' EXIT

tach=$(grep -lx pwm_tach /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1)
fps() {   # each camera's processed fps, from the detector's once-a-second stats in the log
  journalctl -u photonvision --since "-3 s" --no-pager -o cat 2>/dev/null \
    | sed -En 's/^(971|detector) stats (h[0-9]*\) [0-9x]*: \([0-9]*\)\.[0-9]* calls\/s.*/\1=\2/p' | sort -u -t= -k1,1 | tr '\n' ' '
}
echo "time_s,tj_c,cpu_c,gpu_c,power_w,fan_rpm,fan_pwm,cameras_fps" > "$CSV"
echo "Logging to $CSV for $MIN min (stop at $STOP_C C)"
t0=$SECONDS end=$((SECONDS + MIN * 60))
while (( SECONDS < end )); do
  line=$(tail -1 "$TS" 2>/dev/null)
  tj=$(sed -n 's/.*tj@\([0-9.]*\)C.*/\1/p' <<<"$line")
  cpu=$(sed -n 's/.*cpu@\([0-9.]*\)C.*/\1/p' <<<"$line")
  gpu=$(sed -n 's/.*gpu@\([0-9.]*\)C.*/\1/p' <<<"$line")
  mw=$(sed -n 's/.*VDD_IN \([0-9]*\)mW.*/\1/p' <<<"$line")
  rpm=$(cat "${tach%/name}/rpm" 2>/dev/null || echo "")
  pwm=$(cat /sys/devices/platform/pwm-fan*/hwmon/hwmon*/pwm1 2>/dev/null | head -1)
  printf "%d,%s,%s,%s,%s,%s,%s,%s\n" $((SECONDS - t0)) "$tj" "$cpu" "$gpu" \
    "$(awk -v m="${mw:-0}" 'BEGIN{printf "%.2f", m/1000}')" "$rpm" "$pwm" "$(fps)" >> "$CSV"
  if [[ -n $tj ]] && awk -v t="$tj" -v s="$STOP_C" 'BEGIN{exit !(t >= s)}'; then
    echo "STOPPED: tj $tj C reached $STOP_C C after $(( (SECONDS - t0) / 60 )) min"; break
  fi
  sleep 10
done

python3 - "$CSV" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["tj_c"]]
if not rows: sys.exit("no samples")
t = [int(r["time_s"]) / 60 for r in rows]; tj = [float(r["tj_c"]) for r in rows]
pw = [float(r["power_w"]) for r in rows]
print(f"samples {len(rows)} over {t[-1]:.1f} min; tj {tj[0]:.1f} -> {tj[-1]:.1f} C (max {max(tj):.1f}); power avg {sum(pw)/len(pw):.1f} W")
last = [(a, b) for a, b in zip(t, tj) if a >= t[-1] - 10]
if len(last) > 5:
    n = len(last); mx = sum(a for a, _ in last) / n; my = sum(b for _, b in last) / n
    slope = sum((a - mx) * (b - my) for a, b in last) / max(1e-9, sum((a - mx) ** 2 for a, _ in last))
    print(f"last 10 min: {slope:+.2f} C/min" + ("  (levelled off)" if abs(slope) < 0.1 else ""))
fan = sorted({r["fan_pwm"] for r in rows})
print("fan pwm seen:", ", ".join(fan), "(0 = off; 255 = the guard turned it on)")
print("cameras at the end:", rows[-1]["cameras_fps"] or "(no detector stats in the log)")
PY
