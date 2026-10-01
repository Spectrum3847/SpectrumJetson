#!/usr/bin/env bash
# Bench check for the Jetson telemetry (patch 16) and camera mount estimate (patch 17), without a
# robot. Run ON THE JETSON. Before running: Settings > Networking > "Team Number/NetworkTables
# Server Address" = 127.0.0.1, Save. Afterwards: set it back to 8515, Save.
#
# A fake robot (NtTelemetryDump.java, an NT server here) prints every value PhotonVision publishes
# under /photonvision/jetson and each camera's /health and /mount tables. For the mount estimate,
# keep 2+ tags in view of a camera in a 3D AprilTag pipeline.
# Usage: tests/jetson-telemetry/run.sh [seconds]   (default 6)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-arm64/bin/java}
"$JAVA" -cp /opt/photonvision/photonvision.jar "$HERE/NtTelemetryDump.java" "${1:-6}" 2>&1 | grep -v "^\["
echo
echo "Now set the NT server address back to 8515 in Settings and Save."
