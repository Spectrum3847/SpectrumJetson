# PhotonVision native fast path on the SystemCore (design)

Goal: PhotonVision's UI, settings, calibration and NetworkTables output, with sc-vision's latency and CPU.

## Where the gap is (measured, 2026-11-06, performance governor, CD settings, min tag 32, 30 s)

| Path | first USB packet -> pose p50/p95/p99 | tail (last packet -> tags) | CPU |
|---|---|---|---|
| PV stream decode (mjdec) + streaming NAPA, stock uvcvideo (4 ms URBs) | 11.89 / 13.00 / 15.99 ms | 1.10 / 1.67 / 2.56 | 44.7% |
| same, our uvcvideo urb_packets=4 | 8.95 / 9.64 / 10.29 | 0.59 / 0.83 / 1.34 | 44.7% |
| same, urb_packets=2 | 8.95 / 9.35 / 10.19 | 0.54 / 0.83 / 1.36 | 44.9% |
| sc-vision (usbfs, 0.25 ms URBs) | 8.21 / 8.30 / 8.31 | 0.06 / 0.08 / 0.08 | 26.5% |

With small URBs, PhotonVision's stream path is within 0.7 ms (p50) / 1.9 ms (p99) of sc-vision. What is left:
1. **The watcher polls** the V4L2 buffer every 0.1 ms and finds new bytes by scanning for a 0xFF wipe; sc-vision
   blocks in the URB reap. Polling adds 0-0.1 ms per band and wakes the core 10,000 times a second.
2. **cscore copies** each dequeued frame and hands it to the VisionRunner thread; the decoded image is copied into the
   pipeline's Mat (1 MB) and `take` finds the streamed result by content. ~0.4 ms and the p99 tail.
3. **Java pipeline**: settings, pose (orthogonal iteration ~0.2 ms), target objects, NT publish.
4. **CPU**: 45% vs 27%: the watcher's polling and wipes, cscore's copy and JPEG handling, the JVM.

## Design: a native camera backend inside PhotonVision

A per-camera option (camera settings: "Native fast path", Thriftiest/Swyft MJPEG, AprilTag pipeline with NAPA).
When on, the camera's `VisionSource` is a `NativeFastPathSource` instead of `USBCameraSource`:

- **Capture + detect in one native thread** (JNI library built from `native/sc-vision`: `uvc_usb` + `mjdec` +
  streaming NAPA + IPPE/GN pose), pinned to the camera's core, SCHED_FIFO. Capture backend: usbfs (best numbers;
  the video node disappears while it runs) or V4L2 on our uvcvideo with urb_packets=2 plus a blocking per-URB
  wake-up instead of polling (needs a small uvcvideo addition: an eventfd/poll signal per completed URB). Start with
  usbfs; it needs no kernel change.
- **Results to Java**: a lock-free ring of fixed-size records (frame seq, first-packet time, mid-exposure time,
  per tag: id, hamming, margin, 4 corners, best/alt pose, errors). Java polls it with one JNI call per frame
  (`next(timeoutMs)`) on the camera's VisionRunner thread and builds `TrackedTarget`s + `CVPipelineResult` from
  it; the existing `NTDataPublisher` publishes (same topics, serde, timestamps). PV's pose estimator is skipped
  (the native pose uses PV's stored calibration: intrinsics + 8 distortion coefficients passed at start).
- **Settings**: exposure, gain, gamma, brightness, sharpness, backlight from the UI are UVC SET_CUR requests that the
  native side sends (usbfs) on the next frame boundary; NAPA settings (min tag, hamming, far search) are passed on
  change; pipeline switches to non-NAPA types or calibration stop the native thread and fall back to
  `USBCameraSource` (calibration needs color frames and PV's own capture).
- **Dashboard stream**: only when someone watches (photonvision-15): the native thread hands every Nth decoded
  luma frame (1/2 or 1/4 scaled by averaging, or the raw MJPEG bytes for passthrough) into a single-slot buffer;
  a Java thread wraps it in a Mat for the existing MJPEG server. Zero cost when nobody watches.
- **Health**: the existing watchdog sees frame timestamps; on a USB error the native thread rebinds uvcvideo
  (sc-vision-rebind logic) and PV's reconnect path takes over.
- **Rewind**: the raw MJPEG bytes are already contiguous in the native frame buffer; a single-slot copy to the
  recorder when Rewind is on.

## Prototype status

Not built yet. The pieces exist and are measured: `native/sc-vision` (capture, decode, NAPA, pose, PV serde), the
fork's `detectStreamed` result plumbing, and the URB-size work. Next step: `NativeFastPathJNI` (start/stop/next/
set_control) over `sc_vision.cc`'s loop, and `NativeFastPathSource` in the fork, behind `SPECTRUM_NATIVE_FASTPATH`.
