#!/usr/bin/env bash
# Storage fallback test: does a match still run when a data partition is damaged? Run ON THE LAPTOP
# with the Jetson on the USB-C cable. For the chosen partition it:
#   1. (settings) commits the current settings as the last-good copy,
#   2. zeroes the partition's main superblock, as a power cut can, and reboots,
#   3. checks: the Jetson booted, PhotonVision answers, /run/spectrum-data-status says the right
#      thing, the right stand-ins are mounted, and nothing was written to the system partition
#      in their place,
#   4. repairs the partition from ext4's backup superblock (e2fsck -b 32768), reboots, and checks
#      it's back to normal with its files intact.
# Usage: tests/storage-fallback/run.sh scratch|settings
# Every wait has a limit; the whole test ends within ~20 min.
set -uo pipefail
WHICH=${1:?usage: $0 scratch|settings}
[[ $WHICH == scratch || $WHICH == settings ]] || { echo "usage: $0 scratch|settings" >&2; exit 2; }
JETSON=${JETSON:-192.168.55.1}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
JETSON_USER=${JETSON_USER:-spectrum3847}
SSH=(ssh -i "$KEY" -o ConnectTimeout=5 -o BatchMode=yes "$JETSON_USER@$JETSON")
PARTLABEL=$([[ $WHICH == scratch ]] && echo SPECTRUM_SCRATCH || echo SPECTRUM_SETTINGS)
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
j() { timeout 60 "${SSH[@]}" "$@"; }
# PhotonVision's web server answers (the Jetson has no curl).
pv_up() { j 'python3 -c "import urllib.request; urllib.request.urlopen(\"http://localhost:5800/\", timeout=3)"' 2>/dev/null; }

reboot_and_wait() {
  local before; before=$(j cat /proc/sys/kernel/random/boot_id)
  j 'sudo -n systemctl reboot' >/dev/null 2>&1
  local end=$((SECONDS + 300))
  sleep 10
  until [[ $(j cat /proc/sys/kernel/random/boot_id 2>/dev/null) =~ ^[0-9a-f-]+$ && $(j cat /proc/sys/kernel/random/boot_id 2>/dev/null) != "$before" ]]; do
    ((SECONDS < end)) || { echo "TIMEOUT: the Jetson didn't come back within 5 min of the reboot"; exit 1; }
    sleep 3
  done
  end=$((SECONDS + 120))
  until pv_up; do
    ((SECONDS < end)) || { echo "  (PhotonVision not answering 2 min after boot)"; break; }
    sleep 3
  done
}

echo "== Before"
j "~/SpectrumJetson/scripts/jetson/10-data-partition.sh --status" | sed 's/^/  /'
[[ $(j cat /run/spectrum-data-status) == "settings=ok scratch=ok" ]] || { echo "Both partitions must be ok to start"; exit 1; }
PART=$(j "sudo -n blkid -t PARTLABEL=$PARTLABEL -o device")
[[ $PART == /dev/nvme0n1p* ]] || { echo "No $PARTLABEL partition"; exit 1; }
MNT=/data/$WHICH
# A marker file, to check the repair keeps the partition's files.
j "echo storage-fallback-test | sudo tee $MNT/.fallback-test >/dev/null && sync"
if [[ $WHICH == settings ]]; then
  j "~/SpectrumJetson/scripts/jetson/10-data-partition.sh --commit-settings" | sed 's/^/  /'
  # PhotonVision rewrites its database at startup (same contents, different bytes), so compare
  # what's in it, not the file.
  dbsum() { j "sudo -n python3 -c \"import sqlite3,hashlib,sys; c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); print(hashlib.sha256(repr([sorted(c.execute('select * from '+t).fetchall()) for t in ('global','cameras')]).encode()).hexdigest()[:16])\" $1"; }
  committed_db=$(dbsum /opt/photonvision/.last-good-settings/photonvision_config/photon.sqlite)
fi
root_used_before=$(j "df --output=used / | tail -1")

echo "== Damaging $PART ($PARTLABEL): zeroing its main superblock, then rebooting"
# Unmount every mount of the partition first: a mounted ext4 writes its superblock back when it's
# unmounted, which would undo the damage. The system log moves to RAM so its files close.
# journald and the USB watchdog (journalctl -k -f) keep /var/log/journal busy, so both are stopped (the
# reboot right after starts it again).
j "sudo -n systemctl stop photonvision; sudo -n journalctl --relinquish-var; sync
   sudo -n systemctl stop usb-watchdog systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket systemd-journald 2>/dev/null
   for _ in 1 2 3; do for t in \$(findmnt -rn -S $PART -o TARGET | sort -ru); do sudo -n umount -R \$t 2>/dev/null; done; done
   findmnt -rn -S $PART && { echo 'still mounted'; exit 1; }
   sudo -n dd if=/dev/zero of=$PART bs=4096 count=1 conv=fsync status=none; sync" || { echo "Couldn't unmount $PART to damage it"; exit 1; }
reboot_and_wait

echo "== With $WHICH damaged"
st=$(j cat /run/spectrum-data-status)
echo "  status: $st"
check "the Jetson booted and PhotonVision answers on :5800" "pv_up"
check "PhotonVision service active" "[[ \$(j systemctl is-active photonvision) == active ]]"
check "$MNT is not mounted (the damage stuck)" "! j findmnt -n $MNT >/dev/null"
if [[ $WHICH == scratch ]]; then
  check "status says scratch=missing" "[[ '$st' == *scratch=missing* ]]"
  check "PhotonVision's logs are in RAM" "[[ \$(j findmnt -n -o FSTYPE /opt/photonvision/photonvision_config/logs) == tmpfs ]]"
  check "Rewind has only a tiny RAM folder" "[[ \$(j findmnt -n -o FSTYPE /opt/photonvision/rewind) == tmpfs ]]"
  check "the system log is in RAM" "[[ \$(j findmnt -n -o FSTYPE /var/log/journal) == tmpfs ]]"
else
  check "status says settings=last-good" "[[ '$st' == *settings=last-good* ]]"
  check "photonvision_config is the last-good overlay" "[[ \$(j findmnt -n -o FSTYPE /opt/photonvision/photonvision_config) == overlay ]]"
  check "PhotonVision runs on the committed settings (same database contents)" "[[ \$(dbsum /opt/photonvision/photonvision_config/photon.sqlite) == '$committed_db' && -n '$committed_db' ]]"
fi
root_used_after=$(j "df --output=used / | tail -1")
check "nothing piled up on the system partition ($(( (root_used_after - root_used_before) / 1024 )) MB change)" "(( root_used_after - root_used_before < 51200 ))"
j "sudo -n ~/SpectrumJetson/scripts/jetson/health-check.sh 2>/dev/null | sed -n '/== Storage/,/== System/p'" | sed 's/^/  /'

echo "== Repairing $PART from the backup superblock"
j "sudo -n systemctl stop photonvision; sudo -n e2fsck -fy -b 32768 -B 4096 $PART" 2>&1 | tail -4 | sed 's/^/  /'
reboot_and_wait
echo "== After the repair"
st=$(j cat /run/spectrum-data-status)
check "status back to settings=ok scratch=ok ($st)" "[[ '$st' == 'settings=ok scratch=ok' ]]"
check "$MNT mounted from its partition" "[[ \$(j findmnt -n -o SOURCE $MNT) == $PART ]]"
check "the partition's files survived (marker file)" "[[ \$(j sudo -n cat $MNT/.fallback-test 2>/dev/null) == storage-fallback-test ]]"
j "sudo rm -f $MNT/.fallback-test"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
