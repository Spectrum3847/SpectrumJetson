#!/usr/bin/env bash
# Power-cut test: what survives pulling the Jetson's power mid-recording? Run ON THE LAPTOP, with
# the Jetson on the USB-C cable. It starts a bench recording, you pull the power plug when told,
# and after the Jetson boots again it checks:
#   - ext4 recorded no errors, and the kernel replayed its journal cleanly,
#   - the log from before the cut survived (persistent journal),
#   - PhotonVision came back healthy,
#   - how much of the recording survived: seconds lost vs the last status the laptop saw, and every
#     saved frame is a complete JPEG.
#   - the data partitions mounted (no fallback stand-ins), and the fallback ran after their mounts.
# Exits 1 if any check FAILs: added SSD media errors, ext4 errors, a partition not mounted, a
# fallback in use, or PhotonVision not healthy.
# Usage: tests/power-cut/run.sh [seconds_before_cut]   (default 20)
set -uo pipefail
JETSON=${JETSON:-192.168.55.1}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
WAIT=${1:-20}
HERE=$(cd "$(dirname "$0")" && pwd)
# Every command after the cut has a deadline too (timeout): a hung SSH must not hang the test.
SSH=(timeout 90 ssh -i "$KEY" -o ConnectTimeout=3 -o BatchMode=yes "${JETSON_USER:-spectrum3847}@$JETSON")
fails=0
API=http://$JETSON:5800/api/rewind

api() { # GET (no body) or POST a JSON body; prints the reply, or nothing on failure
  python3 - "$API" "${1:-}" <<'PY' 2>/dev/null
import sys, urllib.request
url, body = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, data=body.encode() if body else None,
                             headers={"Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=1).read().decode())
PY
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))" 2>/dev/null; }

boot_before=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id') || { echo "Jetson not reachable at $JETSON"; exit 1; }
# The SSD's own counters, before and after: a cut must never add media errors (the first SSD died
# of 285 of them after 21 cuts, while this test kept passing on the filesystem alone).
smart() { "${SSH[@]}" "sudo -n smartctl -A /dev/nvme0 2>/dev/null | awk -F: '/$1/ {gsub(/[ ,]/,\"\",\$2); print \$2}'"; }
media_before=$(smart "Media and Data Integrity Errors") unsafe_before=$(smart "Unsafe Shutdowns")
echo "SSD before: ${media_before:-?} media errors, ${unsafe_before:-?} unsafe shutdowns" 
api '{"manual": true}' >/dev/null || { echo "Rewind API not reachable"; exit 1; }
sleep 1
session=$(api | field session)
[[ -n $session ]] || { echo "Recording did not start"; exit 1; }
echo "Recording $session. Pull the Jetson's power plug after the countdown."

last_secs=0 dark_since=0 t_start=$(date +%s)
while :; do
  now=$(date +%s)
  if ((now - t_start > WAIT + 120)); then
    echo; echo "TIMEOUT: the Jetson didn't go dark within 2 min of the countdown; stopping the recording"
    api '{"manual": false}' >/dev/null; exit 1
  fi
  s=$(api)
  if [[ -n $s ]]; then
    last_secs=$(field seconds <<<"$s")
    dark_since=0
    left=$((WAIT - (now - t_start)))
    if ((left > 0)); then printf "\r  recording %5.1f s ... pull the power in %2d s " "$last_secs" "$left"
    else printf "\r  recording %5.1f s ... PULL THE POWER NOW          " "$last_secs"; fi
  else
    ((dark_since == 0)) && dark_since=$now
    if ((now - dark_since >= 3)); then break; fi
  fi
  sleep 0.2
done
printf "\n  Jetson went dark; last status said %.1f s recorded.\n" "$last_secs"
echo "Plug the power back in. Waiting for the Jetson to boot..."
end=$((SECONDS + 600))   # power back in and boot: 10 min at most
until "${SSH[@]}" true 2>/dev/null; do ((SECONDS < end)) || { echo "TIMEOUT: no Jetson 10 min after the cut"; exit 1; }; sleep 2; done
boot_after=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id')
[[ $boot_after != "$boot_before" ]] || { echo "The Jetson did not reboot (same boot id); was the power pulled?"; exit 1; }
echo "Booted. Waiting for PhotonVision..."
end=$((SECONDS + 180))
until [[ -n $(api) ]]; do ((SECONDS < end)) || { echo "TIMEOUT: PhotonVision not answering 3 min after boot"; exit 1; }; sleep 2; done
sleep 10 # let the detectors start

