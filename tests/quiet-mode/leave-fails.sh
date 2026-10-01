#!/usr/bin/env bash
# Quiet mode when making the scratch partition writable again fails (photonvision-65). Run ON THE
# JETSON, off the robot.
#
# Before photonvision-65, PhotonVision called quiet mode off even when the helper couldn't remount
# the partition writable: it stayed read-only, nothing tried again, and every Rewind write failed
# until a reboot. Now it stays quiet (and says why in quietError) and tries again every 5 s.
#
# A fake robot plays the end of a match (teleop 3 s, then disabled with the field attached), so
# quiet mode starts. The partition's block device is then made read-only (blockdev --setro), so the
# remount at the enable fails, as it would on a damaged drive. Checks:
#   - after the enable PhotonVision still reports quiet, with the error, and health-check FAILs,
#   - once the block device is writable again (blockdev --setrw), quiet mode ends by itself within
#     a retry (5 s, plus the remount) and the partition is writable.
# The block device is always made writable again on exit. Deadline: 4 min.
set -uo pipefail
if [[ -z ${LEAVE_FAILS_UNDER_TIMEOUT:-} ]]; then
  rc=0; LEAVE_FAILS_UNDER_TIMEOUT=1 timeout --kill-after=15 240 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the quiet-mode leave test didn't finish in 4 min" >&2
  exit "$rc"
fi
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LOG=$(mktemp)
PHASES=/tmp/fake-robot.log   # tests/fake-robot/run.sh writes FakeRobot's phase lines here
rm -f "$PHASES"
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
# quietNow and quietError (the error "-" when empty, spaces as _ so read keeps it in one field).
api() { python3 -c 'import json,urllib.request; s=json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=2)); print(s.get("quietNow"), (s.get("quietError") or "-").replace(" ", "_"))' 2>/dev/null; }
ro() { [[ ,$(findmnt -n -o OPTIONS /data/scratch), == *,ro,* ]]; }
now() { python3 -c 'import time; print(f"{time.monotonic():.1f}")'; }
since() { python3 -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.1f}")' "$1" "$(now)"; }

findmnt -n /data/scratch >/dev/null || { echo "No scratch partition: run 10-data-partition.sh first"; exit 1; }
[[ -n $(api) ]] || { echo "PhotonVision's /api/robotState isn't answering"; exit 1; }
ro && { echo "The scratch partition is already read-only: leave quiet mode first (sudo spectrum-quiet off)"; exit 1; }
DEV=$(findmnt -n -o SOURCE /data/scratch)

echo "== Fake match end: fms-enabled 3 s, fms-disabled 20 s (quiet; $DEV made read-only), enabled 60 s"
timeout -k 10 150 "$ROOT/tests/fake-robot/run.sh" fms-enabled:3 fms-disabled:20 enabled:60 > "$LOG" 2>&1 &
robot=$!
cleanup() {
  sudo -n blockdev --setrw "$DEV"
  touch /tmp/fake-robot-stop
  wait $robot 2>/dev/null
  rm -f "$LOG"
}
trap cleanup EXIT

for _ in $(seq 1 60); do sleep 1; ro && break; done
check "quiet mode made the scratch partition read-only after the match" ro
sudo -n blockdev --setro "$DEV" || { echo "Couldn't make $DEV read-only (sudo)"; exit 1; }

# The enable: wait for the fake robot's enabled phase, then give the failed leave a retry or two.
for _ in $(seq 1 40); do sleep 1; grep -q "phase 2 enabled" "$PHASES" 2>/dev/null && break; done
sleep 7
read -r q err <<<"$(api)"
echo "  enabled, block device read-only: quietNow $q, quietError: ${err//_/ }"
check "PhotonVision still reports quiet mode, with the error" "[[ \$q == True && \$err != - ]] && ro"
hc=$("$ROOT/scripts/jetson/health-check.sh" 2>&1 | grep "quiet mode can't end")
echo "    health-check: ${hc:-no quiet-mode line}"
check "health-check FAILs it" "[[ \$hc == *FAIL* ]]"

sudo -n blockdev --setrw "$DEV"
t0=$(now) writable=""
for _ in $(seq 1 30); do
  sleep 0.5
  read -r q err <<<"$(api)"
  if [[ $q == False ]] && ! ro; then writable=$(since "$t0"); break; fi
done
check "with the block device writable again, quiet mode ended by itself ${writable:+after $writable s}" \
      "[[ -n \$writable ]] && python3 -c 'import sys; sys.exit(float(sys.argv[1]) > 7)' \$writable"
read -r q err <<<"$(api)"
check "and the error cleared" "[[ \$err == - ]]"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
