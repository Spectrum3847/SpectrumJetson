# Latency breakdown: mid-exposure to pose, stage by stage

Where the time goes between a Thriftiest Cam's exposure and the pose reaching NetworkTables,
measured per frame. This test also built
and tested two changes:

- a **streaming decoder** that decodes while the frame arrives (`SPECTRUM_JPEG_DECODER=stream`,
  the default since 2026-11-02, after the 2-camera spike fix below);
- **`urb_packets=4`** as the new default.

Measured 2026-11-02 on the bench Jetson (Orin Nano Super, clocks `full`, stock camera firmware).

- Cameras: two Thriftiest Cams, mono sensor, MJPEG 1280x800 at 122 fps.
- Exposure: 50, which is 5.0 ms.
- `SPECTRUM_CAMERA_DELAY_US=2500`.
- uvcvideo: `hwtimestamps=1`.
- PhotonVision: AprilTagCuda with the GPU detector, or with "Tags on CPU (NAPA)".
- **There were no tags on the bench**, so detection and pose solve are no-tag times.

## Files

| File | What |
|---|---|
| `run.sh SECS [COND...]` | Runs on the Jetson. COND is `gpu`/`napa`/`napastream` (or `gpuyolo`/`napayolo`/`napastreamyolo`: AprilTag + Object with yolo11n at Object FPS max 30), then the number of cameras, then an optional decoder: `gpu-2`, `napa-1-stream` (`nvjpg`, `turbo` or `stream`). Starts PhotonVision with `SPECTRUM_LATENCY_TRACE` (fork `photonvision-103`) for a per-frame CSV, while ftrace records `xhci_urb_giveback`, `vb2_buf_done` and `v4l2_dqbuf` (mono clock). Records CPU and xhci IRQ/s. Restores the settings DB, clocks mode and drop-in, and stops tracing. The second camera is deactivated in the DB for 1-camera runs. `SCHED=1` also traces `sched_switch`/`sched_wakeup`; `EXTRA_ENV="VAR=value ..."` adds environment variables to the drop-in. |
| `analyze.py DIR NAME` | Joins the CSV and the trace per frame on `CLOCK_MONOTONIC`. Prints the stage table and drops (V4L2 sequence gaps). |
| `ktrace.py TRACE --frames` | Kernel stages only: first and last USB packet, done, DQBUF. The camera slot is fixed per video device by majority. |
| `usb-sweep.sh OUT PACKETS...` | Streams with `v4l2-ctl` (PhotonVision stopped) at each `urb_packets` value. Optional `EXPOSURE` and `CAMS`. Measures IRQ/s and CPU. Restores the settings. |
| `streamdec.c` | Offline overlapped-decode test on a capture. libjpeg-turbo with a suspending source, fed in pieces over 8 ms in real time. |

Every run has a hard `timeout` and prints TIMEOUT if it hits it. Tracing, `SPECTRUM_LATENCY_TRACE`
are off by default.

Frames are joined on the hardware timestamp: the dequeued buffer's timestamp equals the frame's
raw time in PhotonVision, and NT time equals `CLOCK_MONOTONIC` on WPILib 2027 (offset < 1 us).
"Mid-exposure" is the time PhotonVision publishes, which is what robot code fuses at. It equals
the hardware timestamp minus half the exposure (2.5 ms) minus the camera delay (2.5 ms). The
camera delay is Team 100's figure and we haven't measured it yet. The first packet's time is
only known to within one URB.

## Results: p50 / p95 / p99 ms, 20 s per condition (~2,400 frames per camera), urb_packets=4

### GPU detector

