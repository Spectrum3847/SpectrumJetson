#!/usr/bin/env bash
# One-command bench session: 4-5 cameras, AprilTags, a human at the bench. Run ON THE JETSON with
# PhotonVision running. Walks through the steps below with prompts ("point all cameras at tags,
# press Enter"), gives every step a hard time limit (it says TIMEOUT and moves on), puts every
# setting it changed back the way it found it (also on Ctrl-C), and writes one results file:
#   ~/bench-results/<yyyymmdd-HHMMSS>/results.md   (raw logs for each step next to it)
#
# Steps (run in this order; name some to run only those):
#   inventory  cameras (model, serial, firmware, USB port, exposure now/min/max, gain range, USB
#              bandwidth reservation: tests/bench-session/cameras.py, read-only), fps per camera,
#              every camera on the NVJPG hardware decoder, clocks locked, temperatures, spectrum-rt
#              mode, detector options
#   baseline   no tags, then tags: fps, latency median/p95/max per camera, detect times, CPU
#              (tests/perf-snapshot.sh, then a perf profile per thread: scripts/jetson/profile-cpu.sh),
#              GPU %, power, temperature
#   graphs     CUDA graphs on/off A/B, interleaved through /tmp/spectrum-detector-graphs (no restart)
#   gpurefine  SPECTRUM_DETECTOR_GPU_REFINE 0 / 2 (detector-16) / 3 (detector-17), interleaved, one
#              PhotonVision restart per run (read at start): PhotonVision CPU (all threads and camera
#              threads), detect avg/max, latency, GPU %. Only calibrated cameras gain (notes which aren't)
#   3d         PhotonVision's 3D mode (solvePNPEnabled) on vs off with tags, through PhotonVision's
#              websocket (the same message the UI sends); CPU and latency
#   rt         spectrum-rt A/B (tests/rt-ab/run.sh) with LOAD=0 and LOAD=4
#   edge       detector edge filter 0, 25, 50 px (one PhotonVision restart each): slide a tag off
#              the image edge and walk it out for range; detections per camera
#   usb        OPT-IN (not in the default list): USB recovery timing (tests/usb-recovery-bench),
#              which cuts camera links. Only with the usbrecov firmware on every camera.
#   stills     OPT-IN: Rewind recordings of a tag held STILL, per camera at ~1, 2.5, 4 m and at the
#              current exposure and half of it, for the field-replay accuracy (static-jitter) judge.
# At the end it asks for camera notes (mounting, focus, cable) and puts them in results.md, under a
# "Camera comparison" that groups every measurement by camera model (Thriftiest vs Swyft, ...).
#
# Usage: tests/bench-session/run.sh [STEP...] [usb]
#   tests/bench-session/run.sh                 everything but usb
#   tests/bench-session/run.sh graphs 3d       just those
#   tests/bench-session/run.sh all usb         everything, USB recovery too
# Env: BENCH_SECS (measurement window, default 30), BENCH_ROUNDS (A/B rounds, default 2),
#      RT_SECS (seconds per spectrum-rt run, default 45), EDGE_VALUES (default "0 25 50"),
#      BENCH_STILL_SECS (seconds per still recording, default 45)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SELF=$HERE/$(basename "$0")
SECS=${BENCH_SECS:-30}
ROUNDS=${BENCH_ROUNDS:-2}
RT_SECS=${RT_SECS:-45}
EDGE_VALUES=${EDGE_VALUES:-"0 25 50"}
STILL_SECS=${BENCH_STILL_SECS:-45}
GRAPHS_FILE=/tmp/spectrum-detector-graphs
REFINE_FILE=/tmp/spectrum-detector-gpu-refine
DROPIN=/etc/systemd/system/photonvision.service.d/detector.conf
# Before the 2026-10-31 rename 08-select-detector.sh wrote 971.conf (SPECTRUM_971_* names).
[[ -f $DROPIN || ! -f ${DROPIN%/*}/971.conf ]] || DROPIN=${DROPIN%/*}/971.conf
PVDB=/opt/photonvision/photonvision_config/photon.sqlite
DEFAULT_STEPS=(inventory baseline graphs gpurefine far 3d rt edge)

# ---------------------------------------------------------------------------------------------
# Measurement (run as "run.sh --measure OUT STEP COND ROUND SECS", under a timeout): perf-snapshot
# for PhotonVision's CPU, tegrastats for GPU/power/temperature/NVJPG, and PhotonVision's own log
# lines for per-camera fps/latency ("Loop timing", 10 s windows) and per-detector stats ("detector
# stats", 1 s windows). Appends rows to OUT/cams.tsv and OUT/sys.tsv.
measure_main() {
  local out=$1 step=$2 cond=$3 round=$4 secs=$5
  local tl=$out/.tegra.$$ ps=$out/.perf.$$ since tp
  since=$(date +%s)
  sudo -n tegrastats --interval 1000 > "$tl" 2>/dev/null & tp=$!
  "$REPO/tests/perf-snapshot.sh" "$secs" "$step/$cond" > "$ps" 2>&1
  sudo -n kill "$tp" 2>/dev/null
  wait "$tp" 2>/dev/null
  sudo -n journalctl -u photonvision --since "@$since" -o cat --no-pager > "$out/.journal.$$" 2>/dev/null
  python3 - "$out" "$step" "$cond" "$round" "$secs" "$tl" "$ps" "$out/.journal.$$" <<'PY'
import re, statistics, sys, collections
out, step, cond, rnd, secs, tl, ps, jl = sys.argv[1:]
ansi = re.compile(r'\x1b\[[0-9;]*m')
loop = collections.defaultdict(list); det = collections.defaultdict(list); jpeg = []
for line in open(jl, errors="replace"):
    line = ansi.sub("", line).rstrip()
    m = re.search(r'\[VisionModule - VisionRunner - \w+ - (.*?)\] \[\w+\] Loop timing over (\d+) frames:'
                  r'.*latency median ([\d.]+) p95 ([\d.]+) max ([\d.]+) ms', line)
    if m:
        loop[m.group(1)].append(tuple(float(x) for x in m.groups()[1:])); continue
    m = re.match(r'(?:971|detector) stats (h\d+) \S+: ([\d.]+) calls/s, detect avg ([\d.]+) ms max ([\d.]+) ms.*?tags/frame ([\d.]+)'
                 r'(?:, margin avg ([\d.]+))?', line)
    if m:
        det[m.group(1)].append(tuple(float(x) if x else None for x in m.groups()[1:])); continue
    m = re.match(r'(?:971 jpeg|jpeg decoder) \d+ s: nvjpg ([\d.]+) frames/s.*?libjpeg-turbo ([\d.]+) frames/s', line)
    if m:
        jpeg.append((float(m.group(1)), float(m.group(2))))
f = lambda x: "" if x is None else f"{x:.2f}"
with open(f"{out}/cams.tsv", "a") as o:
    for cam, w in sorted(loop.items()):
        o.write("\t".join([step, cond, rnd, cam, f(statistics.mean(x[0] for x in w) / 10),
                           f(statistics.median(x[1] for x in w)), f(statistics.median(x[2] for x in w)),
                           f(max(x[3] for x in w)), "", "", "", "", ""]) + "\n")
    for h, w in sorted(det.items()):
        o.write("\t".join([step, cond, rnd, "detector " + h, f(statistics.mean(x[0] for x in w)), "", "", "",
                           f(statistics.mean(x[1] for x in w)), f(max(x[2] for x in w)),
                           f(statistics.mean(x[3] for x in w)), f"{sum(x[0] * x[3] for x in w):.0f}",
                           f(statistics.mean(x[4] for x in w) if all(x[4] is not None for x in w) else None)]) + "\n")
t = collections.defaultdict(list)
for line in open(tl, errors="replace"):
    for k, pat in (("gpu", r'GR3D_FREQ (\d+)%'), ("power", r'VDD_IN (\d+)mW'), ("temp", r'tj@([\d.]+)C'),
                   ("nvjpg0", r'NVJPG0? (\d+)%'), ("nvjpg1", r'NVJPG1 (\d+)%')):
        m = re.search(pat, line)
        t[k].append(float(m.group(1)) if m else 0.0)
    c = re.search(r'CPU \[([^\]]*)\]', line)
    if c:
        v = [int(x.split('%')[0]) for x in c.group(1).split(',') if '%' in x]
        t["cpu"].append(sum(v) / max(len(v), 1))
avg = lambda k: statistics.mean(t[k]) if t[k] else None
snap = open(ps).read()
m = re.search(r'CPU (\d+)% \(camera threads (\d+)%, workers (\d+)%, other (\d+)%\)', snap)
pv = m.groups() if m else ("", "", "", "")
with open(f"{out}/sys.tsv", "a") as o:
    o.write("\t".join([step, cond, rnd, *pv, f(avg("cpu")), f(avg("gpu")),
                       f(avg("power") / 1000 if t["power"] else None),
                       f(max(t["temp"]) if t["temp"] else None), f(avg("nvjpg0")), f(avg("nvjpg1")),
                       f(statistics.mean(x[0] for x in jpeg)) if jpeg else "",
                       f(statistics.mean(x[1] for x in jpeg)) if jpeg else ""]) + "\n")
print(f"  {step} {cond} r{rnd}: {len(loop)} cameras, {len(det)} detectors, PV CPU {pv[0] or '?'}%, "
      f"GPU {f(avg('gpu'))}%, {f(avg('power') / 1000 if t['power'] else None)} W")
for cam, w in sorted(loop.items()):
    print(f"    {cam:24s} {statistics.mean(x[0] for x in w) / 10:6.1f} fps  latency median "
          f"{statistics.median(x[1] for x in w):.1f} p95 {statistics.median(x[2] for x in w):.1f} max {max(x[3] for x in w):.1f} ms")
for h, w in sorted(det.items()):
    print(f"    detector {h:15s} detect avg {statistics.mean(x[1] for x in w):.2f} max {max(x[2] for x in w):.2f} ms"
          f"  tags/frame {statistics.mean(x[3] for x in w):.2f}")
if not loop:
    print("    (no Loop timing lines: window too short, or a PhotonVision build without them)")
PY
  rm -f "$tl" "$ps" "$out/.journal.$$"
}

# PhotonVision helper: camera list (USB API), active pipeline's setting (config DB), and a setting
# change through the websocket, msgpack-encoded like the UI's changePipelineSetting message.
write_pv_helper() {
  cat > "$1" <<'PY'
import base64, json, os, socket, struct, subprocess, sys, time, urllib.request
def cams():
    with urllib.request.urlopen("http://localhost:5800/api/usb/bandwidth", timeout=3) as r:
        for c in json.load(r).get("cameras", []):
            print("\t".join([c.get("uniqueName") or "", c.get("camera") or "?", c.get("port") or "?",
                             "streaming" if c.get("streaming") else "NOT streaming"]))
def get(unique, key):
    row = subprocess.run(["sudo", "-n", "sqlite3", "-readonly", "/opt/photonvision/photonvision_config/photon.sqlite",
                          "select contents from cameras where unique_name = '%s'" % unique.replace("'", "")],
                         capture_output=True, text=True, timeout=10).stdout
    d = json.loads(row)
    for p in d.get("pipelineSettings", []):
        if p.get("pipelineIndex") == d.get("currentPipelineIndex"):
            print(json.dumps(p.get(key))); return
    print("null")
# Per streaming camera: calibrated resolutions (config DB) against the resolution it streams now
# (v4l2-ctl --get-fmt-video on its node from cameras.tsv; read-only). Tab-separated, one per camera.
def calib(tsv):
    nodes = {}
    if os.path.exists(tsv):
        lines = [l.rstrip("\n").split("\t") for l in open(tsv)]
        if lines:
            h = lines[0]
            for r in lines[1:]:
                d = dict(zip(h, r))
                if d.get("uniqueName"): nodes[d["uniqueName"]] = d.get("video", "")
    with urllib.request.urlopen("http://localhost:5800/api/usb/bandwidth", timeout=3) as r:
        cams = [c for c in json.load(r).get("cameras", []) if c.get("streaming")]
    for c in cams:
        u = c.get("uniqueName") or ""
        row = subprocess.run(["sudo", "-n", "sqlite3", "-readonly", "/opt/photonvision/photonvision_config/photon.sqlite",
                              "select contents from cameras where unique_name = '%s'" % u.replace("'", "")],
                             capture_output=True, text=True, timeout=10).stdout
        try: d = json.loads(row)
        except ValueError: d = {}
        res = sorted({"%dx%d" % (x["resolution"]["width"], x["resolution"]["height"])
                      for x in d.get("calibrations", []) if x.get("resolution")})
        now = "?"
        if nodes.get(u):
            f = subprocess.run(["v4l2-ctl", "-d", "/dev/" + nodes[u], "--get-fmt-video"],
                               capture_output=True, text=True, timeout=10).stdout
            m = [l.split(":", 1)[1].strip().replace("/", "x") for l in f.splitlines() if "Width/Height" in l]
            if m: now = m[0]
        state = ("calibrated" if now in res else "UNCALIBRATED at " + now) if now != "?" else \
                ("calibrations " + (",".join(res) or "none") + " (active resolution unknown)")
        if not res: state = "UNCALIBRATED (no calibrations)"
        print("\t".join([c.get("camera") or "?", c.get("port") or "?", now, ",".join(res) or "none", state]))
def mp(v):
    if v is True: return b"\xc3"
    if v is False: return b"\xc2"
    if v is None: return b"\xc0"
    if isinstance(v, int): return b"\xd2" + struct.pack(">i", v)
    if isinstance(v, float): return b"\xcb" + struct.pack(">d", v)
    if isinstance(v, str):
        b = v.encode(); n = len(b)
        return (bytes([0xa0 | n]) if n < 32 else b"\xd9" + bytes([n]) if n < 256 else b"\xda" + struct.pack(">H", n)) + b
    if isinstance(v, dict):
        return bytes([0x80 | len(v)]) + b"".join(mp(k) + mp(x) for k, x in v.items())
    raise TypeError(v)
def frame(op, payload):
    mask = os.urandom(4); n = len(payload)
    head = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else bytes([0xfe]) + struct.pack(">H", n))
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
def set_(unique, key, value):
    s = socket.create_connection(("localhost", 5800), timeout=5)
    k = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /websocket_data HTTP/1.1\r\nHost: localhost:5800\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % k).encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk: break
        resp += chunk
    if b" 101 " not in resp.split(b"\r\n", 1)[0]:
        sys.exit("websocket upgrade refused: %r" % resp[:80])
    s.sendall(frame(2, mp({"changePipelineSetting": {"cameraUniqueName": unique, key: json.loads(value)}})))
    time.sleep(1)
    s.sendall(frame(8, b"")); s.close()
cmd = sys.argv[1]
if cmd == "cams": cams()
elif cmd == "get": get(sys.argv[2], sys.argv[3])
elif cmd == "set": set_(sys.argv[2], sys.argv[3], sys.argv[4])
elif cmd == "calib": calib(sys.argv[2])
PY
}

if [[ ${1:-} == --measure ]]; then
  shift
  measure_main "$@"
  exit
fi

STEPS=()
for a in "$@"; do
  case $a in
    all) STEPS+=("${DEFAULT_STEPS[@]}") ;;
    inventory | baseline | graphs | gpurefine | far | 3d | rt | edge | usb | stills) STEPS+=("$a") ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown step $a (inventory baseline graphs gpurefine far 3d rt edge usb stills all)" >&2; exit 2 ;;
  esac
done
((${#STEPS[@]})) || STEPS=("${DEFAULT_STEPS[@]}")

# ---------------------------------------------------------------------------------------------
# Session plumbing
OUT=~/bench-results/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
PVPY=$OUT/.pv.py
write_pv_helper "$PVPY"
NOTES=$OUT/notes.md
: > "$NOTES"
: > "$OUT/cams.tsv"
: > "$OUT/sys.tsv"
exec > >(tee -a "$OUT/session.log") 2>&1

note() { echo "- **$STEP**: $*" | tee -a "$NOTES"; }
STEP=setup
STEP_END=0
TIMED_OUT=0
step_begin() { STEP=$1; STEP_END=$(($(date +%s) + $2)); TIMED_OUT=0; echo; echo "===== $1 (time limit $(($2 / 60)) min) ====="; }
left() { echo $((STEP_END - $(date +%s))); }
# tmo SECONDS CMD...: run CMD with a hard limit (also capped by the step's remaining time)
tmo() {
  local want=$1 l rc
  shift
  l=$(left)
  ((l > 5)) || { TIMED_OUT=1; echo "TIMEOUT: step out of time before: $*"; return 124; }
  ((want < l)) || want=$l
  timeout -k 10 "$want" "$@"
  rc=$?
  if ((rc == 124 || rc == 137)); then TIMED_OUT=1; echo "TIMEOUT after ${want}s: $*"; fi
  return "$rc"
}
# ask "instruction": 0 = Enter, 2 = human typed s (skip), 1 = no answer before the step's deadline
ask() {
  local l a
  l=$(left)
  ((l > 5)) || { TIMED_OUT=1; return 1; }
  printf '\a\n>>> %s\n' "$*"
  if ! read -r -t "$l" -p ">>> Enter when ready (s + Enter skips this step): " a < /dev/tty; then
    echo; TIMED_OUT=1; echo "TIMEOUT waiting for the human"; return 1
  fi
  [[ $a != s ]] || return 2
}
measure() { # COND ROUND [SECS]
  local s=${3:-$SECS}
  echo "  measuring $1 (round $2, ${s}s)"
  tmo $((s + 60)) "$SELF" --measure "$OUT" "$STEP" "$1" "$2" "$s"
}
settle() { echo "  settling 12 s (a fresh 10 s log window)"; sleep 12; }
pv_pid() { systemctl show photonvision -p MainPID --value; }
pv_cams() { tmo 10 python3 "$PVPY" cams; }
# Wait until PhotonVision is back and every camera it had streams again.
wait_pv() {
  local want=$1 n t0
  t0=$(date +%s)
  while (($(date +%s) - t0 < 150)); do
    n=$(python3 "$PVPY" cams 2>/dev/null | grep -c $'\tstreaming$')
    ((n >= want)) && { echo "  PhotonVision up, $n cameras streaming after $(($(date +%s) - t0)) s"; return 0; }
    sleep 3
  done
  echo "  PhotonVision: only ${n:-0} of $want cameras streaming after 150 s"
  return 1
}
restart_pv() {
  local want
  want=$(python3 "$PVPY" cams 2>/dev/null | grep -c $'\tstreaming$')
  timeout -k 10 120 sudo -n systemctl restart photonvision || echo "  restart didn't finish in 120 s (exit hang?)"
  sleep 5
  wait_pv "$want"
}

# ---------------------------------------------------------------------------------------------
# What we change, and putting it back (EXIT trap: normal end, Ctrl-C, errors)
RT_ORIG=$(cat /etc/spectrum-rt 2>/dev/null || echo off)
if [[ -e $GRAPHS_FILE ]]; then GRAPHS_ORIG=$(cat "$GRAPHS_FILE"); else GRAPHS_ORIG=absent; fi
if [[ -e $REFINE_FILE ]]; then REFINE_ORIG=$(cat "$REFINE_FILE"); else REFINE_ORIG=absent; fi
DROPIN_BACKUP=$OUT/$(basename "$DROPIN").orig
[[ -f $DROPIN ]] && cp "$DROPIN" "$DROPIN_BACKUP"
PNP_CHANGED=()   # "uniqueName<TAB>original value"
EXPO_CHANGED=()  # "uniqueName<TAB>original cameraExposureRaw"
REWIND_ON=0
DROPIN_CHANGED=0
LOAD_PIDS=()
restore() {
  local e u v
  echo; echo "===== restoring settings ====="
  ((${#LOAD_PIDS[@]})) && kill "${LOAD_PIDS[@]}" 2>/dev/null
  if [[ $GRAPHS_ORIG == absent ]]; then rm -f "$GRAPHS_FILE"; else echo "$GRAPHS_ORIG" > "$GRAPHS_FILE"; fi
  echo "  CUDA graphs switch: $GRAPHS_ORIG"
  if [[ $REFINE_ORIG == absent ]]; then rm -f "$REFINE_FILE"; else echo "$REFINE_ORIG" > "$REFINE_FILE"; fi
  echo "  GPU RefineEdges switch: $REFINE_ORIG"
  [[ $(cat /etc/spectrum-rt 2>/dev/null || echo off) == "$RT_ORIG" ]] || sudo -n spectrum-rt "$RT_ORIG" > /dev/null
  echo "  spectrum-rt: $RT_ORIG"
  if [[ -n $FAR_ORIG ]]; then far_set "$FAR_ORIG" && echo "  far search: $FAR_ORIG"; fi
  sudo -n spectrum-clocks mode "$CLOCKS_ORIG" > /dev/null && echo "  spectrum-clocks mode: $CLOCKS_ORIG"
  for e in "${PNP_CHANGED[@]}"; do
    u=${e%%$'\t'*}; v=${e#*$'\t'}
    timeout 15 python3 "$PVPY" set "$u" solvePNPEnabled "$v" && echo "  3D (solvePNPEnabled) $v: $u"
  done
  ((REWIND_ON)) && rewind_set false > /dev/null && echo "  Rewind manual recording stopped"
  for e in "${EXPO_CHANGED[@]}"; do
    u=${e%%$'\t'*}; v=${e#*$'\t'}
    timeout 15 python3 "$PVPY" set "$u" cameraExposureRaw "$v" && echo "  exposure (cameraExposureRaw) $v: $u"
  done
  if ((DROPIN_CHANGED)); then
    # Put back under the new name (08 replaced an old 971.conf), with SPECTRUM_971_* renamed.
    sudo -n rm -f "${DROPIN%/*}/971.conf" "${DROPIN%/*}/detector.conf"
    if [[ -f $DROPIN_BACKUP ]]; then
      sed 's/SPECTRUM_971_/SPECTRUM_DETECTOR_/g' "$DROPIN_BACKUP" | sudo -n tee "${DROPIN%/*}/detector.conf" >/dev/null
    fi
    sudo -n systemctl daemon-reload
    echo "  detector options: ${DROPIN%/*}/detector.conf put back; restarting PhotonVision"
    ((${#PNP_CHANGED[@]})) && sleep 5   # let PhotonVision save the 3D setting first
    restart_pv
  fi
  render
}
trap restore EXIT
# The bench has no robot, so spectrum-clocks would lower the clocks after 20 s: hold them full.
CLOCKS_ORIG=$(cat /etc/spectrum-clocks-mode 2>/dev/null || echo auto)
sudo -n spectrum-clocks mode full > /dev/null && echo "Clocks held full for the session (was: $CLOCKS_ORIG)"
FAR_ORIG=""
trap 'echo; echo "Interrupted"; exit 130' INT TERM

# ---------------------------------------------------------------------------------------------
# Steps
step_inventory() {
  local cams n rt clocks bad pvstart
  cams=$(pv_cams) || return 1
  n=$(grep -c . <<< "$cams")
  note "$n cameras: $(awk -F'\t' '{printf "%s%s @%s (%s)", sep, $2, $3, $4; sep="; "}' <<< "$cams")"
  rt=$(sudo -n spectrum-rt status 2>/dev/null | head -1)
  note "spectrum-rt: $(cat /etc/spectrum-rt 2>/dev/null || echo off) (${rt:-no status})"
  clocks=$(sudo -n jetson_clocks --show 2>/dev/null | awk '
    /MinFreq=/ { for (i = 1; i <= NF; i++) { if ($i ~ /^MinFreq=/) mn = $i; if ($i ~ /^MaxFreq=/) mx = $i }
                 sub(/MinFreq=/, "", mn); sub(/MaxFreq=/, "", mx); if (mn != mx) bad = bad " " $1 }
    /NV Power Mode/ { mode = $NF }
    END { print (bad == "" ? "locked" : "NOT locked:" bad) ", power mode " mode }')
  note "clocks: $clocks"
  note "temperatures now: $(for z in /sys/class/thermal/thermal_zone*; do
    printf '%s %s C, ' "$(cat "$z/type")" $(($(cat "$z/temp") / 1000)); done | sed 's/, $//')"
  note "detector options ($DROPIN): $(grep -o 'Environment=.*' "$DROPIN" 2>/dev/null | sed 's/Environment=//' | tr '\n' ' ')"
  note "CUDA graphs switch $GRAPHS_FILE: $GRAPHS_ORIG"
  # per camera: model, serial, firmware, port, exposure/gain ranges, USB reservation (all read-only)
  tmo 120 python3 "$HERE/cameras.py" inventory "$OUT" "$REPO" | while read -r l; do note "$l"; done
  measure "running" 1 22 || return 1
  awk -F'\t' '$1 == "inventory" { if ($4 ~ /^detector/) d++; else c++ } END {
    printf "%d cameras and %d detectors reported in the logs\n", c, d }' "$OUT/cams.tsv" | while read -r l; do note "$l"; done
  # NVJPG: libjpeg-turbo frames/s must be 0, and no camera may have fallen back since PhotonVision started
  pvstart=$(systemctl show photonvision -p ActiveEnterTimestamp --value)
  bad=$(sudo -n journalctl -u photonvision --since "$pvstart" -o cat --no-pager 2>/dev/null |
    grep -E "^(971 jpeg|jpeg decoder): .*(can't use the hardware|no hardware decoder|hardware decode failed|CUDA failed|DIFFERS|already decode on NVJPG|can't load|missing functions)|hardware decoder OFF" |
    sort | uniq -c | sort -rn | head -5)
  local turbo
  turbo=$(awk -F'\t' '$1 == "inventory" { print $NF }' "$OUT/sys.tsv")
  if [[ -z $bad && ${turbo:-x} == 0.00 ]]; then
    note "NVJPG: every camera on the hardware decoder (libjpeg-turbo 0 frames/s, no fallbacks since $pvstart)"
  else
    note "NVJPG: **CHECK** libjpeg-turbo ${turbo:-?} frames/s; since start: ${bad:-no fallback lines}"
  fi
}

step_baseline() {
  local r prof
  ask "NO TAGS: point every camera away from tags (or cover the tags)." || return
  settle; measure "no tags" 1 || return
  ask "TAGS: point every camera at tags (at least one tag fully in view of each)." || return
  settle; measure "tags" 1 || return
  echo "  CPU profile per thread with perf (20 s; perf never signals PhotonVision)"
  tmo 200 "$REPO/scripts/jetson/profile-cpu.sh" 20 bench-tags > "$OUT/profile-cpu.txt" 2>&1
  r=$?
  prof=$(cat "$OUT/profile-cpu.txt")
  if ((r == 0)); then
    note "perf profile with tags: $(grep -m1 '^PhotonVision CPU' <<< "$prof"); $(grep -m1 '^Whole Jetson' <<< "$prof")"
    note "busiest threads: $(sed -n '/^Busiest threads/,/^$/p' <<< "$prof" | sed 1d | head -6 | sed 's/^ *//' | paste -sd ';' | sed 's/;/; /g')"
    note "profile: $(sed -n 's/^Flame graph: open //p' <<< "$prof") (copy in profile-cpu.txt)"
  else
    note "profile-cpu.sh failed ($r); see profile-cpu.txt"
  fi
}

step_graphs() {
  local r v
  ask "TAGS: every camera at tags; leave them still for the A/B." || return
  for ((r = 1; r <= ROUNDS; r++)); do
    for v in 1 0; do
      echo "$v" > "$GRAPHS_FILE"
      echo "  graphs=$v (the detector re-reads the switch every 2 s)"
      settle; measure "graphs $([[ $v == 1 ]] && echo on || echo off)" "$r" || return
    done
  done
  if [[ $GRAPHS_ORIG == absent ]]; then rm -f "$GRAPHS_FILE"; else echo "$GRAPHS_ORIG" > "$GRAPHS_FILE"; fi
}

# GPU refine modes, 3-way interleaved: SPECTRUM_DETECTOR_GPU_REFINE 0 (CPU corners, refine and
# decode), 2 (detector-16: corners + RefineEdges in stage 3's graph), 3 (detector-17: + the quad
# decode in the graph). 2 and 3 are read once at start (recorded into the stage graphs), so every
# mode is a drop-in change (08-select-detector.sh --gpu-refine, other options kept) and a
# PhotonVision restart; the live switch file is removed so it can't override. graph_bench (calibrated,
# busy): process CPU 1045 / 426 / 132 us a frame. Uncalibrated cameras run the CPU path in every mode,
# so the per-camera calibration check goes in the notes.
step_gpurefine() {
  local r v lib nvlib args mwbd mse jpeg conn edge modes m since
  lib=$HOME/build/gpu-detector/libspectrum-gpu-apriltag.so
  nvlib=$HOME/build/gpu-detector/libspectrumnvjpg.so
  [[ -f $OUT/cameras.tsv ]] || tmo 120 python3 "$HERE/cameras.py" inventory "$OUT" "$REPO" > /dev/null
  echo "  calibration per camera (config DB against the streaming resolution):"
  tmo 60 python3 "$PVPY" calib "$OUT/cameras.tsv" > "$OUT/.calib" 2>&1 || echo "  calibration check failed"
  while IFS=$'\t' read -r cam port now res state; do
    [[ -n $state ]] || { echo "    $cam"; continue; }
    note "$cam @$port: streaming $now, calibrations $res: $state"
  done < "$OUT/.calib"
  grep -q UNCALIBRATED "$OUT/.calib" && note "uncalibrated cameras above run the CPU path in every mode (no gain from 2/3)"
  note "was: env SPECTRUM_DETECTOR_GPU_REFINE in the drop-in: $(grep -o 'SPECTRUM_DETECTOR_GPU_REFINE=[^ "]*' "$DROPIN" 2>/dev/null || echo unset); switch $REFINE_FILE: $REFINE_ORIG"
  if ! grep -q -- '--gpu-refine' "$REPO/scripts/jetson/08-select-detector.sh" || ! grep -qa TakeGraphCorners /usr/lib/libspectrum-gpu-apriltag.so; then
    note "skipped: the installed detector has no in-graph refine (detector-16)"; return 0
  fi
  modes="0 2"
  if grep -qa PrepareGpuDecode /usr/lib/libspectrum-gpu-apriltag.so; then modes="0 2 3"
  else note "the installed detector has no in-graph decode (detector-17): modes 0 and 2 only"; fi
  # 08-select-detector.sh reinstalls the library from ~/build: only if that's what's installed now
  if ! cmp -s "$lib" /usr/lib/libspectrum-gpu-apriltag.so || { [[ -f $nvlib ]] && ! cmp -s "$nvlib" /usr/lib/libspectrumnvjpg.so; }; then
    note "skipped: ~/build/gpu-detector differs from the installed detector; 08-select-detector.sh would swap it"; return 0
  fi
  [[ $(findmnt -n -o FSTYPE /) != overlay ]] || { note "skipped: ro-root is on"; return 0; }
  # keep every other option as it is now
  mwbd=$(sed -En 's/^Environment=SPECTRUM_(DETECTOR|971)_MIN_WHITE_BLACK_DIFF=//p' "$DROPIN" 2>/dev/null)
  mse=$(sed -En 's/^Environment=SPECTRUM_(DETECTOR|971)_MAX_LINE_FIT_MSE=//p' "$DROPIN" 2>/dev/null)
  edge=$(sed -En 's/^Environment=SPECTRUM_(DETECTOR|971)_EDGE_BORDER_PX=//p' "$DROPIN" 2>/dev/null)
  jpeg=$(sed -n 's/^Environment=SPECTRUM_JPEG_DECODER=//p' "$DROPIN" 2>/dev/null)
  conn=$(sed -n 's/^Environment=CUDA_DEVICE_MAX_CONNECTIONS=//p' "$DROPIN" 2>/dev/null)
  args=()
  [[ -n $mwbd ]] && args+=(--mwbd "$mwbd")
  [[ -n $mse ]] && args+=(--mse "$mse")
  [[ -n $edge ]] && args+=(--edge "$edge")
  [[ -n $jpeg ]] && args+=(--jpeg "$jpeg")
  [[ -n $conn ]] && args+=(--gpu-connections "$conn")
  ask "TAGS: every camera at tags; leave them still for the A/B (modes ${modes// /, }, one PhotonVision restart each, ~$((ROUNDS * $(wc -w <<< "$modes") * (SECS + 90) / 60 + 1)) min). Only cameras CALIBRATED at their active resolution use 2/3 (PhotonVision > Cameras > Calibration); uncalibrated ones are listed in results.md." || return
  rm -f "$REFINE_FILE"
  for ((r = 1; r <= ROUNDS; r++)); do
    m=$modes
    ((r % 2 == 0)) && m=$(tr ' ' '\n' <<< "$modes" | tac | paste -sd ' ')  # alternate the order
    for v in $m; do
      DROPIN_CHANGED=1
      tmo 60 "$REPO/scripts/jetson/08-select-detector.sh" gpu "${args[@]}" --gpu-refine "$v" --no-restart > /dev/null || return 1
      echo "  restarting PhotonVision with GPU refine mode $v"
      since=$(date '+%Y-%m-%d %H:%M:%S')
      restart_pv || note "mode $v round $r: not every camera came back after the restart"
      sudo -n journalctl -u photonvision --since "$since" -o cat --no-pager 2>/dev/null | grep -q 'detector loaded' ||
        note "mode $v round $r: no 'detector loaded' line since the restart"
      settle; measure "gpu refine $v" "$r" || return
    done
  done
}

# Far search (photonvision-55) on/off, live through Settings > Robot state's endpoint. The TXMAN1
# replays (tests/field-replay) found +1,728 sightings (1,306 good) for ~1.7 ms/frame; live it once
# cost 5.9 ms. Turn it on for the robot if the live cost is close to the replay's.
far_get() { curl -s -m 10 localhost:5800/api/robotState | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("farSearch")).lower())'; }
far_set() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"farSearch\": $1}" localhost:5800/api/robotState | grep -q 200; }

