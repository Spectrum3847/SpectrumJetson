#!/usr/bin/env bash
# Pin camera threads (photonvision-102) live A/B. Run ON THE JETSON with the cameras plugged in.
#
#   run.sh SECS ROUNDS [OBJFPS]
#
# Every camera's current pipeline -> AprilTagCuda with "Tags on CPU (NAPA)" (min tag px 16, max
# hamming 1) or, with OBJFPS, AprilTag + Object with yolo11n at that Object FPS max.
# Then ROUNDS x CONDITIONS (default "unpinned pinned pinned+others"; also cams-only: tag cameras
# pinned, shared threads not), interleaved, SECS each, PhotonVision restarted per condition with
# the SPECTRUM_PIN_* environment (a systemd drop-in). Clocks mode full during the test,
# back to what it was after; the settings DB restored; PhotonVision left as found. Per condition:
# tag latency p50/p95/p99/max and frames (Loop timing), per-thread CPU, the cores each thread ran on
# and its allowed cores, migrations and context switches (perf stat per thread), VDD_IN and temps.
# Every step has a hard timeout and says TIMEOUT.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
secs=${1:?secs}; rounds=${2:?rounds}; objfps=${3:-0}
CONDITIONS=${CONDITIONS:-unpinned pinned pinned+others}
PERF=${PERF:-$(ls /usr/lib/linux-*tools*/perf 2>/dev/null | head -1)}  # the wrapper in /usr/bin wants a matching linux-tools
CONFIG=/opt/photonvision/photonvision_config
PVDB=$CONFIG/photon.sqlite
DROPIN=/etc/systemd/system/photonvision.service.d/zz-pin-test.conf
OUT=${OUT:-$ROOT/logs/pin-cameras-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
was_active=$(systemctl is-active photonvision)
was_mode=$(cat /etc/spectrum-clocks-mode 2>/dev/null || echo auto)
sudo -n systemctl stop photonvision
sudo -n cp "$PVDB" "$OUT/photon.sqlite.bak"
restore() {
  trap '' PIPE
  sudo -n systemctl stop photonvision
  sudo -n cp "$OUT/photon.sqlite.bak" "$PVDB"
  sudo -n rm -f "$DROPIN"; sudo -n systemctl daemon-reload
  sudo -n spectrum-clocks mode "$was_mode" >/dev/null
  [[ $was_active == active ]] && sudo -n systemctl start photonvision
  echo "restored the settings DB, clocks mode $was_mode; PhotonVision $(systemctl is-active photonvision)"
}
trap restore EXIT
sudo -n spectrum-clocks mode full >/dev/null
set_pipelines() {  # every camera's current pipeline (PhotonVision stopped)
sudo -n python3 - "$PVDB" "$objfps" "$CONFIG/models/yolo11n.onnx" <<'PY'
import json, sqlite3, sys
db, objfps, path = sys.argv[1:4]
c = sqlite3.connect(db)
for uid, contents in c.execute("select unique_name, contents from cameras").fetchall():
    d = json.loads(contents)
    for p in d["pipelineSettings"]:
        if p.get("pipelineIndex") != d.get("currentPipelineIndex"): continue
        p["tagFpsMax"] = 0
        p.update(tagsOnCpu=True, napaMinTagPx=16, napaMaxHamming=1, napaFarSearch=False, napaFarMinTagPx=16)
        if int(objfps) > 0:
            p["type"], p["pipelineType"] = "AprilTagObjectPipelineSettings", "AprilTagObject"
            labels = json.load(open(path[:-5] + ".json"))["labels"]
            p.update(confidence=0.5, nms=0.45, objectFpsMax=int(objfps), objectClasses="", objectMaxTargets=20,
                     model={"modelPath": "file://" + path, "nickname": "bench", "labels": labels,
                            "resolutionWidth": 640, "resolutionHeight": 640, "family": "TENSORRT", "version": "YOLOV11"})
        else:
            p["type"], p["pipelineType"] = "AprilTagCudaPipelineSettings", "AprilTagCuda"
    c.execute("update cameras set contents=? where unique_name=?", (json.dumps(d), uid))
c.commit()
PY
}

measure() {  # measure NAME ENV...
  local name=$1 pid hz since; shift
  printf '[Service]\nEnvironment=%s\n' "$*" | sudo -n tee "$DROPIN" >/dev/null
  sudo -n systemctl daemon-reload; sudo -n systemctl stop photonvision
  sudo -n systemctl start photonvision
  sleep 45  # start-up, cameras, pinning (2 s sweeps)
  pid=$(systemctl show -p MainPID --value photonvision); hz=$(getconf CLK_TCK)
  [[ $pid -gt 0 ]] || { echo "== $name: PhotonVision not running"; return; }
  since=$(date '+%Y-%m-%d %H:%M:%S')
  threads() { for t in /proc/"$pid"/task/*; do
      echo "$(basename "$t")|$(cat "$t/comm")|$(sed 's/.*) //' "$t/stat" | awk '{print $12+$13, $37}')|$(grep -E '^Cpus_allowed_list' "$t/status" | awk '{print $2}')|$(awk '/^(non)?voluntary_ctxt/{printf "%s ", $2}' "$t/status")"
    done 2>/dev/null; }
  threads > "$OUT/$name.threads0"
  local tids; tids=$(grep -E '\|(VisionRunner|SpectrumDecoder|TensorRT|AprilTag)' "$OUT/$name.threads0" | cut -d'|' -f1 | paste -sd,)
  sudo -n tegrastats --interval 500 --logfile "$OUT/$name.tegra" &
  local perfpid=
  [[ -n $tids && -n $PERF ]] && { sudo -n "$PERF" stat -e cpu-migrations,context-switches --per-thread -t "$tids" -o "$OUT/$name.perf" -- sleep "$secs" >/dev/null 2>&1 & perfpid=$!; }
  # which core each camera thread is on, sampled every 0.5 s
  local end=$((SECONDS + secs))
  while (( SECONDS < end )); do
    ps -L -o tid=,psr= -p "$pid" | awk -v want=",$tids," 'index(want, "," $1 ",") {print $1, $2}'
    sleep 0.5
  done > "$OUT/$name.psr"
  [[ -n $perfpid ]] && wait "$perfpid"
  threads > "$OUT/$name.threads1"
  sudo -n tegrastats --stop; sleep 1
  journalctl -u photonvision --since "$since" --no-pager > "$OUT/$name.journal"
  python3 "$ROOT/tests/pin-cameras/summary.py" "$OUT" "$name" "$secs" "$hz"
}

set_pipelines  # once: PhotonVision keeps them across its own saves and restarts
for r in $(seq "$rounds"); do
  for c in $CONDITIONS; do
    case $c in
      unpinned) env="SPECTRUM_PIN_CAMERAS=0" ;;
      pinned) env="SPECTRUM_PIN_CAMERAS=1 SPECTRUM_PIN_SHARED_CORE=1" ;;
      pinned+others) env="SPECTRUM_PIN_CAMERAS=1 SPECTRUM_PIN_SHARED_CORE=1 SPECTRUM_PIN_OTHERS=1" ;;
      cams-only) env="SPECTRUM_PIN_CAMERAS=1 SPECTRUM_PIN_SHARED_CORE=-1" ;;
      *) echo "unknown condition $c"; continue ;;
    esac
    timeout $((secs + 150)) bash -c "$(declare -f measure); OUT=$OUT ROOT=$ROOT DROPIN=$DROPIN PERF=$PERF PVDB=$PVDB CONFIG=$CONFIG objfps=$objfps secs=$secs measure r$r-$c $env"; rc=$?; (( rc == 124 )) && echo "TIMEOUT: r$r-$c"; (( rc != 0 && rc != 124 )) && echo "r$r-$c: exit $rc"
  done
done
echo "logs: $OUT"
