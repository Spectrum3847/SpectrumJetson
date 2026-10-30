#!/usr/bin/env bash
# Flashes one Thriftiest Cam for PhotonVision's Settings > Thriftiest Cam firmware card
# (photonvision-87). PhotonVision starts it as a transient systemd unit, so it outlives PhotonVision,
# which it stops: PhotonVision's camera watchdog would reset the camera mid-write
# (docs/THRIFTIEST-CAM-FIRMWARE.md). PhotonVision is always started again, whatever happens.
# Progress goes to /run/spectrum/thriftiest-flash.json for the card to show.
#
# Usage (as root): thriftiest-flash-job.sh PORT FIRMWARE.bin      e.g. 2.1 /path/usbrecov.bin
set -uo pipefail
port=${1:?usage: $0 PORT FIRMWARE.bin}
image=${2:?usage: $0 PORT FIRMWARE.bin}
HERE=$(dirname "$(readlink -f "$0")")
RUN=/run/spectrum
STATUS=$RUN/thriftiest-flash.json
LOG=$RUN/thriftiest-flash.log
mkdir -p "$RUN"
: > "$LOG"
started=$(date +%s)

status() {  # STATE MESSAGE
  python3 - "$1" "$2" "$port" "$(basename "$image")" "$started" "$LOG" > "$STATUS.new" <<'PY'
import json, sys, time
state, message, port, image, started, log = sys.argv[1:7]
try:
    tail = open(log, errors="replace").read().replace("\r", "\n").splitlines()[-12:]
except OSError:
    tail = []
print(json.dumps({"state": state, "message": message, "port": port, "image": image,
                  "started": int(started), "updated": int(time.time()), "log": tail}))
PY
  mv -f "$STATUS.new" "$STATUS"
}

# pyusb: the system's (09-robot-tuning.sh installs python3-usb), else the copy
# scripts/host/thriftiest-flash.sh leaves in the user's ~/thriftiest-fw/lib.
pypath=""
if ! python3 -c "import usb" 2>/dev/null; then
  pypath=$(ls -d /home/*/thriftiest-fw/lib 2>/dev/null | head -1)
  if [[ -z $pypath ]] || ! PYTHONPATH=$pypath python3 -c "import usb" 2>/dev/null; then
    status failed "pyusb isn't installed (sudo apt install python3-usb, or run scripts/host/thriftiest-flash.sh once from a laptop)"
    exit 1
  fi
fi
# Backups next to the laptop script's: the repo owner's ~/thriftiest-backups.
owner=$(stat -c %U "$HERE")
backups=$(getent passwd "$owner" | cut -d: -f6)/thriftiest-backups

trap 'systemctl start photonvision; [[ ${finished:-} ]] || status failed "Stopped before finishing; PhotonVision started again"' EXIT
status running "Stopping PhotonVision"
systemctl stop photonvision
status running "Flashing the camera on port $port (about 45 s)"
PYTHONPATH=$pypath python3 -u "$HERE/thriftiest-fw.py" flash --port "$port" "$image" --yes --backup-dir "$backups" >> "$LOG" 2>&1 &
pid=$!
while kill -0 $pid 2>/dev/null; do
  status running "Flashing the camera on port $port (about 45 s)"
  sleep 2
done
wait $pid
rc=$?
chown -R "$owner": "$backups" 2>/dev/null
status running "Starting PhotonVision"
systemctl start photonvision
finished=1
if [[ $rc -eq 0 ]]; then
  status done "$(grep -E '^(Done|Already up to date)' "$LOG" | tail -1)"
else
  status failed "$(grep -E '^ERROR' "$LOG" | tail -1 | sed 's/^ERROR: //')"
fi
exit $rc
