#!/usr/bin/env bash
# EXTRA_CMD for nativecam.sh: PhotonVision's CPU with no viewer, one input-stream viewer, one output-stream viewer
# (5 s each; per-thread CPU from ~/bench/scmn/topcpu.py), and what each viewer received.
#   EXTRA_CMD="bash stream-cpu.sh [PORT_IN] [PORT_OUT]"   (defaults 1181 1182: the first camera)
set -uo pipefail
IN=${1:-1181}
OUT=${2:-1182}
view() {  # PORT SECS: read the stream, print bytes / JPEG frames
  python3 - "$1" "$2" <<'PY'
import sys, time, urllib.request
port, secs = sys.argv[1], float(sys.argv[2])
try:
    r = urllib.request.urlopen(f"http://127.0.0.1:{port}/stream.mjpg", timeout=3)
    t, n, frames, tail = time.time(), 0, 0, b""
    while time.time() - t < secs:
        d = r.read(8192)
        frames += (tail + d).count(bytes([0xFF, 0xD8, 0xFF]))
        tail, n = d[-2:], n + len(d)
    print(f"viewer {port}: {n / secs / 1e6:.2f} MB/s, {frames / secs:.1f} JPEG/s")
except Exception as e:
    print(f"viewer {port}: {e}")
PY
}
cpu() { sudo python3 "$HOME/bench/scmn/topcpu.py" "$1" 6 | sed -n 2,7p; }
echo "== no viewer"
cpu 5
echo "== input stream viewer ($IN)"
view "$IN" 6 &
sleep 0.5
cpu 5
wait
echo "== output stream viewer ($OUT)"
view "$OUT" 6 &
sleep 0.5
cpu 5
wait