| Stage | NVJPG, 1 cam | **stream, 1 cam** | NVJPG, 2 cams | **stream, 2 cams** |
|---|---|---|---|---|
| mid-exposure -> first USB packet | 4.60 | 4.38 | 4.18 | 4.48 |
| frame streams over USB | 8.13 / 8.75 / 8.75 | 8.13 | 8.50 | 8.38 |
| last packet -> DQBUF | 0.03 | 0.03 | 0.03 | 0.04 |
| DQBUF -> decoder has the frame (cscore) | 0.06 / 0.07 / 0.32 | 0.06 / 0.08 / 0.47 | 0.05 / 0.08 / 0.37 | 0.06 / 0.17 / **2.87** |
| JPEG decode, after the frame | **2.64 / 2.78 / 3.02** | **0.20 / 0.34 / 0.42** | 2.65 / 2.76 / 3.12 | 0.21 / 0.35 / 0.42 |
| decoded -> camera thread | 0.05 | 0.05 | 0.04 | 0.04 |
| tag detection (GPU) | 0.86 / 1.00 / 1.36 | 0.97 / 1.22 / 1.79 | 0.94 / 1.55 / 2.21 | 1.03 / 1.47 / 2.08 |
| pose solve | < 0.01 (no tags) | < 0.01 | < 0.01 | < 0.01 |
| NT publish + flush | 0.05 | 0.05 | 0.04 | 0.04 |
| **mid-exposure -> pose ready** | 16.54 / 16.98 / 18.88 | **13.89 / 14.35 / 15.93** | 16.54 / 17.31 / 19.35 | **14.26 / 15.00 / 17.34** |
| CPU busy, whole system (of 6 cores) | 6.3% | 11.9% | 12.4% | 21.2% |

### NAPA (tags on the CPU)

| Stage | NVJPG, 1 cam | **stream, 1 cam** | NVJPG, 2 cams | **stream, 2 cams** |
|---|---|---|---|---|
| JPEG decode, after the frame | 2.62 / 2.79 / 3.09 | **0.19 / 0.33 / 0.42** | 2.70 / 2.83 / 3.11 | 0.21 / 0.35 / 0.45 |
| tag detection (NAPA) | 1.07 / 1.12 / 1.16 | 1.07 / 1.12 / 1.17 | 1.09 / 1.14 / 1.18 | 1.09 / 1.14 / 1.18 |
| **mid-exposure -> pose ready** | 16.60 / 16.96 / 17.97 | **14.17 / 14.39 / 15.81** | 16.78 / 17.13 / 18.22 | **14.15 / 14.45 / 15.54** |
| CPU busy, whole system | 7.8% | 13.5% | 13.0% | 24.6% |

- **0 frames dropped** in every run (V4L2 sequence numbers). Max temperature was 72 C.
- In the "decode" row for stream, the time is waiting for the last rows plus copying 1 MB.
- The stream decoder **saves 2.4 to 2.6 ms at p50** and 2.0 to 3.0 ms at p99, with both
  detectors and with 1 or 2 cameras.
