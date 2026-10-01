#!/usr/bin/env bash
# Read-only system test (scripts/jetson/ro-root.sh). Run ON THE LAPTOP, Jetson on the USB-C cable.
# Turns the read-only system on, checks PhotonVision and the data partitions, writes a file to the
# system partition, reboots and checks it's gone, then turns it off and checks the system is
# writable again. Leaves the Jetson writable. Every wait has a limit (~15 min in all).
set -uo pipefail
JETSON=${JETSON:-192.168.55.1}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
JETSON_USER=${JETSON_USER:-spectrum3847}
SSH=(ssh -i "$KEY" -o ConnectTimeout=5 -o BatchMode=yes "$JETSON_USER@$JETSON")
RO=SpectrumJetson/scripts/jetson/ro-root.sh
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
j() { timeout 60 "${SSH[@]}" "$@"; }
pv_up() { j 'python3 -c "import urllib.request; urllib.request.urlopen(\"http://localhost:5800/\", timeout=3)"' 2>/dev/null; }
wait_boot() {  # $1: boot id before
  local end=$((SECONDS + 300)); sleep 10
  until id=$(j cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [[ -n $id && $id != "$1" ]]; do
    ((SECONDS < end)) || { echo "TIMEOUT: no reboot within 5 min"; exit 1; }; sleep 3
  done
  end=$((SECONDS + 120)); until pv_up; do ((SECONDS < end)) || break; sleep 3; done
}
boot() { j cat /proc/sys/kernel/random/boot_id; }

echo "== Turning the read-only system on"
b=$(boot); j "$RO on" | sed 's/^/  /'; wait_boot "$b"
check "system partition is the overlay" "[[ \$(j findmnt -n -o FSTYPE /) == overlay ]]"
check "PhotonVision answers" "pv_up"
check "data partitions ok ($(j cat /run/spectrum-data-status))" "[[ \$(j cat /run/spectrum-data-status) == 'settings=ok scratch=ok' ]]"
check "settings partition writable" "j 'echo x | sudo -n tee /data/settings/.ro-test >/dev/null && sudo -n rm /data/settings/.ro-test'"
j 'echo ro-test | sudo -n tee /etc/spectrum-ro-test >/dev/null'
check "a file written to the system partition exists until reboot" "j test -f /etc/spectrum-ro-test"
b=$(boot); j 'sudo -n systemctl reboot' >/dev/null 2>&1; wait_boot "$b"
check "...and is gone after it" "! j test -f /etc/spectrum-ro-test"
check "still read-only after a plain reboot" "[[ \$(j findmnt -n -o FSTYPE /) == overlay ]]"
j "sudo -n $HOME/$RO status 2>/dev/null || $RO status" | sed 's/^/  /'

echo "== Turning it off"
b=$(boot); j "$RO off" | sed 's/^/  /'; wait_boot "$b"
check "system partition writable again" "[[ \$(j findmnt -n -o FSTYPE /) == ext4 ]]"
check "PhotonVision answers" "pv_up"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
