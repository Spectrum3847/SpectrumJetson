#!/usr/bin/env bash
# PhotonVision's normal (uvcvideo) path, measured as PhotonLib sees it, for stock vs patched uvcvideo, ON THE PI.
#   pvpath.sh OUT NAME [SECS]
# Holds /tmp/camera.lock. Starts photonvision.service as configured (no config change), waits for it, then for SECS:
# nt_check (capture -> publish / received, decoded output), topcpu.py (exact per-thread CPU), sysmon (temps,
# MHz, throttle flags) and an ftrace of xhci_urb_giveback (URB completion interval and bytes per URB on the
# camera's iso endpoint). Records the uvcvideo module (path, vermagic, srcversion, parameters), the governor,
# the camera controls and the under-voltage count before/after. Leaves PhotonVision as it found it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
NAME=${2:?NAME}
SECS=${3:-25}
T=/sys/kernel/tracing
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
was=$(systemctl is-active photonvision)
R=$OUT/$NAME
{
  echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  echo "uvcvideo: $(modinfo -n uvcvideo 2>/dev/null) | $(modinfo -F vermagic uvcvideo 2>/dev/null) | srcversion $(cat /sys/module/uvcvideo/srcversion 2>/dev/null)"
  grep -H . /sys/module/uvcvideo/parameters/* 2>/dev/null | sed 's|/sys/module/uvcvideo/parameters/||'
  echo "kernel $(uname -r); under-voltage before $(sudo dmesg | grep -c 'Undervoltage detected')"
  sudo dmesg | grep -i -E "uvcvideo|uvc" | tail -5
} >"$R.env"
sudo systemctl start photonvision
sleep 45
v4l2-ctl -d /dev/video0 -C exposure_time_absolute,gain,gamma,sharpness,backlight_compensation,brightness >"$R.camera" 2>&1
sudo sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 32768 > $T/buffer_size_kb;
  echo 0 > $T/events/enable; echo 1 > $T/events/xhci-hcd/xhci_urb_giveback/enable; echo 1 > $T/tracing_on"
sudo python3 "$HERE/sysmon.py" "$R.sysmon.csv" --secs "$SECS" >/dev/null &
sudo python3 "$HERE/topcpu.py" "$SECS" 10 >"$R.cpu" &
"$HOME/bench/bin/nt_check" --camera thrifty --secs "$SECS" 2>&1 | grep -v -E '^NT:|topic /photon' >"$R.nt"
wait
sudo sh -c "echo 0 > $T/tracing_on; head -c 20000000 $T/trace > /tmp/pvpath.trace; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
mv /tmp/pvpath.trace "$R.trace"
[[ $was == active ]] || sudo systemctl stop photonvision
echo "under-voltage after $(sudo dmesg | grep -c 'Undervoltage detected')" >>"$R.env"
python3 - "$R.trace" <<'EOF' >"$R.urb"
import re, sys
rx = re.compile(r"\s(\d+\.\d+): xhci_urb_giveback: (\S+) ep(\d+)in-isoc: urb \S+ pipe \d+ slot \d+ length (\d+)/(\d+)")
ev = {}
for ln in open(sys.argv[1]):
    m = rx.search(ln)
    if m:
        ev.setdefault((m.group(2), m.group(3)), []).append((float(m.group(1)), int(m.group(4)), int(m.group(5))))
for k, v in ev.items():
    iv = sorted((b[0] - a[0]) * 1e3 for a, b in zip(v, v[1:]))
    by = sorted(x[1] for x in v if x[1] > 0)
    p = lambda s, q: s[min(len(s) - 1, int(q * (len(s) - 1)))] if s else float("nan")
    print(f"dev {k[0]} ep{k[1]}: {len(v)} URBs, interval p50 {p(iv, .5):.3f} ms, buffer {v[0][2]} B, data bytes/URB p50 {p(by, .5)}")
EOF
{
  echo "== $NAME ($(head -1 "$R.env"))"
  cat "$R.urb"
  grep -E "results in|capture ->" "$R.nt"
  head -3 "$R.cpu"
  python3 - "$R.sysmon.csv" <<'EOF'
import csv, sys
s = list(csv.DictReader(open(sys.argv[1])))
print(f"temp max {max(float(x['temp_c']) for x in s):.1f} C, throttle {sorted(set(x['throttled'] for x in s))}")
EOF
  tail -1 "$R.env"
} | tee -a "$OUT/summary.txt"
