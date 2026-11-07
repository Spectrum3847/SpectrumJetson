#!/usr/bin/env python3
"""Software camera-reset recovery timing on the SystemCore / Pi 5 (run as root, holding /tmp/camera.lock).

  reset_timing.py CAM METHOD REPS [--pv]
    CAM     thrifty (Thriftiest SJ-05) or swyft (Swyft SJ-SW01)
    METHOD  reopen    close and re-open the V4L2 device (without --pv only: PhotonVision owns the device)
            usbreset  USBDEVFS_RESET on /dev/bus/usb/BBB/DDD
            rebind    uvcvideo unbind/bind of the camera's control interface (X:1.0)
            authorize /sys/bus/usb/devices/X/authorized 0 -> 1
            yank      authorized 0, held YANK_S (3) s like an unplugged cable, then 1; times from the 1
    --pv    PhotonVision runs natively: first frame / first tag come from its NT results (rawBytes)
            instead of a v4l2-ctl capture here.

Per repeat it prints one JSON line: node_gone (did the by-id node disappear), t_node (s from the reset to the
node being back), t_frame (first valid MJPEG frame / first PhotonVision result after the outage), t_tag (first
frame with an AprilTag 36h11 / first result with a target), and the controls before and after (exposure, gain,
gamma, brightness, contrast, sharpness, backlight). It never re-applies controls itself; the caller compares.
With --pv also fps_after and lat_p50_after / lat_p99_after (ms, capture -> publish from the results themselves) over
the last 2 s of the TIMEOUT window, the steady state the camera came back to.
No vendor or firmware requests are sent: only the generic USB and sysfs resets above.
"""
import fcntl, json, os, subprocess, sys, time

DEV = {"thrifty": "/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0",
       "swyft": "/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0"}
CTRLS = "exposure_time_absolute,gain,gamma,brightness,contrast,sharpness,backlight_compensation"
USBDEVFS_RESET = 0x5514
TIMEOUT = float(os.environ.get("RESET_TIMEOUT_S", "15"))
YANK_S = float(os.environ.get("YANK_S", "3"))


def usb_dir(node):
    video = os.path.basename(os.path.realpath(node))
    intf = os.path.realpath(f"/sys/class/video4linux/{video}/device")  # .../3-1/3-1:1.0
    return os.path.dirname(intf), os.path.basename(intf)


def controls(node):
    r = subprocess.run(["v4l2-ctl", "-d", node, "-C", CTRLS], capture_output=True, text=True, timeout=5)
    out = {}
    for line in r.stdout.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def do_reset(method, udev, intf):
    if method == "usbreset":
        bus = int(open(f"{udev}/busnum").read()); dev = int(open(f"{udev}/devnum").read())
        fd = os.open(f"/dev/bus/usb/{bus:03d}/{dev:03d}", os.O_WRONLY)
        try:
            fcntl.ioctl(fd, USBDEVFS_RESET, 0)
        finally:
            os.close(fd)
    elif method == "rebind":
        open("/sys/bus/usb/drivers/uvcvideo/unbind", "w").write(intf)
        time.sleep(0.05)
        open("/sys/bus/usb/drivers/uvcvideo/bind", "w").write(intf)
    elif method == "authorize":
        open(f"{udev}/authorized", "w").write("0")
        time.sleep(0.05)
        open(f"{udev}/authorized", "w").write("1")
    elif method == "yank":
        open(f"{udev}/authorized", "w").write("0")
        time.sleep(YANK_S)
        t = time.monotonic()
        open(f"{udev}/authorized", "w").write("1")
        return t
    return None


def wait_node(node, t0):
    gone = False
    while time.monotonic() - t0 < 1.0:  # the node, if it goes, goes within a second
        if not os.path.exists(node):
            gone = True
            break
        time.sleep(0.001)
    while not os.path.exists(node):
        if time.monotonic() - t0 > TIMEOUT:
            return gone, None
        time.sleep(0.001)
    return gone, time.monotonic() - t0


