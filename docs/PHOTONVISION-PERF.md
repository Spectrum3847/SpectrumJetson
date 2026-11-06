# PhotonVision CPU, latency and GC on the SystemCore (pv-perf, 2026-11-06)

Where PhotonVision's own cost goes on the SystemCore (Pi 5 / CM5, 4x Cortex-A76, LimelightOS, Java 25 Temurin,
G1, `-Xmx512m`) when it runs the fast path (`docs/SYSTEMCORE-PV-FASTPATH.md`: streaming luma decode + streaming NAPA
+ native pose + native publish), what was changed, and what to do next. Fork branch `sc/pv-perf` (on
`sc/mjpeg-napa` at 22579eea = photonvision-112), mirrored as `patches/photonvision-120..124`.

## How it was measured

`tests/pv-perf/measure.sh` (on the SystemCore, under `/tmp/camera.lock`): one camera (Thriftiest SJ-05,
1280x800 MJPEG 120 fps, exposure 0.2 ms gain 128, min tag 32), our uvcvideo with `urb_packets=2`, ondemand
governor, 45 s warm-up then 30 s of JFR (profile settings + `jdk.CPUTimeSample`), GC log, per-thread CPU ticks and
context switches from `/proc` (named from `jcmd Thread.print`; `tests/pv-perf/threadcpu.py`), bytes written, and
`nt_probe` (capture -> received on the same SystemCore). `tests/pv-perf/ab.sh` alternates jars (base, perf, base,
perf) with PhotonVision's UI on port 5881 so a browser left open on 5880 can't attach. `tests/pv-perf/jfrsum.py`
summarizes JFR (allocation by stack, CPU samples by thread). `tests/pv-perf/viewer.py` is a headless MJPEG stream
viewer. CPU is % of one core; the Pi has 4.

Caveats: the scene went dark at ~18:05 (room lights off, user remote), so only the runs before that have tags
in view; dark frames also stop the streaming watcher (below), which changes the path. Lit and dark numbers are
never compared with each other here.

## Cost table (lit, one camera, fast path with native publish, no UI, no stream viewer)

PhotonVision process total **43.2%** of a core (base, 2 runs), 6250 context switches/s.

| Rank | What | CPU (% of a core) | Wake-ups/s | Notes |
|---|---|---|---|---|
| 1 | Streaming watcher `SpectrumStream` (native: JPEG luma decode + streaming NAPA + pose + NT publish, waits per URB) | 36.2 | 3900 | the real work; 2.8 ms CPU/frame at 120 fps |
| 2 | JIT (C2 + C1) | 2.5-3.5 | 50-130 | still compiling 45-75 s after start |
| 3 | Java pipeline thread `VisionRunner` at the 30 fps Java cap (UI, health, legacy NT entries) | ~1.7 (JFR) | 280-490 | 4.4% when it runs at 120 fps (Java publish) |
| 4 | `SpectrumDecoder` (cscore sink copy of each JPEG, streamed-frame match, Mat/RawFrame per frame, 1/64 re-decode check) | 1.5 | 240 | handled all 120 frames/s for a 30 fps consumer |
| 5 | cscore native threads (V4L2 dequeue + per-frame JPEG copy) | 1.0 | 280-420 | |
| 6 | Timed tasks (telemetry via oshi, field map 5 Hz, excluded tags 5 Hz, camera list 1 Hz) | 0.7 | 75 | camera list enumerated every USB camera each second for the UI |
| 7 | Stream thread `StreamRunnable` polling with `sleep(1)` | 0.7 | 975 | did nothing: no viewer |
| 8 | UI result/metrics/log serialization with no UI open | 0.2 | 16 | |
| 9 | GC (G1, young every ~10 s, 5-6 ms pause) | ~0.05 | - | 7.3 MB/s allocated (2.5 MB/s VisionRunner); pauses don't reach the native publish |

