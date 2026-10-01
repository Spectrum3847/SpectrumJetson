#!/usr/bin/env bash
# Is the Jetson ready to drive? Run ON THE JETSON (no sudo), e.g. from the laptop:
#   ssh -i ~/.ssh/jetson_ed25519 spectrum3847@<jetson-ip> ~/SpectrumJetson/scripts/jetson/health-check.sh
# Prints PASS / WARN / FAIL per check; exits 1 if anything FAILs.
# Usage: health-check.sh [expected_cameras]   (default 2)
set -uo pipefail

EXPECT=${1:-2}
fails=0 warns=0
pass() { printf "  PASS  %s\n" "$*"; }
warn() { printf "  WARN  %s\n" "$*"; warns=$((warns + 1)); }
fail() { printf "  FAIL  %s\n" "$*"; fails=$((fails + 1)); }

echo "== PhotonVision"
if systemctl is-active --quiet photonvision; then
  P=$(systemctl show photonvision -p MainPID --value)
  up=$(ps -o etimes= -p "$P" | tr -d ' ')
  restarts=$(systemctl show photonvision -p NRestarts --value)
  ver=$(journalctl _PID="$P" --no-pager -o cat 2>/dev/null | grep -m1 -oE "Starting PhotonVision version [^ ]+" | awk '{print $4}')
  pass "running ${up}s, version ${ver:-?}"
  [[ ${restarts:-0} -gt 0 ]] && warn "restarted $restarts time(s) since boot (check: journalctl -u photonvision)"
  # Normal: ~0.7 GB, plus ~0.4 GB per camera all in (decoder, detector, module): 2.25 GB with 5
  # cameras. A leak once grew it to 5.6 GB in minutes before the kernel killed it (libnvjpeg
  # outside MJPEG mode, 2026-09-24).
  rss_mb=$(( $(ps -o rss= -p "$P" | tr -d ' ') / 1024 ))
  ncam=$(ls -d /sys/bus/usb/drivers/uvcvideo/*:1.0 2>/dev/null | wc -l)
  rss_max=$(( 1000 + 500 * ncam ))
  [[ $rss_mb -gt $rss_max ]] && warn "PhotonVision is using ${rss_mb} MB of memory (over ${rss_max} MB for $ncam cameras): a leak? The kernel kills it near 7 GB"
  ooms=$(journalctl -u photonvision -b --no-pager 2>/dev/null | grep -c "killed by the OOM killer")
  [[ $ooms -gt 0 ]] && warn "PhotonVision was killed for running out of memory $ooms time(s) since boot"
  LOG=$(journalctl _PID="$P" --no-pager -o cat 2>/dev/null)
else
  fail "photonvision.service is not running (sudo systemctl restart photonvision)"
  P=0 LOG=""
fi

echo "== CUDA detector"
if grep -q "971 library loaded" <<<"$LOG"; then
  loaded=$(grep -m1 -o '971 library loaded.*' <<<"$LOG")
  pass "$loaded"
  # The robot settings (2026-09-24): the CPU sleeps while the GPU works, and 32 GPU work queues.
  # An older library doesn't print these.
  if grep -q "GPU connections" <<<"$loaded"; then
    grep -q "CUDA wait block" <<<"$loaded" ||
      warn "CUDA wait isn't block (/tmp/spectrum-971-cuda-sync or SPECTRUM_971_CUDA_SYNC left from a test?)"
    grep -q "GPU connections 32" <<<"$loaded" ||
      warn "GPU connections isn't 32 (rerun 08-select-detector.sh, or remove a test drop-in)"
  fi
  # Test switches the detector and decoder re-read every few seconds. Left behind after a test,
  # a fault hook keeps failing frames (and a sticky one restarts PhotonVision again after every
  # restart); the others change how it runs. /tmp is emptied at boot, so a reboot clears them too.
  for f in /tmp/spectrum-971-fault-every /tmp/spectrum-jpeg-fault; do
    [[ -e $f ]] && fail "test fault hook $f is set: sudo rm $f"
  done
  for f in /tmp/spectrum-971-gpu-lock /tmp/spectrum-971-gpu-input /tmp/spectrum-971-threads /tmp/spectrum-jpeg-decoder; do
    [[ -e $f ]] && warn "test override $f is set ($(head -c 40 "$f" 2>/dev/null)): remove it unless you meant it"
  done
elif grep -q "creategpudetector" <<<"$LOG"; then
  warn "running the 4143 detector build (not Austin's current bos build)"
else
  fail "CUDA detector not loaded (is an AprilTagCuda pipeline selected?)"
fi
recent=$(journalctl _PID="$P" --no-pager -o cat --since "-3 s" 2>/dev/null | grep '^971 stats')
handles=$(grep -oE '^971 stats h[0-9]+' <<<"$recent" | sort -u | awk '{print $3}')
for h in $handles; do
  line=$(grep "^971 stats $h " <<<"$recent" | tail -1)
  fps=$(awk '{for(i=1;i<=NF;i++) if($i=="calls/s,") print int($(i-1))}' <<<"$line")
  det=$(awk '{for(i=1;i<=NF;i++) if($i=="avg" && $(i-1)=="detect") print $(i+1)}' <<<"$line")
  err=$(awk '{for(i=1;i<=NF;i++) if($i=="errors") print $(i+1)}' <<<"$line")
  msg="$h: ${fps} fps, detect ${det} ms"
  if [[ -n $err ]]; then warn "$msg, CUDA errors $err"
  elif [[ ${fps:-0} -lt 30 ]]; then warn "$msg (low fps: exposure too long?)"
  else pass "$msg"; fi
done
[[ -z $handles && $P != 0 ]] && fail "no detector stats in the last 3 s (no CUDA pipeline running?)"
ndet=$(wc -w <<<"$handles")
ncam=$(ls -d /sys/bus/usb/drivers/uvcvideo/*:1.0 2>/dev/null | wc -l)
# AprilTag cameras: plugged in, and PhotonVision's saved pipeline for them is an AprilTag one
# (a game-piece or driver camera has no detector). Every camera if the config can't be read.
napril=$(python3 - <<'PY' 2>/dev/null
import glob, json, re, sqlite3
port = lambda s: (m := re.search(r"usb-0:([\d.]+):1\.0-video", s)) and m.group(1)
here = {port(p) for p in glob.glob("/dev/v4l/by-path/*-video-index0")}
db = sqlite3.connect("file:/opt/photonvision/photonvision_config/photon.sqlite?mode=ro", uri=True)
n = 0
for cfg, pipes in db.execute("select config_json, pipeline_jsons from cameras"):
    cfg, pipes = json.loads(cfg), json.loads(pipes)
    i = cfg.get("currentPipelineIndex", 0)
    if cfg.get("deactivated") or port(json.dumps(cfg.get("matchedCameraInfo", {}))) not in here or not 0 <= i < len(pipes):
        continue
    s = json.loads(pipes[i]) if isinstance(pipes[i], str) else pipes[i]
    n += "AprilTag" in (s[0] if isinstance(s, list) else "")
print(n)
PY
)
[[ -z $napril ]] && napril=$ncam
if [[ $P != 0 && $ndet -gt 0 && $ndet -lt $napril ]]; then
  warn "only $ndet of $napril AprilTag cameras are detecting (a camera stuck? restart PhotonVision, or replug it)"
fi
# A camera can get stuck sending corrupt JPEGs (seen once after rapid restarts): cscore drops them.
badjpeg=$(journalctl _PID="$P" --no-pager -o cat --since "-10 s" 2>/dev/null | grep -oE "[A-Za-z]+: invalid JPEG image received" | sort | uniq -c)
if [[ -n $badjpeg ]]; then
  while read -r n cam _; do
    warn "${cam%:} sent $n invalid JPEGs in 10 s (restart PhotonVision; if it persists, replug that camera)"
  done <<<"$badjpeg"
fi
# JPEG decoder ("971 jpeg" lines every 10 s): NVJPG hardware or libjpeg-turbo. Every ~2 s per
# camera one hardware frame is re-decoded by libjpeg-turbo; a difference turns the hardware off.
if grep -q "HARDWARE DECODE DIFFERS" <<<"$LOG"; then
  warn "hardware JPEG decode differed from libjpeg-turbo, so it's off until PhotonVision restarts (run tests/jpeg-hw/run.sh)"
elif grep -q "CUDA failed in the hardware decoder" <<<"$LOG"; then
  warn "the hardware JPEG decoder hit a CUDA error; libjpeg-turbo until PhotonVision restarts"
fi
jline=$(journalctl _PID="$P" --no-pager -o cat --since "-15 s" 2>/dev/null | grep '^971 jpeg [0-9]' | tail -1)
if [[ -n $jline ]]; then
  hw=$(awk '{for(i=1;i<=NF;i++) if($i=="nvjpg") {print int($(i+1)); exit}}' <<<"$jline")
  sw=$(awk '{for(i=1;i<=NF;i++) if($i=="libjpeg-turbo") {print int($(i+1)); exit}}' <<<"$jline")
  fell=$(grep -oE "[0-9]+ fell back" <<<"$jline" | awk '{print $1}')
  checks=$(grep -oE "[0-9]+ ok, [0-9]+ differ" <<<"$jline")
  wanted=$(grep '^971 jpeg decoder:' <<<"$LOG" | tail -1)
  if [[ $jline == *"hardware decoder OFF"* ]]; then
    pass "JPEG decode: libjpeg-turbo, $sw frames/s (hardware decoder off, see above; checks: $checks)"
  elif [[ ${hw:-0} -gt 0 ]]; then
    msg="JPEG decode: NVJPG hardware, $hw frames/s (checks: $checks)"
    [[ ${sw:-0} -gt 0 ]] && msg+=", libjpeg-turbo $sw frames/s"
    if [[ -n $fell ]]; then warn "$msg; $fell frames fell back to libjpeg-turbo in 10 s"; else pass "$msg"; fi
  elif [[ $wanted == *nvjpg* ]]; then
    why=$(grep -oE "971 jpeg: (can't load|no hardware decoder|this camera's JPEGs).*" <<<"$LOG" | tail -1)
    warn "hardware JPEG decode is switched on but not decoding (${why:-see journalctl -u photonvision}); libjpeg-turbo $sw frames/s"
  else
    pass "JPEG decode: libjpeg-turbo, $sw frames/s"
  fi
fi
calib8=$(grep -c "setparams handle .*(8 dist coeffs)" <<<"$LOG")
calib5=$(grep -c "setparams handle .*(5 dist coeffs)\|sending 5 of 8" <<<"$LOG")
want_cal=$(( napril > 0 ? napril : EXPECT ))
if [[ $calib8 -ge $want_cal ]]; then pass "calibration loaded for $calib8 detector(s), 8 lens coefficients"
elif [[ $calib8 -gt 0 ]]; then warn "calibration loaded for only $calib8 of $want_cal AprilTag cameras"
elif [[ $calib5 -gt 0 ]]; then warn "calibration loaded with only 5 lens coefficients"
else warn "no calibration loaded (3D mode needs one at the active resolution)"; fi
nfail=$(journalctl _PID="$P" --no-pager -o cat --since "-60 s" 2>/dev/null | grep -c "^971 detector h.* failure")
[[ $nfail -gt 0 ]] && warn "$nfail CUDA detector failures in the last minute"

echo "== Cameras"
DB=/opt/photonvision/photonvision_config/photon.sqlite
# Each camera's saved settings (config_json), one per line block. Python's sqlite3, read-only: the
# sqlite3 command isn't in the L4T image or installed by install.sh.
camera_configs() {
  python3 - "$DB" <<'PY' 2>/dev/null
import sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=2)
for (cfg,) in db.execute("select config_json from cameras"):
    print(cfg)
PY
}
# PhotonVision camera nickname bound to a USB port (it matches identical cameras by port).
cam_name() {
  camera_configs | python3 -c "
import json, sys, re
text = sys.stdin.read()
for chunk in re.split(r'(?m)^\\{', text):
    if 'usb-0:$1:1.0' in chunk:
        m = re.search(r'\"nickname\" : \"([^\"]*)\"', chunk)
        if m: print(m.group(1)); break
" 2>/dev/null
}
# Every camera PhotonVision knows (its settings name a USB port) that isn't on USB now: the loop
# below only sees cameras that are there, so an unplugged or stuck one used to pass unnoticed
# (2026-10-01: BottomLeft gone from port 2.2, and Match Ready said nothing about it).
while IFS=$'\t' read -r name port; do
  [[ -n $port ]] || continue
  ls /dev/v4l/by-path/*usb-0:"$port":1.0-video-index0 >/dev/null 2>&1 \
    || fail "$name isn't on USB (its port $port is empty): replug it, or power-cycle the robot if it's a stuck Thriftiest Cam"
done < <(camera_configs | python3 -c "
import sys, re
text = sys.stdin.read()
for chunk in re.split(r'(?m)^\{', text):
    n = re.search(r'\"nickname\" : \"([^\"]*)\"', chunk)
    p = re.search(r'usb-0:([0-9.]+):1\.0', chunk)
    if n and p: print(n.group(1) + '\t' + p.group(1))
" 2>/dev/null)
cams=0
for intf in /sys/bus/usb/drivers/uvcvideo/*:1.0; do
  [[ -e $intf ]] || continue
  dev=$(dirname "$(readlink -f "$intf")")
  port=$(basename "$dev")
  ctl=$(cat "$dev/power/control")
  speed=$(cat "$dev/speed")
  cams=$((cams + 1))
  hubport=${port#*-}   # 1-2.1 -> 2.1
  name=$(cam_name "$hubport")
  label="${name:-unnamed camera} on USB port $hubport"
  if [[ -z $name ]]; then warn "$label: not configured in PhotonVision (activate it in Camera Matching)"
  elif [[ $ctl == on ]]; then pass "$label (${speed} Mbps, autosuspend off)"
  else warn "$label has autosuspend on (run 09-robot-tuning.sh)"; fi
  # The mode the camera is really streaming, against the one PhotonVision last set. Setting it
  # races cscore's own restore at startup ("Failed to set video mode!" on every start); once
  # (2026-09-24) a camera stayed at 320x240, and cscore silently upscaled it to 1280x800 for
  # the detector, so fps and detect times looked normal while the image was a thumbnail.
  vdev=$(ls /dev/v4l/by-path/*usb-0:"$hubport":1.0-video-index0 2>/dev/null | head -1)
  if [[ -n $name && -n $vdev ]]; then
    fmt=$(v4l2-ctl -d "$vdev" --get-fmt-video 2>/dev/null)
    actual=$(awk -F'[:/ ]+' '/Width\/Height/ {print $3 "x" $4}' <<<"$fmt")
    pixfmt=$(grep -oE "Pixel Format *: *'[A-Z0-9]+'" <<<"$fmt" | grep -oE "'[A-Z0-9]+'" | tr -d "'")
    want=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$LOG" | grep -E "VisionSourceSettables - $name\] .*Setting video mode to" | tail -1 |
           sed -nE 's/.*Width: ([0-9]+) Height: ([0-9]+) Pixel Format: k([A-Za-z0-9]+).*/\1x\2 \3/p')
    if [[ -z $actual ]]; then warn "$name: couldn't read its video format (v4l2-ctl; is the user in the video group?)"
    elif [[ -n $want && ${want% *} != "$actual" ]]; then
      fail "$name is streaming ${actual} ${pixfmt}, but PhotonVision set ${want% *}: the detector gets an upscaled image (restart PhotonVision)"
    else pass "$name streaming ${actual} ${pixfmt}${want:+, as set}"; fi
  fi
done
if [[ $cams -lt $EXPECT ]]; then fail "$cams camera(s) found, expected $EXPECT"; fi
# USB 2.0 bandwidth: stock uvcvideo lets a Thriftiest Cam reserve ~196 Mbps, so only 2 fit on the
# USB-A ports; our capped driver (11-uvcvideo-payload-cap.sh) fits 4.
cap=$(cat /sys/module/uvcvideo/parameters/payload_cap 2>/dev/null || true)
if [[ -n $cap && $cap != "(null)" ]]; then pass "camera driver: bandwidth cap $cap"
elif [[ $cams -gt 2 ]]; then warn "stock camera driver: only 2 cameras fit on USB 2.0, on any ports (run 11-uvcvideo-payload-cap.sh --install)"
else pass "stock camera driver (fine for 2 cameras; more need 11-uvcvideo-payload-cap.sh)"; fi
# The USB controller watchdog (14-usb-watchdog.sh) and the 1 s USB retries (09-robot-tuning.sh).
if systemctl is-active --quiet usb-watchdog 2>/dev/null; then pass "USB controller watchdog running"
else warn "USB controller watchdog not running (scripts/jetson/14-usb-watchdog.sh --install)"; fi
udt=$(cat /sys/module/usbcore/parameters/initial_descriptor_timeout 2>/dev/null || echo "?")
[[ $udt == 1000 ]] || warn "USB retries time out after $udt ms, not 1000 (rerun 09-robot-tuning.sh)"
# USB bandwidth and connection trouble in the last 10 minutes, with what to do about it
# (usb-bandwidth.py: each camera's reservation, what failed, and the fix).
# readlink: also run through /opt/photonvision/health-check.sh (the Match ready page, photonvision-52)
UB=$(dirname "$(readlink -f "$0")")/usb-bandwidth.py
if [[ -x $UB ]]; then
  ub=$(python3 "$UB" --json 2>/dev/null || true)
  if [[ -n $ub ]]; then
    # Read through process substitution, not a pipe: fail() in a piped while loop runs in a subshell,
    # and its count was lost (USB FAIL lines with a READY verdict).
    while IFS=$'\t' read -r kind line; do [[ $kind == FAIL ]] && fail "$line" || pass "$line"; done < <(python3 - "$ub" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
for a in s.get("advice", []):
    print("FAIL\t" + a)
used = ", ".join("bus %d: %d of ~%d bytes" % (b["bus"], b["reservedBytes"], s["budgetBytes"]) for b in s["buses"])
if used:
    print("PASS\tUSB bandwidth reserved: %s per microframe (usb-bandwidth.py for details)" % used)
PY
)
  fi
fi

# photonvision-54: how each camera's tags look (only when a tag is close enough to measure).
contrast=$(timeout 5 python3 -c '
import json, urllib.request
for cam, t in json.load(urllib.request.urlopen("http://localhost:5800/api/tagContrast", timeout=3)).items():
    if t["verdict"] == "no tags": continue
    line = "%s tags: white %s, black %s (contrast %s), %s%% clipped: %s" % (cam, t["white"], t["black"], t["contrast"], t["clipped"], t["verdict"])
    print(("PASS\t" if t["verdict"] == "good" else "WARN\t") + line + ("" if t["verdict"] == "good" else ". " + t["advice"]))
' 2>/dev/null || true)
while IFS= read -r l; do
  [[ -z $l ]] && continue
  case ${l%%$'\t'*} in PASS) pass "${l#*$'\t'}" ;; WARN) warn "${l#*$'\t'}" ;; esac
