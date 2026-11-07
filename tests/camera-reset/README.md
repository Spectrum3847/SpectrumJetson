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

## Fixed (photonvision-137, 2026-11-06 22:00 CST): every reset recovers to 120 fps

Root causes, all in the native camera path:
- **Thriftiest "20 fps".** Those results were one stale frame, published again and again. The capture thread never checked V4L2 errors. Its mmap buffer still held the last JPEG, so each pass decoded it again and published it when `DQBUF` failed (ENODEV). Each pass took about 50 ms, so the results came at 20 fps with about 52 ms latency, the same tags every time, and fresh capture times.
- **Swyft "never comes back".** Its buffer had been wiped, so the thread spun forever waiting for a JPEG start (about one core busy), and nothing was published. Nothing noticed, so nothing reconnected.
- **Rebind came back with no video node.** PhotonVision still held the dead device's fd and mappings. That kept the old uvcvideo device's streaming interface claimed, so the rebind probe failed with "No streaming interface found for terminal 5".
- **After a reopen, the Swyft ran at about 85 fps with 40 ms latency.** A reopened camera's NAPA handle often reuses the old handle's address. `NapaDetector` therefore skipped re-sending the pipeline's settings, and the new detector ran NAPA's defaults instead of min tag 22. That is too slow for 120 fps on the Swyft. A cscore handover had the same bug.

The fix:
- **Native side (detector/napa/NapaDetectorJNI.cc).**
  - Any `DQBUF` error other than EAGAIN, an ENODEV from the wake ioctl, or no completed buffer for `SPECTRUM_NATIVE_FRAME_TIMEOUT_MS` (default 500 ms, after a 2 s start-up grace) ends capture.
  - The thread then lets go of the device at once: stream off, buffers unmapped, fds closed, including the control fd.
  - A frame whose buffer never completed is not published.
  - `cameraStats[5]` reports the errno.
- **Fork side.**
  - `NativeFrameProvider` closes the handle and reopens the camera by its by-id path (its serial, so the `/dev/videoN` number doesn't matter). It retries every 100 ms in the selected mode and writes controls back where they differ.
  - It logs `lost (...)` and `reconnected N ms after ...`. Health `state` shows `disconnected` or `recovering`, and `recoveries` counts reconnects.
  - Handles are compared by (handle, open count).

Results with PhotonVision running both cameras natively, 5 repeats each:
- `RESET_TIMEOUT_S=5`; fps and latency are measured over the last 2 s.
- `yank` holds `authorized` at 0 for 3 s, like an unplugged cable, and times from the re-plug.
- "First result" is the median (range) in seconds.

| Camera | Method | Recovered | Node back | First result | fps after | p50 / max p99 ms |
|---|---|---|---|---|---|---|
| Thriftiest | usbreset | 5/5 | 0.49 | 1.01 (0.98-1.04) | 121-122 | 8.84 / 10.2 |
| | rebind | 5/5 | 0.20 | 0.75 (0.70-0.76) | 121.5-122 | 8.83 / 9.5 |
| | authorize | 5/5 | 0.26 | 0.78 (0.76-0.81) | 121.5-122 | 8.84 / 9.6 |
| | yank | 5/5 | 0.31 | 0.83 (0.81-0.86) | 121.5-122 | 8.84 / 9.5 |
| Swyft | usbreset | 5/5 | 0.37 | 0.82 (0.79-0.88) | 120.5 | 8.92 / 16.8 |
| | rebind | 5/5 | 0.12 | 0.53 (0.50-0.58) | 120-120.5 | 9.00 / 15.9 |
| | authorize | 5/5 | 0.15 | 0.59 (0.53-0.64) | 120.5 | 8.91 / 17.8 |
| | yank | 5/5 | 0.16 | 0.58 (0.55-0.62) | 120.5 | 8.97 / 13.4 |

Across all 40 resets:
- Every steady-state result had tags, and the controls read the same afterwards (nothing had to be written back).
- A first result comes about 0.4-0.5 s after the node is back. That is the camera's own start-up, the same as standalone.

**Caution: the Thriftiest can fail to re-enumerate after a USB reset.** In an earlier attempt, the 5th Thriftiest usbreset left it failing descriptor reads (error -110, camera side). While the hub was stuck retrying, reading `usb3-port1/disable` hung and the hung-task watchdog rebooted the Pi, which brought the camera back. So never read hub or port sysfs attributes while a device is enumerating. PhotonVision cannot recover a camera that is not on USB.

