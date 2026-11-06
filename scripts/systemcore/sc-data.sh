#!/usr/bin/env bash
# Data area for a SystemCore / DIY SystemCore (LimelightOS beta, Pi 5 or CM5): everything written while the robot
# runs (PhotonVision settings and logs, Rewind, the system journal, test data) goes to two ext4 filesystems in the
# card's free space after the A/B system slots, so a power cut mid-write can't damage the system partition.
# See docs/SYSTEMCORE-DATA-PARTITION.md for why it is NOT a partition (LimelightOS's expandfs.sh rewrites the
# extended partition at first boot and after every OTA into slot A, and would drop a logical p7).
#
#   sudo sc-data.sh check       read-only: geometry, overlap and signature checks, what apply would do (default)
#   sudo sc-data.sh apply --yes create (only where no filesystem exists) + install the boot unit + mount + move data
#   sudo sc-data.sh status      what is mounted where
#   sudo sc-data.sh remove --yes undo apply: copy data back to the system partition, unmount, uninstall the unit
#                               (the filesystems stay on the card; nothing is wiped)
#
# Layout (fixed offsets, recorded in /etc/spectrum-sc-data.conf and in each filesystem's label):
#   SC_SETTINGS  1 GiB   right after the last partition (+1 MiB): PhotonVision's database and calibrations.
#                        Mounted sync,data=journal (each change reaches the card at once, contents journaled).
#   SC_SCRATCH   the rest (to the end of the card - 1 MiB): Rewind, PhotonVision's logs, the journal, test data.
# LimelightOS's busybox losetup has no size limit, so each loop device runs to the end of the card and a
# filesystem's size is fixed by mkfs: never resize2fs these filesystems.
set -euo pipefail
DISK=${DISK:-/dev/mmcblk0}
CONF=/etc/spectrum-sc-data.conf
LIB=/usr/local/lib/spectrum-sc-data
UNIT=/etc/systemd/system/spectrum-sc-data.service
SET_BYTES=$((1024 * 1024 * 1024))
MIB=1048576
SET_DIR=/data/settings
SCR_DIR=/data/scratch
PV=/opt/photonvision
# region-relative dir | mount point (binds, in order)
BINDS=(
  "$SET_DIR/photonvision_config|$PV/photonvision_config"
  "$SCR_DIR/pv-logs|$PV/photonvision_config/logs"
  "$SCR_DIR/rewind|$PV/rewind"
  "$SCR_DIR/journal|/var/log/journal"
)

geometry() {  # sets DISK_BYTES SET_OFF SCR_OFF SCR_BYTES LAST_END (bytes) from the partition table
  DISK_BYTES=$(($(blockdev --getsz "$DISK") * 512))
  LAST_END=0
  local start size end
  while read -r start size; do
    end=$(((start + size) * 512))
    ((end > LAST_END)) && LAST_END=$end
  done < <(sfdisk -d "$DISK" | sed -nE 's/^[^:]+: start= *([0-9]+), size= *([0-9]+).*/\1 \2/p')
  SET_OFF=$((((LAST_END + MIB - 1) / MIB) * MIB + MIB))
  SCR_OFF=$((SET_OFF + SET_BYTES + MIB))
  SCR_BYTES=$((((DISK_BYTES - MIB - SCR_OFF) / MIB) * MIB))
}

load_conf() {  # the recorded offsets win over a recomputation (a later table change must not move them)
  if [[ -f $CONF ]]; then
    # shellcheck disable=SC1090
    . "$CONF"
  else
    geometry
  fi
}

sig_at() {  # filesystem TYPE/LABEL found at byte offset $1, or nothing (blkid exits 2 when there is none)
  { blkid -p -O "$1" -o export "$DISK" 2>/dev/null || true; } | sed -n 's/^\(TYPE\|LABEL\)=//p' | tr '\n' ' '
}

check() {
  geometry
  echo "disk $DISK: $((DISK_BYTES / MIB)) MiB, last partition ends at $((LAST_END / MIB)) MiB"
  sfdisk -d "$DISK" | grep "^/dev"
  echo "root: $(findmnt -no SOURCE /)   expandfs marker: $([[ -e /var/lib/partitions-expanded ]] && echo present || echo MISSING)"
  [[ -f $CONF ]] && { echo "recorded layout ($CONF):"; cat "$CONF"; }
  echo "SC_SETTINGS at $((SET_OFF / MIB)) MiB, $((SET_BYTES / MIB)) MiB: signature: $(sig_at "$SET_OFF")"
  echo "SC_SCRATCH  at $((SCR_OFF / MIB)) MiB, $((SCR_BYTES / MIB)) MiB: signature: $(sig_at "$SCR_OFF")"
  local ok=1
  ((SET_OFF > LAST_END)) || { echo "PROBLEM: settings would overlap a partition"; ok=0; }
  ((SCR_BYTES >= 4 * 1024 * MIB)) || { echo "PROBLEM: less than 4 GiB free after the partitions"; ok=0; }
  for o in "$SET_OFF" "$SCR_OFF"; do
    s=$(sig_at "$o")
    [[ -z $s || $s == *SC_SETTINGS* || $s == *SC_SCRATCH* ]] || { echo "PROBLEM: foreign signature at $o: $s"; ok=0; }
  done
  echo "sizes to move: $(du -sh "$PV/photonvision_config" "$PV/rewind" /var/log/journal 2>/dev/null | tr '\n' ' ')"
  if ((ok)); then echo "check: OK (apply would create only the missing filesystems)"; else echo "check: NOT OK"; return 1; fi
}