- The 2-camera spike in the cscore handoff (p99 2.9 ms with the GPU detector, 1.3 with NAPA)
  is fixed; see [The 2-camera handoff spike](#the-2-camera-handoff-spike-fixed).

### Streaming NAPA (`napastream`, 2026-11-02)

NAPA runs band by band while the frame is decoded, so tags are ready ~0.5 ms after the last packet, not
~1.45 ms. Mid-exposure → pose p50 is 13.0-13.4 ms instead of 14.0-14.3 ms (1 or 2 cameras, with or without
yolo11n), and p99 drops by 0.8-2.5 ms. Full tables and the identity checks are in
[`../napa-stream`](../napa-stream/README.md#live-results-bench-jetson-clocks-full-2-thriftiest-cams-at-122-fps-urb_packets4-stream-decoder-both-sides).
`analyze.py` now also prints `TAIL last packet -> tags detected`. Set `TAG_FPS_MAX=N` to run with Tag FPS max.

### Earlier baseline at urb_packets=16 (2 ms URBs), NVJPG

| | GPU, 1 cam | GPU, 2 cams | NAPA, 1 cam | NAPA, 2 cams |
|---|---|---|---|---|
| mid-exposure -> pose ready | 16.98 / 18.04 / 19.91 | 17.24 / 18.12 / 19.50 | 16.70 / 17.60 / 18.11 | 17.31 / 18.23 / 18.65 |

## The 2-camera handoff spike (fixed)

**Cause.** The handoff (DQBUF -> `grab_ret`) ends when the camera's SpectrumDecoder thread wakes and
takes the frame. `SCHED=1 run.sh` adds `sched_switch`/`sched_wakeup` to the trace. Both cameras'
SpectrumDecoder threads only ever ran on core 1: the bench settings DB held `pinSharedCore` 1, saved by
the first `photonvision-102` build when 1 was its default (now -1). The decoders woke together and the
second waited, and in the worst frame (3.97 ms) a decoder woke on core 1 and waited 5.6 ms behind a C2
JIT thread while other cores were idle. The watchers weren't the cause; they ran on other cores.

**Fix.** The fork resets a saved `pinSharedCore` 1 to -1 once (`pinSettingsVersion` 1, logged), so
shared threads are unpinned as documented. The bench DB is fixed. `SPECTRUM_PIN_SHARED_CORE=-1` does the
same for a test.

Also tried: **watcher placement**, `SPECTRUM_STREAM_CPUS` (`all` = scheduler, the default; `auto` = off
the cores a camera thread is pinned to; or a list). With 2 cameras it made no difference (handoff p99
0.23/0.26 auto vs 0.13/0.22 all). With 4 cameras, `auto` would crowd 4 watchers onto 2 cores, so `all`
stays the default. Watcher polling (0.1 ms sleeps while idle) and SCHED_FIFO weren't needed.

Before and after (GPU detector, 2 cameras, 20 s each, ms):

| `pinSharedCore` | handoff p50/p95/p99 | mid-exposure -> pose p50/p95/p99 |
|---|---|---|
| 1 (stale DB), 3 runs | 0.056-0.057/0.14-0.18/0.43-0.61 | 13.85-14.21/14.35-14.79/16.05-16.30 |
| -1 (fixed), 8 runs | 0.057-0.062/0.072-0.082/0.13-0.27 | 14.02-14.62/14.58-15.05/16.30-16.89 |

The handoff tail is gone. The total p99 didn't move: what's left of 2 cameras' p99 is GPU detection
(p99 2.2 to 2.9 ms with 2 cameras, 1.6 to 2.7 with 1); 1-camera totals had p99 15.5 to 16.8, which runs the same way with either decoder.

### After the fix: 1 vs 2 cameras, with and without YOLO (p50 / p95 / p99 ms, 20 s each)

yolo = AprilTag + Object pipeline, yolo11n (TensorRT, 640x640) at Object FPS max 30 on every camera.
CPU is the whole system, % of 6 cores, from `/proc/stat` (noisy: 2-camera stream runs ranged 16 to 27%).

| Condition | Decoder | handoff | decode after the frame | detection | **mid-exposure -> pose** | drops | CPU |
|---|---|---|---|---|---|---|---|
| GPU, 1 cam | stream | 0.06/0.07/0.08 | 0.21/0.33/0.43 | 0.97/1.28/1.71 | **14.09/14.47/15.52** | 0 | 12.4 |
| GPU, 1 cam | NVJPG | 0.06/0.07/0.08 | 2.63/2.79/2.87 | 0.86/1.23/1.66 | 16.29/16.80/17.62 | 0 | 6.9 |
| GPU, 2 cams | stream | 0.06/0.07/0.22 | 0.21/0.35/0.46 | 0.99/1.38/2.31 | **14.22/14.72/16.89** | 0 | 21.5 |
| GPU, 2 cams | stream (repeat) | 0.06/0.08/0.27 | 0.21/0.34/0.44 | 1.00/1.43/2.23 | **14.02/14.61/16.48** | 0 | 17.8 |
| GPU, 2 cams | NVJPG | 0.06/0.07/0.08 | 2.68/2.78/2.88 | 0.90/1.40/1.93 | 16.37/16.96/18.00 | 0 | 8.8 |
| NAPA, 1 cam | stream | 0.06/0.07/0.18 | 0.21/0.34/0.39 | 1.07/1.14/1.19 | **14.17/14.39/14.92** | 0 | 14.1 |
| NAPA, 2 cams | stream | 0.06/0.08/0.26 | 0.20/0.34/0.41 | 1.09/1.14/1.18 | **14.09/14.38/15.20** | 0 | 25.1 |
| NAPA, 2 cams | NVJPG | 0.06/0.07/0.08 | 2.70/2.80/2.90 | 1.09/1.14/1.18 | 16.68/16.96/17.28 | 0 | 12.7 |
| GPU + yolo, 1 cam | stream | 0.06/0.08/0.10 | 0.20/0.33/0.41 | 1.38/1.60/1.99 | **14.47/14.88/17.18** | 0 | 15.5 |
| GPU + yolo, 2 cams | stream | 0.06/0.08/0.26 | 0.21/0.37/0.48 | 1.10/2.55/4.03 | **14.15/16.54/17.96** | 0 | 25.8 |
| GPU + yolo, 2 cams | stream (repeat) | 0.06/0.08/0.26 | 0.21/0.35/0.50 | 1.09/1.66/3.18 | **14.05/14.78/17.28** | 0 | 28.4 |
| GPU + yolo, 2 cams | NVJPG | 0.06/0.07/0.10 | 2.71/2.88/3.00 | 0.90/1.69/2.42 | 16.60/17.71/18.82 | 0 | 14.3 |
| NAPA + yolo, 1 cam | stream | 0.06/0.07/0.09 | 0.20/0.33/0.41 | 1.08/1.14/1.20 | **13.96/14.16/14.51** | 0 | 17.0 |
| NAPA + yolo, 2 cams | stream | 0.06/0.07/0.11 | 0.21/0.35/0.45 | 1.10/1.16/1.22 | **14.03/14.45/15.62** | 0 | 26.7 |
| NAPA + yolo, 2 cams | NVJPG | 0.06/0.08/0.10 | 2.76/2.93/3.18 | 1.10/1.16/1.22 | 16.92/17.28/18.43 | 0 | 17.7 |

- Stream saves 2.2 to 2.9 ms at p50 and 0.9 to 2.8 ms at p99 in every layout. It costs about 0.38 of a
  core per camera (+9 to +14 points of the 6 cores for 2 cameras).
- With the likely robot layout (2 tag cameras + yolo11n), NAPA + stream has the tightest tail
  (p99 15.6 ms). With the GPU detector, YOLO's TensorRT work and the tag detector share the GPU, which
  spreads detection's p95/p99.
- Every stream run: 0 drops, checks 0 differ (189 per 2-camera run), 6 to 10 unmatched frames (start-up)
  decoded by the fallback. A live switch to `turbo` and back (`/tmp/spectrum-jpeg-decoder`), 0 drops.
- Max temperature 78 C (yolo runs).

## The streaming decoder (`SPECTRUM_JPEG_DECODER=stream`)

Code: `detector/stream_decode.cc`, called from `decodeMjpegGray` in `detector/GpuDetectorJNI.cc`.
It is the default (`08-select-detector.sh`); `nvjpg` and `turbo` are unchanged and selectable.

1. **Reading the frame early.** A watcher thread per camera opens the camera's `/dev/videoN` a
   second time and mmaps cscore's V4L2 buffers. In kernel 6.8, the vb2 cookie for buffer i is
   offset i << 3 pages. An mmap needs no stream ownership. Nothing is queued, dequeued,
   configured or reset. uvcvideo copies each USB packet into the buffer as it arrives.
2. **Finding the fill point.** 3 ms after a frame is complete (cscore copies it within about
   0.1 ms, p99 0.3), the watcher fills that buffer with 0xFF. The driver refills the buffer at the
   earliest about 2 frames later. Valid JPEG data never contains a run of 0xFF bytes, so the
   first run of 16 0xFF bytes marks how far the new frame has arrived. At start-up, a buffer is
   first wiped 12 ms after its content changes.
3. **Decoding.** libjpeg-turbo with a suspending source decodes every complete MCU row as it
   arrives. Output is brightness (Y) only, with `JCS_GRAYSCALE` and the ISLOW IDCT, the same as
   the `turbo` decoder. Cb/Cr are entropy-decoded (unavoidable, they are interleaved) but get no
   IDCT, upsampling or colour conversion. libjpeg skips those for components a gray output
   doesn't need, so raw-data mode wouldn't save anything more.
4. **Matching and checking.** PhotonVision still takes every frame from cscore. `decodeMjpegGray`
   uses the watcher's image only if the length, the last 32 bytes and 32 bytes from the middle
   match. If the decode is still in its last rows, it waits up to 3 ms. Otherwise it decodes
   normally. Every 64th matched frame is re-decoded whole on a low-priority thread and compared
   byte for byte; one difference turns streaming off until restart. A watcher closes 300 ms
   after its camera stops (mmaps released), and cameras are rescanned every 2 s.

Live, 20 s per run, 8 runs:

| | 1 camera | 2 cameras |
|---|---|---|
| Tail, last byte seen -> image done, urb_packets=4 | **0.11 / 0.19 / 0.20 ms** | 0.11 to 0.12 / 0.19 to 0.21 / 0.20 to 0.22 ms |
| Tail at urb_packets=16 (bytes land in 2 ms chunks) | 0.41 / 0.82 / 0.86 ms | n/a |
| Watcher CPU per camera | 3.15 ms/frame, **38% of a core** | 3.06 to 3.16 ms/frame each |
| Frames matched / missed | 6,058 / 6 (the misses are at start-up) | 12,113 / 6 |
| Byte-for-byte checks against a whole-frame decode | 94 ok, 0 differ | 189 ok, 0 differ |
| Resyncs | 0 | 0 |
| JPEG decode failures (cscore copy corrupted by a wipe) | 0 | 0 |

- **Pixel identity:**
  - Stream output equals the whole-frame libjpeg-turbo decode, byte for byte (the checks above).
  - The NVJPG runs' own checks against libjpeg-turbo were 42 and 52 ok, 0 differ.
  - So stream, turbo and NVJPG give the same Y image. Detection is identical by construction:
    same input pixels, same detector.
- **CPU for 4 cameras:** 4 x 0.38 = 1.5 cores, 25% of the 6 cores.
  - With the GPU detector: about 30% of the CPU in total.
  - With NAPA: about 40% of the CPU (NAPA adds about 1.1 ms x 122 x 4, about 9%, plus its
    threads). That is tight next to object detection and robot traffic, so prefer the GPU
    detector with streaming.
  - Mixing is possible: `stream` for some cameras and NVJPG for the rest would need a
    per-camera limit like `nvjpg:N`. Not built.
- **Can NAPA or the GPU detector start on completed rows?** Not as built. Both find quads over
  the whole image, and a tag can span the last rows. A banded detector with an overlap is a
  rewrite, worth at most about 1 ms.

## The Thriftiest MJPEG stream

- **YUV 4:2:2**: SOF0 baseline with 3 components, Y at 2x1 sampling and Cb/Cr at 1x1. It is not
  Y-only. The sensor is mono, so the chroma is flat, but every MCU still carries chroma blocks
  that the decoder must Huffman-decode.
- **Restart markers**: DRI 80. An MCU is 16x8, so there is one restart interval per 8-pixel row
  band: 100 intervals and 99 RSTn markers per frame.
- **Frame size**: 52.7 / 54.0 / 55.0 KB (p5 / p50 / p95), max 64 KB, on the dark bench scene.
  Exposure 0.5 ms gives 42.5 KB.
- **Arrival**: bytes come evenly over about 8.0 ms (25% by 2.5 ms, 50% by 4.5 ms, 75% by
  6.3 ms). The camera sends the JPEG as the sensor reads it out. USB isn't the limit: the cap
  allows 10 MB/s, and the stream uses 6.7 MB/s.

## urb_packets (now 4 by default)

`usb-sweep.sh`, with PhotonVision stopped and `v4l2-ctl` streaming:

| `urb_packets` (URB length) | hw -> first packet | hw -> DQBUF p50 / p99 | IRQ/s | drops |
|---|---|---|---|---|
| 1 camera, 16 (2 ms, old default) | (URB-coarse) | 8.51 / 9.48 | 497 | 0 |
| 1 camera, 8 (1 ms) | -0.53 | 7.87 / 8.36 | 989 | 0 |
| **1 camera, 4 (0.5 ms)** | -0.78 | **7.49 / 7.73** | 1,973 | 0 |
| 1 camera, 2 (0.25 ms) | -0.41 | 7.74 / 7.86 | 3,941 | 0 |
| 1 camera, 1 | stream won't start (`STREAMON`: ENOMEM) | | | |
| 2 cameras, 16 | | 8.31 / 9.33 | 994 | 0 |
| **2 cameras, 4** | -0.45 | **7.80 / 8.10** | 3,945 | 0 |
| 2 cameras, 2 | -0.57 | 7.61 / 7.73 | 6,072 | 0 |

PhotonVision A/B, 2 cameras, NVJPG, 16 then 4, 2 rounds:

| | p50 / p95 / p99 mid-exposure -> pose | xhci IRQ/s | CPU (of 6) | drops |
|---|---|---|---|---|
| 16, round 1 | 16.80 / 17.78 / 18.51 | 1,000 | 8.3% | 0 |
| 4, round 1 | 16.92 / 17.77 / 19.41 | 2,988 | 9.8% | 0 |
| 16, round 2 | 16.97 / 18.04 / 19.01 | 1,003 | 9.0% | 0 |
| 4, round 2 | 16.53 / 17.16 / 18.59 | 3,011 | 9.5% | 0 |

- The driver hands over frames 0.5 to 0.7 ms sooner with 4 (last packet -> DQBUF stays about
  0.03 ms).
- With NVJPG, the end-to-end p50 changes by -0.15 ms on average, which is inside run-to-run
  noise.
- With the stream decoder, short URBs matter more: the tail drops from 0.41 to 0.11 ms,
  because the last bytes arrive in 0.5 ms pieces instead of 2 ms pieces.
- The cost is about 1,000 more interrupts a second per camera and about +1% CPU.
- 2 is not better than 4 with 1 camera, and is about 0.2 ms better with 2 cameras for about
  3,000 IRQ/s per camera.
- Set live by writing `/sys/module/uvcvideo/parameters/urb_packets`, which takes effect at the
  next stream start. Persisted in `/etc/modprobe.d/92-spectrum-uvcvideo-urb-packets.conf` by
  `scripts/jetson/11-uvcvideo-payload-cap.sh`.
- With 5 cameras, the older sweep found 8 cost more CPU for 0.15 ms. Check IRQ/s and CPU on the
  next 4- or 5-camera bench run.

## Exposure

- The current exposure is 50 (5.0 ms), so mid-exposure is 2.5 ms before the end of exposure.
- At 0.5 ms, mid-exposure is 0.25 ms before the end: **2.25 ms sooner**.
- Changing exposure live with `v4l2-ctl` (exposure 5, no USB reset, restored to 50) didn't move
  the hardware timestamp relative to the first packet (-0.53 ms) or DQBUF (7.61 ms). The readout
  is anchored to the end of exposure, so the whole saving is real.
- The cost is a darker image. Decision margin tracks exposure (TECHNICAL.md), so test tag
  decoding at 0.5 to 1 ms first.

## Recommendations, ranked by expected saving

1. **Stream decoder: -2.4 to -2.6 ms p50 (measured).** It costs 38% of a core per camera. Try
   it on the robot with 2 to 4 cameras and the GPU detector. Fix the 2-camera cscore-handoff p99
   spike first (thread priority or pinning), then consider making it the default.
2. **Shorter exposure, 5 ms to 0.5 to 1 ms: -2.0 to -2.25 ms.** Free, a setting, but it needs a
   tag-decode check first.
3. **`urb_packets=4`** (done, the new default): -0.5 to -0.7 ms at DQBUF, about -0.3 ms of tail
   with the stream decoder.
4. **Measure the camera delay.** It is the largest uncertainty in "mid-exposure to first packet".
   This is about accuracy, not latency.
5. Detection, pose and NT are already small: 1.0 ms or less together.

With 1 to 3, the estimate is 14.0 - 2.25, about **11.8 ms**. Most of what's left is the sensor
readout over USB (8.1 ms) and the assumed camera delay (2.5 ms).
