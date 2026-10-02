#!/usr/bin/env bash
# Quiet mode when the Jetson's date jumps (photonvision-65). Run ON THE JETSON, off the robot.
#
# At an event the Jetson boots on the date it last saved, and PhotonVision moves it forward to the
# robot's when the robot connects (RobotClockSync, patch 08). Quiet mode timed "disabled for 60 s"
# on the date, so the jump started it about a second after connecting. photonvision-65 times it on
# a monotonic clock.
#
# A fake robot (tests/fake-robot) enables for 3 s (which restarts the disabled-for timer: a robot
# that left disabled earlier would otherwise count), stays disabled for quietAfterDisabledSeconds
# + 15 s, then enables for 5 s. 3 s into the disabled stretch it starts publishing a clock OFFSET
# seconds ahead (default 3600), so the date jumps while quiet mode is timing it. Checks:
#   - PhotonVision set the date forward (the jump happened),
#   - quiet mode started quietAfterDisabledSeconds after the disable (-2/+4 s), not at the jump,
#   - the enable made the scratch partition writable again.
# Internet time (NTP) is paused for the test, since PhotonVision leaves the date alone while the
# Jetson has it, and put back afterwards with the date (tests/lib/bench.sh, ntp_pause/ntp_restore).
# Usage: tests/quiet-mode/clock-jump.sh [OFFSET_S]. Deadline: 4 min.
set -uo pipefail
if [[ -z ${CLOCK_JUMP_UNDER_TIMEOUT:-} ]]; then
  rc=0; CLOCK_JUMP_UNDER_TIMEOUT=1 timeout --kill-after=15 240 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the clock-jump test didn't finish in 4 min" >&2
  exit "$rc"
fi
OFFSET=${1:-3600}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LOG=$(mktemp)
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
api() { python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=2))["'"$1"'"])' 2>/dev/null; }
ro() { [[ ,$(findmnt -n -o OPTIONS /data/scratch), == *,ro,* ]]; }
source "$ROOT/tests/lib/bench.sh"

findmnt -n /data/scratch >/dev/null || { echo "No scratch partition: run 10-data-partition.sh first"; exit 1; }
[[ $(api robotConnected) == False ]] || { echo "PhotonVision is connected to a robot already (or isn't answering); not running."; exit 1; }
ro && { echo "The scratch partition is already read-only: leave quiet mode first (sudo spectrum-quiet off)"; exit 1; }
LIMIT=$(api quietAfterDisabledSeconds)
[[ $LIMIT =~ ^[0-9]+$ && $LIMIT -gt 0 ]] || { echo "Quiet mode after disabled is off (quietAfterDisabledSeconds=$LIMIT): nothing to test"; exit 1; }

cleanup() {
  touch /tmp/fake-robot-stop
  wait "${robot:-}" 2>/dev/null
  ntp_restore
  rm -f "$LOG"
}
trap cleanup EXIT
ntp_pause
skew0=$bench_skew0

echo "== Fake robot: its clock ${OFFSET} s ahead; enabled 3 s, disabled $((LIMIT + 15)) s, enabled 5 s (quiet after ${LIMIT} s disabled)"
FAKE_ROBOT_CLOCK_OFFSET_S=$OFFSET FAKE_ROBOT_CLOCK_AFTER_S=8 timeout -k 10 $((LIMIT + 95)) "$ROOT/tests/fake-robot/run.sh" enabled:3 "disabled:$((LIMIT + 15))" enabled:5 > "$LOG" 2>&1 &
robot=$!

# Watch 5 times a second, on the monotonic clock: connected, the jump, the disable after the first
# enable, quiet on, writable again. The jump is timed from connecting, the rest from the disable.
read -r t_connect jump t_jump t_quiet reason t_rw < <(python3 - "$skew0" "$LIMIT" <<'PY'
import json, sys, time, urllib.request
skew0, limit = float(sys.argv[1]), int(sys.argv[2])
def state():
    try:
        return json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=1))
    except Exception:
        return {}
def ro():
    for line in open("/proc/mounts"):
        f = line.split()
        if f[1] == "/data/scratch":
            return "ro" in f[3].split(",")
    return False
t0 = time.monotonic()
connect = jump = t_jump = enabled_seen = disabled = quiet = rw = None
reason = "-"
while time.monotonic() - t0 < limit + 70:
    now = time.monotonic()
    s = state()
    if connect is None and s.get("robotConnected"):
        connect = now
    j = time.time() - time.monotonic() - skew0
    if t_jump is None and abs(j) > 60:
        jump, t_jump = j, now
    if connect is not None and s.get("enabled"):
        enabled_seen = True
    if enabled_seen and disabled is None and s.get("robotConnected") and s.get("enabled") is False:
        disabled = now
    if disabled is not None and quiet is None and s.get("quietNow"):
        quiet, reason = now, (s.get("quietReason") or "-").replace(" ", "_")
    if quiet is not None and rw is None and not s.get("quietNow") and not ro():
        rw = now
        break
    time.sleep(0.2)
since = lambda t, base: "-" if t is None or base is None else f"{t - base:.1f}"
print(since(connect, t0), f"{jump:.0f}" if jump is not None else "-", since(t_jump, connect), since(quiet, disabled), reason, since(rw, disabled))
PY
)
[[ $t_connect == - ]] && echo "  PhotonVision never connected to the fake robot"
echo "  date jumped ${jump} s, ${t_jump} s after connecting; after the disable: quiet at +${t_quiet} s (${reason//_/ }), writable again at +${t_rw} s"
check "PhotonVision set the date from the robot's clock (forward ~${OFFSET} s)" \
      "[[ \$jump != - ]] && (( \${jump#-} > OFFSET - 60 && \${jump#-} < OFFSET + 60 ))"
# Quiet at about LIMIT s after the disable.
check "quiet mode started after ${LIMIT} s disabled, not at the jump" \
      "[[ \$t_quiet != - ]] && python3 -c 'import sys; sys.exit(not ${LIMIT} - 2 <= float(sys.argv[1]) <= ${LIMIT} + 4)' \"\$t_quiet\""
check "the enable made the scratch partition writable again" "[[ \$t_rw != - ]] && ! ro"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
