#!/bin/bash
# Installs the CANable 2.0 (slcan) -> can0 bring-up on a SystemCore / DIY SystemCore. Run on the device with sudo
# from this directory. Idempotent. Does not touch can_s0..can_s4 (the SystemCore stack's buses).
set -euo pipefail
cd "$(dirname "$0")"
install -D -m 755 usb-can-up.sh /opt/sc-usb-can/usb-can-up.sh
install -m 644 sc-usb-can@.service /etc/systemd/system/sc-usb-can@.service
install -m 644 90-sc-usb-can.rules /etc/udev/rules.d/90-sc-usb-can.rules
[[ -f /etc/sc-usb-can.conf ]] || printf 'IFACE=can0\nBITRATE=1000000\nTXQLEN=1000\nUP=1\n' > /etc/sc-usb-can.conf
echo slcan > /etc/modules-load.d/sc-usb-can.conf
systemctl daemon-reload
udevadm control --reload
# Start now if the adapter is plugged in: replays the add event for its tty only (no USB rebind or reset).
for t in /sys/class/tty/ttyACM*; do
  [[ -e $t ]] || continue
  udevadm info -q property "$t" | grep -q '^ID_MODEL_ID=117e' && udevadm trigger --action=add "$t"
done
echo "installed; check: systemctl status sc-usb-can@canable; ip -details link show can0"
