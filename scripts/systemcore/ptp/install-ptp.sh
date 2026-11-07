#!/bin/sh
# Installs linuxptp (static arm64 build) and runs the SystemCore as the robot's PTP grandmaster.
# Usage on the SystemCore: sudo sh install-ptp.sh [dir with ptp4l phc2sys pmc phc_ctl]
# Build the binaries with build-linuxptp.sh (Docker, arm64, linuxptp v4.4, static).
set -eu
here=$(dirname "$0")
bin=${1:-$here}
for b in ptp4l phc2sys pmc phc_ctl; do
  if [ -f "$bin/$b" ] && [ "$(readlink -f "$bin/$b")" != "/usr/local/sbin/$b" ]; then install -m755 "$bin/$b" /usr/local/sbin/; fi
  command -v "/usr/local/sbin/$b" >/dev/null || { echo "missing $b"; exit 1; }
done
mkdir -p /etc/sc-ptp
install -m644 "$here/ptp4l-master.conf" /etc/sc-ptp/
install -m644 "$here/sc-ptp4l.service" "$here/sc-phc2sys.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sc-ptp4l.service sc-phc2sys.service
ethtool -T eth0 | grep -q hardware-transmit || echo "warning: eth0 has no hardware transmit timestamps"
echo "PTP grandmaster installed; status: systemctl status sc-ptp4l sc-phc2sys"