echo
echo "== SSD"
media_after=$(smart "Media and Data Integrity Errors") unsafe_after=$(smart "Unsafe Shutdowns")
echo "  media errors ${media_before:-?} -> ${media_after:-?}, unsafe shutdowns ${unsafe_before:-?} -> ${unsafe_after:-?}"
if [[ -n $media_after && -n $media_before && $media_after -gt $media_before ]]; then
  echo "  FAIL: the cut added $((media_after - media_before)) media errors: this SSD is losing data on power cuts"
  fails=$((fails + 1))
fi
echo "== Filesystems (system, settings, scratch)"
fs=$("${SSH[@]}" 'bash -s' <<'REMOTE'
for m in / /data/settings /data/scratch; do
  findmnt -n "$m" >/dev/null || { echo "  FAIL: $m NOT MOUNTED"; continue; }
  dev=$(basename "$(findmnt -no SOURCE "$m")")
  n=$(cat /sys/fs/ext4/$dev/errors_count 2>/dev/null || echo 0)
  if [[ $n -gt 0 ]]; then echo "  FAIL: $m ($dev): ext4 recorded $n errors"; else echo "  $m ($dev): no ext4 errors"; fi
  journalctl -k -b 0 --no-pager -o cat | grep -F "EXT4-fs ($dev)" | sed 's/^/    kernel: /'
done
st=$(cat /run/spectrum-data-status 2>/dev/null)
if [[ $st == "settings=ok scratch=ok" ]]; then echo "  fallback: $st"; else echo "  FAIL: fallback in use: ${st:-no status}"; fi
# The fallback must have run after the data mounts finished (10-data-partition.sh orders it).
fb=$(systemctl show -p ExecMainStartTimestampMonotonic --value spectrum-data-fallback 2>/dev/null)
for u in data-settings.mount data-scratch.mount; do
  t=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$u" 2>/dev/null)
  [[ -n $fb && -n $t && $t -gt 0 && $t -gt $fb ]] && echo "  FAIL: $u finished mounting after the fallback ran"
done
true
REMOTE
)
echo "$fs"
fails=$((fails + $(grep -c "FAIL" <<<"$fs")))
echo "== Log from before the cut (the last lines the old boot saved)"
# By boot id: -b -1 is unreliable here, since the clock restarts at 1970 after a cut (no RTC battery).
"${SSH[@]}" "journalctl _BOOT_ID=${boot_before//-/} --no-pager -o short-iso -n 3 2>&1 | sed 's/^/  /'"
echo "== PhotonVision"
pv=$("${SSH[@]}" '~/SpectrumJetson/scripts/jetson/health-check.sh' | sed -n '/== PhotonVision/,/== Cameras/p' | grep -v '== Cameras')
echo "$pv"
fails=$((fails + $(grep -c "  FAIL" <<<"$pv")))
echo "== The recording"
"${SSH[@]}" "cat /opt/photonvision/rewind/sessions/$session/${session}_session.json" | python3 -c '
import json, sys
m = json.load(sys.stdin)
print("  session.json:", "ended cleanly (" + m["endReason"] + ")" if m.get("endReason") else "no end recorded (expected: power was cut)")'
dest=$(mktemp -d)
rsync -a -e "ssh -i $KEY" "${JETSON_USER:-spectrum3847}@$JETSON:/opt/photonvision/rewind/sessions/$session" "$dest/"
python3 "$HERE/../../scripts/host/rewind-export.py" "$dest/$session" --out "$dest/export" | sed 's/^/  /'
python3 - "$dest/$session" "$last_secs" <<'PY'
import csv, glob, os, sys
sess, last = sys.argv[1], float(sys.argv[2])
for cam in sorted(glob.glob(sess + "/*/")):
    t = []
    for idx in sorted(glob.glob(cam + "*.csv")):
        data = idx[:-4] + ".mjpeg"
        n = os.path.getsize(data) if os.path.exists(data) else 0
        for r in csv.reader(l for l in open(idx) if not l.startswith("#")):
            if len(r) >= 7 and int(r[1]) + int(r[2]) <= n:
                t.append(int(r[5]))
    if not t:
        print(f"  {os.path.basename(cam[:-1])}: nothing saved")
        continue
    dur = (t[-1] - t[0]) / 1e6
    print(f"  {os.path.basename(cam[:-1])}: {dur:.1f} s saved, {last:.1f} s seen recording -> "
          f"about {max(0.0, last - dur):.1f} s lost at the cut")
PY
echo
echo "Copied to $dest (delete it when done). The recording stays on the Jetson; delete it in the UI."
if ((fails > 0)); then echo "FAIL: $fails check(s) failed (above)"; exit 1; fi
echo "PASS"
