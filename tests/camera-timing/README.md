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
