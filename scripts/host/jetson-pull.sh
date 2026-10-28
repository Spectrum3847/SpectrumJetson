#!/usr/bin/env bash
# Copy everything robotlog.spectrum3847.org takes off the Jetson: Rewind recordings (video, frame
# tables, vision logs), PhotonVision's logs, and the system journal, one JSON file per boot.
# Run ON THE LAPTOP, over Ethernet or the USB-C cable (a match is ~1-2 GB: not over the radio).
#
# Usage: jetson-pull.sh [DEST]      (default ~/jetson-pull/<yyyymmdd-HHMMSS>)
#   then: npm run import -- --url ... --key ... --team 8515 DEST   (in WPI-Log-Analizer)
#
# The journal is JSON (journalctl -o json) so each line keeps its boot ID and monotonic time: the
# Jetson's wall clock is wrong until the robot sets it, and the "Clock mark" lines
# (photonvision-80) let tools put every line on the robot's clock.
#
# Environment: JETSON (default 192.168.55.1, the USB-C cable; 10.85.15.15 on the robot),
#              BOOTS (default 10: how many of the latest boots' journals to copy).
set -euo pipefail
JETSON=${JETSON:-192.168.55.1}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
JETSON_USER=${JETSON_USER:-spectrum3847}
BOOTS=${BOOTS:-10}
DEST=${1:-$HOME/jetson-pull/$(date +%Y%m%d-%H%M%S)}
SSH=(ssh -i "$KEY" -o ConnectTimeout=5 "$JETSON_USER@$JETSON")
RSYNC=(rsync -a --info=progress2 -e "ssh -i $KEY")

mkdir -p "$DEST/rewind" "$DEST/photonvision" "$DEST/journal"
echo "==> Rewind recordings"
"${RSYNC[@]}" "$JETSON_USER@$JETSON:/opt/photonvision/rewind/sessions/" "$DEST/rewind/"
echo "==> PhotonVision logs"
"${RSYNC[@]}" "$JETSON_USER@$JETSON:/opt/photonvision/photonvision_config/logs/" "$DEST/photonvision/"
echo "==> System journal, last $BOOTS boots"
for n in $(seq 0 $((BOOTS - 1))); do
  out="$DEST/journal/boot-$n.json.gz"
  if "${SSH[@]}" "sudo -n journalctl -b -$n -o json --no-pager 2>/dev/null | gzip" > "$out" && [[ $(gzip -dc "$out" | head -c 1 | wc -c) -gt 0 ]]; then
    echo "  boot -$n: $(gzip -dc "$out" | wc -l) lines"
  else
    rm -f "$out"
    break
  fi
done
echo
echo "Pulled to $DEST"
