# Camera timing: per-packet UVC timing, PTS/SCR, JPEG structure

Tools for characterizing the USB 2 OV9281 cameras (Thriftiest Cam, Swyft USB Camera) without test gear. They
were used for [CAMERA-FIRMWARE-OPTIMIZATION.md](../../docs/CAMERA-FIRMWARE-OPTIMIZATION.md). Only standard
requests reach a camera: V4L2 controls, UVC VS probe/commit and SET_INTERFACE. No vendor or extension-unit
command is ever sent. Every run holds `flock /tmp/camera.lock`.

| File | What |
|---|---|
| `uvc_timing.c` (+ `uvc_usb.c/.h` from `native/sc-vision`, branch `sc/mjpeg-napa`) | Streams one camera over usbfs with 1-packet URBs for up to 60 s and logs every non-empty isochronous packet: reap time (`CLOCK_MONOTONIC`), bytes, header flags, PTS, SCR (source clock + SOF). `--frames N F.mjpeg` keeps whole frames. It detaches uvcvideo while it runs and gives it back on exit. A 5 s watchdog past SECS stops a camera that sends nothing |
| `build.sh` | Cross-builds `uvc_timing` with WPILib's SystemCore toolchain (`out/uvc_timing`) |
| `sweep.sh exposure ...` / `sweep.sh modes ...` | Exposure sweep (4 s per setting) and per-mode capture (2 s per mode), under the camera lock |
| `analyze.py RUN.csv [--clock HZ] [--exposure-ms E]` | Per-frame period, bytes, first->last packet (transfer), gap, SCR clock fit, **PTS -> first data packet** in the camera's own clock and through the host clock |
| `jpeg_info.py F.mjpeg` | Markers, SOF sampling, DHT/DQT, DRI (rows per restart interval), bytes per frame and per interval |
| `brightness.py DIR` | Mean luma per exposure setting (laptop, Pillow), for exposure-control linearity |
| `mode_map.py FULL.mjpeg MODE.mjpeg...` | Fits each mode onto the full-resolution image: crop window at full pitch, or scaled/binned |
| `napa_stats.py RUN.csv...` | Summary of sc-vision per-frame CSVs (latency, transfer, CPU, margin, pose jitter) |
| `flicker_phase.py A.mjpeg DA EA B.mjpeg DB EB` | Relative exposure timing of two cameras streaming at the same time, from the phase of the 120 Hz light flicker (`--frames` writes `F.mjpeg.idx` with each frame's first-packet time) |
| `led-test.sh thr\|swyft OUT [SECS]` + `led_analyze.py OUT/frames.mjpeg OUT/pulses.csv --clock HZ` | **LED camera-delay test**: `uvc_timing --led` pulses the Pi's ACT LED (SoC GPIO; on-write ~9 us, scheduling error p50 0.1 us / p99 7-52 us) 100 us long at 0..8.3 ms after a frame's first packet (0.05 ms steps, every 4th frame). The analysis fits the exposure window relative to the first packet and to the PTS |

```bash
tests/camera-timing/build.sh && scp tests/camera-timing/out/uvc_timing tests/camera-timing/*.py \
  tests/camera-timing/sweep.sh systemcore@172.26.0.1:fw/
# on the Pi
cd ~/fw
T=/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0
UVC_TIMING=~/fw/uvc_timing ./sweep.sh exposure "$T" 1bcf:28c5 1280x800 120 thr 128 2 10 20
python3 -I analyze.py thr/e10.csv --clock 48e6 --exposure-ms 1.0
UVC_TIMING=~/fw/uvc_timing ./sweep.sh modes 0bda:3035 swyft modes 120:1280x800 120:1280x720 210:640x400
```

The 120 Hz flicker of bench lighting beats with ~121 fps capture (period ~100 frames). Brightness numbers need
whole seconds of frames (the sweep keeps 480 per setting).

## Camera delay (LED test), 2026-11-05/06

**Result** (Thriftiest SJ-05, usbrecov 5.13, 1280x800 MJPEG 120 fps, SystemCore bench):

| From the end of exposure to | ms | How |
|---|---|---|
| the camera's PTS | **0.045 ± 0.02** | LED test, camera clock |
| the frame's first USB data packet | **0.41 ± 0.05** | LED test, host clock (`uvc_timing --led`, `led_analyze.py --invert`) |
| uvcvideo's buffer timestamp, `hwtimestamps=1` (the Jetson's setting) | **0.18 ± 0.1** | PTS + 0.135 ms uvcvideo conversion offset (`v4l2_ts --meta` + `ts_vs_pts.py`, SystemCore uvcvideo 6.12) |
| uvcvideo's buffer timestamp, `hwtimestamps=0` (stock) | -0.34 | the frame's first packet is stamped: it's header-only, ~1 ms before the data |

