#!/usr/bin/env bash
# Object detection (photonvision-100) bench measurements. Run ON THE JETSON. See
# docs/OBJECT-DETECTION.md and docs/TECHNICAL.md "Object detection (TensorRT)".
#
#   run.sh bench MODEL.onnx [SIZE ...]   engine timing at batch 1/2/4 (trt_yolo_bench), with
#                                        tegrastats (GPU %, VDD_IN, temperatures) per run
#   run.sh live  MODEL.onnx LABELS SECS OBJFPS [OBJFPS ...]
#                                        PhotonVision with every camera's current pipeline as
#                                        AprilTagCuda (baseline) and then as AprilTag + Object at
#                                        each OBJFPS; logs per-camera tag latency (Loop timing),
#                                        the TensorRT batch stats and tegrastats. Restores the
#                                        settings DB and leaves PhotonVision as it found it.
#                                        TAG_FPS=N sets every camera's Tag FPS max (default 0).
#                                        TAGS_ON_CPU=1: "Tags on CPU (NAPA)" in both pipeline types
#                                        (NAPA min tag px 16, max hamming 1; NAPA_FAR=1 adds its far
#                                        search). Also logs PhotonVision's CPU use (cores).
# Every step has a hard timeout and says TIMEOUT if it hits it.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BENCH=${TRT_YOLO_BENCH:-$HOME/build/gpu-detector/trt_yolo_bench}
CONFIG=/opt/photonvision/photonvision_config
PVDB=$CONFIG/photon.sqlite
OUT=${OUT:-$ROOT/logs/object-detection-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

tegra_summary() {  # tegrastats log -> mean GPU %, mean/max VDD_IN mW, max temps
  python3 - "$1" <<'PY'
import re, sys
g, p, r, t = [], [], [], {}
for l in open(sys.argv[1]):
    m = re.search(r"GR3D_FREQ (\d+)%", l); g += [int(m.group(1))] if m else []
    m = re.search(r"VDD_IN (\d+)mW", l); p += [int(m.group(1))] if m else []
    m = re.search(r"VDD_CPU_GPU_CV (\d+)mW", l); r += [int(m.group(1))] if m else []
    for k, v in re.findall(r"(\w+)@([\d.]+)C", l): t[k] = max(t.get(k, 0), float(v))
if not g: print("tegrastats: no samples"); sys.exit()
print("GPU %.0f%% (max %d) | VDD_IN %.1f W mean, %.1f W max | CPU_GPU_CV %.2f W mean | max temp %s" % (
    sum(g) / len(g), max(g), sum(p) / len(p) / 1000, max(p) / 1000, sum(r) / max(len(r), 1) / 1000,
    ", ".join("%s %.0fC" % kv for kv in sorted(t.items()) if kv[0] in ("cpu", "gpu", "tj", "soc0", "soc1", "soc2"))))
PY
}

with_tegra() {  # with_tegra NAME TIMEOUT cmd...
  local name=$1 tmo=$2; shift 2
  sudo -n tegrastats --interval 500 --logfile "$OUT/$name.tegra" &
  timeout "$tmo" "$@" > "$OUT/$name.log" 2>&1 || { [[ $? == 124 ]] && echo "TIMEOUT: $name" | tee -a "$OUT/$name.log"; }
  sudo -n tegrastats --stop; sleep 1
  grep -E "^(batch|engine|FAIL)" "$OUT/$name.log"
  echo "  $(tegra_summary "$OUT/$name.tegra")"
}

case ${1:-} in
  bench)
    model=${2:?model}; shift 2
    sizes=("${@:-640x640 640x384}"); [[ $# -gt 0 ]] && sizes=("$@") || sizes=(640x640 640x384)
    for s in "${sizes[@]}"; do
      echo "== $(basename "$model") $s FP16"
      with_tegra "bench-$(basename "${model%.onnx}")-$s" 1500 \
        "$BENCH" --model "$model" --cache "$HOME/models/trt-cache" --size "$s" --max-batch 4 --iters 300
    done
    ;;
  live)
    model=${2:?model}; labels=${3:?labels}; secs=${4:?secs}; shift 4
    [[ $# -gt 0 ]] || { echo "need at least one OBJFPS" >&2; exit 2; }
    was_active=$(systemctl is-active photonvision)
    sudo -n cp "$PVDB" "$OUT/photon.sqlite.bak"
    restore() {
      trap '' PIPE
      sudo -n systemctl stop photonvision
      sudo -n cp "$OUT/photon.sqlite.bak" "$PVDB"
      [[ $was_active == active ]] && sudo -n systemctl start photonvision
      echo "restored the settings DB; PhotonVision $(systemctl is-active photonvision)"
    }
    trap restore EXIT
    name=$(basename "${model%.onnx}")
    set_pipelines() {  # set_pipelines TYPE OBJFPS
      sudo -n systemctl stop photonvision
      sudo -n python3 - "$PVDB" "$1" "$2" "$CONFIG/models/$name.onnx" "$labels" "${TAG_FPS:-0}" \
        "${TAGS_ON_CPU:-0}" "${NAPA_FAR:-0}" <<'PY'
import json, sqlite3, sys
db, kind, objfps, path, labels, tagfps, oncpu, napafar = sys.argv[1:9]
c = sqlite3.connect(db)
for uid, contents in c.execute("select unique_name, contents from cameras").fetchall():
    d = json.loads(contents)
    for p in d["pipelineSettings"]:
        if p.get("pipelineIndex") != d.get("currentPipelineIndex"): continue
        p["tagFpsMax"] = int(tagfps)
        p.update(tagsOnCpu=oncpu == "1", napaMinTagPx=16, napaMaxHamming=1, napaFarSearch=napafar == "1",
                 napaFarMinTagPx=16)
        if kind == "AprilTagObject":
            p["type"], p["pipelineType"] = "AprilTagObjectPipelineSettings", "AprilTagObject"
            p.update(confidence=0.5, nms=0.45, objectFpsMax=int(objfps), objectClasses="", objectMaxTargets=20,
                     model={"modelPath": "file://" + path, "nickname": "bench", "labels": labels.split(","),
                            "resolutionWidth": 640, "resolutionHeight": 640, "family": "TENSORRT", "version": "YOLOV11"})
        else:
            p["type"], p["pipelineType"] = "AprilTagCudaPipelineSettings", "AprilTagCuda"
    c.execute("update cameras set contents=? where unique_name=?", (json.dumps(d), uid))
c.commit()
PY
      sudo -n systemctl start photonvision
    }
    measure() {  # measure NAME
      local since; sleep 45  # start-up, camera open, engine load (cached)
      since=$(date '+%Y-%m-%d %H:%M:%S')
      local pid t0 t1 hz; pid=$(systemctl show -p MainPID --value photonvision); hz=$(getconf CLK_TCK)
      t0=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0)
      threads() { for f in /proc/"$pid"/task/*/stat; do sed -E 's/^([0-9]+) \((.*)\) . (.*)/\1|\2|\3/' "$f"; done 2>/dev/null; }
      threads > "$OUT/live-$1.threads0"
      sudo -n tegrastats --interval 500 --logfile "$OUT/live-$1.tegra" &
      sleep "$secs"
      t1=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0)
      threads > "$OUT/live-$1.threads1"
      sudo -n tegrastats --stop; sleep 1
      journalctl -u photonvision --since "$since" --no-pager > "$OUT/live-$1.journal"
      echo "== $1"
      grep -E "Loop timing" "$OUT/live-$1.journal" | sed -E 's/.*VisionRunner - ([^]]*).*over ([0-9]+) frames.*pipeline ([0-9.]+) ms.*latency (.*)/  \1: \2 frames\/10s, pipeline \3 ms, latency \4/' | tail -4
      grep -E "TensorRT .*frames in" "$OUT/live-$1.journal" | sed -E 's/.*(TensorRT .*)/  \1/' | tail -2
      grep -E "TensorRT|Exception" "$OUT/live-$1.journal" | grep -i -E "fail|exception" | head -3
      echo "  $(tegra_summary "$OUT/live-$1.tegra")"
      echo "  top threads (cores): $(awk -F'|' -v hz="$hz" -v s="$secs" 'NR==FNR{split($3,a," "); t[$1]=a[11]+a[12]; next}
        {split($3,a," "); u=(a[11]+a[12]-t[$1])/hz/s; n[$2]+=u} END{for(k in n) if(n[k]>=0.02) printf "%.2f %s\n", n[k], k}' \
        "$OUT/live-$1.threads0" "$OUT/live-$1.threads1" | sort -rn | head -8 | awk '{c=$1; $1=""; printf "%s%s %s", sep, substr($0,2), c; sep="; "}')"
      echo "  PhotonVision CPU $(awk -v a="$t0" -v b="$t1" -v hz="$hz" -v s="$secs" 'BEGIN{printf "%.2f", (b - a) / hz / s}') cores"
    }
    set_pipelines AprilTagCuda 0; timeout $((secs + 120)) bash -c "$(declare -f measure tegra_summary); OUT=$OUT secs=$secs measure baseline" || echo "TIMEOUT: baseline"
    for f in "$@"; do
      set_pipelines AprilTagObject "$f"
      timeout $((secs + 120)) bash -c "$(declare -f measure tegra_summary); OUT=$OUT secs=$secs measure objects-${f}fps" || echo "TIMEOUT: objects $f"
    done
    ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac
echo "logs: $OUT"
