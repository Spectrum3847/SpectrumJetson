#!/bin/bash
# Live latency + CPU of a vision program on the SystemCore, per frame. Run ON THE SYSTEMCORE (as systemcore,
# sudo -n), the Thriftiest Cam on /dev/video0. Holds /tmp/camera.lock for the whole run.
#
#   run.sh pv SECS NAME [VAR=value ...]       PhotonVision (photonvision.service) with SPECTRUM_LATENCY_TRACE
#                                             and the given environment (systemd drop-in, removed after)
#   run.sh native SECS NAME [ARGS ...]        the native app (sc-vision), its own per-frame CSV (start-up
#                                             frames dropped by native_analyze.py); EXPOSURE_MS for the table
#
# Records ftrace (mono clock) xhci_urb_giveback / vb2_buf_done / v4l2_dqbuf for the USB stages, CPU of the
# whole system (% of 4 cores) and of the vision process (% of one core) from /proc, and the CPU clock.
# Then: python3 analyze.py OUT NAME (from tests/latency-breakdown, packet size taken from the trace).
# OUT default ~/shared/latency/<date>. Leaves PhotonVision as it was (running or stopped).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:?pv|native}; secs=${2:?secs}; name=${3:?name}; shift 3
OUT=${OUT:-$HOME/shared/latency/$(date +%Y%m%d)}
mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
T=/sys/kernel/tracing
DROPIN=/etc/systemd/system/photonvision.service.d/zz-latency.conf
exec 9>/tmp/camera.lock
flock -w 120 9 || { echo "camera busy (/tmp/camera.lock)"; exit 1; }
was_pv=$(systemctl is-active photonvision)
cleanup() {
  sudo -n sh -c "echo 0 > $T/tracing_on; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
  if [[ $mode == pv ]]; then
    sudo -n rm -f "$DROPIN"; sudo -n systemctl daemon-reload
    sudo -n systemctl stop photonvision
    [[ $was_pv == active ]] && sudo -n systemctl start photonvision
  fi
  [[ -n ${npid:-} ]] && sudo -n kill "$npid" 2>/dev/null
  true
}
trap cleanup EXIT
cpu_snap() { awk '/^cpu /{print $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat; }
proc_ticks() { sudo -n awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

sudo -n systemctl stop photonvision sc-vision-native 2>/dev/null
if [[ $mode == pv ]]; then
  { printf '[Service]\nEnvironment=SPECTRUM_LATENCY_TRACE=%s\n' "$OUT/$name.csv"
    for v in "$@"; do printf 'Environment=%s\n' "$v"; done; } | sudo -n tee "$DROPIN" >/dev/null
  sudo -n systemctl daemon-reload; sudo -n systemctl start photonvision
  sleep 45
  pid=$(systemctl show -p MainPID --value photonvision)
  sudo -n truncate -s 0 "$OUT/$name.csv" 2>/dev/null
else
  BIN=${SC_VISION_BIN:-/opt/sc-vision/bin/sc-vision}
  sudo -n "$BIN" --csv "$OUT/$name.csv" "$@" > "$OUT/$name.log" 2>&1 &
  npid=$!
  sleep 3
  pid=$(pidof sc-vision | cut -d" " -f1); pid=${pid:-$npid}
fi
since=$(date '+%Y-%m-%d %H:%M:%S')
sudo -n sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 32768 > $T/buffer_size_kb;
  echo 0 > $T/events/enable; for e in xhci-hcd/xhci_urb_giveback vb2/vb2_buf_done v4l2/v4l2_dqbuf; do echo 1 > $T/events/\$e/enable; done; echo 1 > $T/tracing_on"
read -r b0 a0 < <(cpu_snap); p0=$(proc_ticks "$pid")
sleep "$secs"
read -r b1 a1 < <(cpu_snap); p1=$(proc_ticks "$pid")
sudo -n sh -c "echo 0 > $T/tracing_on; cat $T/trace" > "$OUT/$name.trace"
freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
robot=$(systemctl is-active robot)
echo "cpu_busy_pct_of_4 $(awk -v b=$((b1 - b0)) -v a=$((a1 - a0)) 'BEGIN{printf "%.1f", 100*b/a}') proc_pct_of_1 $(awk -v p=$((p1 - p0)) -v s="$secs" 'BEGIN{printf "%.1f", p/s}') freq_khz $freq temp_c $temp robot $robot" | tee "$OUT/$name.cpu"
[[ $mode == pv ]] && journalctl -u photonvision --since "$since" --no-pager | grep -v -E 'vcgencmd|Could not parse' > "$OUT/$name.journal"
if [[ $mode == native ]]; then sudo -n kill -TERM "$npid" 2>/dev/null; wait "$npid" 2>/dev/null; npid=""; fi
sudo -n cp "$OUT/$name.csv" "$OUT/$name.csv.tmp" && sudo -n chown "$USER" "$OUT/$name.csv.tmp" && mv "$OUT/$name.csv.tmp" "$OUT/$name.csv"
if [[ $mode == pv ]]; then
  grep -h -o -E '(stream decode /dev|NAPA streaming).*' "$OUT/$name.journal" 2>/dev/null | tail -3
  python3 "$HERE/analyze.py" "$OUT" "$name" 2>&1 | tee "$OUT/$name.table"
else
  tail -2 "$OUT/$name.log"
  python3 "$HERE/native_analyze.py" "$OUT/$name.csv" --exposure-ms "${EXPOSURE_MS:-5.0}" 2>&1 | tee "$OUT/$name.table"
fi
