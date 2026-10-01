#!/usr/bin/env bash
# Bench test for the Jetson setting its clock from the robot's (patch 08), without a robot.
# Run ON THE JETSON. Before running: Settings > Networking > "Team Number/NetworkTables Server
# Address" = 127.0.0.1, Save. Afterwards: set it back to 8515, Save.
#
# A fake robot (FakeRobotClock.java, an NT server here) publishes /photonvision/clock/unixMs
# OFFSET seconds fast for 40 s, then the correct time for 40 s. Expected: PhotonVision moves the
# clock forward by OFFSET, then (after its 30 s limit) back.
# Usage: tests/robot-clock/run.sh [offset_s]   (default 120)
set -euo pipefail
OFFSET=${1:-120}
HERE=$(cd "$(dirname "$0")" && pwd)
JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-arm64/bin/java}
P=$(systemctl show photonvision -p MainPID --value)
"$JAVA" -cp /opt/photonvision/photonvision.jar "$HERE/FakeRobotClock.java" "$OFFSET" 40 2>&1 \
  | grep -v "^\[" | sed 's/^/  fake robot: /' &
fake=$!
for i in $(seq 1 44); do
  sleep 2
  printf "\r  Jetson clock now %s UTC " "$(date -u +%T)"
done
wait $fake || true
echo
echo "== PhotonVision's log"
journalctl _PID="$P" --no-pager -o cat | grep "Clock set from the robot" | tail -4 | sed 's/^/  /' \
  || echo "  (no 'Clock set' lines: was the NT server address set to 127.0.0.1?)"
echo "== timesyncd's clock file (next boot starts from here)"
echo "  $(stat -c '%y' /var/lib/systemd/timesync/clock)"
echo
echo "Now set the NT server address back to 8515 in Settings and Save."
