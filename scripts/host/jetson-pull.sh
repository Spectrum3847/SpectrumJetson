#!/usr/bin/env bash
# Copy everything robotlog.spectrum3847.org takes off the Jetson: Rewind recordings (video, frame
# tables, vision logs), PhotonVision's logs, and the system journal, one JSON file per boot.
# Run ON THE LAPTOP, over Ethernet or the USB-C cable (a match is ~1-2 GB: not over the radio).
# Works from Git Bash on Windows too: without rsync it copies with tar over ssh.
#
# Usage: jetson-pull.sh [DEST]      (default ~/jetson-pull/<yyyymmdd-HHMMSS>)
#   then: npm run import -- --url ... --key ... --team 8515 DEST   (in WPI-Log-Analizer)
#
# The journal is JSON (journalctl -o json) so each line keeps its boot ID and monotonic time: the
# Jetson's wall clock is wrong until the robot sets it, and the "Clock mark" lines
# (photonvision-80) let tools put every line on the robot's clock.
#
# Every boot still in the journal is copied, as journal/boot-<boot id>.json.gz, found by its
# _BOOT_ID. Not `journalctl -b -N`: power cuts and the clock jumping between 1970, the last saved
# date and the robot's time scramble journald's boot list, so at TXMAN1 it listed 13 of 61 boots
# and `-b -3` and older found nothing.
#
# Environment: JETSON (default 192.168.55.1, the USB-C cable; 10.85.15.15 on the robot, or the
#              address it got from DHCP if it lost its static one),
#              KEY (default ~/.ssh/jetson_ed25519; ssh's own keys if that file doesn't exist).
set -euo pipefail
JETSON=${JETSON:-192.168.55.1}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
JETSON_USER=${JETSON_USER:-spectrum3847}
DEST=${1:-$HOME/jetson-pull/$(date +%Y%m%d-%H%M%S)}
SSH=(ssh -o ConnectTimeout=5)
[[ -f $KEY ]] && SSH+=(-i "$KEY")
REMOTE=("${SSH[@]}" "$JETSON_USER@$JETSON")

# copy REMOTE_DIR LOCAL_DIR: rsync when the laptop has it, else tar over ssh.
copy() {
  if command -v rsync >/dev/null; then
    rsync -a --info=progress2 -e "${SSH[*]}" "$JETSON_USER@$JETSON:$1/" "$2/"
  else
    "${REMOTE[@]}" "tar cf - -C '$1' ." | tar xf - -C "$2"
  fi
}

mkdir -p "$DEST/rewind" "$DEST/photonvision" "$DEST/journal"
echo "==> Rewind recordings"
copy /opt/photonvision/rewind/sessions "$DEST/rewind"
echo "==> PhotonVision logs"
copy /opt/photonvision/photonvision_config/logs "$DEST/photonvision"
echo "==> System journal, every boot"
"${REMOTE[@]}" 'set -e; t=$(mktemp -d); trap "rm -rf $t" EXIT
  for b in $(sudo -n journalctl -F _BOOT_ID); do
    sudo -n journalctl _BOOT_ID=$b -o json --no-pager -q | gzip > $t/boot-$b.json.gz
  done
  tar cf - -C $t .' | tar xf - -C "$DEST/journal"
n=0
for f in "$DEST"/journal/boot-*.json.gz; do
  [[ -e $f ]] || break
  if [[ $(gzip -dc "$f" | head -c 1 | wc -c) -eq 0 ]]; then rm -f "$f"; else n=$((n + 1)); fi
done
echo "  $n boots"
[[ $n -gt 0 ]] || echo "  WARNING: no journal copied (passwordless sudo on the Jetson?)"
echo
echo "Pulled to $DEST"
