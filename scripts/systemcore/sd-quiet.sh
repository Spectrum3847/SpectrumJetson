#!/bin/sh
# Keep routine log writes off the SD card (SystemCore / Pi 5 with LimelightOS).
# The bench SD card stalls under writes; LimelightOS panics on a 30 s hung task (hung_task_panic=1), so a stall
# resets the Pi. The 2026-11-06 07:48 reset was systemd-journal blocked >30 s while PhotonVision logged at start-up.
#  - journald: Storage=volatile (RAM, /run/log/journal, capped). Crash logs still survive via pstore/ramoops.
#  - PhotonVision's own log files: a tmpfs over photonvision_config/logs.
# Idempotent. Run as root on the device. Undo: rm the two files below, systemctl daemon-reload, reboot.
set -eu
PV_LOGS=${PV_LOGS:-/opt/photonvision/photonvision_config/logs}

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-spectrum-volatile.conf <<'J'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
J

unit=$(systemd-escape -p --suffix=mount "$PV_LOGS")
cat > "/etc/systemd/system/$unit" <<M
[Unit]
Description=PhotonVision logs in RAM (keep writes off the SD card)
Before=photonvision.service

[Mount]
What=tmpfs
Where=$PV_LOGS
Type=tmpfs
Options=mode=0755,size=64M,noatime

[Install]
WantedBy=local-fs.target
M
systemctl daemon-reload
systemctl enable "$unit" >/dev/null 2>&1 || true
systemctl restart systemd-journald
if ! mountpoint -q "$PV_LOGS"; then
  systemctl start "$unit"
fi
echo "journald: $(journalctl --header 2>/dev/null | grep -m1 'File path' || echo volatile); PV logs: $(findmnt -no FSTYPE "$PV_LOGS")"