done <<<"$contrast"

echo "== Robot connection"
last_nt=$(grep -E "NT connected to|Could not connect to the robot|disconnected" <<<"$LOG" | tail -1)
team=$(grep -m1 -oE "server team is [0-9]+|server IP is [^ ]+" <<<"$LOG")
if grep -q "NT connected to" <<<"$last_nt"; then
  pass "$(grep -oE 'NT connected to [^!]+' <<<"$last_nt") (${team})"
  if grep -q "Changing TimeSyncClient server to" <<<"$LOG"; then pass "time sync pointed at the robot"
  else warn "time sync has not switched to the robot yet"; fi
else
  warn "not connected to the robot (${team:-no team set}); expected off the robot"
fi
# Bench tests stand in for the robot by taking over its address (10.85.15.2): tests/fake-robot puts
# it on the loopback, and tests/systemcore-rehearsal redirects it to a laptop. If either is left
# behind, PhotonVision can't reach the real robot.
if ip -4 addr show dev lo 2>/dev/null | grep -q " 10\.85\.15\.2/"; then
  fail "the robot's address 10.85.15.2 is on the loopback (left by tests/fake-robot): sudo ip addr del 10.85.15.2/32 dev lo"
fi
if sudo -n iptables -t nat -S 2>/dev/null | grep -q SPECTRUM_REHEARSAL; then
  fail "the robot's address is redirected to a laptop (left by tests/systemcore-rehearsal): run.sh --cleanup on the laptop, or restart the Jetson"