write_lib() {
  sudo mkdir -p "$LIB"
  sudo tee "$LIB/attach.sh" >/dev/null <<'ATTACH'
#!/bin/bash
# spectrum-sc-data: attach and mount the data area at boot (before journald flushes and before PhotonVision).
# A region whose label doesn't match, that overlaps a partition, or that fsck can't repair is left unmounted;
# fallback: RAM folders for the scratch binds (logs/Rewind to RAM), PhotonVision keeps the system copy of its
# settings. Never formats anything. Result: /run/spectrum-sc-data-status.
set -u
. /etc/spectrum-sc-data.conf
DISK=${DISK:-/dev/mmcblk0}
status=""
last_end=$(sfdisk -d "$DISK" | sed -nE 's/^[^:]+: start= *([0-9]+), size= *([0-9]+).*/\1 \2/p' |
  awk '{e=($1+$2)*512; if (e>m) m=e} END {print m+0}')
attach() {  # attach OFFSET LABEL DIR OPTS
  local off=$1 label=$2 dir=$3 opts=$4 dev rc
  if (( off <= last_end )); then status+="$label:overlaps-partition "; return 1; fi
  dev=$(losetup -a | awk -F: -v d="$DISK" -v o="$off" '$0 ~ d && $0 ~ ("offset " o) {print $1; exit}')
  if [[ -z $dev ]]; then dev=$(losetup -f) && losetup -o "$off" "$dev" "$DISK" || { status+="$label:no-loop "; return 1; }; fi
  if [[ $(blkid -o value -s LABEL "$dev") != "$label" ]]; then losetup -d "$dev"; status+="$label:wrong-label "; return 1; fi
  e2fsck -p "$dev" >/dev/null 2>&1; rc=$?
  if (( rc >= 4 )); then status+="$label:fsck-$rc "; return 1; fi
  mkdir -p "$dir"
  mountpoint -q "$dir" || mount -t ext4 -o "$opts" "$dev" "$dir" || { status+="$label:mount-failed "; return 1; }
  status+="$label:ok "
}
attach "$SET_OFF" SC_SETTINGS /data/settings noatime,sync,data=journal,errors=remount-ro; set_ok=$?
attach "$SCR_OFF" SC_SCRATCH /data/scratch noatime,commit=5,errors=remount-ro; scr_ok=$?
PV=/opt/photonvision
bind() { mkdir -p "$1" "$2"; mountpoint -q "$2" || mount --bind "$1" "$2"; }
if (( set_ok == 0 )); then bind /data/settings/photonvision_config "$PV/photonvision_config"; fi
if (( scr_ok == 0 )); then
  bind /data/scratch/pv-logs "$PV/photonvision_config/logs"
  bind /data/scratch/rewind "$PV/rewind"
  bind /data/scratch/journal /var/log/journal
else  # logs to RAM; a tiny Rewind folder so it finds no space and doesn't record
  for d in "$PV/photonvision_config/logs:64M" /var/log/journal:64M "$PV/rewind:1M"; do
    mkdir -p "${d%:*}"; mountpoint -q "${d%:*}" || mount -t tmpfs -o "size=${d##*:}" spectrum-ram "${d%:*}"
  done
fi
echo "$status" > /run/spectrum-sc-data-status
exit 0
ATTACH
  sudo chmod 755 "$LIB/attach.sh"
  sudo tee "$UNIT" >/dev/null <<'UNITFILE'
[Unit]
Description=SpectrumJetson data area (SC_SETTINGS / SC_SCRATCH on the SD card, after the A/B slots)
DefaultDependencies=no
After=systemd-remount-fs.service
Before=systemd-journal-flush.service local-fs.target photonvision.service sc-vision-native.service
ConditionPathExists=/etc/spectrum-sc-data.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/spectrum-sc-data/attach.sh
TimeoutStartSec=600

[Install]
WantedBy=local-fs.target
UNITFILE
}