With a browser on the dashboard (websocket, permessage-deflate) add `DataChangeEventDispatchThread` 0.6-0.9% +
Jetty 0.5% (+ the USB bandwidth poll's sysfs survey every 1.5 s on the Camera Matching / USB pages). With a stream
viewer, see "Streams" below (+6-7 points).

**Java publish (native publish off, same lit scene):** 46.0%; VisionRunner runs every frame (4.4%), 13.7 MB/s
allocated (VisionRunner 9.1 MB/s, ~75 KB a frame: TrackedTarget/OpenCV Points and Mats with Cleaners, WPILib
geometry/EJML), young GC every 5 s with **6-16 ms pauses on the publish path** (loop max 20 ms vs p99 9.3 ms).

PhotonVision vs sc-vision is now mostly the watcher (36% here vs sc-vision's ~26-27% of a core for the same frames
in `SYSTEMCORE-PV-FASTPATH.md`): V4L2 + cscore instead of usbfs, the per-URB driver wake, and PhotonVision's copies.
Everything on the Java side together is ~6-7% of a core per camera.

## Changes (fork `sc/pv-perf`)

| Patch | Commit | What |
|---|---|---|
| photonvision-120 | 7da26c1e | `StreamRunnable` waits on its frame lock instead of `sleep(1)` polling |
| photonvision-121 | 88c08c62 | `FrameRateCap` parks to the due time in one go (was 1-5 ms slices) outside idle mode |
| photonvision-122 | 85b2475a | The decoder thread decodes only around the frames the camera loop takes (its cap, incl. the native-publish 30 fps Java cap), as it already did for idle mode |
| photonvision-123 | 24d1ef12 | No web-UI work while no UI is connected: no 10 Hz UI result maps, no 1 Hz USB camera enumeration, no msgpack serialization for nobody |
| photonvision-124 | e511dba8 | While native publish is on, the decoder decodes one frame per Java take (newest, 3 ms before it) instead of every frame of the take window |

Behaviour is unchanged: the same frames are published natively (3638-3640 results in 30 s, all with tags, same
corners/ambiguity in `nt_probe`), the UI still gets everything once it connects, and with no frame-rate cap nothing
in the decoder changes.

### Measured (lit, native publish, no UI, 2 x 30 s each, 120-123)

| | base (fork 7218a6de) | perf (120-123) |
|---|---|---|
| PhotonVision CPU, % of a core | 43.5, 42.8 (mean 43.2) | 42.7, 42.0 (mean 42.4) |
| context switches/s | 6232, 6276 | 5048, 5044 |
| StreamRunnable | 0.7%, 975/s | 0, 0 |
| SpectrumDecoder | 1.5%, frames matched 120/s | 1.25%, ~87/s |
| UI dispatch thread | 0.2% | idle |
| capture -> received p50 / p95 / p99 ms | 9.18 / 10.10 / 10.38 and 9.17 / 10.12 / 10.33 | 9.12 / 10.09 / 10.33 and 9.02 / 10.05 / 10.33 |

-0.8 points of a core per camera (-2%) and -19% wake-ups; latency unchanged.

### Dark scene (A/B on fork 22579eea vs 120-124, after the libs of photonvision-112 were installed)

The streaming watcher can't follow dark frames ("stream decode: stopped watching /dev/video2" 38 times in 75 s,
"0 streamed, 1213 whole-frame"), so every frame is decoded and detected in Java (`CpuMjpegDecode` + whole-frame
NAPA) at 120 fps and native publish is off. That is the Java path, not the fast path: base 32.1 / 32.3%, 2500
switches/s; perf 30.3%, 1590/s (one valid run; the other was stopped from outside mid-run). With an output-stream
viewer: base 33.9%, perf 32.3%. Robot latency the same within run-to-run noise (p50 ~11.9-12.1 ms on this reference).
photonvision-124 couldn't be measured lit (it only acts while native publish is on); it's expected to cut the decoder's
frames from ~87/s to ~30/s and, with a stream viewer, two of every three 1 MB copies.

## Streams and the web UI

