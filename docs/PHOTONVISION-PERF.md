# PhotonVision CPU, latency and GC on the SystemCore (pv-perf, 2026-11-06)

Where PhotonVision's own cost goes on the SystemCore (Pi 5 / CM5, 4x Cortex-A76, LimelightOS, Java 25 Temurin,
G1, `-Xmx512m`) when it runs the fast path (`docs/SYSTEMCORE-PV-FASTPATH.md`: streaming luma decode + streaming NAPA
+ native pose + native publish), what was changed, and what to do next. photonvision-120..124 are merged: fork
`sc/mjpeg-napa` 1d2b5021, mirrored in SpectrumJetson `sc/mjpeg-napa` f8327b0. The later items (stream preview,
idle Java rate, Rewind) are on fork `sc/pv-perf` only; see "Round 2" at the end.

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

The first round's "recommended next" list above was worked through in round 2 (below): the native-side items
(tag quality, dark frames, native backend) went to the builder, the rest were tried here.

## Round 2 (2026-11-06 evening): merged, the recommended items, Rewind, AOT cache

Bench state: dark scene (lights off, user remote), so all runs use the **Swyft** (its watcher works in the dark;
the Thriftiest's didn't until the builder's 84a229d), one camera at 120 fps, native publish, ondemand, 25-30 s,
no web UI open (PhotonVision on port 5881), detection-free. The SystemCore rebooted twice during the evening (an
under-voltage at 19:03 during a two-camera run; a kernel panic from the old SD card hanging I/O at 19:27); after
that, test jars, logs and Rewind recordings were kept in RAM (`/dev/shm`).

### Merged

photonvision-120..124 fast-forwarded onto fork `sc/mjpeg-napa` (1d2b5021) and mirrored in SpectrumJetson
`sc/mjpeg-napa` (f8327b0). Dark A/B, installed build (fork 54922480) vs the same plus 120-124 and the round-2
items: **32.7 / 32.6% -> 29.1-29.5% of a core, 6340 -> 4880-4965 wake-ups/s**, capture -> received p99
10.88-11.00 -> 10.82-10.88 ms (`tests/pv-perf/ab.sh`, `dC-*`). 120-124 alone: 29.3%.

### The round-2 items (fork `sc/pv-perf`, not merged)

| Item | Commit | Measured | Verdict |
|---|---|---|---|
| Identity checks every 1024th frame (stream re-decode, NAPA re-detect; `SPECTRUM_STREAM_CHECK_EVERY`, `SPECTRUM_NAPA_CHECK_EVERY`) | SpectrumJetson sc/pv-perf (`stream_decode.cc`, `NapaDetectorJNI.cc`) | 29.3 -> 29.5% (noise) in the dark, where a whole-frame decode is cheap | keep; ~1 point lit by the first round's estimate, unmeasured lit |
| Java pipeline at 10 fps while no UI and no stream viewer (`SPECTRUM_NATIVE_PUBLISH_IDLE_FPS`) | f9868494 | 29.5 -> 29.1% (noise; C2 alone moves 1-4 points) | small; merge only if the legacy NT entries at 10 Hz are fine |
| Stream preview: a 1/2 or 1/4-size picture from the decoder for a watched stream instead of the 1 MB copy | 2bc0e468 + SpectrumJetson `spectrum_stream_preview` | two viewers: 33.8 / 34.3% without, 34.2 / 33.7% with; decoder 1.5 -> 1.2%, stream thread 1.25 -> 1.05% | **not worth it**: after 124 the copy happens 30 times a second (~0.3% of a core); most of a viewer's cost is cscore's MJPEG encode/serve (2.4%) and the stream thread. Leave unmerged |
| Dashboard: back off failed stream retries (0.1 s doubling to 5 s) | bce4e514 | client lint/prettier clean | merge (client only) |
| Rewind recorder: grab only around kept frames, fdatasync | 340af6cc | Rewind thread 1.2% / 155 wake-ups/s -> 1.0% / 113 (one run each) | small; merge with the native Rewind writer in mind |
| Rewind defaults scaled to a small disk | 5509a54e | functional (below) | **merge**: without it Rewind never records on the SystemCore |

With a stream viewer the first round's +6-7 points (lit Thriftiest) are now ~+4.5 points (dark Swyft: 29.5 ->
~34%), most of it cscore's encode and serve; a cheaper picture doesn't change that much.

### Rewind on the SystemCore

