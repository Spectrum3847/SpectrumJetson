#!/usr/bin/env bash
# Bench check for the Jetson telemetry (patch 16) and camera mount estimate (patch 17), without a
# robot. Run ON THE JETSON, off the robot. No PhotonVision setting changes: the loopback interface
# answers as the robot (tests/lib/bench.sh) for the length of the test.
#
# A fake robot (NtTelemetryDump.java, an NT server here) prints every value PhotonVision publishes
# under /photonvision/jetson and each camera's /health and /mount tables. For the mount estimate,
# keep 2+ tags in view of a camera in a 3D AprilTag pipeline.
# Usage: tests/jetson-telemetry/run.sh [seconds]   (default 6). Exits 1 if PhotonVision never
# connected or published nothing under /photonvision/jetson.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
JAVA=/usr/lib/jvm/java-17-openjdk-arm64/bin/java
source "$ROOT/tests/lib/bench.sh"
robot_address_add
trap robot_address_del EXIT
out=$(timeout --kill-after=10 $(( ${1:-6} + 60 )) "$JAVA" -cp /opt/photonvision/photonvision.jar "$HERE/NtTelemetryDump.java" "${1:-6}" 2>&1 | grep -v "^\[")
echo "$out"
grep -q "/photonvision/jetson/" <<<"$out" || { echo "FAIL: nothing under /photonvision/jetson (did PhotonVision connect?)"; exit 1; }