def capture(node, t0, frames=240):
    """v4l2-ctl capture at 1280x800 MJPEG 120 fps; time of the first dequeued buffer, and the first tag by index."""
    out = "/dev/shm/reset_timing.mjpeg"
    t_first = None
    deadline = t0 + TIMEOUT
    while t_first is None and time.monotonic() < deadline:
        p = subprocess.Popen(["v4l2-ctl", "-d", node, "--set-fmt-video=width=1280,height=800,pixelformat=MJPG",
                              "--set-parm=120", "--stream-mmap=4", f"--stream-count={frames}", f"--stream-to={out}"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        while True:
            c = p.stderr.read(1)  # v4l2-ctl prints a "<" per buffer on stderr
            if not c:
                break
            if c == b"<" and t_first is None:
                t_first = time.monotonic() - t0
        p.wait()
        if t_first is None:
            time.sleep(0.02)
    if t_first is None:
        return None, None
    import cv2, numpy as np
    det = cv2.aruco.ArucoDetector(cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11),
                                  cv2.aruco.DetectorParameters())
    data = open(out, "rb").read(); i = 0; k = 0
    while True:
        a = data.find(b"\xff\xd8", i); b = data.find(b"\xff\xd9", a + 2)
        if a < 0 or b < 0:
            return t_first, None
        i = b + 2
        img = cv2.imdecode(np.frombuffer(data[a:b + 2], np.uint8), cv2.IMREAD_GRAYSCALE)
        if img is not None and img.shape == (800, 1280):
            if det.detectMarkers(img)[1] is not None:
                return t_first, t_first + k / 120.0
        k += 1


def pv_watch(cam, t0):
    """First PhotonVision result after the outage (a gap of >= 50 ms in rawBytes), and its first with a target."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "exposure-sweep"))
    sys.path.insert(0, os.path.expanduser("~systemcore/bench/exposure"))
    from expo_probe import WS, mp_unpack, decode_result
    ws = WS("127.0.0.1", 5810, "/nt/reset_timing")
    ws.send(json.dumps([{"method": "subscribe", "params": {"topics": [f"/photonvision/{cam}/rawBytes"], "subuid": 1,
                                                           "options": {"all": True, "periodic": 0.001}}}]))
    ws.k.settimeout(0.05)
    return ws, mp_unpack, decode_result


def pv_times(ws, mp_unpack, decode_result, t0):
    """Every rawBytes arrival from t0 on; the outage is the longest gap between results with new capture times.
    Returns (outage s, t_frame, t_tag, fps over the last 2 s, results with tags fraction over the last 2 s,
    latency p50 and p99 over the last 2 s in ms)."""
    ids = {}; rows = []; last_cap = None
    while time.monotonic() - t0 < TIMEOUT:
        try:
            op, m = ws.recv()
        except (TimeoutError, OSError):
            continue
        if op == 1:
            for a in json.loads(m):
                if a.get("method") == "announce":
                    ids[a["params"]["id"]] = a["params"]["name"]
            continue
        now = time.monotonic() - t0; i = 0
        while i < len(m):
            arr, i = mp_unpack(m, i)
            if not ids.get(arr[0], "").endswith("/rawBytes"):
                continue
            _, cap, tg = decode_result(arr[3])
            pub = int.from_bytes(arr[3][16:24], "little", signed=True)
            if last_cap is not None and cap <= last_cap:
                continue  # a repeat, not a new frame
            last_cap = cap
            rows.append((now, len(tg), (pub - cap) / 1e6))  # ns -> ms
    rows = [r for r in rows if r[0] >= 0]
    if len(rows) < 2:
        return None, None, None, 0.0, 0.0, None, None
    prev = [0.0] + [r[0] for r in rows[:-1]]
    gap, k = max((rows[j][0] - prev[j], j) for j in range(len(rows)))
    t_frame = rows[k][0]
    t_tag = next((r[0] for r in rows[k:] if r[1]), None)
    tail = [r for r in rows if r[0] >= TIMEOUT - 2.0]
    lat = sorted(r[2] for r in tail)
    pct = (lambda q: round(lat[min(len(lat) - 1, int(q * len(lat)))], 2)) if lat else (lambda q: None)
    return gap, t_frame, t_tag, len(tail) / 2.0, sum(1 for r in tail if r[1]) / max(len(tail), 1), pct(.5), pct(.99)


def main():
    cam, method, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
    pv = "--pv" in sys.argv
    node = DEV[cam]
    for rep in range(reps):
        udev, intf = usb_dir(node)
        before = controls(node)
        ws = None
        if pv:
            ws, mp_unpack, decode_result = pv_watch(cam, time.monotonic())
            time.sleep(0.5)  # announces and a few results first
        t0 = time.monotonic()
        if method != "reopen":
            t0 = do_reset(method, udev, intf) or t0
        gone, t_node = (False, 0.0) if method == "reopen" else wait_node(node, t0)
        row = {"cam": cam, "method": method, "pv": pv, "rep": rep, "node_gone": gone, "t_node": t_node}
        if t_node is not None:
            time.sleep(0.2)  # udev permissions / PhotonVision's own re-open
            row["after_node"] = controls(node)
        if pv:
            outage, t_frame, t_tag, fps, tagged, p50, p99 = pv_times(ws, mp_unpack, decode_result, t0)
            ws.k.close()
            row.update(outage=outage, t_frame=t_frame, t_tag=t_tag, fps_after=fps, tagged_after=tagged,
                       lat_p50_after=p50, lat_p99_after=p99)
        elif t_node is not None:
            row["t_frame"], row["t_tag"] = capture(node, t0)
        row["before"] = before
        row["after"] = controls(node) if os.path.exists(node) else None
        print(json.dumps(row), flush=True)
        time.sleep(2.0 if pv else 0.5)


if __name__ == "__main__":
    main()
