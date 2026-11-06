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

## Multi-camera native publish (photonvision-110, 2026-11-06)

What shipped instead of the separate backend above (option 1: V4L2 with our small-URB uvcvideo, cscore keeps the
device): photonvision-108 (no image copy without a viewer, native pose) and 109 (each frame's result published from
the streaming thread). photonvision-110 makes that work for any number of cameras in one PhotonVision:

- `NativePublish` is one instance per camera, owned by its `VisionRunner` and current on its vision thread; the
  native side was already per NAPA handle (per camera). Calibration, tag size, mid-exposure shift and topic are
  per camera. A camera whose frames aren't streamed stays on the Java path.
- **One NetworkTables client per camera.** ntcore drops a flush that comes within 5 ms of the connection's last
  send (`NetworkOutgoingQueue::SendOutgoing`, `MIN_PERIOD_MS = 5`; the value then waits for the next send), so
  coalescing on one connection can't fix it: two cameras at 120 fps on PhotonVision's connection lost 7 ms at p95.
  Each camera's native publisher is its own client of the same server (identity `photonvision-native-*`),
  publishing the same `/photonvision/<cam>/rawBytes` topic and type; PhotonVision's Java publisher stays idle while
  the native one is active. `SPECTRUM_NATIVE_NT_CLIENT=0` shares PhotonVision's connection instead.
- Health (`/photonvision/<cam>/health`): fps and frames are the native publish count, `latencyMs` the mean
  capture -> publish (it read 30 fps, the capped Java rate, before).
- Camera delay 0.4 ms (LED test), per camera: `SPECTRUM_CAMERA_DELAY_US="400,name=N"`. The streaming watcher's
  first sight is now converted back to the first packet (less the URB length) before it is applied.

Measured (`tests/systemcore-latency/multicam-native.sh 20`, our uvcvideo urb_packets 2, ondemand, Thriftiest
exposure 0.2 ms gain 128, Swyft exposure 1 ms, min tag 32, both cameras seeing tag 3, NT subscriber on the same
SystemCore; capture -> received ms p50/p95/p99; PhotonVision process CPU in % of one core):

| Run | Thriftiest | Swyft | CPU |
|---|---|---|---|
| Swyft alone | | 9.46 / 10.71 / 11.03 | 44.1% |
| Thriftiest alone | 9.13 / 10.13 / 10.42 | | 44.3% |
| Both, shared NT connection | 10.28 / 16.93 / 17.90 | 13.33 / 17.72 / 18.73 | 92.2% |
| Both, one NT client per camera (default) | 9.16 / 10.18 / 10.54 | 9.77 / 10.84 / 11.41 | 86.5% |
| Both, per-camera clients, pinned (cores 1-3, watcher with its camera) | 9.17 / 10.25 / 11.02 | 9.65 / 10.92 / 11.92 | 90.8% |

Every run at the full camera rate (120-121 results/s per camera, all with tags). Two cameras cost what two single
cameras cost (the streaming threads are ~35% of a core each) and neither camera's latency moves. Pinning didn't
help at two cameras. Health read fps 120-121 per camera.

### What knowing it's two cameras buys (2026-11-06, same setup, 20 s runs)

`multicam-native.sh` also writes each probe's per-result CSV; `multicam_phase.py` bins every frame by its offset
to the other camera's nearest capture. The cameras free-run (120 vs 121 fps), so a 20 s run sweeps every phase.
capture -> publish (on the SystemCore, no NT) p50/p95/p99 ms:

| Placement | Thriftiest, other camera 0-1 ms away | Thriftiest, 3-4 ms away | Swyft, 0-1 ms | Swyft, 3-4 ms | CPU |
|---|---|---|---|---|---|
| unpinned (default) | 7.90 / 8.17 / 8.40 | 7.90 / 8.19 / 8.64 | 8.52 / 8.67 / 8.83 | 8.52 / 8.83 / 9.32 | 85.3% |
| watcher per core (`spread:2-3`), camera threads pinned | 7.89 / 8.13 / 8.39 | 7.89 / 8.13 / 8.61 | 8.52 / 8.77 / 9.20 | 8.51 / 8.93 / 9.16 | 91.7% |
| + every other PV thread off cores 2-3 | 7.89 / 8.15 / 8.69 | 7.89 / 8.11 / 8.27 | 8.52 / 8.78 / 9.16 | 8.52 / 8.63 / 8.80 | 89.5% |
| unpinned, Thriftiest min tag 16 | 8.00 / 9.55 / 11.16 | 7.99 / 9.11 / 12.23 | 8.53 / 8.97 / 10.23 | 8.52 / 8.91 / 10.15 | 109.3% |

- **Phase / staggering:** no dependence on phase: frames that arrive together (24% publish within 1 ms of the
  other camera's) are as fast as frames 3-4 ms apart. Offsetting the cameras' start would buy nothing at two
  cameras.
- **Core placement:** one core per camera's watcher, and keeping PhotonVision's other threads off them, changed
  nothing measurable (p50 identical, p99 within run-to-run noise); no sign of cross-camera cache or memory
  interference. Leave it to the scheduler (default). `SPECTRUM_STREAM_CPUS=spread:LIST` (new) places watchers one
  per core for any number of cameras; photonvision-111 stops `CameraThreads` from moving them back every 2 s (the
  earlier "pinned" run above was really unpinned watchers).
- **Shared work:** one NT flush per batch can't work (ntcore's 5 ms rule above), one client per camera is the fix.
  One watcher thread for both cameras would serialize the 24% of frames that finish together; at ~35% of a core
  per camera there's no CPU to win back that way.
- **min tag by role:** min 16 on the Thriftiest costs +20-24% of a core and raises both cameras' p99 by 2-3 ms
  (ondemand governor); keep min 16 for the camera whose role needs far tags only.
- **USB:** the two cameras are on separate RP1 xHCI controllers (Swyft usb1 IRQ 129, Thriftiest usb3 IRQ 134).
  Both hard IRQs are delivered on CPU 0 (RP1's chained interrupt; effective affinity 0) and their threaded
  handlers (SCHED_FIFO 50) float on 0-3. No contention showed: each camera's latency matches its single-camera run.
- One unpinned two-camera run was discarded: both NT probes stalled together for ~2 s (received times jumped 2.3 s
  for both cameras at once while PhotonVision's health kept 120 fps) during bench under-voltage; the rerun
  matched the earlier one.
