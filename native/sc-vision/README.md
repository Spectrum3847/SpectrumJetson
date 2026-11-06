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
same SystemCore. "Mid-exposure" = the frame's first USB packet - (exposure/2 + 2.5 ms camera delay): the same
constants PhotonVision uses, but PhotonVision applies them to uvcvideo's buffer timestamp, which (hwtimestamps=0 on
LimelightOS) is taken when the first 4 ms URB completes, ~2.4 ms after the first packet. Compare runs on the first
USB packet (kernel trace for PhotonVision, the app's own reap time for sc-vision).
