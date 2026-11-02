#!/usr/bin/env bash
# Fake cameras for testing without hardware: Rewind recordings played into v4l2loopback devices,
# with PhotonVision running on a throwaway settings folder (in RAM) so your real cameras' settings
# are never touched. Run ON THE JETSON.
#
#   fake-cameras.sh start [SESSION_DIR]   one fake camera per camera folder of the session
#                                          (default: a synthetic session with tags, generated)
#   fake-cameras.sh status
#   fake-cameras.sh stop                   real settings and real cameras back, as before
#
# While it runs, PhotonVision sees only the fake cameras (FakeCam-1, -2, ...): the real ones are
# unassigned in the throwaway settings. Fake cameras have no exposure/gain controls and no USB
# bandwidth, so tests of those skip. Needs v4l2loopback (install.sh's fake-cameras step, or
# sudo apt install v4l2loopback-dkms) and photonvision-60 or later.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PV=/opt/photonvision
RUN=/run/spectrum-fakecam
UDEV=/etc/udev/rules.d/90-spectrum-fakecam.rules
FIRST=40   # /dev/video40, 41, ...
API=http://localhost:5800

sudo -n true 2>/dev/null || sudo -v
api_ok() { python3 -c "import urllib.request; urllib.request.urlopen('$API/', timeout=2)" 2>/dev/null; }
wait_pv() {
  local end=$((SECONDS + 90))
  until api_ok; do ((SECONDS < end)) || { echo "PhotonVision didn't come back within 90 s" >&2; return 1; }; sleep 2; done
}
# The player runs as root: kill -0 on it as a normal user fails with EPERM, so ask with sudo.
running() { [[ -f $RUN/player.pid ]] && sudo kill -0 "$(cat $RUN/player.pid)" 2>/dev/null; }

