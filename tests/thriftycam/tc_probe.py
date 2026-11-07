#!/usr/bin/env python3
"""ThriftyCam (05c8:0a00) bench probe: control effects, exposure mapping, exposure/gain sweep.
   tc_probe.py MODE WxH   MODE = effects | mapping | sweep | grab
Detection with OpenCV aruco AprilTag 36h11. 'margin' here is a contrast proxy: (mean of white border ring
- mean of black border) on the decoded grayscale tag, in DN; jitter = sd of corner coordinates (px)."""
import json, os, subprocess, sys, time
import cv2, numpy as np

DEV = "/dev/v4l/by-id/usb-DCX-240524--XH_SPCA2630_PC_Camera-video-index0"


def ctl(**kw):
    subprocess.run(["v4l2-ctl", "-d", DEV, "-c", ",".join(f"{k}={v}" for k, v in kw.items())], check=False)


def open_cam(w, h):
    cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*os.environ.get("FMT", "MJPG")))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, w); cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
    cap.set(cv2.CAP_PROP_FPS, 60); cap.set(cv2.CAP_PROP_CONVERT_RGB, 0 if os.environ.get("FMT", "MJPG") == "MJPG" else 1); cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
    return cap


DET = cv2.aruco.ArucoDetector(cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11),
                              cv2.aruco.DetectorParameters())


def grab(cap, n, settle=0.6):
    t_end = time.time() + settle
    while time.time() < t_end: cap.grab()
    out = []; t0 = time.time()
    for _ in range(n):
        ok, buf = cap.read()
        if not ok: continue
        raw = buf.tobytes() if buf.ndim == 1 or buf.shape[0] == 1 else None
        img = cv2.imdecode(buf, cv2.IMREAD_GRAYSCALE) if raw is not None else cv2.cvtColor(buf, cv2.COLOR_BGR2GRAY)
        out.append((len(raw) if raw else 0, img))
    return out, time.time() - t0


def margin(img, c):
    # warp tag to 10x10 cells (8 data + 1 black border + 1 white outer ring for 36h11: 6 data + 2 border..)
    s = 100; dst = np.float32([[s, s], [9 * s, s], [9 * s, 9 * s], [s, 9 * s]])  # black square = cells 1..9 of 10
    M = cv2.getPerspectiveTransform(np.float32(c), dst)
    wimg = cv2.warpPerspective(img, M, (10 * s, 10 * s)).astype(float)
    k = s // 4
    black = np.concatenate([wimg[s + k:2 * s - k, s + k:9 * s - k].ravel(), wimg[8 * s + k:9 * s - k, s + k:9 * s - k].ravel()])
    white = np.concatenate([wimg[k:s - k, k:10 * s - k].ravel(), wimg[9 * s + k:10 * s - k, k:10 * s - k].ravel()])
    return float(white.mean() - black.mean()), float(white.mean())


def analyze(frames, dt):
    per = {}; nb = []; means = []
    for b, img in frames:
        nb.append(b); means.append(float(img.mean()))
        corners, ids, _ = DET.detectMarkers(img)
        if ids is None: continue
        for c, i in zip(corners, ids.ravel()):
            m, wm = margin(img, c[0])
            per.setdefault(int(i), []).append((c[0], m, wm))
    n = len(frames)
    tags = {}
    for i, v in sorted(per.items()):
        cs = np.array([x[0] for x in v])
        tags[i] = dict(rate=round(len(v) / n, 3), margin=round(float(np.median([x[1] for x in v])), 1),
                       white=round(float(np.median([x[2] for x in v])), 1),
                       jitter=round(float(cs.std(axis=0).mean()), 3) if len(v) > 2 else None)
    return dict(frames=n, fps=round(n / dt, 1), bytes_p50=int(np.median(nb)) if nb else 0,
                mean=round(float(np.mean(means)), 1), tags=tags)


def main():
    mode, wh = sys.argv[1], sys.argv[2]
    w, h = map(int, wh.split("x"))
    cap = open_cam(w, h)
    ctl(auto_exposure=1, sharpness=0)
    if mode == "grab":
        ctl(exposure_time_absolute=int(sys.argv[3]), gain=int(sys.argv[4]))
        fr, dt = grab(cap, 120)
        a = analyze(fr, dt)
        corners, ids, _ = DET.detectMarkers(fr[-1][1])
        a["size"] = {int(i): [round(float(v), 1) for v in (c[0][:, 0].max() - c[0][:, 0].min(), c[0][:, 1].max() - c[0][:, 1].min(), c[0][:, 0].mean(), c[0][:, 1].mean())] for c, i in zip(corners, ids.ravel())} if ids is not None else {}
        print(json.dumps(dict(mode=mode, wh=wh, fmt=os.environ.get("FMT", "MJPG"), **a)))
    elif mode == "mapping":
        ctl(gain=0)
        for e in [3, 4, 5, 6, 7, 8, 10, 12, 16, 20, 30, 50, 80, 100, 166, 200]:
            ctl(exposure_time_absolute=e); fr, dt = grab(cap, 30)
            a = analyze(fr, dt); a.pop("tags")
            print(json.dumps(dict(mode=mode, exp=e, **a)), flush=True)
    elif mode == "effects":
        ctl(exposure_time_absolute=12, gain=0)
        base = analyze(*grab(cap, 20)); print(json.dumps(dict(mode=mode, ctrl="base", **base)), flush=True)
        for name, vals, dflt in [("brightness", [-64, 64], 0), ("contrast", [95], 0), ("gamma", [300], 100),
                                 ("gain", [1, 2, 3, 4], 0), ("sharpness", [50, 100], 0),
                                 ("backlight_compensation", [1], 0), ("saturation", [100], 0), ("hue", [2000], 0)]:
            for v in vals:
                ctl(**{name: v}); a = analyze(*grab(cap, 20))
                print(json.dumps(dict(mode=mode, ctrl=name, val=v, **a)), flush=True)
            ctl(**{name: dflt})
    elif mode == "sweep":
        for e, g, sh in [(3, 0, 0), (4, 0, 0), (5, 0, 0), (6, 0, 0), (8, 0, 0), (10, 0, 0), (3, 1, 0), (4, 1, 0),
                         (5, 1, 0), (5, 0, 50), (8, 0, 50), (5, 0, 100), (8, 0, 100)]:
            ctl(exposure_time_absolute=e, gain=g, sharpness=sh); a = analyze(*grab(cap, 60))
            print(json.dumps(dict(mode=mode, exp=e, gain=g, sharp=sh, **a)), flush=True)
        ctl(sharpness=0)
    cap.release()


main()