fi
# Camera-clock timestamps (uvcvideo hwtimestamps=1): 0.01 ms jitter instead of 0.95 ms.
if [[ $(cat /sys/module/uvcvideo/parameters/hwtimestamps 2>/dev/null) == 1 ]]; then
  pass "frames timestamped by the camera clock (uvcvideo hwtimestamps)"
else
  warn "frames timestamped on USB arrival (~1 ms jitter): 11-uvcvideo-payload-cap.sh --install sets hwtimestamps=1"
fi
# A driver setting changed live but not saved is lost at the next boot (a 5th camera's 1280-byte
# cap set by hand once reverted to 256 that way). Compare each live value with modprobe.d.
for parm in payload_cap hwtimestamps urb_packets; do
  live=$(cat /sys/module/uvcvideo/parameters/$parm 2>/dev/null) || continue
  saved=$(cat /etc/modprobe.d/9*-spectrum-uvcvideo*.conf 2>/dev/null | sed -n "s/^options uvcvideo .*$parm=\([^ ]*\).*/\1/p" | tail -1)
  default=$([[ $parm == payload_cap ]] && echo "" || echo 0)
  if [[ $live != "${saved:-$default}" ]]; then
    warn "camera driver $parm is '$live' now but '${saved:-$default}' after a reboot (save it: Camera Matching page for payload_cap, or /etc/modprobe.d)"
  fi
