#!/usr/bin/env bash
# Rewind's recording numbers and delete (photonvision-65). Run ON THE JETSON, off the robot.
#
# Recordings are numbered from a counter file on the scratch partition, which takes power cuts, and
# name order is age order: the quota deletes the lowest numbers first. A counter lost or rolled back
# restarted the numbering, so the quota would then have deleted the newest recordings first. And a
# delete in quiet mode (the partition read-only after a match) reported success but deleted nothing.
#
#   1. The counter is rolled back to 1 (as a power cut can); a 3 s bench recording must still be
#      numbered after the newest one on disk.
#   2. A fake robot ends a match, so quiet mode starts: deleting that recording must be refused,
#      saying why, and it must still be there.
#   3. After an enable (partition writable), the delete works and the recording is gone.
# The counter is left as PhotonVision wrote it (numbers aren't reused). Deadline: 3 min.
set -uo pipefail
if [[ -z ${REWIND_SESSIONS_UNDER_TIMEOUT:-} ]]; then
  rc=0; REWIND_SESSIONS_UNDER_TIMEOUT=1 timeout --kill-after=15 180 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the Rewind sessions test didn't finish in 3 min" >&2
  exit "$rc"
fi
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
COUNTER=/opt/photonvision/rewind/next-session-number
LOG=$(mktemp)
PHASES=/tmp/fake-robot.log   # tests/fake-robot/run.sh writes FakeRobot's phase lines here
rm -f "$PHASES"
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
# Rewind's API: GET with no argument, else POST the JSON given. Prints "HTTP-status body".
rewind() { python3 - "${1:-}" <<'PY'
import sys, urllib.error, urllib.request
body = sys.argv[1]
req = urllib.request.Request("http://localhost:5800/api/rewind", data=body.encode() if body else None,
                             headers={"Content-Type": "application/json"})
try:
    r = urllib.request.urlopen(req, timeout=5)
    print(r.status, r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
PY
}
field() { python3 -c "import json,sys; print(json.loads(sys.stdin.read().split(' ', 1)[1]).get('$1'))" 2>/dev/null; }
newest() { rewind | python3 -c 'import json,sys; r=json.loads(sys.stdin.read().split(" ", 1)[1])["recent"]; print(r[0]["name"] if r else "")'; }
quiet() { python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=2))["quietNow"])' 2>/dev/null; }
listed() { rewind | grep -q "\"name\":\"$1\""; }
ro() { [[ ,$(findmnt -n -o OPTIONS /data/scratch), == *,ro,* ]]; }

[[ $(rewind | field robotConnected) == False ]] || { echo "PhotonVision is connected to a robot (or isn't answering); not running."; exit 1; }
[[ $(rewind | field recording) == False ]] || { echo "Rewind is recording; not running."; exit 1; }
ro && { echo "The scratch partition is read-only (quiet mode): leave it first"; exit 1; }
cleanup() { rewind '{"manual": false}' >/dev/null; touch /tmp/fake-robot-stop; wait "${robot:-}" 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT

before=$(newest)
echo "== 1. Counter rolled back to 1 (newest recording: ${before:-none}), then a 3 s bench recording"
echo 1 | sudo -n tee "$COUNTER" >/dev/null || { echo "Couldn't write $COUNTER (sudo)"; exit 1; }
rewind '{"manual": true}' >/dev/null
for _ in $(seq 20); do sleep 0.5; [[ $(rewind | field recording) == True ]] && break; done
sleep 3
name=$(rewind | field session)
rewind '{"manual": false}' >/dev/null
for _ in $(seq 20); do sleep 0.5; [[ $(rewind | field recording) == False ]] && break; done
echo "  recorded $name"
b=${before%%_*}; n_before=$((10#${b:-0})); n=$((10#${name%%_*}))
check "numbered after the newest on disk (${b:-none} -> ${name%%_*}), not 0001" "(( n == n_before + 1 ))"
check "listed first, as the newest" "[[ \$(newest) == \$name ]]"

echo "== 2. A fake match ends (fms-enabled 3 s, fms-disabled 20 s, then enabled 5 s); delete while quiet"
timeout -k 10 90 "$ROOT/tests/fake-robot/run.sh" fms-enabled:3 fms-disabled:20 enabled:5 > "$LOG" 2>&1 &
robot=$!
for _ in $(seq 1 60); do sleep 0.5; [[ $(quiet) == True ]] && ro && break; done
reply=$(rewind "{\"delete\": \"$name\"}")
echo "  delete answered: $reply"
check "refused in quiet mode, saying why" "[[ \$reply == 400* && \$reply == *quiet* ]]"
check "the recording is still there" "listed \"\$name\" && sudo -n test -d /opt/photonvision/rewind/sessions/\$name"

echo "== 3. After the enable"
for _ in $(seq 1 60); do sleep 0.5; [[ $(quiet) == False ]] && ! ro && break; done
reply=$(rewind "{\"delete\": \"$name\"}")
echo "  delete answered: ${reply%% *}"
check "deleted (HTTP 200)" "[[ \$reply == 200* ]]"
check "and gone" "! listed \"\$name\" && ! sudo -n test -e /opt/photonvision/rewind/sessions/\$name"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
