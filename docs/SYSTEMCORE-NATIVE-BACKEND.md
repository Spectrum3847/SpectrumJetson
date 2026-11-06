# Native camera backend for PhotonVision on the SystemCore (design, 2026-11-06)

Goal (user): per camera, the whole per-frame path is native (capture -> mjdec -> streaming NAPA -> pose -> publish,
health, tag quality, Rewind video and vision log). PhotonVision keeps the UI, settings, calibration, pipeline config
and stream-on-demand; Java touches nothing per frame. Target: per-camera CPU near sc-vision's (~27% of a core at
120 fps, min tag 32) instead of the fast path's ~35-42% (PV-perf's photonvision-120..124 bring the fast path to
~29-30% on the dark bench), same latency, same results. Per camera, fallback to today's fast path.

## Where the fast path's extra CPU goes (measured so far)

- The streaming thread (decode + NAPA + pose + publish) is the same work sc-vision does.
- On top: cscore's capture thread dequeues every frame and copies its JPEG into a cscore frame; the Java vision
  thread runs at 30 fps (grab, NAPA result take, health, NT); the JIT; PV's own NT traffic. PV-perf measured the
  wake-ups: 6340/s before, 4880-4965/s with its patches (PVPERF-LOG).

## Capture: own the V4L2 device natively (our uvcvideo), not usbfs

| | V4L2, native owner (chosen) | usbfs (sc-vision's) |
|---|---|---|
| Latency | urb_packets 2: first sight +0.085 ms; camera-clock stamps with hwtimestamps=1 | same; packet-exact first data packet |
| CPU | DQBUF per frame, bytes read straight from the mmap'd buffer while they land (the watcher already does) | URB reaping per 0.25 ms (more wake-ups) |
| Timestamps | QUERYBUF/DQBUF work (we own the queue): camera-clock stamp per frame directly, no Java anchors | own PTS/SCR conversion needed |
| Hot-plug / reconnect | the kernel driver handles it; reopen the node by /dev/v4l/by-id | detach/rebind uvcvideo ourselves; a crash leaves the camera unbound (sc-vision-rebind) |
| Controls | V4L2 ioctls on our own fd (read before write: the Swyft writes them to flash) | needs the node anyway (we already go back to V4L2 for controls) |
| Risk with the user remote | none new (proven driver load) | detach/rebind of a remote camera |

So the backend owns `/dev/v4l/by-id/...` with our uvcvideo (urb_packets 2, hwtimestamps 1). cscore never opens
the camera while the native backend runs it.

## Components (fork + SpectrumJetson)

1. `libspectrum-camera.so` (SpectrumJetson `detector/native_camera.cc`, built with the NAPA libs):
   - one thread per camera: S_FMT/REQBUFS/mmap/STREAMON on its own fd; the watcher's progressive decode
     (mjdec) + streaming NAPA + pose + pv_pack + NT publish (one NT client per camera) + tag quality + health,
     all as today but without cscore or the RefTag handoff;
   - capture time from the dequeued buffer's camera-clock stamp (no Java anchors, no first-sight bias);
   - frame policy (skip / 1/2) decided at frame start, as now;
   - controls: set/get by V4L2 id, read before write;
   - Rewind: the frame's JPEG (already in the mmap buffer) copied into a ring for a low-priority writer thread
     (skip, never block vision), large sequential writes, periodic fdatasync, same file/index format as
     docs/REWIND.md; recording fps independent of the policy; the vision log entries from the native results;
   - stream-on-demand: when a viewer is connected, the latest JPEG (or 1/2-scale gray) handed to Java at the
     stream rate only (cscore RawSource can pass MJPEG through to the MjpegServer without re-encoding).
2. Fork: `NativeCameraSource` (a VisionSource) chosen per camera when the library is there and
   `SPECTRUM_NATIVE_CAMERA=1` (later: a per-camera setting); settings changes (exposure, gain, pipeline params,
   calibration, policy) go to the native side through JNI setters; the Java VisionRunner idles (no per-frame work)
   except for the stream-on-demand pump and health/UI at 1-2 Hz. Fallback per camera: if the library or the
   device open fails, the camera is handed to today's USBCameraSource + fast path.

## Fork files (coordination with PV-perf, branch sc/pv-perf, photonvision-120..124)

PV-perf's changes touch USBFrameProvider, VisionRunner, VisionModule, VisionSourceManager, FrameRateCap,
ClockThrottle, UIDataPublisher, DataSocketHandler. The backend adds new files (NativeCameraSource, its settables,
JNI class) and needs small hooks in VisionSourceManager (choosing the source) and VisionModule (no per-frame
consumers for a native camera). Plan: rebase onto sc/pv-perf once it is merged into sc/mjpeg-napa (or merge it
first), and keep the hooks small; posted in PVPERF-LOG.

## Test plan (until the supply is fixed: single camera, ondemand, <= 20-30 s runs)

- Offline: the capture loop against recorded MJPEG (a fake V4L2 source fed from cd-e2g128.mjpeg) for decode/NAPA/
  pose/serde identity with the fast path; Rewind writer throughput on the SD card with no camera.
- Live (single camera): results identical to the fast path on the same scene (Swyft at exposure 300 while dark,
  restored after), CPU per camera vs sc-vision and the fast path, latency on the same time reference
  (tsref-compare.sh), hot-unplug simulated only by stopping/starting the stream (no physical action).