done
urbp=$(cat /sys/module/uvcvideo/parameters/urb_packets 2>/dev/null || echo none)
case $urbp in
  16) pass "camera driver hands frames over in 2 ms steps (urb_packets 16)" ;;
  none) warn "stock camera driver: no payload_cap or urb_packets (11-uvcvideo-payload-cap.sh --install)" ;;
  *) warn "camera driver urb_packets is $urbp (16 is 1.2 ms lower latency than the stock 32; 11-uvcvideo-payload-cap.sh --install)" ;;
esac
# photonvision-49/50: idle mode (30 fps per camera while the robot is disabled) switched off?
idle=$(timeout 5 python3 -c 'import json,urllib.request; s=json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=3)); print("on %g" % s["idleFps"] if s["idleWhileDisabled"] else "off")' 2>/dev/null || true)
case $idle in
  on*) pass "idle while disabled: ${idle#on } fps per camera" ;;
  off) warn "idle while disabled is off: cameras run at full speed while the robot is disabled (Settings > Robot state)" ;;
esac
# photonvision-55: far-tag search (full-size searches while no camera has a good view).
far=$(timeout 5 python3 -c 'import json,urllib.request; s=json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=3)); print("on %g %s" % (s["farSweepsPerSecond"], s.get("farSearchSweeps", "?")) if s["farSearch"] else "off")' 2>/dev/null || true)
case $far in
  on*) set -- $far; pass "far-tag search on: up to $2 full-size searches a second while no camera has a good view ($3 so far)" ;;
  off) echo "        far-tag search off (Settings > Robot state): tags under ~20 px aren't searched for" ;;
