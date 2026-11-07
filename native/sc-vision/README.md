# sc-vision: native AprilTags on the SystemCore

One Thriftiest Cam (USB 2, MJPEG 1280x800 at 120 fps) on a SystemCore (Raspberry Pi 5 / CM5, 4x Cortex-A76,
LimelightOS), tags with NAPA, poses on NetworkTables in PhotonVision's format, as fast as the camera allows.

```
USB isochronous packets (user-space UVC, 0.25-0.5 ms URBs, mmap'd usbfs buffers)
  -> mjdec: luma-only JPEG decode, one restart interval (8 rows) at a time as the bytes land
  -> streaming NAPA (napa_stream_feed per band; patches/napa-03 + napa-04)
  -> IPPE-square pose + Gauss-Newton refine
  -> /photonvision/<camera>/rawBytes (PhotonLib reads it as a PhotonVision camera) + per-frame CSV
```

One thread does everything, pinned to one core (SCHED_FIFO optional). A nice-19 checker thread re-decodes every
64th frame with libjpeg-turbo and re-runs whole-frame `napa_detect`, and counts differences.

## ThriftyCam (USB 3, 05c8:0a00)

`sc-vision --usb 05c8:0a00 --size 1600x1304 --fps 60 --exposure 8 --gain 0 --sharpness 50 --calib CAL.json`
(and `--port 2-1` when there are two; it has no serial). At SuperSpeed the reader takes the bandwidth from the
endpoint's SuperSpeed companion descriptor (wBytesPerInterval, 33792 B in alt 17, not wMaxPacketSize 1024) and the
camera's own alt setting (it is alone on its USB 3 bus); one UVC payload per 125 us service interval, as at high
speed, so 4-packet URBs still give the bytes every 0.5 ms. Controls are read first and written only when they
differ (they persist in the camera). The overload skip now scales with the rate (84% of a frame period): the old
fixed 7 ms (120 fps) dropped every other ThriftyCam frame, whose decode + NAPA takes ~10 ms of CPU.

Bench Pi 5, 2026-11-06, 30 s, 7 tags in view, PhotonVision running the other two cameras (provisional pinhole
calibration: timing only): 60.2 fps, 0 overload skips of note (4), 3 bad frames of 1807; first -> last packet
p50 15.6 ms (the camera spreads a frame over the period); last packet -> pose p50/p99 0.77/1.40 ms; first packet ->
pose 16.3/17.6 ms; capture (mid-exposure) -> pose 17.1/18.3 ms; 10.3 ms CPU a frame (62% of a core); 6 tags a frame,
tagfit 74 us a tag. URB size matters at SuperSpeed only for latency: the default there is 1 packet a URB (EOF -> tags p50/p99 0.03/0.05 ms, 4 packets 0.27/0.57, 8 packets 0.52/0.76, 16 dropped to 58 fps; +5% of a core vs 4).
Camera delay (exposure end -> first packet) defaults to 0.7 ms for this camera: not measured, it assumes the PTS
(0.7 ms before the first packet) marks the end of exposure. Override with `--camera-delay-ms`.

## Files

| File | What |
|---|---|
| `src/mjdec.c/.h` | The decoder. Baseline Huffman, any DRI/tables; Y 1x1/2x1/2x2 + 1x1 chroma. Bit-identical to libjpeg-turbo `JCS_GRAYSCALE` + `JDCT_ISLOW`. |
| `src/uvc_usb.c/.h` | User-space UVC reader: detaches uvcvideo (camera untouched: no firmware, no reset), probe/commit, iso URBs; gives the camera back on exit. Refuses a camera whose `/dev/video` node is open. |
| `src/pose.c/.h` | IPPE for a square (analytic) + Gauss-Newton on pixel reprojection error, 8-coefficient OpenCV undistort. |
| `src/nt_pub.cc` | PhotonVision-compatible NetworkTables output (the Spectrum fork's serde, uuid fd353b11...). `nt_pub_stub.cc`: none. |
| `src/sc_vision.cc` | The app. `--help`-style options are listed at the top of the file. |
| `tools/mjdec_bench.c` | Decoder identity + speed against libjpeg-turbo on a recorded `.mjpeg`. |
| `tools/nt_probe.cc` | Subscribes like PhotonLib; prints results/s and capture -> received latency. |
| `tools/scmn_adapter.c` | The tester's `scmn_dec_*` decoder ABI over mjdec (`libscvision-dec.so`). |
| `build.sh`, `fetch-ntcore.sh` | Cross build with WPILib's SystemCore toolchain (laptop, Windows or Linux). |
| `sc-vision-rebind` | Gives the camera back to uvcvideo after a crash/SIGKILL (the service runs it at stop). |

Install: `scripts/systemcore/install-native.sh` (service `sc-vision-native`, not enabled at boot; options in
`/etc/default/sc-vision`). Switch the camera's owner: `sc-vision native | photonvision | limelight | off`.
Measure: `tests/systemcore-latency/run.sh native SECS NAME [args]`, `native-matrix.sh`, `post-compare.sh`.

## Why these choices

- **User-space UVC.** LimelightOS's uvcvideo completes 32-packet isochronous URBs: a frame's bytes reach user space
  in ~4 ms chunks (2-3 per frame), so most of the decode and NAPA work happens after the last packet. usbfs lets us
  keep many 2-4 packet URBs in flight (0.25-0.5 ms) without a kernel change, and reap them with a blocking ioctl:
  no polling, no 0xFF-wipe trick, no extra frame copy in the kernel's V4L2 path (the payloads are copied once,
  ~50 KB, into the frame buffer the decoder reads).
- **C with NEON intrinsics.** The hot paths are a table-driven Huffman loop (scalar, branchy) and a fixed-point
  IDCT (NEON). The same compiler backend generates both from C or Rust, NAPA is C, ntcore is C++, and libjpeg-turbo
  (the reference) is C: nothing to gain from another language for speed, and C keeps one toolchain.
- **Luma only.** The camera is monochrome: every chroma block is "DC difference 0, EOB" (4 bits). mjdec skips all
  of an MCU's chroma with one 8-bit peek; libjpeg-turbo entropy-decodes them (and uses its slow restart path for
  every MCU row, because the camera sets a restart interval).
- **Bit-identical output**, so NAPA's results are the validated ones (identity checked live and on recordings).

## Clock

The app's times are CLOCK_MONOTONIC, which is NetworkTables time on WPILib 2027 and the robot code's clock on the
same SystemCore. "Mid-exposure" = the frame's first USB packet - (exposure/2 + camera delay). The camera delay (exposure end ->
first packet, `--camera-delay-ms`, per camera) defaults to 0.4 ms: the LED test measured 0.41 +- 0.04 ms on the
Thriftiest, and the camera clock's PTS -> first packet is 0.35 ms on both the Thriftiest and the Swyft (the Swyft uses
the default until measured). (It was Team 100's 2.5 ms until 2026-11-06.) The PhotonVision fork applies the same
delay, after converting its own reference back to the first packet: uvcvideo's buffer timestamp (hwtimestamps=0 on
LimelightOS) is taken when the URB holding the first packet completes, ~2.4 ms after it with 4 ms URBs. Compare runs on the first
USB packet (kernel trace for PhotonVision, the app's own reap time for sc-vision).
