#!/usr/bin/env python3
"""Fake cameras: play Rewind recordings into v4l2loopback devices, so PhotonVision sees cameras.

Each camera folder of a Rewind session (docs/REWIND.md: NNNN.mjpeg + NNNN.csv) goes to one
v4l2loopback device as MJPEG, frame for frame at the recording's own timing, looping. PhotonVision
opens them like USB cameras, so the real path runs: cscore, our MJPEG decode, the GPU detector.
They have no camera controls (exposure, gain) and no USB bandwidth, so tests of those skip.

    fakecam.py SESSION_DIR [--devices /dev/video40,/dev/video41] [--cameras CamA,CamB] [--seconds N]

Started by scripts/jetson/fake-cameras.sh, which loads v4l2loopback first. Plain Python, no packages.
"""
import argparse
import csv
import fcntl
import os
import struct
import threading
import time

# ioctl numbers for 64-bit Linux: _IOWR('V', nr, size)
def _iowr(nr, size):
    return (3 << 30) | (size << 16) | (ord("V") << 8) | nr

V4L2_FORMAT_SIZE = 208       # u32 type + 200-byte union, 8-byte aligned
V4L2_STREAMPARM_SIZE = 204   # u32 type + 200-byte union
VIDIOC_S_FMT = _iowr(5, V4L2_FORMAT_SIZE)
VIDIOC_S_PARM = _iowr(22, V4L2_STREAMPARM_SIZE)
BUF_TYPE_VIDEO_OUTPUT = 2
FIELD_NONE = 1
COLORSPACE_JPEG = 7
MJPG = struct.unpack("<I", b"MJPG")[0]


def read_camera(folder):
    """Every frame of one camera folder: (jpeg bytes, jetson_us), in order."""
    frames = []
    for name in sorted(f for f in os.listdir(folder) if f.endswith(".csv")):
        mjpeg = os.path.join(folder, name[:-4] + ".mjpeg")
        with open(mjpeg, "rb") as mj, open(os.path.join(folder, name)) as idx:
            for row in csv.reader(l for l in idx if not l.startswith("#")):
                frame, offset, size, w, h, jetson_us = (int(x) for x in row[:6])
                mj.seek(offset)
                frames.append((mj.read(size), jetson_us, w, h))
    if not frames:
        raise SystemExit(f"{folder}: no frames")
    return frames


def setup(fd, width, height, fps, max_size):
    fmt = bytearray(V4L2_FORMAT_SIZE)
    struct.pack_into("<I", fmt, 0, BUF_TYPE_VIDEO_OUTPUT)
    # struct v4l2_pix_format at offset 8 (the union is 8-byte aligned)
    struct.pack_into("<IIIIIIII", fmt, 8, width, height, MJPG, FIELD_NONE, 0, max_size, COLORSPACE_JPEG, 0)
    # Right after v4l2loopback loads, a device can refuse the format (EINVAL) for a moment while
    # something else probes it (udev, PhotonVision's camera scan); retry for up to 5 s.
    for attempt in range(25):
        try:
            fcntl.ioctl(fd, VIDIOC_S_FMT, fmt)
            break
        except OSError as e:
            if attempt == 24:
                raise
            if attempt in (0, 5, 15):
                print(f"VIDIOC_S_FMT: {e}; retrying", flush=True)
            time.sleep(0.2)
    parm = bytearray(V4L2_STREAMPARM_SIZE)
    struct.pack_into("<I", parm, 0, BUF_TYPE_VIDEO_OUTPUT)
    # struct v4l2_outputparm: capability, outputmode, timeperframe {numerator, denominator}
    struct.pack_into("<IIII", parm, 4, 0x1000, 0, 1, int(round(fps)))
    try:
        fcntl.ioctl(fd, VIDIOC_S_PARM, parm)
    except OSError:
        pass  # older v4l2loopback: the frame rate is then just how fast we write


def play(device, frames, stop, stats, name):
    width, height = frames[0][2], frames[0][3]
    gaps = [b[1] - a[1] for a, b in zip(frames, frames[1:]) if b[1] > a[1]]
    period_us = sorted(gaps)[len(gaps) // 2] if gaps else 8333
    fps = 1e6 / period_us
    max_size = max(len(f[0]) for f in frames) + 4096
    fd = os.open(device, os.O_WRONLY)
    try:
        setup(fd, width, height, fps, max_size)
        print(f"{name} -> {device}: {len(frames)} frames, {width}x{height}, {fps:.0f} fps, looping", flush=True)
        while not stop.is_set():
            base_us = frames[0][1]
            t0 = time.monotonic()  # each loop is timed from its own start
            for jpeg, us, _, _ in frames:
                if stop.is_set():
                    break
                due = t0 + (us - base_us) / 1e6
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                os.write(fd, jpeg)
                stats[name] = stats.get(name, 0) + 1
            # The next loop starts one frame period after this loop's last frame.
            time.sleep(period_us / 1e6)
    finally:
        os.close(fd)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session")
    ap.add_argument("--devices", default="", help="comma-separated; default /dev/video40, 41, ...")
    ap.add_argument("--cameras", default="", help="camera folders to play, in device order (default: all)")
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until killed)")
    a = ap.parse_args()
    cams = a.cameras.split(",") if a.cameras else sorted(
        d for d in os.listdir(a.session) if os.path.isdir(os.path.join(a.session, d)))
    devices = a.devices.split(",") if a.devices else [f"/dev/video{40 + i}" for i in range(len(cams))]
    if len(devices) < len(cams):
        raise SystemExit(f"{len(cams)} cameras but only {len(devices)} devices")
    stop, stats, threads = threading.Event(), {}, []
    for cam, dev in zip(cams, devices):
        frames = read_camera(os.path.join(a.session, cam))
        t = threading.Thread(target=play, args=(dev, frames, stop, stats, cam), daemon=True)
        t.start()
        threads.append(t)
    end = time.monotonic() + a.seconds if a.seconds else None
    last = dict(stats)
    try:
        while any(t.is_alive() for t in threads) and (end is None or time.monotonic() < end):
            time.sleep(5)
            now = dict(stats)
            print("fps: " + ", ".join(f"{c} {(now.get(c, 0) - last.get(c, 0)) / 5:.0f}" for c in cams), flush=True)
            last = now
    except KeyboardInterrupt:
        pass
    stop.set()
    for t in threads:
        t.join(timeout=2)


if __name__ == "__main__":
    main()
