#!/usr/bin/env bash
# The FRC-Team-4143 GpuDetectorJNI build is for the 2026 jar only. It links libwpiutil's JNI
# helpers and looks up edu/wpi/first/apriltag/AprilTagDetection, which the alpha-7 jar renamed.
set -euo pipefail
echo "The 4143 detector does not load in the alpha-7 jar. Build the BOS detector with" >&2
echo "07-build-bos-detector.sh, then install it with 08-select-detector.sh bos." >&2
exit 1