esac
# photonvision-51: the event pipeline, and what each camera has at that number.
event=$(timeout 5 python3 - <<'PY' 2>/dev/null || true
import json, urllib.request
get = lambda p: json.load(urllib.request.urlopen("http://localhost:5800" + p, timeout=3))
s = get("/api/robotState")
if s["eventProfileOnFms"]:
    n = s["eventPipeline"]
    cams = get("/api/spectrum/uiState")["cameras"]
    have = ["%s '%s'" % (c["nickname"], c["pipelineNicknames"][n]) for c in cams if len(c["pipelineNicknames"]) > n]
    miss = [c["nickname"] for c in cams if len(c["pipelineNicknames"]) <= n]
    names = {c["pipelineNicknames"][n] for c in cams if len(c["pipelineNicknames"]) > n}
    line = "event pipeline %d when the field connects: %s" % (n, ", ".join(have))
    if miss: line += "; no pipeline %d on %s" % (n, ", ".join(miss))
    print(("WARN\t" if miss or len(names) > 1 else "PASS\t") + line)
else:
    print("INFO\tevent pipeline when the field connects: off (Settings > Robot state)")
PY
)
case ${event%%$'\t'*} in
  PASS) pass "${event#*$'\t'}" ;;
  WARN) warn "${event#*$'\t'}" ;;
  INFO) echo "        ${event#*$'\t'}" ;;
