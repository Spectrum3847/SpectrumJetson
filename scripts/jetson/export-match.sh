#!/usr/bin/env bash
# Everything the Jetson recorded about a match, in one .tar.gz for robotlog.spectrum3847.org (or a
# bug report). Run ON THE JETSON; it writes the bundle to stdout, so from the laptop:
#
#   ssh -i ~/.ssh/jetson_ed25519 spectrum3847@<jetson-ip> \
#       '~/SpectrumJetson/scripts/jetson/export-match.sh Q13' > jetson-Q13.tar.gz
#
# Usage: export-match.sh [MATCH ...]   e.g. Q13, E4, "Match: 0" (practice). No MATCH: everything kept.
#
# What goes in (TXMAN1: we had none of it, then hand-picked pieces two weeks later):
#   - PhotonVision's log files that mention the match (PhotonVision logs "Event: TXMAN1, Match: Q13"
#     when the field connects). No MATCH: all of them.
#   - The system journal of every boot whose text mentions the match, kernel included, with the
#     boot ID in the name. Times are the Jetson's clock: if it was never set from the robot
#     (clockSource "unset"), the date is wrong; order by the boot ID and the uptime in each line.
#   - Each matching Rewind session's session.json and per-camera CSV (frame times), not the video
#     (rewind-pull.sh copies that).
#   - Now: lsusb -t, smartctl, the ext4 error counts, and health-check.sh's report.
#
# Quiet mode (photonvision-56) keeps the journal in RAM after a match, so a boot's journal ends at
# the match: run this before the next power cut if you need what came after.
set -uo pipefail
PV=/opt/photonvision
LOGS=$PV/photonvision_config/logs
SESSIONS=$PV/rewind/sessions
HERE=$(cd "$(dirname "$0")" && pwd)

[[ -t 1 ]] && { echo "Writes a .tar.gz to stdout: redirect it (export-match.sh Q13 > jetson-Q13.tar.gz)" >&2; exit 2; }

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
want=("$@")

# Does this text mention one of the wanted matches? (No matches given: everything does.)
mentions() {  # $1 file
  [[ ${#want[@]} -eq 0 ]] && return 0
  local m
  for m in "${want[@]}"; do
    if [[ $m == "Match: "* ]]; then grep -aqF -- "$m" "$1" && return 0
    else grep -aqE -- "Match: ${m}([^0-9A-Za-z]|$)" "$1" && return 0; fi
  done
  return 1
}

mkdir -p "$out/photonvision-logs" "$out/journal" "$out/rewind" "$out/now"

# PhotonVision's logs (root-owned on the scratch partition).
while read -r f; do
  copy="$out/photonvision-logs/$(basename "$f")"
  sudo -n cat "$f" > "$copy" 2>/dev/null || continue
  mentions "$copy" || rm -f "$copy"
done < <(sudo -n find "$LOGS" -maxdepth 1 -name '*.log' 2>/dev/null | sort)

# The journal, one file per boot that mentions the match.
while read -r idx bootid _; do
  [[ $bootid =~ ^[0-9a-f]{32}$ ]] || continue
  f="$out/journal/boot_${idx}_${bootid}.txt"
  sudo -n journalctl -b "$bootid" -o short-iso-precise --no-pager > "$f" 2>/dev/null || { rm -f "$f"; continue; }
  if mentions "$f"; then gzip -9 "$f"; else rm -f "$f"; fi
done < <(sudo -n journalctl --list-boots --no-pager 2>/dev/null)

# Rewind sessions: named NNNN_<match>_<date>; their metadata and frame times, not the video.
while read -r d; do
  name=$(basename "$d") keep=0
  if [[ ${#want[@]} -eq 0 ]]; then keep=1; fi
  for m in "${want[@]}"; do [[ $name == *"_${m}_"* || $name == *"-${m}-"* ]] && keep=1; done
  [[ $keep == 1 ]] || continue
  mkdir -p "$out/rewind/$name"
  sudo -n find "$d" -maxdepth 1 \( -name '*.json' -o -name '*.csv' \) -exec cp -t "$out/rewind/$name" {} + 2>/dev/null
done < <(sudo -n find "$SESSIONS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

# The state now.
{
  echo "exported $(date -u +%FT%TZ) (Jetson clock), boot $(cat /proc/sys/kernel/random/boot_id), up $(cut -d' ' -f1 /proc/uptime) s"
  echo "matches: ${want[*]:-all}"
} > "$out/README.txt"
lsusb -t > "$out/now/lsusb-tree.txt" 2>&1
sudo -n smartctl -a /dev/nvme0 > "$out/now/smartctl.txt" 2>&1
for e in /sys/fs/ext4/*/errors_count; do echo "$e: $(cat "$e" 2>/dev/null)"; done > "$out/now/ext4-errors.txt"
"$HERE/health-check.sh" > "$out/now/health-check.txt" 2>&1

n=$(find "$out" -type f | wc -l)
count() { find "$1" -mindepth 1 -maxdepth 1 | wc -l; }
echo "export-match: $n files (PhotonVision logs: $(count "$out/photonvision-logs"), boots: $(count "$out/journal"), Rewind sessions: $(count "$out/rewind"))" >&2
tar -C "$out" -czf - .
