#!/usr/bin/env bash
# Bench test for the Jetson setting its date from the robot's (patch 08), without a robot. Run ON
# THE JETSON, off the robot. No PhotonVision setting changes: the loopback interface answers as
# the robot (tests/lib/bench.sh), and internet time is paused for the test, then put back.
#
# A fake robot (FakeRobotClock.java, an NT server here) publishes /photonvision/clock/unixMs
# OFFSET seconds fast for 40 s, then the correct time for 40 s. Checks:
#   - PhotonVision moved the date forward by OFFSET soon after connecting,
#   - and back to the right time once the robot's clock was right again (it waits 30 s between
#     changes, so a robot publishing nonsense can't thrash the clock).
# Usage: tests/robot-clock/run.sh [offset_s]   (default 120). Deadline: 3 min.
set -uo pipefail
if [[ -z ${ROBOT_CLOCK_UNDER_TIMEOUT:-} ]]; then
  rc=0; ROBOT_CLOCK_UNDER_TIMEOUT=1 timeout --kill-after=15 180 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the robot-clock test didn't finish in 3 min" >&2
  exit "$rc"
fi
OFFSET=${1:-120}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
JAVA=/usr/lib/jvm/java-17-openjdk-arm64/bin/java
source "$ROOT/tests/lib/bench.sh"
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }

robot_address_add
ntp_pause
cleanup() { [[ -n ${fake:-} ]] && kill "$fake" 2>/dev/null; wait 2>/dev/null; ntp_restore; robot_address_del; }
trap cleanup EXIT

P=$(systemctl show photonvision -p MainPID --value)
"$JAVA" -cp /opt/photonvision/photonvision.jar "$HERE/FakeRobotClock.java" "$OFFSET" 40 2>&1 \
  | grep --line-buffered -v "^\[" | sed -u 's/^/  fake robot: /' &
fake=$!
# The date against the true time (the monotonic clock plus the skew before the test), twice a
# second: when it first went OFFSET forward, and whether it's right again at the end.
# (bench_skew0 is set by ntp_pause, in tests/lib/bench.sh.)
# shellcheck disable=SC2154
read -r t_fwd off_fwd off_end < <(python3 - "$bench_skew0" "$OFFSET" <<'PY'
import sys, time
skew0, offset = float(sys.argv[1]), float(sys.argv[2])
t0 = time.monotonic()
fwd = None
off = 0.0
while time.monotonic() - t0 < 84:
    off = time.time() - time.monotonic() - skew0
    if fwd is None and abs(off - offset) < 5:
        fwd = (time.monotonic() - t0, off)
    time.sleep(0.5)
print(f"{fwd[0]:.1f}" if fwd else "-", f"{fwd[1]:.1f}" if fwd else "-", f"{off:.1f}")
PY
)
wait "$fake" 2>/dev/null; fake=""
echo "  date moved +${off_fwd} s at ${t_fwd} s; off by ${off_end} s at the end"
check "PhotonVision moved the date forward by ~${OFFSET} s" "[[ \$t_fwd != - ]]"
check "and back to the right time when the robot's clock was right (within 2 s)" \
      "python3 -c 'import sys; sys.exit(abs(float(sys.argv[1])) > 2)' \"\$off_end\""
echo "== PhotonVision's log"
journalctl _PID="$P" --no-pager -o cat | grep "Clock set from the robot" | tail -4 | sed 's/^/  /'
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