esac
ips=$(ip -4 -br addr | awk '$1 !~ /^(lo|l4tbr0|usb|docker)/ && $3 != "" {print $1" "$3}' | paste -sd',' | sed 's/,/, /g')
echo "        addresses: ${ips:-none}"
if nmcli -t -f DEVICE,TYPE,STATE dev 2>/dev/null | grep -q ":wifi:connected"; then
  warn "Wi-Fi is connected: turn it off before competition (robot coprocessors may not use radios)"
fi

echo "== Storage"
# 10-data-partition.sh: settings and scratch partitions, and spectrum-data-fallback's verdict.
if ! grep -q x-spectrum-data /etc/fstab 2>/dev/null; then
  warn "no data partitions: everything is written to the system partition (run 10-data-partition.sh)"
else
  ds=$(cat /run/spectrum-data-status 2>/dev/null)
  case $ds in
    *settings=ok*) findmnt -n /opt/photonvision/photonvision_config >/dev/null \
                     && pass "settings partition mounted (sync, data=journal)" \
                     || fail "settings partition mounted but PhotonVision's folder isn't bound to it" ;;
    *settings=last-good*) fail "settings partition didn't mount: running on the last-good settings from $(cat /opt/photonvision/.last-good-settings/.committed 2>/dev/null), changes aren't kept" ;;
    *settings=defaults*) fail "settings partition didn't mount and no last-good copy: PhotonVision is on DEFAULT settings" ;;
    *) warn "data fallback didn't run this boot (spectrum-data-fallback.service)" ;;
  esac
  case $ds in
    # (Through Rewind's bind mount: /data is root-only, and this runs without sudo.)
    *scratch=ok*) pass "scratch partition mounted ($(df -h --output=avail /opt/photonvision/rewind 2>/dev/null | tail -1 | xargs) free)" ;;
    *scratch=missing*) fail "scratch partition didn't mount: not recording, logs in RAM (copy off what you need, then 10-data-partition.sh --reformat-scratch)" ;;
  esac
  if [[ -d /opt/photonvision/.last-good-settings ]]; then
    pass "last-good settings committed $(cat /opt/photonvision/.last-good-settings/.committed 2>/dev/null)"
  else
    warn "no last-good settings committed (10-data-partition.sh --commit-settings after tuning)"
  fi
fi
# Thermal limit (spectrum-fan-guard, FAN=off): cameras capped while the chip is hot.
if [[ -f /run/spectrum-thermal-limit ]]; then
  fail "thermal limit: cameras capped ($(cat /run/spectrum-thermal-limit)); it lifts below 88 C"