step_far() {
  local r v
  FAR_ORIG=$(far_get)
  [[ $FAR_ORIG == true || $FAR_ORIG == false ]] || { note "can't read farSearch ($FAR_ORIG)"; FAR_ORIG=""; return 1; }
  note "far search was $FAR_ORIG"
  ask "TAGS: every camera at tags, some FAR away (5+ m) if you can; leave them still." || return
  for ((r = 1; r <= ROUNDS; r++)); do
    for v in true false; do
      far_set "$v" || { note "farSearch change failed"; return 1; }
      settle; measure "far search $([[ $v == true ]] && echo on || echo off)" "$r" || return
    done
  done
  far_set "$FAR_ORIG"; note "far search put back to $FAR_ORIG"; FAR_ORIG=""
}

step_3d() {
  local cams u name port st orig v r e got
  cams=$(pv_cams) || return 1
  ask "TAGS: every camera at tags (3D needs a calibration for the active resolution, or it does nothing)." || return
  # remember each camera's current value first
  while IFS=$'\t' read -r u name port st; do
    [[ -n $u ]] || continue
    orig=$(timeout 15 python3 "$PVPY" get "$u" solvePNPEnabled) || orig=null
    if [[ $orig != true && $orig != false ]]; then note "$name @$port: can't read solvePNPEnabled ($orig); left alone"; continue; fi
    PNP_CHANGED+=("$u"$'\t'"$orig")
    note "$name @$port: 3D was $orig"
  done <<< "$cams"
  ((${#PNP_CHANGED[@]})) || { note "no camera to toggle"; return 1; }
  for ((r = 1; r <= ROUNDS; r++)); do
    for v in true false; do
      for e in "${PNP_CHANGED[@]}"; do
        tmo 15 python3 "$PVPY" set "${e%%$'\t'*}" solvePNPEnabled "$v" || { note "websocket change failed"; return 1; }
      done
      settle
      if ((r == 1)); then  # PhotonVision saves the change to its database: confirm it took
        got=$(timeout 15 python3 "$PVPY" get "${PNP_CHANGED[0]%%$'\t'*}" solvePNPEnabled)
        [[ $got == "$v" ]] || note "3D=$v not confirmed in PhotonVision's database yet (reads $got); numbers may be wrong"
      fi
      measure "3D $([[ $v == true ]] && echo on || echo off)" "$r" || return
    done
  done
  for e in "${PNP_CHANGED[@]}"; do tmo 15 python3 "$PVPY" set "${e%%$'\t'*}" solvePNPEnabled "${e#*$'\t'}"; done
  PNP_CHANGED=()
  note "3D settings put back"
}

step_rt() {
  local load out
  ask "TAGS: every camera at tags; leave them still (2 spectrum-rt A/Bs, ~$((2 * ROUNDS * (RT_SECS + 12) * 2 / 60 + 1)) min)." || return
  for load in 0 4; do
    echo "  spectrum-rt A/B, LOAD=$load"
    LOAD=$load tmo $((ROUNDS * 2 * (RT_SECS + 15) + 60)) "$REPO/tests/rt-ab/run.sh" "$ROUNDS" "$RT_SECS" > "$OUT/.rt" 2>&1
    out=$(cat "$OUT/.rt"); rm -f "$OUT/.rt"
    echo "$out" | tee -a "$OUT/rt-ab.txt"
    grep -E '^  (off|on) *:' <<< "$out" | while read -r l; do note "LOAD=$load $l"; done
    ((TIMED_OUT)) && return 1
  done
}

step_edge() {
  local lib nvlib args mwbd mse jpeg conn v
  lib=$HOME/build/gpu-detector/libspectrum-gpu-apriltag.so
  nvlib=$HOME/build/gpu-detector/libspectrumnvjpg.so
  if ! grep -q -- '--edge' "$REPO/scripts/jetson/08-select-detector.sh" || ! grep -qa SPECTRUM_DETECTOR_EDGE_BORDER_PX /usr/lib/libspectrum-gpu-apriltag.so; then
    note "skipped: the installed detector has no edge filter (SPECTRUM_DETECTOR_EDGE_BORDER_PX; detector-12) yet"; return 0
  fi
  # 08-select-detector.sh reinstalls the library from ~/build: only if that's what's installed now
  if ! cmp -s "$lib" /usr/lib/libspectrum-gpu-apriltag.so || { [[ -f $nvlib ]] && ! cmp -s "$nvlib" /usr/lib/libspectrumnvjpg.so; }; then
    note "skipped: ~/build/gpu-detector differs from the installed detector; 08-select-detector.sh would swap it"; return 0
  fi
  [[ $(findmnt -n -o FSTYPE /) != overlay ]] || { note "skipped: ro-root is on"; return 0; }
  # keep every other option as it is now
  mwbd=$(sed -En 's/^Environment=SPECTRUM_(DETECTOR|971)_MIN_WHITE_BLACK_DIFF=//p' "$DROPIN" 2>/dev/null)
  mse=$(sed -En 's/^Environment=SPECTRUM_(DETECTOR|971)_MAX_LINE_FIT_MSE=//p' "$DROPIN" 2>/dev/null)
  jpeg=$(sed -n 's/^Environment=SPECTRUM_JPEG_DECODER=//p' "$DROPIN" 2>/dev/null)
  conn=$(sed -n 's/^Environment=CUDA_DEVICE_MAX_CONNECTIONS=//p' "$DROPIN" 2>/dev/null)
  args=()
  [[ -n $mwbd ]] && args+=(--mwbd "$mwbd")
  [[ -n $mse ]] && args+=(--mse "$mse")
  [[ -n $jpeg ]] && args+=(--jpeg "$jpeg")
  [[ -n $conn ]] && args+=(--gpu-connections "$conn")
  ask "EDGE FILTER: ${EDGE_VALUES// /, } px, one PhotonVision restart each (~1 min). Have one tag on a stick ready." || return
  for v in $EDGE_VALUES; do
    DROPIN_CHANGED=1
    tmo 60 "$REPO/scripts/jetson/08-select-detector.sh" gpu "${args[@]}" --edge "$v" --no-restart || return 1
    echo "  restarting PhotonVision with edge border $v px"
    restart_pv || note "edge $v: not every camera came back after the restart"
    ask "EDGE $v px: for 40 s, slide the tag slowly off the edge of each camera's image, then walk it away from one camera for range. Press Enter, then start." || return
    measure "edge $v px" 1 40 || return
  done
}

step_usb() {
  local fw sw ports swports
  # Thriftiests: only those with the usbrecov firmware (a stock one can wedge until it's unplugged).
  fw=$(tmo 60 sudo -n python3 "$REPO/scripts/jetson/thriftiest-fw.py" variant --json) || fw="[]"
  echo "$fw" > "$OUT/firmware.json"
  ports=$(python3 -c 'import json,sys
seen=set(); out=[]
for x in json.loads(sys.argv[1]):
    if x["port"] in seen: continue
    seen.add(x["port"])
    if x["recovers"]: out.append(x["port"])
print(" ".join(out))' "$fw")
  python3 -c 'import json,sys
for x in {x["port"]: x for x in json.loads(sys.argv[1])}.values():
    print("%s %s%s" % (x["port"], x["label"], "" if x["recovers"] else " (no usbrecov firmware: skipped)"))' "$fw" | while read -r l; do note "Thriftiest $l"; done
  # Swyfts: their drop recovery is what we want to learn; it may need a replug or power cycle.
  sw=$(tmo 60 sudo -n python3 "$REPO/scripts/jetson/swyft-fw.py" list --json 2>/dev/null) || sw="[]"
  echo "$sw" > "$OUT/swyft.json"
  swports=$(python3 -c 'import json,sys; print(" ".join(x["port"] for x in json.loads(sys.argv[1]) if not x.get("bootloader")))' "$sw" 2>/dev/null)
  if [[ -n $swports ]] && ask "Also test the Swyft camera(s) on ports $swports? Untested: one may stay stuck until you unplug it or power-cycle. Enter = yes, s = skip"; then
    ports="$ports $swports"; note "Swyft ports tested: $swports"
  elif [[ -n $swports ]]; then note "Swyft ports skipped: $swports"; fi
  ports=$(xargs <<< "$ports")
  [[ -n $ports ]] || { note "refused: no camera to test (Thriftiests need the usbrecov firmware; flash it from Settings)"; return 1; }
  ask "USB RECOVERY on ports $ports: this cuts each camera's USB link (disable, remove, reset) and resets the hub. Cameras stay plugged in; watch PhotonVision." || return
  # shellcheck disable=SC2086  # one argument per port
  tmo $(((3 * $(wc -w <<< "$ports") + 2) * 75 + 60)) "$REPO/tests/usb-recovery-bench/run.sh" 1 $ports > "$OUT/usb-recovery.txt" 2>&1
  cat "$OUT/usb-recovery.txt"
  awk '{print $3, $4, $5}' "$OUT/usb-recovery.txt" | while read -r l; do note "$l s"; done
}

# Still captures (RESULTS.md in tests/field-replay/accuracy, "Needs new recordings"): Rewind's
# manual recording (POST /api/rewind {"manual": ...}; the REST call takes no label, so the session
# name, "NNNN_<label>_<time>", is read from GET /api/rewind while it records). Rewind records every
# camera at once; the condition is about the camera the tag faces. JPEG quality: PhotonVision has no
# setting for it (the cameras' MJPEG quality is fixed in their firmware), so that axis is skipped.
rewind_set() { curl -s -m 10 -H 'Content-Type: application/json' -d "{\"manual\": $1}" localhost:5800/api/rewind; }
rewind_session() { curl -s -m 10 localhost:5800/api/rewind | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["session"] if d.get("recording") else "")'; }
# detector stats over a window: per detector, tags/frame and decision margin avg/min
still_stats() {
  sudo -n journalctl -u photonvision --since "@$1" --until "@$2" -o cat --no-pager 2>/dev/null | python3 -c '
import collections, re, sys
d = collections.defaultdict(lambda: [0.0, 0, 0.0, 0.0, 1e9])  # tags/frame sum, windows, margin*calls, calls, min
for l in sys.stdin:
    m = re.match(r"(?:971|detector) stats (h\d+) \S+: ([\d.]+) calls/s.*?tags/frame ([\d.]+)(?:, margin avg ([\d.]+) min ([\d.]+))?", l)
    if not m: continue
    x = d[m.group(1)]; x[0] += float(m.group(3)); x[1] += 1
    if m.group(4):
        w = float(m.group(2)) * float(m.group(3)); x[2] += w * float(m.group(4)); x[3] += w; x[4] = min(x[4], float(m.group(5)))
print("; ".join("%s %.2f tags/frame%s" % (h, x[0] / x[1], ", margin avg %.1f min %.1f" % (x[2] / x[3], x[4]) if x[3] else "")
                for h, x in sorted(d.items())) or "no detector stats lines")'
}

step_stills() {
  local cams u name port st orig auto half dist e sess t0 t1 stats i
  cams=$(pv_cams) || return 1
  [[ $(rewind_session) == "" ]] || { note "Rewind is already recording; not starting another"; return 1; }
  note "JPEG quality: skipped (PhotonVision has no JPEG quality setting; the MJPEG quality is the camera firmware's)"
  ask "STILLS: per camera, a tag at ~1, 2.5 and 4 m, two exposures each, ${STILL_SECS} s recordings. Tag on a stand (not in a hand). Nothing may move while it records." || return
  while IFS=$'\t' read -r u name port st; do
    [[ -n $u ]] || continue
    orig=$(timeout 15 python3 "$PVPY" get "$u" cameraExposureRaw)
    auto=$(timeout 15 python3 "$PVPY" get "$u" cameraAutoExposure)
    half=""
    if [[ $auto == false ]] && [[ $orig =~ ^[0-9.]+$ ]]; then
      half=$(python3 -c "print(max(1, round(float('$orig') / 2, 1)))")
    else
      note "$name @$port: exposure $orig (auto $auto); only the current exposure"
    fi
    for dist in 1 2.5 4; do
      for e in "$orig" $half; do
        ask "STILL $name @$port: tag at ~$dist m, centred in this camera's image, don't touch anything (exposure $e; s skips just this one)."
        i=$?
        ((i == 1)) && return 1
        ((i == 2)) && { note "$name @$port $dist m exposure $e: skipped"; continue; }
        if [[ $e != "$orig" ]]; then
          EXPO_CHANGED+=("$u"$'\t'"$orig")
          tmo 15 python3 "$PVPY" set "$u" cameraExposureRaw "$e" || { note "exposure change failed"; return 1; }
          sleep 3
        fi
        t0=$(date +%s)
        REWIND_ON=1
        rewind_set true > /dev/null || { note "Rewind start failed"; return 1; }
        sleep 3
        sess=$(rewind_session)
        echo "  recording ${STILL_SECS}s: ${sess:-?}"
        sleep $((STILL_SECS - 3 > 1 ? STILL_SECS - 3 : 1))
        rewind_set false > /dev/null; REWIND_ON=0
        t1=$(date +%s)
        if [[ $e != "$orig" ]]; then
          tmo 15 python3 "$PVPY" set "$u" cameraExposureRaw "$orig"; unset 'EXPO_CHANGED[-1]'
        fi
        stats=$(still_stats "$t0" "$t1")
        note "still ${sess:-(no session name)}: $name @$port, ~$dist m, exposure $e: $stats"
        sleep 2
      done
    done
  done <<< "$cams"
  note "copy the recordings to the laptop for the accuracy judge (tests/field-replay/accuracy):"
  note "  rsync -a jetson:/opt/photonvision/rewind/sessions/ logs/rewind/sessions/"
}

# ---------------------------------------------------------------------------------------------
# results.md: the TSVs averaged over rounds (max columns: worst), plus the notes
render() {
  BENCH_HERE=$HERE python3 - "$OUT" <<'PY' > "$OUT/results.md"
import collections, os, statistics, subprocess, sys, time
out = sys.argv[1]
def rows(name):
    p = f"{out}/{name}"
    return [l.rstrip("\n").split("\t") for l in open(p)] if os.path.exists(p) else []
def agg(rs, nkey, maxcols):
    g = collections.OrderedDict()
    for r in rs:
        g.setdefault(tuple(r[i] for i in nkey), []).append(r)
    for k, rr in g.items():
        cols = []
        for i in range(len(rr[0])):
            if i in nkey or i == 2: continue
            vals = [float(r[i]) for r in rr if i < len(r) and r[i] != ""]
            cols.append("" if not vals else f"{(max(vals) if i in maxcols else statistics.mean(vals)):.2f}".rstrip("0").rstrip("."))
        yield list(k), cols, len(rr)
print(f"# Bench session {os.path.basename(out)}\n")
print(f"Jetson {os.uname().nodename}, kernel {os.uname().release}; PhotonVision since "
      + subprocess.run(["systemctl", "show", "photonvision", "-p", "ActiveEnterTimestamp", "--value"],
                       capture_output=True, text=True).stdout.strip() + "\n")
print("Several rounds of an A/B are averaged (max columns: the worst round).\n")
print("## Per camera and per detector\n")
print("| step | condition | camera / detector | rounds | fps | latency median ms | p95 ms | max ms | detect avg ms | detect max ms | tags/frame | detections | margin avg |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for k, c, n in agg(rows("cams.tsv"), (0, 1, 3), {7, 9}):
    print("| " + " | ".join(k + [str(n)] + c) + " |")
print()
sys.stdout.flush()
subprocess.run([sys.executable, os.path.join(os.environ["BENCH_HERE"], "cameras.py"), "compare", out])
print("## Whole Jetson\n")
print("| step | condition | rounds | PV CPU % (1 core = 100) | camera threads % | workers % | other % | Jetson CPU % (avg of 6) | GPU % | power W | max temp C | NVJPG0 % | NVJPG1 % | nvjpg fps | libjpeg-turbo fps |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for k, c, n in agg(rows("sys.tsv"), (0, 1), {10}):
    print("| " + " | ".join(k + [str(n)] + c) + " |")
print("\n## Checks and notes\n")
print(open(f"{out}/notes.md").read() or "(none)")
if os.path.exists(f"{out}/camera-notes.md"):
    print("\n## Camera notes (from the bench)\n")
    print(open(f"{out}/camera-notes.md").read() or "(none given)")
print("\nRaw: session.log (everything printed), cameras.tsv, cams.tsv, sys.tsv, profile-cpu.txt, rt-ab.txt, usb-recovery.txt (when run)")
PY
  echo
  cat "$OUT/results.md"
  echo
  echo "Results: $OUT/results.md"
}

# ---------------------------------------------------------------------------------------------

[[ $(pv_pid) != 0 ]] || { echo "PhotonVision isn't running" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "Needs passwordless sudo (run 'sudo true' first)" >&2; exit 1; }
echo "Bench session: ${STEPS[*]} -> $OUT  (window ${SECS}s, ${ROUNDS} rounds; Ctrl-C puts everything back)"

declare -A LIMIT=([inventory]=300 [far]=$((ROUNDS * 2 * (SECS + 90) + 600)) [baseline]=900 [graphs]=$((ROUNDS * 2 * (SECS + 90) + 600))
                  [gpurefine]=$((ROUNDS * 3 * (SECS + 200) + 900))
                  [3d]=$((ROUNDS * 2 * (SECS + 120) + 600)) [rt]=$((4 * ROUNDS * (RT_SECS + 15) + 900))
                  [edge]=2400 [usb]=2400
                  [stills]=$((5 * 3 * 2 * (STILL_SECS + 90) + 600)))
for s in "${STEPS[@]}"; do
  step_begin "$s" "${LIMIT[$s]}"
  "step_$s"
  rc=$?
  if ((TIMED_OUT)); then note "TIMEOUT (limit ${LIMIT[$s]} s); moved on"
  elif ((rc == 2)); then note "skipped at the bench"
  elif ((rc != 0)); then note "failed (exit $rc); see session.log"
  else echo "  $s done"; fi
done
STEP=end
# Qualitative camera notes for the Thriftiest vs Swyft decision (results.md, "Camera notes")
camera_notes() {
  local l
  printf '\a\n>>> CAMERA NOTES: per camera, anything the numbers miss (mounting, focus, cable, lens, heat).\n'
  printf '>>> One line each, e.g. "Swyft @2.3: cable loose at the camera end". Empty line (or 5 min) ends.\n'
  : > "$OUT/camera-notes.md"
  while read -r -t 300 -p ">>> " l < /dev/tty && [[ -n $l ]]; do echo "- $l" >> "$OUT/camera-notes.md"; done
  echo
}
camera_notes
for s in "${STEPS[@]}"; do [[ $s == stills ]] && echo "Still recordings: copy them off with  rsync -a jetson:/opt/photonvision/rewind/sessions/ logs/rewind/sessions/  (session names in results.md)"; done
