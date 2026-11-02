#!/usr/bin/env bash
# Per-frame latency breakdown of the live PhotonVision pipeline. Run ON THE JETSON, cameras plugged
# in, as the normal user (sudo -n).
#
#   run.sh SECS [CONDITIONS...]      (default: gpu-2 gpu-1 napa-2 napa-1)
#
# CONDITION = gpu|napa|gpuyolo|napayolo (yolo: AprilTag + Object, yolo11n, Object FPS max 30) - number of cameras (1: the second camera is deactivated in the settings DB)
# [- decoder: nvjpg (the installed default) | turbo | stream (SPECTRUM_JPEG_DECODER)], e.g. gpu-2-stream.
# Every camera's current pipeline -> AprilTagCuda (GPU detector; napa: "Tags on CPU (NAPA)", min
# tag px 16, max hamming 1). PhotonVision runs with SPECTRUM_LATENCY_TRACE (fork photonvision-103:
# per-frame CSV of decode, detect, pose, NT flush) via a systemd drop-in, while ftrace (mono clock)
# records xhci_urb_giveback, vb2_buf_done and v4l2_dqbuf for the USB/kernel stages. analyze.py joins
# them per frame. Clocks mode full during the test and back to what they were after; the settings
# DB restored; the drop-in removed; PhotonVision left STOPPED (or running, if it was). Every
# step has a hard timeout and says TIMEOUT. Not USB-disrupting (streams start/stop only).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
secs=${1:?secs}; shift
CONDITIONS=${*:-gpu-2 gpu-1 napa-2 napa-1}
CONFIG=/opt/photonvision/photonvision_config
PVDB=$CONFIG/photon.sqlite
DROPIN=/etc/systemd/system/photonvision.service.d/zz-latency-trace.conf
T=/sys/kernel/tracing
OUT=${OUT:-$ROOT/logs/latency-breakdown-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; chmod 777 "$OUT"
was_active=$(systemctl is-active photonvision)
was_mode=$(cat /etc/spectrum-clocks-mode 2>/dev/null || echo auto)
sudo -n systemctl stop photonvision
sudo -n cp "$PVDB" "$OUT/photon.sqlite.bak"
restore() {
  trap '' PIPE
  sudo -n sh -c "echo 0 > $T/tracing_on; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
  sudo -n systemctl stop photonvision
  sudo -n cp "$OUT/photon.sqlite.bak" "$PVDB"
  sudo -n rm -f "$DROPIN"; sudo -n systemctl daemon-reload
  sudo -n spectrum-clocks mode "$was_mode" >/dev/null
  [[ $was_active == active ]] && sudo -n systemctl start photonvision
  echo "restored the settings DB, clocks mode $was_mode, tracing off; PhotonVision $(systemctl is-active photonvision)"
}
trap restore EXIT
sudo -n spectrum-clocks mode full >/dev/null
v4l2-ctl -d /dev/video0 -C exposure_time_absolute > "$OUT/exposure.txt" 2>&1
cat /sys/module/uvcvideo/parameters/{urb_packets,hwtimestamps,clock} > "$OUT/uvcvideo.txt"
grep -h SPECTRUM_CAMERA_DELAY_US /etc/systemd/system/photonvision.service.d/*.conf > "$OUT/camera-delay.txt"

set_pipelines() {  # set_pipelines napa(0/1) cams(1/2) objfps(0: AprilTagCuda; N: AprilTag + Object, yolo11n)
sudo -n cp "$OUT/photon.sqlite.bak" "$PVDB"
sudo -n python3 - "$PVDB" "$1" "$2" "${3:-0}" "$CONFIG/models/yolo11n.onnx" <<'PY'
import json, sqlite3, sys
db, napa, cams, objfps, model = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
c = sqlite3.connect(db)
for i, (uid, contents) in enumerate(c.execute("select unique_name, contents from cameras order by unique_name").fetchall()):
    d = json.loads(contents)
    d["deactivated"] = i >= cams
    for p in d["pipelineSettings"]:
        if p.get("pipelineIndex") != d.get("currentPipelineIndex"): continue
        p["type"], p["pipelineType"] = "AprilTagCudaPipelineSettings", "AprilTagCuda"
        p.update(tagFpsMax=0, tagsOnCpu=napa, napaMinTagPx=16, napaMaxHamming=1, napaFarSearch=False)
        if objfps > 0:
            p["type"], p["pipelineType"] = "AprilTagObjectPipelineSettings", "AprilTagObject"
            p.update(confidence=0.5, nms=0.45, objectFpsMax=objfps, objectClasses="", objectMaxTargets=20,
                     model={"modelPath": "file://" + model, "nickname": "bench",
                            "labels": json.load(open(model[:-5] + ".json"))["labels"],
                            "resolutionWidth": 640, "resolutionHeight": 640, "family": "TENSORRT", "version": "YOLOV11"})
    c.execute("update cameras set contents=? where unique_name=?", (json.dumps(d), uid))
c.commit()
PY
}

measure() {  # measure NAME [DECODER]
  local name=$1 dec=${2:-} since
  [[ ${SCHED:-0} == 1 ]] && SCHED_EVENTS='sched/sched_switch sched/sched_wakeup' || SCHED_EVENTS=''
  { printf '[Service]\nEnvironment=SPECTRUM_LATENCY_TRACE=%s\n' "$OUT/$name.csv"
    [[ -n $dec ]] && printf 'Environment=SPECTRUM_JPEG_DECODER=%s\n' "$dec"
    for v in $EXTRA_ENV; do printf 'Environment=%s\n' "$v"; done; } | sudo -n tee "$DROPIN" >/dev/null
  sudo -n systemctl daemon-reload; sudo -n systemctl start photonvision
  sleep 40  # start-up, cameras, pipelines
  sudo -n truncate -s 0 "$OUT/$name.csv" 2>/dev/null  # drop the start-up frames
  since=$(date '+%Y-%m-%d %H:%M:%S')
  sudo -n sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 32768 > $T/buffer_size_kb;
    echo 0 > $T/events/enable; for e in xhci-hcd/xhci_urb_giveback vb2/vb2_buf_done v4l2/v4l2_dqbuf $SCHED_EVENTS; do echo 1 > $T/events/\$e/enable; done; echo 1 > $T/tracing_on"
  sudo -n tegrastats --interval 500 --logfile "$OUT/$name.tegra" &
  i0=$(awk '/xhci/{for(i=2;i<=7;i++) s+=$i} END{print s}' /proc/interrupts)
  read -r b0 a0 < <(awk '/^cpu /{print $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat)
  sleep "$secs"
  read -r b1 a1 < <(awk '/^cpu /{print $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat)
  i1=$(awk '/xhci/{for(i=2;i<=7;i++) s+=$i} END{print s}' /proc/interrupts)
  sudo -n sh -c "echo 0 > $T/tracing_on; cat $T/trace" > "$OUT/$name.trace"
  sudo -n tegrastats --stop; sleep 1
  echo "cpu_busy_pct_of_6 $(awk -v b=$((b1 - b0)) -v a=$((a1 - a0)) 'BEGIN{printf "%.1f", 100*b/a}') xhci_irq_per_s $(( (i1 - i0) / secs ))" > "$OUT/$name.cpu"
  journalctl -u photonvision --since "$since" --no-pager > "$OUT/$name.journal"
  sudo -n systemctl stop photonvision
  sudo -n cp "$OUT/$name.csv" "$OUT/$name.csv.tmp" && sudo -n chown "$USER" "$OUT/$name.csv.tmp" && mv "$OUT/$name.csv.tmp" "$OUT/$name.csv"
}

for c in $CONDITIONS; do
  IFS=- read -r kind n dec <<<"$c"
  set_pipelines "$([[ $kind == napa* ]] && echo 1 || echo 0)" "$n" "$([[ $kind == *yolo ]] && echo 30 || echo 0)"
  timeout $((secs + 120)) bash -c "$(declare -f measure); OUT=$OUT DROPIN=$DROPIN T=$T secs=$secs SCHED=${SCHED:-0} EXTRA_ENV=\"${EXTRA_ENV:-}\" measure $c $dec"; rc=$?
  (( rc == 124 )) && { echo "TIMEOUT: $c"; sudo -n systemctl stop photonvision; }
  (( rc != 0 && rc != 124 )) && echo "$c: exit $rc"
  grep -h -o -E 'stream decode /dev.*' "$OUT/$c.journal" 2>/dev/null | tail -2
  echo "== $c: $(cat "$OUT/$c.cpu" 2>/dev/null), max temp $(grep -o -E '(cpu|gpu|tj)@[0-9.]+C' "$OUT/$c.tegra" 2>/dev/null | sed 's/.*@//; s/C//' | sort -n | tail -1) C"
done
echo "logs: $OUT"
