#!/usr/bin/env bash
# Printed distance-test tags (ids 10-15 at 1/2..1/12 scale next to tag 3), ON THE PI, under /tmp/camera.lock:
#   tagdist.sh OUT thr|swy [SECS]
# 1. 240-frame capture through uvcvideo -> scmn_bench pertag at min 16/22/32 (per id: seen %, side px, decision
#    margin, centre jitter px; NAPA CPU per frame).
# 2. sc-vision live per min_tag (SECS each, --nt): nt_check per id (seen %, side px, range and its sd, rotation
#    sd, ambiguity), app CSV latency/tail/frame CPU, exact per-thread CPU (topcpu.py).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
CAM=${2:?thr|swy}
SECS=${3:-20}
B=${SCMN_BIN:-$HOME/bench/bin}
SCV=${SCV:-/opt/sc-vision/bin/sc-vision}
case $CAM in
  thr) DEV=/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0; SEL="--usb 1bcf:28c5 --exposure 2 --gain 128 --gamma 100 --backlight 0" ;;
  swy) DEV=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0; SEL="--usb 0bda:3035" ;;
  *) echo "thr|swy" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor), under-voltage $(sudo dmesg | grep -c 'Undervoltage detected'), temp $(cat /sys/class/thermal/thermal_zone0/temp)"
v4l2-ctl -d "$DEV" -C exposure_time_absolute,gain,gamma,sharpness,backlight_compensation | tr '\n' ' '
echo
v4l2-ctl -d "$DEV" --set-fmt-video=width=1280,height=800,pixelformat=MJPG --stream-mmap=4 --stream-count=240 \
  --stream-to="$OUT/$CAM.mjpeg" >/dev/null 2>&1 &
cap=$!
( sleep 20 && kill "$cap" 2>/dev/null && echo "capture hung (no frames in 20 s): stopped" >&2 ) &
wait "$cap"
[[ -s $OUT/$CAM.mjpeg ]] || { echo "no frames captured: camera not streaming 1280x800" >&2; exit 1; }
python3 "$HERE/mjpeg2rewind.py" "$OUT/$CAM.mjpeg" "$OUT/$CAM" --cam cam >/dev/null && rm -f "$OUT/$CAM.mjpeg"
"$B/scmn_bench" pertag "$OUT/$CAM" --cpu 3 --mintags 16,22,32
for m in 16 22 32; do
  n=$CAM-min$m
  # shellcheck disable=SC2086
  sudo "$SCV" $SEL --cpu 3 --fifo 40 --pkts 2 --min-tag "$m" --calib /opt/sc-vision/etc/calib.json --nt 127.0.0.1 \
    --name thrifty --secs "$((SECS + 6))" --csv "$OUT/$n.csv" >"$OUT/$n.log" 2>&1 </dev/null &
  sleep 4
  sudo python3 "$HERE/topcpu.py" "$SECS" 3 >"$OUT/$n.cpu" &
  "$HOME/bench/bin/nt_check" --camera thrifty --secs "$SECS" --dump 0 2>&1 | grep -v -E '^NT:|topic /photon' >"$OUT/$n.nt"
  wait
  echo "== sc-vision $CAM min_tag $m"
  grep -E "results in|capture ->|per tag id|^  id " "$OUT/$n.nt"
  sed -n 2p "$OUT/$n.cpu"
  python3 - "$OUT/$n.csv" <<'EOF'
import csv, sys
r = list(csv.DictReader(open(sys.argv[1])))[30:]
p = lambda v, q: sorted(v)[min(len(v) - 1, int(q * (len(v) - 1) + .5))] if v else float("nan")
lat = [(int(x["t_pose"]) - int(x["t_first"])) / 1e6 for x in r]
tail = [(int(x["t_pose"]) - int(x["t_eof_reap"])) / 1e6 for x in r]
cpu = [float(x["frame_cpu_us"]) / 1e3 for x in r]
napa = [float(x["napa_cpu_us"]) / 1e3 for x in r]
print(f"  {len(r)} frames  first->pose {p(lat,.5):.2f}/{p(lat,.95):.2f}/{p(lat,.99):.2f}  tail {p(tail,.5):.3f}/{p(tail,.95):.3f}/{p(tail,.99):.3f}"
      f"  frame CPU {p(cpu,.5):.2f}/{p(cpu,.95):.2f} ms  NAPA {p(napa,.5):.2f}/{p(napa,.95):.2f} ms")
EOF
done
