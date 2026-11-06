#!/usr/bin/env bash
# Independent two-camera check of sc-vision (Thriftiest + Swyft), ON THE PI, under /tmp/camera.lock, performance
# governor for the run (restored): each camera alone, then both at once. Per run: first packet -> pose, tail, frame
# CPU, bad frames and interval gaps (app CSV/log), exact per-thread CPU over all threads (topcpu.py), temps and
# throttle flags (sysmon), under-voltage count and new USB/uvc kernel messages.
#   twocam.sh OUT [SECS] [MIN_TAG]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
SECS=${2:-20}
M=${3:-32}
BIN=${SCV:-/opt/sc-vision/bin/sc-vision}
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
P=/sys/devices/system/cpu/cpufreq/policy0
orig=$(cat $P/scaling_governor)
trap 'echo "$orig" | sudo tee $P/scaling_governor >/dev/null' EXIT
echo performance | sudo tee $P/scaling_governor >/dev/null
COMMON="--fifo 40 --pkts 2 --min-tag $M --calib /opt/sc-vision/etc/calib.json --secs $SECS"
TH="--usb 1bcf:28c5 --cpu 3 --exposure 2 --gain 128 --gamma 100 --backlight 0"
SW="--usb 0bda:3035 --cpu 2"
summ() {
  python3 - "$OUT/$1.csv" "$1" <<'EOF'
import csv, sys
r = list(csv.DictReader(open(sys.argv[1])))[30:]
p = lambda v, q: sorted(v)[min(len(v) - 1, int(q * (len(v) - 1) + .5))] if v else float("nan")
lat = [(int(x["t_pose"]) - int(x["t_first"])) / 1e6 for x in r]
tail = [(int(x["t_pose"]) - int(x["t_eof_reap"])) / 1e6 for x in r]
cpu = [float(x["frame_cpu_us"]) / 1e3 for x in r]
iv = [(int(b["t_first"]) - int(a["t_first"])) / 1e6 for a, b in zip(r, r[1:])]
per = p(iv, .5)
gaps = sum(1 for x in iv if x > 1.5 * per)
tags = sum(1 for x in r if x["ntags"] not in ("0", ""))
print(f"  {sys.argv[2]:9s} {len(r)} frames, period {per:.3f} ms, gaps {gaps}, tags {100 * tags / max(1, len(r)):.1f}%  "
      f"first->pose {p(lat,.5):.2f}/{p(lat,.95):.2f}/{p(lat,.99):.2f}  tail {p(tail,.5):.3f}/{p(tail,.95):.3f}/{p(tail,.99):.3f}  "
      f"frame CPU {p(cpu,.5):.2f}/{p(cpu,.95):.2f} ms")
EOF
}
run() {  # run LABEL then pairs NAME ARGS
  local label=$1
  shift
  local uv0 k0
  uv0=$(sudo dmesg | grep -c "Undervoltage detected")
  k0=$(sudo dmesg | wc -l)
  local names=()
  while (($#)); do
    local n=$1 a=$2
    shift 2
    names+=("$n")
    # shellcheck disable=SC2086
    sudo "$BIN" --csv "$OUT/$n.csv" $COMMON $a >"$OUT/$n.log" 2>&1 </dev/null &
  done
  sleep 3
  sudo python3 "$HERE/sysmon.py" "$OUT/$label.sysmon.csv" --secs "$((SECS - 6))" >/dev/null &
  sudo python3 "$HERE/topcpu.py" "$((SECS - 6))" 6 >"$OUT/$label.cpu"
  wait
  echo "== $label (governor $(cat $P/scaling_governor)): under-voltage +$(($(sudo dmesg | grep -c 'Undervoltage detected') - uv0))"
  sudo dmesg | tail -n +"$((k0 + 1))" | grep -i -E "usb|uvc|xhci" | grep -v -i undervoltage | head -5 | sed 's/^/  kernel: /'
  for n in "${names[@]}"; do summ "$n"; tail -1 "$OUT/$n.log" | grep -o "[0-9]* bad" | sed "s/^/  $n /"; done
  sed -n 1,4p "$OUT/$label.cpu" | sed 's/^/  /'
  python3 -c "import csv,sys; s=list(csv.DictReader(open(sys.argv[1]))); print(f'  temp max {max(float(x[\"temp_c\"]) for x in s):.1f} C, throttle {sorted(set(x[\"throttled\"] for x in s))}')" "$OUT/$label.sysmon.csv"
}
run th-alone th-alone "$TH" | tee -a "$OUT/summary.txt"
run sw-alone sw-alone "$SW" | tee -a "$OUT/summary.txt"
run both th-both "$TH" sw-both "$SW" | tee -a "$OUT/summary.txt"