So `SPECTRUM_CAMERA_DELAY_US` (mid-exposure = timestamp - exposure/2 - delay) depends on the timestamp:
- **180** for the Jetson's camera-clock timestamps.
- **400** for a timestamp taken at the first data packet (sc-vision).

The old 2500 (Team 100's figure) made every published timestamp ~2.3 ms too early.

**How the LED test works.**
- The LED is pulsed for 0.3 ms at 0..8.3 ms (0.05 ms steps) after every 4th frame. The camera looks at it from
  ~15 cm at ~1 ms exposure.
- Which frame changes, and by how much, traces the exposure window relative to the frame's timestamp.
- A trapezoid fit (exposure convolved with the pulse) gives the window's end, with a bootstrap error bar.

**Pitfalls.**
- The bench Pi 5's ACT LED (LimelightOS) is **inverted**: brightness 0 is lit, so its pulses are dips. Use
  `--invert`.
- Find the LED first with `LOCATE=1 led-test.sh` (1 s on, 1 s off).
- The camera must not move during the 15 s.

| File | What |
|---|---|
| `v4l2_ts.c` | Captures through uvcvideo (V4L2), optionally with the UVC metadata node: every header's PTS/SCR, with the time uvcvideo saw it. Same `--led` pulse sweep. `--frames` writes `F.mjpeg.idx` keyed by the buffer timestamp, so `led_analyze.py` measures end of exposure -> buffer timestamp directly. LED: a sysfs `1/0` file or `/dev/gpiochipN:LINE` |
| `ts_vs_pts.py OUT.csv` | Buffer timestamp minus PTS from a `v4l2_ts --meta` run, and the camera delay it implies |
| `led-test-v4l2.sh /dev/videoN LED OUT [SECS]` | The LED test through uvcvideo (the Jetson/PhotonVision path) |

### LED test on a Jetson (not done yet)

The Jetson's 180 us comes from the same camera and the same uvcvideo algorithm, but on the SystemCore's kernel
(6.12). The Jetson's kernel and its `urb_packets=4` uvcvideo may convert differently. To measure it:

1. Wire an LED + 330 ohm from a free 40-pin header GPIO to GND. Find its line with `gpioinfo` (e.g. header pin 7
   on the Orin Nano dev kit), and check that nothing else uses it.
2. Build on the Jetson: `gcc -O2 -std=gnu11 tests/camera-timing/v4l2_ts.c -o tests/camera-timing/v4l2_ts -lpthread`.
3. Stop PhotonVision (`sudo systemctl stop photonvision`). Point one Thriftiest at the LED from ~15 cm, fixed in
   place.
4. Run `tests/camera-timing/led-test-v4l2.sh /dev/video0 /dev/gpiochip0:LINE /tmp/led 15`. Add `INVERT=1` if the
   LED is lit when the line is low. Copy `/tmp/led` to a laptop.
5. Run `led_analyze.py /tmp/led/frames.mjpeg /tmp/led/pulses.csv --clock 48e6 --roi X0 Y0 X1 Y1` on the LED's
   spot. Its "exposure end -> first data packet" line is here end of exposure -> buffer timestamp. Set it with
   `CAMERA_DELAY_US=... scripts/jetson/09-robot-tuning.sh`.
6. Without an LED: `v4l2_ts /dev/video0 --meta /dev/video1 1280x800 120 5 /tmp/ts.csv`, then `ts_vs_pts.py
   /tmp/ts.csv`, gives the uvcvideo conversion offset. Add 0.045 ms to get the delay.

The GPIO-chip LED path in `v4l2_ts` (GPIO v2 line request) is untested. The sysfs path was tested on the Pi.