- **Storage:** this bench SystemCore records to `/opt/photonvision/rewind` on `/` = `mmcblk0p5`, a 6.8 GB ext4
  root (A/B layout, p5/p6 7 GB each) on a **32 GB SD card** (`/sys/block/mmcblk0/device/type` = SD, so no eMMC
  `life_time`/`pre_eol_info` wear estimate); ~15 GB of the card is unpartitioned. Free space varied 0.9-2.6 GB
  during the day. The SD card is slow: with nothing recording it was busy writing 63% of the time for 0.46 MB/s
  (journald, logs; 17 KB writes), and it hung I/O > 30 s once (the 19:27 panic). Rewind on a real SystemCore
  needs its eMMC (and ideally a partition of its own); measure that device again.
- **Defaults:** quota 100 GB, keep 15 GB free, stop below 7.5 GB: on a 6.8 GB root Rewind refuses to record at all
  ("Rewind: disk nearly full, recording stopped" at every start). 5509a54e scales the defaults when there is no
  settings.json: quota = half the filesystem, keep 10% (at least 0.5 GB) free -> 3.4 GB / 0.68 GB (stop below
  0.34 GB) on this root. A 1280x800 lit Thriftiest frame is ~50-60 KB: one camera at 30 fps is ~1.6 MB/s, two are
  ~3.3 MB/s, ~0.5 GB for a 2.5 min match, so a 3.4 GB quota holds ~6 matches of two cameras. Pull after every match.
- **Cost (dark Swyft, 30 fps kept of 120, recordings in RAM, 25 s, `tests/pv-perf/rewind-ab.sh`):** off 32.3% of a
  core; on 35.0% (the `Rewind-swyft` thread 1.2%, the rest JIT noise); on with 340af6cc 30.1% (thread 1.0%).
  0.95 MB/s written (31 KB dark frames, 30.0 fps kept, 0 dropped). Latency p99 10.89 (off) / 11.04 / 10.85 ms:
  no effect on the native publish. fdatasync every 2 s per camera (video, then index).
- **Write pattern:** one `write()` per kept frame (the whole JPEG, 20-200 KB) plus a ~60-byte index line through a
  BufferedWriter; both fsync'd every 2 s, so the device sees the page cache's writeback: large sequential writes
  every 2 s per camera. Not measured on the SD itself (kept in RAM for the card's sake).
- **Cheap wins left:** the recorder runs at nice 10 already; cscore still copies each kept JPEG once into the
  recorder's buffer (unavoidable from Java). The builder's native backend can write the JPEG straight from the
  V4L2 buffer (its Rewind ring writer, e0c8ca2) and drop the Java thread.

### Java 25 AOT cache (JEP 483/514/515; `tests/pv-perf/aot.sh`)

PhotonVision runs `/usr/bin/java -Xmx512m -jar /opt/photonvision/photonvision.jar -n` (Temurin 25.0.2). A
training run (`-XX:AOTMode=record -XX:AOTConfiguration=pv.aotconf`, 40 s with the camera, written at JVM exit), then
`-XX:AOTMode=create` (no camera; 42.5 MB cache), then start-up with and without `-XX:AOTCache=pv.aot`, the first
25 s from 1 s after `systemctl start` (2 runs each):

| | without | with the cache |
|---|---|---|
| PhotonVision CPU, first 25 s | 40.4%, 40.4% | 29.9%, 30.3% |
| JIT (C1 + C2) | 7.9%, 7.9% | 2.6%, 3.0% |
| main thread (class loading, start-up) | 5.3%, 5.2% | 0.4%, 0.5% |
| web server up | 2.86, 2.82 s | 1.63, 1.65 s |
| first decoded frame | 2.74, 2.71 s | 1.92, 2.03 s |
| results published in the window | 2826 | 2913 |

The cache belongs to one jar and one JVM build (a different jar or JDK makes the JVM ignore it with a warning, not
fail). Install: after copying a new jar, run the training run (or a short headless start) and the create step, put
the cache next to the jar (`/opt/photonvision/photonvision.aot`, ~43 MB) and add `-XX:AOTCache=...` to ExecStart.
Not measured: steady state after minutes (the JIT finishes either way).

### Next

- Builder: the native camera backend (owns `USBFrameProvider`, `VisionSourceManager`, `NativeCameraSource`), its
  Rewind writer, and a proper eMMC/partition plan for recordings.
- Merge into `sc/mjpeg-napa` (with the builder's OK on the files it owns): bce4e514 (client), 5509a54e (Rewind
  defaults), the identity-check interval; optionally 340af6cc and f9868494. Not 2bc0e468 (preview).
- AOT cache in `install-photonvision.sh` (training + create per jar).
- Lights on: the lit A/B for the identity-check interval and the idle Java rate, and nt_check identity of the
  merged build.
