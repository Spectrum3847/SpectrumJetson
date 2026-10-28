#!/usr/bin/env bash
# A robot recording through a NetworkTables drop (photonvision-77). Run ON THE JETSON, off the robot.
#
# At TXMAN1 (2026-10-17) a flaky robot switch dropped NetworkTables for ~2 s mid-match, and each
# reconnect split the match's recording in two: after a reconnect, record reads false until the
# robot's value arrives again, and Rewind took that for "robot stopped". Now a robot recording keeps
# its grace after the reconnect until the robot sends record again.
#
# A fake robot (tests/fake-robot, FAKE_ROBOT_RECORD=1) plays an FMS match and asks Rewind to record:
#   phase 0  fms-enabled 9 s, record true; 4 s in, a firewall rule drops the robot's traffic
#   phase 1  fms-enabled-norecord 10 s: record unpublished (PhotonVision can't see that yet); the
#            rule comes off once PhotonVision has noticed the drop, so it reconnects to a robot
#            that hasn't sent record yet, for several seconds
#   phase 2  fms-enabled 5 s, record true again
#   phase 3  fms-disabled 3 s, then record false
# Checks: PhotonVision disconnected and reconnected; one recording for the whole match (the same
# session name throughout, one "recording session" log line); the log says it kept the session
# and that the robot still wanted it; it ended at the robot's false, as "robot stopped".
# The firewall rules are removed on exit. Deadline: 2 min.
set -uo pipefail
if [[ -z ${REWIND_RECONNECT_UNDER_TIMEOUT:-} ]]; then
  rc=0; REWIND_RECONNECT_UNDER_TIMEOUT=1 timeout --kill-after=15 120 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the Rewind reconnect test didn't finish in 2 min" >&2
  exit "$rc"
fi
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LOG=$(mktemp)
PHASES=/tmp/fake-robot.log   # tests/fake-robot/run.sh writes FakeRobot's phase lines here
ROBOT_IP=10.85.15.2
LABEL=reconnect-test
rm -f "$PHASES"
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
status() { python3 -c '
import json, urllib.request
s = json.load(urllib.request.urlopen("http://localhost:5800/api/rewind", timeout=2))
print(s.get("robotConnected"), s.get("recording"), s.get("session") or "-")' 2>/dev/null; }
phase_started() { grep -q "^phase $1 " "$PHASES" 2>/dev/null; }
block() { for d in -s -d; do sudo -n iptables -I INPUT "$d" "$ROBOT_IP" -j DROP; done; blocked=1; }
unblock() { for d in -s -d; do while sudo -n iptables -D INPUT "$d" "$ROBOT_IP" -j DROP 2>/dev/null; do :; done; done; blocked=0; }

read -r connected recording _ <<<"$(status)"
[[ $connected == False ]] || { echo "PhotonVision is connected to a robot (or isn't answering); not running."; exit 1; }
[[ $recording == False ]] || { echo "Rewind is recording; not running."; exit 1; }
sudo -n iptables -L INPUT -n >/dev/null || { echo "Couldn't run iptables (sudo)"; exit 1; }
blocked=0
cleanup() { [[ $blocked == 1 ]] && unblock; touch /tmp/fake-robot-stop; wait "${robot:-}" 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT

start=$(date +%s)
FAKE_ROBOT_RECORD=1 FAKE_ROBOT_LABEL=$LABEL timeout -k 10 90 "$ROOT/tests/fake-robot/run.sh" \
  fms-enabled:9 fms-enabled-norecord:10 fms-enabled:5 fms-disabled:3 > "$LOG" 2>&1 &
robot=$!

# Sample the connection and the session name every 0.25 s until the fake robot is done.
samples=() saw_down=0 saw_back=0
for _ in $(seq 1 30); do sleep 0.5; phase_started 0 && break; done
phase_started 0 || { echo "The fake robot never started its match"; cat "$LOG"; exit 1; }
t0=$(date +%s.%N)
while kill -0 "$robot" 2>/dev/null; do
  t=$(python3 -c "print($(date +%s.%N) - $t0)")
  if [[ $blocked == 0 ]] && ! phase_started 1 && python3 -c "import sys; sys.exit(not $t >= 4)"; then
    block; echo "  $(printf %.1f "$t") s: robot's traffic dropped"
  fi
  if [[ $blocked == 1 ]] && phase_started 1 && (( saw_down == 1 )); then
    unblock; echo "  $(printf %.1f "$t") s: robot's traffic back"
  fi
  read -r connected recording session <<<"$(status)"
  [[ $connected == False && $blocked == 1 ]] && saw_down=1
  [[ $connected == True && $saw_down == 1 ]] && saw_back=1
  [[ $recording == True ]] && samples+=("$session")
  sleep 0.25
done
wait "$robot"; robot=""
sleep 1

journalctl -u photonvision --since "@$start" --no-pager -o cat > "$LOG.pv"
mapfile -t names < <(printf '%s\n' "${samples[@]}" | sort -u)
opened=$(grep -c "Rewind: recording session .*_${LABEL}_" "$LOG.pv")
echo "  recordings seen while sampling: ${names[*]:-none}"
grep -E "Rewind: (recording session|stopped session|NetworkTables reconnected|the robot still)|NT (lost connection|connected)" "$LOG.pv" | sed 's/^/    /'
check "PhotonVision lost the robot during the drop" "(( saw_down == 1 ))"
check "and reconnected" "(( saw_back == 1 ))"
check "one recording for the whole match (${#names[@]} name(s) seen, $opened opened)" "(( \${#names[@]} == 1 && opened == 1 ))"
check "kept it after the reconnect, until the robot sent record" "grep -q 'NetworkTables reconnected; keeping' \"\$LOG.pv\""
check "the robot's late true kept the same session" "grep -q 'the robot still wants recording; same session' \"\$LOG.pv\""
check "ended at the robot's false (robot stopped)" "grep -q 'stopped session .*_${LABEL}_.*(robot stopped)' \"\$LOG.pv\""
rm -f "$LOG.pv"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
