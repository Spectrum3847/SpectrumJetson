#!/usr/bin/env bash
# USB hub reset test: every camera on one hub drops at once and comes back, as when a static shock
# resets the Jetson's internal USB-A hub. Does PhotonVision recover every camera by itself, and how
# fast? Run ON THE JETSON with the cameras running (sudo -n resets the hub; PhotonVision's
# USB bandwidth API at localhost:5800 says which cameras stream).
# Usage: tests/usb-hub-reset/run.sh [hub] [seconds_down] [cameras_expected]
#   hub: 1-2 = the four USB-A ports (default), 1-1 = a hub in the USB-C port
#   seconds_down: how long the hub stays off (default 2)
set -uo pipefail
rc=0
python3 - "$@" <<'PY' || rc=$?
import json, re, subprocess, sys, time, urllib.request

hub = sys.argv[1] if len(sys.argv) > 1 else "1-2"
down = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
auth = f"/sys/bus/usb/devices/{hub}/authorized"
pid = subprocess.run(["systemctl", "show", "photonvision", "-p", "MainPID", "--value"],
                     capture_output=True, text=True).stdout.strip()
if pid in ("", "0"):
    sys.exit("photonvision is not running")

def survey():
    try:
        with urllib.request.urlopen("http://localhost:5800/api/usb/bandwidth", timeout=2) as r:
            return json.load(r)
    except Exception:
        return None

def on_hub(s):
    return {c["port"]: c for c in (s or {}).get("cameras", []) if c["port"].startswith(hub + ".")}

def set_auth(v):
    subprocess.run(["sudo", "-n", "tee", auth], input=v, text=True, stdout=subprocess.DEVNULL, check=True)

survey(); time.sleep(1.5)  # two looks, so the fps numbers are fresh
before = {p: c for p, c in on_hub(survey()).items() if c["streaming"]}
if not before:
    sys.exit(f"no cameras streaming on hub {hub}")
names = {p: c["camera"] or c["product"] for p, c in before.items()}
print(f"Before: {len(before)} cameras streaming on hub {hub}: "
      + ", ".join(f"{names[p]} ({p}, {c['fps'] or 0:.0f} fps)" for p, c in sorted(before.items())))

t0 = time.time()
print(f"Resetting hub {hub}: off for {down:g} s")
# The hub is switched back on whatever happens (Ctrl-C, a timeout): left off, its cameras stay gone.
try:
    set_auth("0")
    time.sleep(down)
finally:
    t_on = time.time()
    set_auth("1")

back = {}
deadline = t_on + 60
while time.time() < deadline and len(back) < len(before):
    for p, c in on_hub(survey()).items():
        if p in before and p not in back and c["streaming"]:
            back[p] = time.time()
    time.sleep(0.25)
time.sleep(4)  # let the detectors settle, then read the log

def journal(args):
    out = subprocess.run(["journalctl", "--no-pager", "-o", "short-unix", "--since", f"@{int(t0) - 1}"] + args,
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"(\d+\.\d+) \S+ ([^:]+): (.*)", line)
        if m:
            yield float(m.group(1)), m.group(3)

pv = list(journal([f"_PID={pid}"]))
stats = [(t, re.match(r"(?:971|detector) stats (h\d+)", m).group(1)) for t, m in pv if m.startswith(("971 stats", "detector stats"))]
handles_before = {h for t, h in stats if t < t0}
det_back = None
for t in sorted({round(t * 2) / 2 for t, _ in stats if t > t_on}):
    if len({h for tt, h in stats if t - 1.5 <= tt <= t}) >= len(handles_before):
        det_back = t
        break
after = on_hub(survey())

print("\n== After the hub came back (seconds after it was switched on)")
for p in sorted(before):
    fps = after.get(p, {}).get("fps")
    when = f"{back[p] - t_on:5.1f} s" if p in back else "  never"
    print(f"  {when}  {names[p]} ({p}) streaming again" + (f", now {fps:.0f} fps" if fps else ""))
if det_back:
    print(f"  {det_back - t_on:5.1f} s  all {len(handles_before)} AprilTag detectors reporting again")
else:
    print(f"  never   AprilTag detectors: not all {len(handles_before)} reporting again")
for t, m in pv:
    if t > t0 and re.search(r"USB level|reconnect|no usable frames|bandwidth|Camera connected|lost", m, re.I) \
            and "DEBUG" not in m:
        clean = re.sub(r"\x1b\[[0-9;]*m", "", m)
        print(f"  {t - t_on:5.1f} s  PV: {clean[:150]}")
kern = [(t, m) for t, m in journal(["-k"]) if t > t0 and re.search(r"error|fail|not enough|unable", m, re.I)]
for t, m in kern[:10]:
    print(f"  {t - t_on:5.1f} s  kernel: {m[:150]}")
ok = len(back) == len(before) and det_back is not None
print("\nPASS: every camera recovered by itself" if ok else "\nFAIL: not every camera came back")
sys.exit(0 if ok else 1)
PY
# What the health check says now: the JPEG decoder still on NVJPG with 0 differ, every camera back
# in the mode PhotonVision set (patch 27's race), and no camera stuck sending invalid JPEGs.
echo
~/SpectrumJetson/scripts/jetson/health-check.sh "${3:-2}" | grep -E "JPEG|streaming|invalid|detect|FAIL|WARN" | grep -v "Wi-Fi\|robot"
exit $rc