fi
# Quiet mode (photonvision-56): the SSD isn't being written after a match.
IFS=$'\t' read -r pvquiet pvquiet_err < <(timeout 5 python3 -c 'import json,urllib.request; s=json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=3)); print(s.get("quietNow"), s.get("quietError") or "", sep="\t")' 2>/dev/null || true)
scratch_ro=$(findmnt -n -o OPTIONS /data/scratch 2>/dev/null | tr ',' '\n' | grep -qx ro && echo yes)
if [[ ($scratch_ro == yes || -f /run/spectrum-quiet) && $pvquiet == False ]]; then
  # Quiet mode, then a PhotonVision restart: before photonvision-64 the new process didn't know,
  # so no enable made the partition writable again and Rewind couldn't record.
  fail "scratch partition read-only, but PhotonVision isn't in quiet mode (left from before a restart): Rewind can't record. sudo spectrum-quiet off"
elif [[ $pvquiet == True && -n $pvquiet_err ]]; then
  # photonvision-65: leaving quiet mode failed; PhotonVision stays quiet and retries every 5 s.
  fail "quiet mode can't end: $pvquiet_err (retried every 5 s; Rewind can't record until it works)"
elif [[ -n $pvquiet_err ]]; then
  warn "quiet mode couldn't start last time: $pvquiet_err (the SSD was written after that match)"
elif [[ -f /run/spectrum-quiet ]]; then
  pass "quiet mode: scratch partition read-only ($(cat /run/spectrum-quiet)); any enable ends it"
elif grep -q x-spectrum-data /etc/fstab 2>/dev/null && [[ ! -x /usr/local/bin/spectrum-quiet ]]; then
  warn "quiet mode's helper isn't installed (re-run 10-data-partition.sh)"
fi
# Read-only system partition (ro-root.sh).
if [[ $(findmnt -n -o FSTYPE /) == overlay ]]; then
  pass "system partition read-only (ro-root on; $(( $(df --output=used -k / | tail -1) / 1024 )) MB in its RAM layer)"
else
  warn "system partition writable (ro-root.sh on before competition)"
fi
# The SSD's own error count: it should never grow. 285 of these killed the first SSD.
if command -v smartctl >/dev/null; then
  me=$(smartctl -A /dev/nvme0 2>/dev/null | awk -F: '/Media and Data Integrity Errors/ {gsub(/[ ,]/,"",$2); print $2}')
  us=$(smartctl -A /dev/nvme0 2>/dev/null | awk -F: '/Unsafe Shutdowns/ {gsub(/[ ,]/,"",$2); print $2}')
  if [[ -n $me && $me -gt 0 ]]; then fail "SSD reports $me media errors (unreadable data): replace it"
  elif [[ -n $me ]]; then pass "SSD: no media errors ($us unsafe shutdowns)"; fi
else
  warn "smartctl not installed: SSD health unknown (sudo apt install smartmontools)"
fi

echo "== System"
mode=$(cut -d: -f2 /var/lib/nvpmodel/status 2>/dev/null)
[[ $mode == 0002 ]] && pass "power mode MAXN SUPER" || fail "power mode is ${mode:-unknown}, expected MAXN SUPER (0002)"
cmin=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq) cmax=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
G=$(ls -d /sys/devices/platform/bus@0/17000000.gpu/devfreq/* 2>/dev/null | head -1)
gmin=$(cat "$G/min_freq" 2>/dev/null) gmax=$(cat "$G/max_freq" 2>/dev/null)
if [[ $cmin == "$cmax" && -n $gmin && $gmin == "$gmax" ]]; then pass "clocks locked (CPU $((cmax / 1000)) MHz, GPU $((gmax / 1000000)) MHz)"
else warn "clocks not locked (CPU min $((cmin / 1000)) / max $((cmax / 1000)) MHz): jetson-clocks service?"; fi
hot=0 hotname=""
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat "$z/temp" 2>/dev/null) || continue
  [[ $t -gt $hot ]] && hot=$t hotname=$(cat "$z/type")
done
tc=$((hot / 1000))
# Fanless (09-robot-tuning.sh FAN=off, the fan guard running): idle at 30 fps settles ~80 C on the
# plate and matches peak 86-88 C (README, Fanless), and the guard caps the cameras at 60 fps from
# 95 C. So warn at 90 and fail at 95 there; with a fan, warn at 70 and fail at 85.
warn_c=70 fail_c=85
systemctl is-active --quiet spectrum-fan-guard && warn_c=90 fail_c=95
if [[ $tc -ge $fail_c ]]; then fail "hottest sensor ${hotname} ${tc} C (throttling territory)"
elif [[ $tc -ge $warn_c ]]; then warn "hottest sensor ${hotname} ${tc} C (check the fan and airflow)"
else pass "hottest sensor ${hotname} ${tc} C"; fi
avail=$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
[[ $avail -ge 1500 ]] && pass "memory available ${avail} MB" || warn "memory available only ${avail} MB"
disk=$(df -P / | awk 'NR == 2 {print int($5)}')
[[ $disk -lt 85 ]] && pass "disk ${disk}% used" || warn "disk ${disk}% used"
# Fan: pwm1 is only what the fan was told to do. The real speed comes from the tachometer, so a
# jammed, dead or unplugged fan (0 rpm at pwm 255) can't pass. Full speed measured 5,586-6,234 rpm.
fan=$(cat /sys/devices/platform/pwm-fan*/hwmon/hwmon*/pwm1 2>/dev/null | head -1)
tach=$(grep -lx pwm_tach /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1)
rpm=""
if [[ -n $tach ]]; then
  rpm=0
  for _ in 1 2 3; do   # highest of 3 reads, so one slow tach sample isn't a false alarm
    r=$(cat "${tach%/name}/rpm" 2>/dev/null || echo 0)
    [[ $r -gt $rpm ]] && rpm=$r
    sleep 0.3
  done
