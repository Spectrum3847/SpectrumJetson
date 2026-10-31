#!/usr/bin/env bash
# Camera unplug/replug test: does PhotonVision recover on its own when a camera's USB plug is
# pulled and put back, and how fast? Run ON THE JETSON (no sudo) with the cameras running.
# Follow the prompts: unplug one camera, wait, plug it back into the SAME port.
# Usage: tests/camera-replug/run.sh [seconds_unplugged]   (default 5)
set -euo pipefail
AWAY=${1:-5}
P=$(systemctl show photonvision -p MainPID --value)
[[ $P != 0 ]] || { echo "photonvision is not running" >&2; exit 1; }
t0=$(date +%s.%N)

countdown() { for ((i = $1; i > 0; i--)); do printf "\r  %s in %2d s " "$2" "$i"; sleep 1; done; printf "\r%-40s\n" "  $2 NOW"; }
echo "Detection before: $(journalctl _PID="$P" --no-pager -o cat --since "-2 s" | grep -cE '^(971|detector) stats') stats lines in 2 s"
countdown 5 "UNPLUG one camera"
sleep "$AWAY"
countdown 1 "PLUG IT BACK IN (same port)"
echo "  watching for 30 s..."
sleep 30

python3 - "$t0" "$P" <<'PY'
import re, subprocess, sys
t0, pid = float(sys.argv[1]), sys.argv[2]
since = f"@{int(t0)}"
def log(args):
    out = subprocess.run(["journalctl", "--no-pager", "-o", "short-unix", "--since", since] + args,
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"(\d+\.\d+) \S+ ([^:]+): (.*)", line)
        if m:
            yield float(m.group(1)), m.group(3)

kern = list(log(["-k"]))
unplug = next((t for t, msg in kern if "USB disconnect" in msg), None)
# This kernel logs "new high-speed USB device number N" (not always "New USB device found").
replug = next((t for t, msg in kern if unplug and t > unplug
               and re.search(r"new \S+-speed USB device|New USB device found", msg)), None)
pv = list(log([f"_PID={pid}"]))
stats = [(t, re.match(r"(?:971|detector) stats (h\d+)", m).group(1)) for t, m in pv if m.startswith(("971 stats", "detector stats"))]

def rel(t):
    return f"{t - t0:6.1f} s" if t else "   never"

print("\n== Timeline (seconds from the start of the test)")
print(f"  {rel(unplug)}  USB: camera unplugged")
print(f"  {rel(replug)}  USB: camera plugged back in")
if unplug:
    before = {h for t, h in stats if t < unplug}
    # A camera's detector stops reporting when it's unplugged.
    gone = set()
    for h in before:
        last = max(t for t, x in stats if x == h and t < unplug + 3)
        if not any(x == h and last < t < last + 2.5 for t, x in stats):
            gone.add(h)
    back = None
    if replug:
        # Recovered: as many detectors reporting as before the unplug.
        n = len(before)
        for t in sorted({round(t) for t, _ in stats if t > replug}):
            active = {h for tt, h in stats if t - 1.5 <= tt <= t + 0.5}
            if len(active) >= n:
                back = t
                break
    print(f"  {rel(back)}  PhotonVision: all {len(before)} cameras detecting again")
    if replug and back:
        print(f"\n  Detection back {back - replug:.1f} s after the plug went back in "
              f"({back - unplug:.1f} s without that camera in total).")
    elif replug:
        print("\n  FAIL: detection did not come back within 30 s of re-plugging.")
for t, m in pv:
    if re.search(r"setparams handle .*dist coeffs|[Dd]isconnect|reconnect|Camera .* connected|lost", m):
        print(f"  {rel(t)}  PV: {m[:140]}")
PY
echo
~/SpectrumJetson/scripts/jetson/health-check.sh | sed -n '/== CUDA detector/,/== Robot connection/p' | grep -v "== Robot"