**Streams (lit, perf jar, `viewer.py` reading the MJPEG stream; stream frames are small: 2.3 KB input, 3.5 KB output
at 30 fps, i.e. the dashboard's divided resolution):**

| | PV CPU | what grows |
|---|---|---|
| no viewer | 42.4% | |
| input stream (1181) | 48.9% | SpectrumDecoder 1.25 -> 3.9% (the full 1 MB gray copy is switched on for every decoded frame while anyone watches), stream thread 2.0% (resize, gray->BGR, draw), cscore encode +0.8%, JIT +1% |
| output stream (1182) | 49.6% | same |
| both | 49.8% | cscore +1.7% |

So one watched stream costs ~6-7 points of a core per camera, and the robot sees it: capture -> received p99 +0.3 to
+0.45 ms (10.33 -> 10.63-10.80). Most of it is the 1 MB copy of a frame that is then shrunk to a few KB.
Nothing is encoded when nobody watches (photonvision-15 + 48 hold: no viewer = no stream work, and with 120 the
stream thread no longer polls either).

**Web UI (dashboard open in a browser, dark scene, perf jar):** 33.4% vs 30.3% without (+1.1 of that is UI threads:
websocket dispatch with permessage-deflate 0.6%, Jetty 0.5%; the rest JIT noise); robot latency within noise
(p50 12.08 vs 11.84, p99 14.0 vs 13.76). PhotonVision wrote 63 KB/s with the UI open (NT + websocket + logs).
Websocket traffic per camera: pipeline results 10 Hz (one map per target), metrics 1 Hz, camera list 1 Hz, every log
line; before 123 all of it was also built and serialized with no UI open (results and camera list) or serialized
for nobody (everything).

**Client:** polling while a page is open: USB bandwidth survey every 1.5 s (Camera Matching and USB pages; each one
reads every USB device's descriptors in sysfs, ~0.3 MB/s of allocation on the server), tag contrast 1 s (Input tab),
robot state 2 s (dashboard), Rewind/firmware cards 2-3 s, Ready view 30 s. Streams already disconnect in a hidden tab
(photonvision-48). One thing to fix: `photon-camera-stream.vue` retries a failed stream every 100 ms forever
(`handleStreamError`), a reconnect storm against cscore when the stream can't load (seen in the bench browser pane,
where the stream image never loaded). Rendering cost could not be measured (the pane's tab was in the background,
rAF throttled to 1 fps).

## Other findings

- **Tag quality doesn't pair with native-published results.** `tagQuality` still goes out with the Java frame's
  sequence ID at 30/s while `rawBytes` carries the native counter; robot-side `TagQualityMatcher` pairs by sequence
  ID, so on the fast path results get no quality. Same for Rewind's vision log (Java results only). Logged for the
  builder in PVPERF-LOG.
- **Dark/flat frames stop the streaming watcher** (restarts every ~2 s, every frame falls back to Java whole-frame
  decode). Probably the same as the tester's "watcher stops/restarts, 72% not stream-decoded" (FINDINGS ~886).
- **Identity checks:** `stream_decode.cc` re-decodes every 64th matched frame whole on a fresh thread (copy of the
  JPEG + 1 MB gray, libjpeg-turbo decode), NAPA re-detects every 64th streamed frame: ~2 checks/s, ~1% of a core.
  Fine for validation; make it every 1024th (or off) for matches.
- **JIT:** C2 still uses 2.5-4% of a core 45-75 s after start, more than the whole Java pipeline.

## Recommended next (not done)

| What | Expected gain | Risk |
|---|---|---|
| Stream frames from the watcher: a quarter-size (or the 1/8 DC-coefficient) gray image written natively into a single-slot buffer only while someone watches, instead of the 1 MB copy + Java resize + gray->BGR | most of the +6-7 points a watched stream costs, and its +0.3-0.45 ms p99 | low; native change in `stream_decode.cc` |
| Serve the camera's own JPEG for the input stream (RawSource, MJPEG passthrough) | the encode and resize, but 150-250 KB a frame at full size: only for a wired laptop, not the robot radio | low |
| Native-publish mode: Java pipeline at 5-10 fps while no UI or stream viewer (`SPECTRUM_NATIVE_PUBLISH_JAVA_FPS`), health and legacy NT entries from the native side | ~1.5-2 points per camera | low; legacy NT entries (targetPose, hasTarget) update slower |
| Publish tag quality natively with the same sequence ID | correctness | low |
| Fix the watcher on dark/flat frames | keeps the fast path in low light (else 120 fps Java fallback) | medium |
| Identity checks every 1024th frame in production | ~1 point | none |
| Java 25 AOT cache (`-XX:AOTCacheOutput` training run, then `-XX:AOTCache`) | C2 2.5-4 points for the first minutes, faster start | low; needs a training run per jar |
| Java-publish path: fewer per-frame objects (TrackedTarget Points/Mats/Cleaners, WPILib geometry), or ZGC | removes the 6-16 ms GC pauses on the publish path | medium; only matters with native publish off |
| `photon-camera-stream.vue`: back off stream retries (1 s, 2 s, ... ) | no reconnect storm | none |
| Fully native camera backend with Java for UI only (usbfs capture as in sc-vision) | to sc-vision's ~26-27% from ~42%: ~15 points per camera, and its p99 | high; the design in SYSTEMCORE-PV-FASTPATH.md |

Needs from the user: none. No tools were downloaded (JFR, jcmd, `/proc` only; async-profiler wasn't needed).
