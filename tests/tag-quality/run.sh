#!/usr/bin/env bash
# Live check of the per-tag quality topic (photonvision-61). Run ON THE JETSON:
#   tests/tag-quality/run.sh [SECONDS]
# 1. Bench.java: what TagQuality costs per tag on this CPU.
# 2. Fake cameras (a synthetic session with tags) and a fake robot, then Probe.java reads every
#    camera's rawBytes and tagQuality the way robot code would, and checks each frame with tags got
#    its quality array (same sequence ID, same tag IDs). Real cameras and settings come back after.
# Fake cameras run without lens calibrations, so undistortPx and the reprojection errors are NaN
# here; the fork's TagQualityTest checks those numbers.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SECS=${1:-20}
JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-arm64/bin/java}
JAR=/opt/photonvision/photonvision.jar
DEADLINE=$((SECS + 360))
if [[ -z ${TQ_UNDER_TIMEOUT:-} ]]; then
  rc=0
  TQ_UNDER_TIMEOUT=1 timeout --kill-after=20 "$DEADLINE" "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: tag-quality test didn't finish in $DEADLINE s" >&2
  exit "$rc"
fi

echo "== Cost per tag"
timeout 120 "$JAVA" -cp "$JAR" "$HERE/Bench.java" 2>&1 | grep -E "TagQuality|Exception|Error" || echo "bench failed"

started_robot=0
cleanup() {
  "$ROOT/scripts/jetson/fake-cameras.sh" stop >/dev/null 2>&1 || echo "WARNING: fake-cameras.sh stop failed; run it by hand" >&2
  if [[ $started_robot == 1 ]]; then touch /tmp/fake-robot-stop; wait "$robot_pid" 2>/dev/null; fi
}
trap cleanup EXIT

if ! pgrep -f FakeRobot.java >/dev/null; then
  "$ROOT/tests/fake-robot/run.sh" "disabled:$((SECS + 240))" >/tmp/tag-quality-robot.log 2>&1 &
  robot_pid=$!
  started_robot=1
fi
echo "== Fake cameras"
"$ROOT/scripts/jetson/fake-cameras.sh" start || exit 1
# Wait for the fake cameras' results on NetworkTables (PhotonVision restarted onto them).
sleep 20
echo "== Probe ($SECS s)"
"$JAVA" -cp "$JAR" "$HERE/Probe.java" "$SECS"