start() {
  local session=${1:-$HOME/fakecam/synthetic}
  running && { echo "Already running ($(cat $RUN/session))."; exit 0; }
  if [[ ! -d $session ]]; then
    [[ $session == "$HOME/fakecam/synthetic" ]] || { echo "No session at $session" >&2; exit 1; }
    gen=$HOME/build/gpu-detector/far_search_test
    [[ -x $gen ]] || cmake --build "$HOME/build/gpu-detector" --target far_search_test --parallel 3 >/dev/null
    mkdir -p "$HOME/fakecam"
    "$gen" --write-session "$session" | tail -1
  fi
  mapfile -t cams < <(find "$session" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  ((${#cams[@]})) || { echo "No camera folders in $session" >&2; exit 1; }
  n=${#cams[@]}
  nrs=$(seq -s, $FIRST $((FIRST + n - 1)))
  labels=$(for i in $(seq 1 "$n"); do printf 'FakeCam-%d,' "$i"; done); labels=${labels%,}
  echo "==> $n fake camera(s) from $session: ${cams[*]}"
  modinfo v4l2loopback >/dev/null 2>&1 || { echo "v4l2loopback isn't installed: sudo apt install v4l2loopback-dkms" >&2; exit 1; }
  # Anything that goes wrong from here puts everything back (real settings, PhotonVision running).
  trap 'echo "start failed: putting everything back"; trap - ERR; stop; exit 1' ERR
  set -E
  # PhotonVision stops first, and any player left from an earlier run goes, so the module reloads
  # clean.
  sudo systemctl stop photonvision
  sudo pkill -f "tools/fakecam/fakecam.py" 2>/dev/null; sleep 1
  # PhotonVision skips cameras without a /dev/v4l/by-id or by-path link; give the fakes one.
  echo 'SUBSYSTEM=="video4linux", ATTR{name}=="FakeCam-*", SYMLINK+="v4l/by-id/spectrum-fakecam-$attr{name}-video-index0"' \
    | sudo tee "$UDEV" >/dev/null
  sudo udevadm control --reload
  if lsmod | grep -q '^v4l2loopback'; then
    sudo modprobe -r v4l2loopback || { echo "v4l2loopback is in use (lsof /dev/video4*): can't reload it" >&2; false; }
  fi
  # exclusive_caps is per device: a single value sets only the first one (seen: "Y,N,N,..."), and
  # that first device then refused the player's format (EINVAL). Give every device the same value.
  caps=$(for i in $(seq 1 "$n"); do printf '0,'; done); caps=${caps%,}
  sudo modprobe v4l2loopback devices="$n" video_nr="$nrs" card_label="$labels" exclusive_caps="$caps" max_buffers=4 || exit 1
  sudo udevadm trigger --subsystem-match=video4linux; sudo udevadm settle
  sudo mkdir -p "$RUN"; echo "$session" | sudo tee "$RUN/session" >/dev/null
  devs=$(seq -s, -f "/dev/video%g" $FIRST $((FIRST + n - 1)))
  sudo sh -c "nohup python3 '$ROOT/tools/fakecam/fakecam.py' '$session' --devices '$devs' --cameras '$(IFS=,; echo "${cams[*]}")' > '$RUN/player.log' 2>&1 & echo \$! > '$RUN/player.pid'"
  sleep 3
  if ! running || grep -q Traceback "$RUN/player.log"; then echo "The player failed:"; cat "$RUN/player.log"; false; fi
  echo "==> PhotonVision on a throwaway settings folder (RAM); your real settings are left alone"
  for d in photonvision_config snapshots; do
    sudo mkdir -p "$RUN/$d"
    findmnt -n "$RUN/$d" >/dev/null || sudo mount -t tmpfs -o size=256M fakecam "$RUN/$d"
  done
  # The throwaway settings start as a copy of the real database with no cameras in it: the team
  # number and network settings come along (or PhotonVision wouldn't look for the robot), no real
  # camera's setup does. A consistent copy (SQLite backup), from the real file, before the binds.
  sudo python3 - "$PV/photonvision_config/photon.sqlite" "$RUN/photonvision_config/photon.sqlite" <<'PYDB'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.execute("DELETE FROM cameras")
dst.commit()
dst.execute("VACUUM")
print("throwaway settings: network/team settings kept, cameras removed")
PYDB
  for d in photonvision_config snapshots; do sudo mount --bind "$RUN/$d" "$PV/$d"; done
  sudo systemctl start photonvision
  wait_pv
  echo "==> Adopting the fake cameras"
  local end=$((SECONDS + 60)) adopted=0
  while ((SECONDS < end && adopted < n)); do
    adopted=$(python3 - "$API" <<'PY'
import json, sys, urllib.request
api = sys.argv[1]
u = json.load(urllib.request.urlopen(api + "/api/spectrum/uiState", timeout=5))
done = sum(1 for c in u["cameras"] if c["nickname"].startswith("FakeCam") or "fakecam" in json.dumps(c).lower())
for info in u.get("unmatchedCameras", []):
    if "fakecam" not in json.dumps(info).lower():
        continue
    req = urllib.request.Request(api + "/api/utils/assignUnmatchedCamera", data=json.dumps({"cameraInfo": info}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"assign failed: {e}", file=sys.stderr)
print(len([c for c in json.load(urllib.request.urlopen(api + "/api/spectrum/uiState", timeout=5))["cameras"]]))
PY
)
    ((adopted < n)) && sleep 3
  done
  trap - ERR
  ((adopted >= n)) || { echo "Only $adopted of $n fake cameras adopted"; stop; exit 1; }
  status
}

stop() {
  echo "==> Real settings back"
  sudo systemctl stop photonvision
  for d in snapshots photonvision_config; do
    while findmnt -n "$PV/$d" | grep -q fakecam; do sudo umount "$PV/$d"; done
    findmnt -n "$RUN/$d" >/dev/null && sudo umount "$RUN/$d"
  done
  if running; then sudo kill "$(cat $RUN/player.pid)"; fi
  sudo pkill -f "tools/fakecam/fakecam.py" 2>/dev/null
  # The module can only unload once the player has closed the devices.
  for _ in $(seq 20); do pgrep -f "tools/fakecam/fakecam.py" >/dev/null || break; sleep 0.25; done
  sudo rm -rf "$RUN"
  if lsmod | grep -q '^v4l2loopback'; then
    sudo modprobe -r v4l2loopback || echo "v4l2loopback still in use; it's unloaded at the next start"
  fi
  sudo systemctl start photonvision
  wait_pv && echo "PhotonVision back on the real settings and cameras."
}

status() {
  if running; then
    echo "fake cameras: playing $(cat $RUN/session)"
    tail -1 "$RUN/player.log" 2>/dev/null | sed 's/^/  player: /'
  else
    echo "fake cameras: not running"
  fi
  findmnt -n "$PV/photonvision_config" | grep -q fakecam && echo "PhotonVision: throwaway settings (real ones untouched)" \
    || echo "PhotonVision: real settings"
  python3 - "$API" <<'PY' 2>/dev/null
import json, sys, urllib.request
u = json.load(urllib.request.urlopen(sys.argv[1] + "/api/spectrum/uiState", timeout=5))
print("cameras in PhotonVision:", ", ".join(c["nickname"] for c in u["cameras"]) or "none")
PY
}

case ${1:-} in
  start) start "${2:-}" ;;
  stop) stop ;;
  status) status ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
