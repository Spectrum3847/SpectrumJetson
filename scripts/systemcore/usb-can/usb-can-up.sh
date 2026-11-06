#!/bin/bash
# CANable 2.0 (slcan firmware) -> SocketCAN netdev. Run by sc-usb-can@canable.service.
#   usb-can-up.sh /dev/canable   start slcand (forks), which creates $IFACE
#   usb-can-up.sh --link         set bitrate/txqueuelen and bring $IFACE up
# Config /etc/sc-usb-can.conf (shell): IFACE=can0, BITRATE=1000000, TXQLEN=1000, UP=1 (0: create, leave down).
set -uo pipefail
IFACE=can_s0
BITRATE=1000000
TXQLEN=1000
UP=1
# shellcheck disable=SC1091
[[ -f /etc/sc-usb-can.conf ]] && . /etc/sc-usb-can.conf

if [[ ${1:-} == --wait ]]; then   # can-bringup.service ExecStartPre: never fails
  [[ -e /dev/canable ]] || exit 0
  for _ in $(seq 1 150); do ip -d link show "$IFACE" 2>/dev/null | grep -q slcan && break; sleep 0.1; done
  echo "sc-usb-can: $IFACE $(ip -d link show "$IFACE" 2>/dev/null | grep -qw slcan && echo slcan || echo 'not up (vcan fallback)')"
  exit 0
fi
if [[ ${1:-} == --link ]]; then
  for _ in $(seq 1 50); do ip link show "$IFACE" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link set "$IFACE" down
  ip link set "$IFACE" type can bitrate "$BITRATE" || exit 1
  ip link set "$IFACE" txqueuelen "$TXQLEN"
  [[ $UP == 1 ]] && ip link set "$IFACE" up
  echo "sc-usb-can: $IFACE bitrate $BITRATE up=$UP"
  exit 0
fi
modprobe slcan || exit 1
# -o open, -c close on exit; the bitrate is set afterwards with ip link (slcan >= 6.0 takes its fixed rates).
exec slcand -o -c "${1:?tty}" "$IFACE"
