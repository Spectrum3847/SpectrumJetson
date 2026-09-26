#!/usr/bin/env bash
# Install upstream PhotonVision (CPU AprilTag detection) as a boot-time systemd service.
# Run ON THE JETSON. Needs internet.
#
# Current released installer pin. This CPU-only install provides the boot-time
# service before the custom CUDA fork jar replaces it. The robot uses WPILib
# 2027.0.0-alpha-6 and PhotonLib v2027.0.0-alpha-2. The alpha-7 migration target
# is documented in docs/WPILIB-2027-ALPHA-7.md. Do not point this script at a
# development asset.
# Usage: scripts/jetson/03-photonvision.sh [version]
set -euo pipefail

PV_VERSION=${1:-v2027.0.0-alpha-2}
# photon-image-modifier install.sh, pinned (reviewed 2026-09-23).
INSTALLER_SHA=2852eb01bea977bd1300428edd71cc9c4716da26
INSTALLER_URL=https://raw.githubusercontent.com/PhotonVision/photon-image-modifier/$INSTALLER_SHA/install.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
wget -q -O "$tmp/install.sh" "$INSTALLER_URL"

# --control-networking=no: leave NetworkManager config alone (the service runs with -n).
# Use the long --version= form; the installer's short -v does not take an argument reliably.
sudo bash "$tmp/install.sh" --version="$PV_VERSION" --control-networking=no

sudo systemctl restart photonvision
sleep 5
systemctl --no-pager --lines=0 status photonvision || true

echo
echo "PhotonVision $PV_VERSION installed. Web UI: http://<jetson-ip>:5800"
echo "In the UI, set Settings > Networking > Team Number (8515 for the Oct 2026 event)."
