#!/bin/bash
# Installs the CANable 2.0 (slcan) -> can0 bring-up on a SystemCore / DIY SystemCore. Run on the device with sudo
# from this directory. Idempotent. Does not touch can_s0..can_s4 (the SystemCore stack's buses).
set -euo pipefail
cd "$(dirname "$0")"
install -D -m 755 usb-can-up.sh /opt/sc-usb-can/usb-can-up.sh
install -m 644 sc-usb-can@.service /etc/systemd/system/sc-usb-can@.service
install -m 644 90-sc-usb-can.rules /etc/udev/rules.d/90-sc-usb-can.rules
install -D -m 644 can-bringup-usb-s0.conf /etc/systemd/system/can-bringup.service.d/usb-s0.conf
printf 'IFACE=can_s0\nBITRATE=1000000\nTXQLEN=1000\nUP=1\n' > /etc/sc-usb-can.conf
echo slcan > /etc/modules-load.d/sc-usb-can.conf
systemctl daemon-reload
udevadm control --reload
systemctl stop 'sc-usb-can@*.service' 2>/dev/null || true
# A running vcan can_s0 is held by can_sender/robot_heartbeat (bound at their load): don't delete it live, the
# swap happens at the next boot (can-bringup drop-in). Otherwise start now.
if ip -d link show can_s0 2>/dev/null | grep -qw vcan; then
  echo "can_s0 is the vcan placeholder: the adapter becomes can_s0 at the next reboot"; exit 0
fi
# Start now if the adapter is plugged in: replays the add event for its tty only (no USB rebind or reset).
for t in /sys/class/tty/ttyACM*; do
  [[ -e $t ]] || continue
  udevadm info -q property "$t" | grep -q '^ID_MODEL_ID=117e' && udevadm trigger --action=add "$t"
done
echo "installed; check: systemctl status sc-usb-can@canable; ip -details link show can0"