fi
profile=$(sed -n 's/^[[:space:]]*FAN_DEFAULT_PROFILE[[:space:]]*//p' /etc/nvfancontrol.conf 2>/dev/null | head -1)
if systemctl is-active --quiet spectrum-fan-guard; then fanmode="off (fanless), cameras capped at 95 C"
elif systemctl is-active --quiet nvfancontrol; then fanmode="NVIDIA fan control, ${profile:-?} profile"
elif [[ ${fan:-0} -ge 250 ]]; then fanmode="full speed (jetson_clocks)"
else fanmode="fixed at pwm ${fan:-?}/255"; fi
if [[ -z $rpm ]]; then
  warn "fan speed unknown (no tachometer found); mode: $fanmode"
elif [[ ${fan:-0} -ge 100 && $rpm -lt 1000 ]]; then
  fail "fan not spinning: $rpm rpm at pwm ${fan}/255 (unplugged, jammed or dead: check its cable)"
elif [[ $fanmode == "full speed (jetson_clocks)" && $rpm -lt 4500 ]]; then
  warn "fan slow: $rpm rpm at full speed, normally ~5,600-6,200 (dust or a worn bearing?)"
elif [[ $fanmode == off* && ${fan:-0} -eq 0 ]]; then
  pass "fan: $fanmode, pwm 0/255, $rpm rpm"
elif [[ $fanmode == off* ]]; then
  warn "fan: $fanmode, but it's running (pwm ${fan}/255, $rpm rpm): FAN_ON_HOT, or something else drives it"
elif [[ $fanmode == NVIDIA* || $fanmode == full* ]]; then
  # The quiet profile (09-robot-tuning.sh's default) speeds up as the chip warms; FAN=full is full speed.
  pass "fan: $fanmode, pwm ${fan:-?}/255, $rpm rpm"
else
  warn "fan $fanmode and not controlled: $rpm rpm (run 09-robot-tuning.sh)"
fi
year=$(date -u +%Y)
if [[ $year -ge 2026 ]]; then pass "clock: $(date -u '+%Y-%m-%d %H:%M UTC')"
else warn "clock says $year: not set yet (no internet, and robot code hasn't published /photonvision/clock/unixMs)"; fi
# Filesystem errors ext4 has recorded (world-readable counter; a power cut alone shouldn't cause any).
fsdev=$(basename "$(findmnt -no SOURCE /)")
fserr=$(cat "/sys/fs/ext4/$fsdev/errors_count" 2>/dev/null || echo "?")
if [[ $fserr == 0 ]]; then pass "filesystem: no ext4 errors recorded"
elif [[ $fserr == "?" ]]; then warn "filesystem: could not read the ext4 error count"
else fail "filesystem: $fserr ext4 error(s) recorded (see docs/TECHNICAL.md, power-cut safety)"; fi
if [[ -d /var/log/journal ]]; then
  boots=$(journalctl --list-boots --no-pager 2>/dev/null | wc -l)
  pass "system log kept across power cuts ($boots boot(s) on file)"
else
  warn "system log is RAM-only: it's lost at every power cut (run 09-robot-tuning.sh)"
fi
boot=$(systemd-analyze 2>/dev/null | grep -oE '= [0-9.]+s' | tr -d '= ')
[[ -n $boot ]] && echo "        boot time: ${boot} ($(systemctl get-default))"

echo
if [[ $fails -gt 0 ]]; then echo "NOT READY: $fails failure(s), $warns warning(s)"; exit 1; fi
echo "READY${warns:+ ($warns warning(s))}"