mkregion() {  # mkregion OFFSET BYTES LABEL OPTS_FOR_MKFS...
  local off=$1 bytes=$2 label=$3 dev s
  s=$(sig_at "$off")
  if [[ $s == *"$label"* ]]; then echo "  $label exists: kept"; return; fi
  [[ -z $s ]] || { echo "STOP: foreign signature at $off: $s" >&2; exit 1; }
  dev=$(sudo losetup -f)
  sudo losetup -o "$off" "$dev" "$DISK"
  # -E nodiscard: no discard through the loop device; lazy init off: no background writes after mkfs.
  sudo mkfs.ext4 -q -L "$label" -b 4096 -m 1 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$dev" $((bytes / 4096))
  sudo tune2fs -c 0 -i 0 "$dev" >/dev/null
  sudo losetup -d "$dev"
  echo "  $label created: $((bytes / MIB)) MiB at $((off / MIB)) MiB"
}

apply() {
  [[ ${1:-} == --yes ]] || { echo "apply changes the card: run '$0 check' first, then '$0 apply --yes'" >&2; exit 2; }
  check
  [[ -f $CONF ]] || printf 'DISK=%s\nSET_OFF=%s\nSET_BYTES=%s\nSCR_OFF=%s\nSCR_BYTES=%s\n' \
    "$DISK" "$SET_OFF" "$SET_BYTES" "$SCR_OFF" "$SCR_BYTES" | sudo tee "$CONF" >/dev/null
  load_conf
  echo "==> filesystems"
  mkregion "$SET_OFF" "$SET_BYTES" SC_SETTINGS
  mkregion "$SCR_OFF" "$SCR_BYTES" SC_SCRATCH
  echo "==> boot unit"
  write_lib
  sudo systemctl daemon-reload
  sudo systemctl enable spectrum-sc-data.service
  echo "==> move data (PhotonVision and sc-vision stopped; nothing deleted from the system partition)"
  sudo systemctl stop photonvision sc-vision-native 2>/dev/null || true
  local dev
  for r in "$SET_OFF:SC_SETTINGS:$SET_DIR:noatime,sync,data=journal,errors=remount-ro" \
           "$SCR_OFF:SC_SCRATCH:$SCR_DIR:noatime,commit=5,errors=remount-ro"; do
    IFS=: read -r off label dir opts <<<"$r"
    mountpoint -q "$dir" && continue
    dev=$(sudo losetup -f); sudo losetup -o "$off" "$dev" "$DISK"
    sudo mkdir -p "$dir"; sudo mount -t ext4 -o "$opts" "$dev" "$dir"
  done
  for b in "${BINDS[@]}"; do
    src=${b%%|*} dst=${b##*|}
    mountpoint -q "$dst" && continue
    sudo mkdir -p "$src" "$dst"
    if [[ -z $(sudo ls -A "$src") ]]; then sudo cp -a "$dst/." "$src/" 2>/dev/null || true; fi
    [[ $dst == /var/log/journal ]] && sudo journalctl --relinquish-var
    sudo mount --bind "$src" "$dst"
    [[ $dst == /var/log/journal ]] && sudo journalctl --flush
  done
  echo "==> done; reboot to check the boot path: $0 status"
}

status() {
  for m in "$SET_DIR" "$SCR_DIR" "$PV/photonvision_config" "$PV/photonvision_config/logs" "$PV/rewind" /var/log/journal; do
    if findmnt -n "$m" >/dev/null; then echo "mounted     $m ($(findmnt -n -o SOURCE,FSTYPE,OPTIONS "$m"))"
    else echo "NOT MOUNTED $m"; fi
  done
  echo "boot: $(cat /run/spectrum-sc-data-status 2>/dev/null || echo 'unit not run this boot')"
  df -h "$SET_DIR" "$SCR_DIR" 2>/dev/null | tail -n +2 || true
}

remove() {
  [[ ${1:-} == --yes ]] || { echo "run '$0 remove --yes'" >&2; exit 2; }
  sudo systemctl stop photonvision sc-vision-native 2>/dev/null || true
  local i b src dst
  for ((i = ${#BINDS[@]} - 1; i >= 0; i--)); do
    b=${BINDS[$i]} src=${b%%|*} dst=${b##*|}
    mountpoint -q "$dst" || continue
    [[ $dst == /var/log/journal ]] && sudo journalctl --relinquish-var
    sudo umount "$dst"
    # copy back what the system partition needs (settings; logs only if small)
    [[ $dst == "$PV/photonvision_config" ]] && sudo rsync -a "$src/" "$dst/"
    [[ $dst == /var/log/journal ]] && sudo journalctl --flush
  done
  for m in "$SCR_DIR" "$SET_DIR"; do
    mountpoint -q "$m" || continue
    dev=$(findmnt -n -o SOURCE "$m"); sudo umount "$m"; sudo losetup -d "$dev" || true
  done
  sudo systemctl disable spectrum-sc-data.service 2>/dev/null || true
  sudo rm -f "$UNIT" "$CONF"; sudo rm -rf "$LIB"; sudo systemctl daemon-reload
  echo "removed: the data area's filesystems are still on the card (apply --yes reuses them)"
}

cmd=${1:-check}
shift || true
case $cmd in
  check) check ;;
  apply) apply "$@" ;;
  status) status ;;
  remove) remove "$@" ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
