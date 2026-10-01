#!/usr/bin/env bash
# Flash QSPI bootloader + NVMe rootfs on an Orin Nano Super devkit in Force Recovery Mode.
#
# While flashing, this temporarily:
#   - tells NetworkManager to leave the Jetson's USB network interface alone
#     (otherwise it DHCPs the interface and drops the address mid-flash)
#   - allows the flash tool's IPv6 subnet (fc00:1:1::/48) through ufw
# Both are reverted on exit, success or failure.
#
# Run as your normal user (not with sudo); it calls sudo where needed.
#
# It erases the whole SSD (--erase-all), the settings and Rewind partitions too, so it asks you to
# type ERASE first. YES=1 skips the question (for when nobody is at the keyboard).
#
# The system partition (APP, /dev/nvme0n1p1) is ROOTFS_SIZE, 64GiB by default; the rest of the
# SSD stays free for the /data partition that scripts/jetson/10-data-partition.sh creates, where
# everything the Jetson writes while running lives. ROOTFS_SIZE=full gives the system the whole
# SSD, as before.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO_ROOT/config.env"

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root. It will sudo when needed." >&2
  exit 1
fi

if [[ ! -x $L4T_DIR/tools/kernel_flash/l4t_initrd_flash.sh ]]; then
  echo "No BSP at $L4T_DIR. Run scripts/host/01-prepare-bsp.sh first." >&2
  exit 1
fi

if ! lsusb -d "$RCM_USB_ID" >/dev/null; then
  echo "No Jetson in Force Recovery Mode (USB $RCM_USB_ID) found." >&2
  echo "Power off, jumper FC REC to GND (button header J14, pins 9-10), power on, remove jumper." >&2
  exit 1
fi

if [[ ${YES:-} != 1 ]]; then
  echo "This erases the Jetson's whole SSD: the system, the settings partition (pipelines, calibrations,"
  echo "field calibration, snapshots) and the scratch partition (Rewind recordings). To keep them, stop"
  echo "here and back up first: scripts/host/04-backup-ssd.sh, scripts/host/rewind-pull.sh."
  read -r -p "Type ERASE to flash: " answer || answer=""
  [[ $answer == ERASE ]] || { echo "Not flashing." >&2; exit 1; }
fi

sudo -n true 2>/dev/null || sudo -v   # ask for the password only if sudo needs one

NM_CONF=/etc/NetworkManager/conf.d/99-jetson-flash-unmanaged.conf
UFW_RULE=(from fc00:1:1::/48)
UFW_ADDED=0

cleanup() {
  echo "==> Restoring host network settings"
  if [[ -f $NM_CONF ]]; then
    sudo rm -f "$NM_CONF"
    sudo systemctl reload NetworkManager || true
  fi
  if [[ $UFW_ADDED -eq 1 ]]; then
    sudo ufw delete allow "${UFW_RULE[@]}" >/dev/null || true
  fi
}
trap cleanup EXIT

if systemctl is-active --quiet NetworkManager; then
  echo "==> Telling NetworkManager to ignore USB gadget network interfaces"
  # The Jetson shows up as a USB network gadget; host USB NICs (e.g. r8152) are unaffected.
  sudo tee "$NM_CONF" >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=driver:rndis_host;driver:cdc_ncm;driver:cdc_ether;interface-name:usb*
EOF
  sudo systemctl reload NetworkManager
fi

if systemctl is-active --quiet ufw; then
  echo "==> Temporarily allowing flash subnet through ufw"
  sudo ufw allow "${UFW_RULE[@]}" >/dev/null
  UFW_ADDED=1
fi

mkdir -p "$REPO_ROOT/logs"
LOG=$REPO_ROOT/logs/flash-$(date +%Y%m%d-%H%M%S).log
echo "==> Flashing $BOARD (L4T $L4T_VERSION) to NVMe. Log: $LOG"
echo "    This takes roughly 10-20 minutes. Do not unplug the Jetson."

# The system partition (APP) is marked "expand" in NVIDIA's layout, and the part of the flash that
# runs on the Jetson grows it to fill the whole SSD. -S gives it a fixed size instead (and drops
# the expand mark). The flash tool can't read the SSD's size either (its default is 57 GiB, too
# small for a 64 GiB APP), so it's told the SSD is ROOTFS_SIZE + 2 GiB: the other partitions take
# ~1.6 GiB. 10-data-partition.sh then moves the backup GPT to the real end and uses the rest, so
# the SSD needs 80 GB or more (64 GiB system, 2 GiB settings, at least 8 GiB scratch).
ROOTFS_SIZE=${ROOTFS_SIZE:-64GiB}
if [[ $ROOTFS_SIZE == full ]]; then
  echo "    System partition: the whole SSD"
  SECTORS_ENV=() SIZE_ARGS=()
else
  gib=${ROOTFS_SIZE%GiB}
  [[ $gib =~ ^[0-9]+$ && $ROOTFS_SIZE == *GiB ]] || { echo "ROOTFS_SIZE must be like 64GiB or full" >&2; exit 2; }
  SECTORS_ENV=(EXT_NUM_SECTORS=$(( (gib + 2) * 2097152 )))
  SIZE_ARGS=(-S "$ROOTFS_SIZE")
  echo "    System partition: $ROOTFS_SIZE; the rest of the SSD is left for /data"
fi
# NVIDIA's first boot (nv-late-init.sh, in automatic oem-config mode) then grows the system
# partition to fill the SSD with nvresizefs.sh, over the space left for /data. With a fixed size,
# skip just that call in the image; the rest of the automatic first boot (swap etc.) still runs.
LATE_INIT=$L4T_DIR/rootfs/etc/systemd/nv-late-init.sh
if [[ $ROOTFS_SIZE != full ]] && ! sudo grep -q "spectrum-no-resizefs" "$LATE_INIT"; then
  sudo sed -i 's|^\(\s*\)if \[ -e "${nvresizefs_script}" \]; then|\1# spectrum-no-resizefs: 02-flash-nvme.sh keeps the system partition at ROOTFS_SIZE\n\1if [ -e "${nvresizefs_script}" ] \&\& [ ! -e /etc/nv/spectrum-no-resizefs ]; then|' "$LATE_INIT"
  sudo touch "$L4T_DIR/rootfs/etc/nv/spectrum-no-resizefs"
fi
# A different L4T can word that line differently, and then sed changes nothing: the first boot
# would grow the system partition over the space 10-data-partition.sh needs. Stop instead.
if [[ $ROOTFS_SIZE != full ]] && ! sudo grep -qF '[ ! -e /etc/nv/spectrum-no-resizefs ]' "$LATE_INIT"; then
  echo "STOP: couldn't find nvresizefs's call in $LATE_INIT (a new L4T?). Edit it by hand so the" >&2
  echo "      call is skipped while /etc/nv/spectrum-no-resizefs exists, or flash with ROOTFS_SIZE=full." >&2
  exit 1
fi
if [[ $ROOTFS_SIZE == full ]]; then sudo rm -f "$L4T_DIR/rootfs/etc/nv/spectrum-no-resizefs"; fi

cd "$L4T_DIR"
sudo "${SECTORS_ENV[@]}" ./tools/kernel_flash/l4t_initrd_flash.sh \
  --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  "${SIZE_ARGS[@]}" \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 --erase-all \
  "$BOARD" internal 2>&1 | tee "$LOG"

echo
echo "Flash finished. The Jetson reboots into the new image from NVMe."
echo "Next: log in (monitor/keyboard, or 'ssh <user>@192.168.55.1' over the USB-C cable)"
echo "and run scripts/jetson/01-verify.sh on the Jetson."
