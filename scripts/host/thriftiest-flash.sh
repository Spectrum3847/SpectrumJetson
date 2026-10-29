#!/usr/bin/env bash
# Update a Thriftiest Cam's firmware while it stays plugged into the Jetson, from the laptop.
# Run ON THE LAPTOP (Git Bash on Windows works), over Ethernet or the USB-C cable. The Jetson has
# no internet, so this downloads the firmware and pyusb here, copies them and
# scripts/jetson/thriftiest-fw.py to ~/thriftiest-fw on the Jetson, and runs the tool there.
# See docs/THRIFTIEST-CAM-FIRMWARE.md.
#
# Usage: thriftiest-flash.sh list                     # every Thriftiest Cam: port, firmware, gain
#        thriftiest-flash.sh dump PORT                # read a camera's flash into ~/thriftiest-backups
#        thriftiest-flash.sh flash PORT FIRMWARE      # FIRMWARE: a .bin file, its URL, or a
#                                                     # published version number such as 5.13
# PORT is the USB port health-check.sh shows, e.g. 2.1. Robot disabled: PhotonVision is stopped
# for about a minute (every camera), then started again. Flash one camera, check it, then the next.
#
# Environment: JETSON (default 192.168.55.1, the USB-C cable; 10.85.15.15 on the robot),
#              KEY (default ~/.ssh/jetson_ed25519; ssh's own keys if that file doesn't exist),
#              YES=1 to skip the confirmation.
set -euo pipefail
JETSON=${JETSON:-192.168.55.1}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
JETSON_USER=${JETSON_USER:-spectrum3847}
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/../jetson/thriftiest-fw.py
BACKUPS=$HOME/thriftiest-backups
CACHE=$BACKUPS/downloads
PYUSB=pyusb==1.3.1
FW_URL=https://software.thethriftybot.com/firmware/thriftiest-cam   # /<version>/ThriftiestCam-Firmware-v<version>.bin
SSH=(ssh -o ConnectTimeout=5)
SCP=(scp -q -o ConnectTimeout=5)
[[ -f $KEY ]] && SSH+=(-i "$KEY") && SCP+=(-i "$KEY")
REMOTE=("${SSH[@]}" "$JETSON_USER@$JETSON")
RUN='sudo -n env PYTHONPATH=$HOME/thriftiest-fw/lib PYTHONDONTWRITEBYTECODE=1 python3 -u $HOME/thriftiest-fw/thriftiest-fw.py'

usage() { sed -n '8,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "ERROR: $*" >&2; exit 1; }
cmd=${1:-}; port=${2:-}; fw=${3:-}
case $cmd in list) ;; dump) [[ -n $port ]] || usage ;; flash) [[ -n $port && -n $fw ]] || usage ;; *) usage ;; esac
mkdir -p "$CACHE"

# Firmware: a version number or URL is downloaded once into ~/thriftiest-backups/downloads.
if [[ $cmd == flash ]]; then
  if [[ $fw =~ ^[0-9]+\.[0-9]+$ ]]; then fw=$FW_URL/$fw/ThriftiestCam-Firmware-v$fw.bin; fi
  if [[ $fw == http*://* ]]; then
    file=$CACHE/$(basename "$fw")
    [[ -s $file ]] || curl -fsSL -o "$file" "$fw" || die "couldn't download $fw (no internet? download it beforehand)"
    fw=$file
  fi
  [[ -f $fw ]] || die "no firmware file $fw"
fi

echo "==> Copying the tool to $JETSON"
"${REMOTE[@]}" 'mkdir -p ~/thriftiest-fw' || die "can't reach $JETSON_USER@$JETSON (set JETSON=...)"
"${SCP[@]}" "$TOOL" "$JETSON_USER@$JETSON:thriftiest-fw/thriftiest-fw.py"
if ! "${REMOTE[@]}" 'python3 -c "import usb" 2>/dev/null || PYTHONPATH=~/thriftiest-fw/lib python3 -c "import usb" 2>/dev/null'; then
  echo "==> pyusb for the Jetson"
  wheel=$(ls "$CACHE"/pyusb-*.whl 2>/dev/null | head -1 || true)
  if [[ -z $wheel ]]; then
    py=$(command -v python3 || command -v python) || die "no python here to download pyusb with"
    "$py" -m pip download "$PYUSB" --no-deps -q --disable-pip-version-check -d "$CACHE" || die "couldn't download pyusb (no internet?)"
    wheel=$(ls "$CACHE"/pyusb-*.whl | head -1)
  fi
  "${SCP[@]}" "$wheel" "$JETSON_USER@$JETSON:thriftiest-fw/pyusb.whl"
  "${REMOTE[@]}" 'cd ~/thriftiest-fw && rm -rf lib && python3 -m zipfile -e pyusb.whl lib'
fi

gain_report() {
  "${REMOTE[@]}" 'for v in /dev/v4l/by-path/*usb-0:*:1.0-video-index0; do
    [ -e "$v" ] || continue; p=${v#*usb-0:}; p=${p%%:*}
    [ "$(cat /sys/bus/usb/devices/1-$p/idProduct 2>/dev/null)" = 28c5 ] || continue
    g=$(v4l2-ctl -d "$v" -l 2>/dev/null | grep -E "^ *gain " | sed "s/.*: //"); echo "  $p gain: ${g:-none}"; done'
}

# dump and flash take the camera away from PhotonVision, whose camera watchdog (photonvision-81)
# resets a camera's USB port after 5 s without frames: mid-write that could leave the flash
# half-written. So PhotonVision is stopped first and always started again, whatever happens.
if [[ $cmd != list ]]; then
  trap '"${REMOTE[@]}" "sudo -n systemctl start photonvision" && echo "PhotonVision started again"' EXIT
fi
stop_pv() { echo "==> Stopping PhotonVision (all cameras off until it's started again)"; "${REMOTE[@]}" "sudo -n systemctl stop photonvision"; }

case $cmd in
list)
  "${REMOTE[@]}" "$RUN list"
  gain_report ;;
dump)
  out=dump-$port-$(date +%Y%m%d-%H%M%S).bin
  stop_pv
  "${REMOTE[@]}" "$RUN dump --port $port ~/thriftiest-backups/$out" </dev/null
  "${SCP[@]}" "$JETSON_USER@$JETSON:thriftiest-backups/$out" "$BACKUPS/"
  echo "Saved $BACKUPS/$out" ;;
flash)
  name=$(basename "$fw")
  "${SCP[@]}" "$fw" "$JETSON_USER@$JETSON:thriftiest-fw/$name"
  "${REMOTE[@]}" "python3 ~/thriftiest-fw/thriftiest-fw.py check-image ~/thriftiest-fw/$name"
  echo "  sha256 $(sha256sum "$fw" | cut -d' ' -f1)"
  "${REMOTE[@]}" "$RUN list"
  if [[ ${YES:-} != 1 ]]; then
    read -r -p "Flash $name onto the camera on port $port? Robot disabled? [y/N] " ok
    [[ $ok == [yY]* ]] || die "not flashed"
  fi
  stop_pv
  "${REMOTE[@]}" "$RUN flash --port $port ~/thriftiest-fw/$name --yes" </dev/null
  echo "==> After the update"
  sleep 5
  "${REMOTE[@]}" "$RUN list"
  gain_report ;;
esac
"${SCP[@]}" "$JETSON_USER@$JETSON:thriftiest-backups/*" "$BACKUPS/" 2>/dev/null && echo "Backups copied to $BACKUPS" || true
