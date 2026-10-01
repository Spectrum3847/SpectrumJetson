#!/usr/bin/env bash
# USB controller watchdog: resets the Jetson's USB controller if the kernel says it died, so the
# cameras come back without a person. Run ON THE JETSON. See usb-watchdog.py for what it does and
# doesn't do (it never reboots).
#
# Usage:
#   14-usb-watchdog.sh --install   install and start usb-watchdog.service
#   14-usb-watchdog.sh --undo      remove it
#   14-usb-watchdog.sh --test      fake a dead controller in the kernel log and show what happened.
#                                  This resets every USB device, and can leave a Thriftiest Cam
#                                  stuck until its power is cut (the known issue in the README).
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot (--test writes nothing).
[[ ${1:-} == --test || $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=/opt/spectrum/usb-watchdog.py
UNIT=/etc/systemd/system/usb-watchdog.service

case ${1:-} in
  --install)
    sudo install -D -m 755 "$HERE/usb-watchdog.py" "$BIN"
    sudo tee "$UNIT" >/dev/null <<UNIT
# SpectrumJetson: reset the USB controller if the kernel says it died (scripts/jetson/14-usb-watchdog.sh)
[Unit]
Description=SpectrumJetson USB controller watchdog
After=systemd-journald.service

[Service]
ExecStart=/usr/bin/python3 $BIN
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now usb-watchdog.service
    sudo systemctl restart usb-watchdog.service
    sleep 1
    systemctl is-active usb-watchdog.service
    journalctl -u usb-watchdog -n 1 -o cat --no-pager
    ;;
  --undo)
    sudo systemctl disable --now usb-watchdog.service 2>/dev/null || true
    sudo rm -f "$UNIT" "$BIN"
    sudo systemctl daemon-reload
    echo "Removed."
    ;;
  --test)
    systemctl is-active --quiet usb-watchdog.service || { echo "usb-watchdog.service isn't running" >&2; exit 1; }
    since=$(date +%s)
    echo "usb-watchdog test: xHCI host controller not responding, assume dead" | sudo tee /dev/kmsg >/dev/null
    echo "Faked a dead USB controller; watching for 50 s..."
    sleep 50
    journalctl -u usb-watchdog --since "@$since" -o short-precise --no-pager
    ;;
  *) echo "usage: $0 --install | --undo | --test" >&2; exit 2 ;;
esac
