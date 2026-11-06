#!/usr/bin/env bash
# Exposure x gain through sc-vision itself (its CSV: margin, pose, CPU per frame, latency), short runs, ON THE PI.
#   scvsweep.sh OUT SECS "EXPOSURES" "GAINS" [extra sc-vision args]
# Holds /tmp/camera.lock; sc-vision sets exposure/gain itself; gamma 100, backlight 0, sharpness 1 set first.
set -uo pipefail
OUT=${1:?OUT}
SECS=${2:-10}
EXPS=${3:-"3 5 10"}
GAINS=${4:-"64 96 128"}
shift 4 || true
SCV=${SCV:-/opt/sc-vision/bin/sc-vision}
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 300 9 || { echo "camera lock busy" >&2; exit 1; }
orig=$(v4l2-ctl -d /dev/video0 -C exposure_time_absolute,gain | tr -d ' ')
trap 'for kv in $orig; do v4l2-ctl -d /dev/video0 -c "${kv/:/=}"; done' EXIT  # put the camera back
v4l2-ctl -d /dev/video0 -c sharpness=1 -c gamma=100 -c backlight_compensation=0
for e in $EXPS; do
  for g in $GAINS; do
    n=e${e}_g${g}
    sudo "$SCV" --cpu 3 --fifo 40 --pkts 2 --exposure "$e" --gain "$g" --min-tag 32 --calib /opt/sc-vision/etc/calib.json \
      --secs "$SECS" --csv "$OUT/$n.csv" "$@" >"$OUT/$n.log" 2>&1 </dev/null
    python3 - "$OUT/$n.csv" "$n" <<'EOF'
import csv, statistics as st, sys
r = list(csv.DictReader(open(sys.argv[1])))[30:]
def p(v, q):
    v = sorted(v); return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")
t = [x for x in r if x["ntags"] not in ("0", "")]
f = lambda k: [float(x[k]) for x in t if x[k]]
lat = [(int(x["t_pose"]) - int(x["t_first"])) / 1e6 for x in r]
if len(t) < 2:
    print(f"{sys.argv[2]:9s} frames {len(r)} tags {len(t)}  (KB {p([float(x['bytes']) for x in r], .5) / 1024:.0f})")
    sys.exit(0)
print(f"{sys.argv[2]:9s} frames {len(r)} tags {100 * len(t) / max(1, len(r)):5.1f}% margin p5/p50 {p(f('margin'), .05):6.1f} {p(f('margin'), .5):6.1f} "
      f"tz sd {1000 * st.pstdev(f('tz')):.2f} mm tx sd {1000 * st.pstdev(f('tx')):.2f} mm | KB {p(f('bytes'), .5) / 1024:.0f} "
      f"cpu ms {p([float(x['frame_cpu_us']) / 1e3 for x in r], .5):.2f} | first->pose p50/p99 {p(lat, .5):.2f}/{p(lat, .99):.2f}")
EOF
  done
done
