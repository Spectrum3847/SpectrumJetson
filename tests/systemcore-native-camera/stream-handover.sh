#!/usr/bin/env bash
# EXTRA_CMD for nativecam.sh: stream on demand, then the cscore handover (as calibration does) and back.
#   1 s in: reads PhotonVision's input (1181) and output (1182) MJPEG streams for 3 s each (bytes, frames)
#   then /tmp/spectrum-native-handover-test for 4 s (native capture closed, a temporary UsbCamera streams), then
#   removed (native reopened); PV's video fds at each step.
set -uo pipefail
fds() { sudo ls -l "/proc/$(systemctl show -p MainPID --value photonvision)/fd" 2>/dev/null | grep -c video; }
stream() {
  python3 - "$1" <<'PY'
import sys, time, urllib.request
try:
    r = urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/stream.mjpg", timeout=3)
    t, data = time.time(), b""
    while time.time() - t < 3:
        data += r.read(4096)
    print(f"port {sys.argv[1]}: {len(data)} bytes, {data.count(bytes([0xFF, 0xD8, 0xFF]))} JPEG frames in 3 s")
except Exception as e:
    print(f"port {sys.argv[1]}: {e}")
PY
}
sleep 1
echo "before: $(fds) video fds"
stream 1181
stream 1182
touch /tmp/spectrum-native-handover-test
sleep 4
echo "during handover: $(fds) video fds"
rm -f /tmp/spectrum-native-handover-test
sleep 3
echo "after: $(fds) video fds"
