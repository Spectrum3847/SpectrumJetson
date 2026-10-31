#!/usr/bin/env bash
# Flashes one Swyft USB Camera for PhotonVision's Settings > Swyft camera firmware card. PhotonVision
# starts it as a transient systemd unit, so it outlives PhotonVision, which it stops: PhotonVision's
# camera watchdog would reset the camera mid-write (docs/SWYFT-CAMERA-FIRMWARE.md). PhotonVision is
# always started again, whatever happens. Progress goes to /run/spectrum/swyft-flash.json for the card.
# After the boot loader the camera's video stays off until the robot is power cycled (a Jetson reboot
# isn't enough); the card says so.
#
# Usage (as root): swyft-flash-job.sh PORT FIRMWARE.rfw BACKUP_DIR [SERIAL]
#   e.g. 2.4 /path/LowExposureSWYFTUSBOV9281.rfw /opt/photonvision/photonvision_config/swyft-firmware/backups SJ-SW01
set -uo pipefail
port=${1:?usage: $0 PORT FIRMWARE.rfw BACKUP_DIR [SERIAL]}
image=${2:?usage: $0 PORT FIRMWARE.rfw BACKUP_DIR [SERIAL]}
backups=${3:?usage: $0 PORT FIRMWARE.rfw BACKUP_DIR [SERIAL]}
serial=${4:-}
HERE=$(dirname "$(readlink -f "$0")")
RUN=/run/spectrum
STATUS=$RUN/swyft-flash.json
LOG=$RUN/swyft-flash.log
mkdir -p "$RUN"
: > "$LOG"
started=$(date +%s)

status() {  # STATE MESSAGE
  python3 - "$1" "$2" "$port" "$(basename "$image")" "$serial" "$started" "$LOG" > "$STATUS.new" <<'PY'
import json, sys, time
state, message, port, image, serial, started, log = sys.argv[1:8]
try:
    tail = open(log, errors="replace").read().replace("\r", "\n").splitlines()[-12:]
except OSError:
    tail = []
print(json.dumps({"state": state, "message": message, "port": port, "image": image, "serial": serial,
                  "started": int(started), "updated": int(time.time()), "log": tail}))
PY
  mv -f "$STATUS.new" "$STATUS"
}

if ! python3 -c "import usb" 2>/dev/null; then
  status failed "pyusb isn't installed (sudo apt install python3-usb)"
  exit 1
fi
args=(flash --port "$port" "$image" --yes --backup-dir "$backups")
[[ -n $serial ]] && args+=(--serial "$serial")

trap 'systemctl start photonvision; [[ ${finished:-} ]] || status failed "Stopped before finishing; PhotonVision started again"' EXIT
status running "Stopping PhotonVision"
systemctl stop photonvision
status running "Flashing the camera on port $port (about 10 s)"
python3 -u "$HERE/swyft-fw.py" "${args[@]}" >> "$LOG" 2>&1 &
pid=$!
while kill -0 $pid 2>/dev/null; do
  status running "Flashing the camera on port $port (about 10 s)"
  sleep 2
done
wait $pid
rc=$?
status running "Starting PhotonVision"
systemctl start photonvision
finished=1
if [[ $rc -eq 0 ]]; then
  if grep -q '^Already up to date' "$LOG"; then
    msg="Already up to date: nothing written."
  else
    msg="$(grep -E '^Done' "$LOG" | tail -1)"
  fi
  status "done" "$msg Power cycle the robot (main breaker) to bring the camera's video back: a Jetson reboot isn't enough."
else
  status failed "$(grep -E '^ERROR' "$LOG" | tail -1 | sed 's/^ERROR: //')"
fi
exit $rc
