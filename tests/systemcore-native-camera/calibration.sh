#!/usr/bin/env bash
# EXTRA_CMD for nativecam.sh: a real calibration entry/exit through PhotonVision's API, as the UI does it:
# the websocket message startPnpCalibration (msgpack on /websocket_data), CALIB_S s in calibration, then
# POST /api/calibration/cancel. PV's video fds and journal lines at each step.
#   EXTRA_CMD="bash calibration.sh UNIQUE_NAME [VIDEO_MODE_INDEX]"   (unique name: pvdb.py show)
set -uo pipefail
UNIQ=${1:?camera unique name}
MODE=${2:-0}
CALIB_S=${CALIB_S:-5}
fds() { sudo ls -l "/proc/$(systemctl show -p MainPID --value photonvision)/fd" 2>/dev/null | grep -c video; }
sleep 1
echo "before: $(fds) video fds"
python3 - "$UNIQ" "$MODE" <<'PY'
import base64, os, socket, struct, sys

def pack(o):  # the msgpack subset this message needs
    if o is True: return b"\xc3"
    if o is False: return b"\xc2"
    if isinstance(o, int): return bytes([o]) if 0 <= o < 128 else b"\xd2" + struct.pack(">i", o)
    if isinstance(o, float): return b"\xcb" + struct.pack(">d", o)
    if isinstance(o, str):
        b = o.encode()
        return (bytes([0xA0 | len(b)]) if len(b) < 32 else b"\xd9" + bytes([len(b)])) + b
    if isinstance(o, dict):
        return bytes([0x80 | len(o)]) + b"".join(pack(k) + pack(v) for k, v in o.items())
    raise TypeError(o)

msg = {"startPnpCalibration": {"count": 12, "videoModeIndex": int(sys.argv[2]), "squareSizeMeters": 0.0254,
                               "markerSizeMeters": 0.019, "patternWidth": 8, "patternHeight": 8, "boardType": 1,
                               "useOldPattern": False, "tagFamily": 0, "autoCalibrate": False},
       "cameraUniqueName": sys.argv[1]}
s = socket.create_connection(("127.0.0.1", 5880), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /websocket_data HTTP/1.1\r\nHost: 127.0.0.1:5880\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
resp = s.recv(4096)
print("websocket:", resp.split(b"\r\n")[0].decode())
payload = pack(msg)
mask = os.urandom(4)
n = len(payload)
head = b"\x82" + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
print(f"sent startPnpCalibration ({n} bytes msgpack)")
# read what PV sends for 1 s, then close (PV streams UI data continuously: never wait for it to stop)
import time
s.settimeout(0.2)
end = time.time() + 1
while time.time() < end:
    try:
        if not s.recv(65536):
            break
    except OSError:
        pass
s.close()
PY
sleep "$CALIB_S"
echo "in calibration: $(fds) video fds"
python3 - "$UNIQ" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:5880/api/calibration/cancel",
                             data=json.dumps({"cameraUniqueName": sys.argv[1]}).encode(),
                             headers={"Content-Type": "application/json"})
try:
    print("cancel:", urllib.request.urlopen(req, timeout=5).read().decode())
except Exception as e:
    print("cancel:", e)
PY
sleep 4
echo "after: $(fds) video fds"
