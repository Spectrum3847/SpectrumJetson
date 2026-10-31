#!/usr/bin/env bash
# One camera's USB link glitches, the way TXMAN1 Q13's orin-left did ("usb 1-2-port1: disabled by
# hub (EMI?), re-enabling..."), and does it come back by itself, and how fast? Unlike
# tests/usb-hub-reset (every camera on the hub at once), this hits one port and leaves the others.
# Run ON THE JETSON with PhotonVision running (sudo -n for the USB requests; PhotonVision's USB
# bandwidth API at localhost:5800 says which cameras stream).
#
# Usage: tests/usb-port-glitch/run.sh PORT [KIND] [WAIT]
#   PORT: the camera's port, e.g. 1-2.1 (or 2.1)
#   KIND: disable  ClearPortFeature(PORT_ENABLE) on the hub port: the port is switched off as the
#                  hub does on a signal error, and the kernel finds it and re-enables it (default)
#         reset    a port reset of the camera (USBDEVFS_RESET), as the kernel and PhotonVision's
#                  watchdog do
#         remove   the kernel forgets the camera (sysfs remove): it's gone from USB until something
#                  makes the hub enumerate the port again (PhotonVision's port power toggle)
#   WAIT: seconds to wait for it to stream again (default 60)
# Exit 0 if the camera streams again by itself within WAIT.
set -uo pipefail
port=${1:?usage: $0 PORT [disable|reset|remove] [WAIT]}
[[ $port == *-* ]] || port=1-$port
sudo -n python3 - "$port" "${2:-disable}" "${3:-60}" <<'PY'
import fcntl, json, os, re, struct, subprocess, sys, time, urllib.request, ctypes

port, kind, wait = sys.argv[1], sys.argv[2], float(sys.argv[3])
hub, hubport = port.rsplit(".", 1)
dev = f"/sys/bus/usb/devices/{port}"

def survey():
    try:
        with urllib.request.urlopen("http://localhost:5800/api/usb/bandwidth", timeout=2) as r:
            return {c["port"]: c for c in json.load(r).get("cameras", [])}
    except Exception:
        return {}

def node(sysdev):
    bus, num = (int(open(f"{sysdev}/{f}").read()) for f in ("busnum", "devnum"))
    return f"/dev/bus/usb/{bus:03d}/{num:03d}"

USBDEVFS_RESET = 0x5514                      # _IO('U', 20)
USBDEVFS_CONTROL = 0xC0185500                # _IOWR('U', 0, struct usbdevfs_ctrltransfer), 64-bit

def hub_request(req_type, req, value, index):
    """A control request to the hub itself (ep0), e.g. ClearPortFeature."""
    fd = os.open(node(f"/sys/bus/usb/devices/{hub}"), os.O_RDWR)
    try:
        ctl = struct.pack("=BBHHHI4xQ", req_type, req, value, index, 0, 1000, 0)
        fcntl.ioctl(fd, USBDEVFS_CONTROL, bytearray(ctl))
    finally:
        os.close(fd)

survey(); time.sleep(1.5)  # two looks, so the fps numbers are fresh
before = survey().get(port)
if not before or not before["streaming"]:
    sys.exit(f"no camera streaming on {port}")
name = before["camera"] or before["product"]
print(f"Before: {name} on {port} streaming at {before['fps'] or 0:.0f} fps; "
      f"firmware {open(dev + '/bcdDevice').read().strip()}")

t0 = time.time()
if kind == "disable":
    print(f"ClearPortFeature(PORT_ENABLE) on hub {hub} port {hubport}")
    hub_request(0x23, 1, 1, int(hubport))   # CLEAR_FEATURE, PORT_ENABLE (1), port
elif kind == "remove":
    print(f"sysfs remove of {port}")
    open(dev + "/remove", "w").write("1")
elif kind == "reset":
    print(f"USBDEVFS_RESET on {port}")
    fd = os.open(node(dev), os.O_WRONLY)
    try:
        fcntl.ioctl(fd, USBDEVFS_RESET, 0)
    except OSError as e:
        print(f"  reset returned {e}")
    finally:
        os.close(fd)
else:
    sys.exit(f"unknown kind {kind}")

gone = back = None
while time.time() < t0 + wait:
    c = survey().get(port)
    if gone is None and not (c and c["streaming"]):
        gone = time.time()
    if gone is not None and c and c["streaming"]:
        back = time.time()
        break
    time.sleep(0.2)
time.sleep(3)

def journal(args):
    out = subprocess.run(["journalctl", "--no-pager", "-o", "short-unix", "--since", f"@{int(t0) - 1}"] + args,
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"(\d+\.\d+) \S+ ([^:]+): (.*)", line)
        if m:
            yield float(m.group(1)), m.group(3)

print(f"\n== {name} ({port}), seconds after the {kind}")
if gone is None:
    print("  never stopped streaming (the glitch didn't take it down)")
elif back:
    c = survey().get(port) or {}
    print(f"  {gone - t0:5.1f} s  stopped streaming")
    print(f"  {back - t0:5.1f} s  streaming again by itself, {c.get('fps') or 0:.0f} fps")
else:
    print(f"  {gone - t0:5.1f} s  stopped streaming")
    print(f"  never   streaming again within {wait:g} s"
          + ("" if os.path.exists(dev + "/idVendor") else f"; not on USB ({port} empty): stuck"))
short = port.split("-", 1)[1]
for t, m in journal(["-k"]):
    if t >= t0 - 0.5 and (port + ":" in m or port + " " in m or f"{hub}-port{hubport}" in m) \
            and "capping max payload" not in m:
        print(f"  {t - t0:5.1f} s  kernel: {m[:140]}")
for t, m in journal(["-u", "photonvision"]):
    clean = re.sub(r"\x1b\[[0-9;]*m", "", m)
    # The recovery's steps (photonvision-84, -88, -89): the reset or power toggle, cscore setting
    # the format on the reopened camera, and the first usable frame in PhotonVision ("delivering
    # frames again": "streaming again" above is only the camera's USB bandwidth reserved again).
    if t >= t0 and (name in clean or short in clean) \
            and re.search(r"ERROR|Resetting|Connected|set format|delivering frames again|working again"
                          r"|Restart", clean) \
            and "timed out getting frame" not in clean and "DEBUG" not in clean:
        print(f"  {t - t0:5.1f} s  PV: {clean[:140]}")
print("\nPASS: came back by itself" if back or gone is None else "\nFAIL: didn't come back")
sys.exit(0 if back or gone is None else 1)
PY
