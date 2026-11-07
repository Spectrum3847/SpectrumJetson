# Software camera resets: recovery timing (SystemCore / Pi 5, 2026-11-07)

`run.sh [REPS]` runs `reset_timing.py` on both cameras, holding `/tmp/camera.lock`. Copy this folder and `tests/exposure-sweep/expo_probe.py` to `~/bench/exposure` first.

It runs in two phases:
- **PhotonVision stopped.** Frames are captured here with `v4l2-ctl` (1280x800 MJPEG 120), and tags are found with OpenCV's AprilTag 36h11.
- **PhotonVision running natively.** Frames and tags are timed from its NT `rawBytes` results that carry new capture times.

Only generic resets are used: re-open, USBDEVFS_RESET, uvcvideo unbind/bind, and sysfs `authorized` 0 -> 1. No vendor or firmware requests are sent. Hubs and power switching are out of scope.

5 repeats each. Times are in seconds from the reset, as the median (range). Every repeat came back.

| Camera | Method | Node gone | Node back | First frame | First tag | Controls |
|---|---|---|---|---|---|---|
| Thriftiest SJ-05 | re-open | no | - | 0.35 (0.34-0.35) | 0.35 | kept |
| | usbreset | yes | 0.47 | 1.07 (1.06-1.07) | 1.07 | kept |
| | uvcvideo rebind | yes | 0.19 | 0.78 (0.78-0.79) | 0.78 | kept |
| | authorize 0->1 | yes | 0.25 | 0.86 (0.84-0.87) | 0.86 | kept |
| Swyft SJ-SW01 | re-open | no | - | 0.38 | 0.38 | kept |
| | usbreset | yes | 0.34 | 0.80 (0.79-0.82) | 0.80 | kept |
| | uvcvideo rebind | yes | 0.09 | 0.55 (0.54-0.55) | 0.55 | kept |
| | authorize 0->1 | yes | 0.10 | 0.56 | 0.56 | kept |

The tag comes in the first frame every time. "Controls" covers exposure, gain, gamma, brightness, contrast, sharpness and backlight, read before and after. Nothing is reset, so nothing has to be re-applied.

**Answer: the cameras differ only in speed on normal resets.** Both come back from every method, and their settings persist. The Swyft is 0.1-0.3 s faster. So the difference the user has seen is plausibly firmware flashing only; no flashing was tested here.

**With PhotonVision running, it does not recover by itself:**

| Camera | Method | Node back | First result | After 13-15 s |
|---|---|---|---|---|
| Thriftiest | usbreset | 0.47 | 0.95 (0.93-0.97) | 20 fps |
| | rebind | 0.19 | 0.65 (0.63-0.67) | 20 fps |
| | authorize | 0.26 | 0.73 (0.72-0.74) | 20 fps |
| Swyft | usbreset | 0.34 | 0.65 in 1 of 5 | 0 fps |
| | rebind | 0.09 | none | 0 fps |
| | authorize | 0.10 | none | 0 fps |

- **Thriftiest.** Its results resume within a second, but at 20 fps with about 52 ms latency instead of 120 fps and 9.5 ms.
- **Swyft.** After the first reset it stopped publishing, and it was still dead minutes later. The journal showed no error, no reconnect and no loop-timing lines: a silent stall.
- **Recovery.** A PhotonVision restart brought both back to 120 fps and 9.3-9.5 ms. The native capture path (`NativeFrameProvider`, PV fork) needs a reconnect on USB re-enumeration. That is a fork change, reported rather than made here.
