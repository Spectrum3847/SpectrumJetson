# Streaming NAPA (2026-11-02)

NAPA (`third_party/napa`, v0.5.1, GPL-3.0-only, credit Zachary Wilson) runs **while the frame arrives**. The camera's
rows land top to bottom over about 8 ms (`../latency-breakdown`). The streaming decoder
(`detector/stream_decode.cc`) hands over Y rows in 8-row restart bands. Streaming NAPA thresholds, labels and
decodes each band as soon as it can. When the last row arrives, only a short tail of work is left.

The output is **identical** to `napa_detect`: the same detections, in the same order, with bit-identical
corners. Patch: `patches/napa-03-streaming.patch`. The upstream file is unmodified; `scripts/jetson/napa-src.sh`
applies the patch at build time, like napa-01/02.

## Results (Jetson Orin Nano, full clocks, one thread on core 3, 8-row bands paced evenly over 8 ms)

| Config | Session | Whole-frame NAPA ms p50/p95/p99 | **Stream tail ms p50/p95/p99** | Stream CPU ms p50/p95/p99 |
|---|---|---|---|---|
| min 16 | Q24 (545 frames) | 2.04 / 2.24 / 2.47 | **0.11 / 0.17 / 0.23** | 2.62 / 2.90 / 3.15 |
| min 16 | Q17 (357) | 2.07 / 2.27 / 2.40 | **0.11 / 0.17 / 0.20** | 2.68 / 3.09 / 3.27 |
| far (32 + 16 crops/sweeps) | Q24 | 1.02 / 1.36 / 1.64 | **0.05 / 0.41 / 0.62** | 1.34 / 1.80 / 2.11 |
| far | Q17 | 1.12 / 1.45 / 1.58 | **0.12 / 0.52 / 0.62** | 1.47 / 1.87 / 2.20 |

- **What the columns mean:**
  - Tail: time from the last band's arrival to the results being ready.
  - Whole-frame NAPA: the latency today, since it can only start after the last row. It is measured as
    thread CPU time on the same frames.
- **Latency:** at min 16, about 1.9 ms less after the frame is complete (2.04 → 0.11 ms p50), a 95% cut.
- **Feeding keeps up:** the stream never fell behind the arriving bands ("behind" p99 0.001 ms).
- **Far config tail:** the p95 and p99 come from the far crops. They need the base pass's tags, so they run
  in `Finish()`. The base pass and the sweep band are streamed.
- **CPU per frame is about 28-30% higher** (min 16: 2.04 → 2.62 ms p50; far: 1.02 → 1.34 ms). The extra work:
  - each level keeps its own buffers (whole-frame NAPA rakes each coarser level in place);
  - blob boxes are updated per row for every blob;
  - extreme points are rescanned for each candidate;
  - every candidate's back end runs, including ones a finer level would have covered.

  At 2 cameras this is a small share of the CPU. Speculative-skip and per-level buffer reuse could win some of
  it back.
- **What is left when the last row arrives** (`lag`): per level, the rows still to threshold.
  - min 16: L0 32 rows, L1 16, L2 8, L3 8.
  - far: 11 and 6 level rows.
  - Why: the last 64-row noise region has to be complete before the last bands can be thresholded, and the
    coarse levels need their source rows.

Raw logs: `results/timing.log`, `results/identity.log`.

### Identity (all 13 TXMAN1 sessions, min 16 and far)

- **In process:** every frame's stream result was compared field by field with `napa_far::Detector::Detect()`,
  corners compared as raw doubles. 0 mismatches.
- **`same.py` on the CSVs:**
  - `whole16` vs `stream16`: IDENTICAL, 44,954 sightings.
  - `wholefar` vs `streamfar`: IDENTICAL, 43,057 sightings.
  - `stream16` also matches the earlier `napa16` replay outputs.
- **Reruns:** 20 frames, all in one session (far, Q17 0002), were reprocessed because the noise-floor guess
  missed (see the design). The other 25 runs had none. The timing runs had none.

## Design

API (`napa_core.h`):

```c
napa_stream *napa_stream_create(napa_detector *det);   // borrows det (family, slack, scratch)
int napa_stream_begin(napa_stream *, const uint8_t *img, int w, int h, int stride, const napa_params *);
int napa_stream_feed(napa_stream *, int rows);         // rows [0, rows) of img are valid now
int napa_stream_finish(napa_stream *, napa_detection *out, int max_out);   // == napa_detect
```

`napa_far::Detector` adds `Begin()`, `Feed()` and `Finish()`, which return exactly what `Detect()` does. The base
pass and a scheduled sweep band are streamed (the sweep has its own detector and stream). Tracking crops run in
`Finish()`.

Per pyramid level, NAPA's coarse-to-fine downscaled levels are all kept:

1. **Rake:** a level row is built once its source rows exist.
   - The stride-1 level is the frame itself.
   - L1 takes every second sample of frame row 2y.
   - Coarser levels take every second sample of the previous level's row 2y.
   - On a noisy frame, the box re-rake reads the frame rows of its kernel.
2. **Noise floors:** a region row (64 level rows, sampled every 8th) gets its floors as soon as its last
   sampled row is in.
3. **Tiles:** a tile row's min/max is computed once its 4 rows are in. Band ty is thresholded once tile row
   ty+1 (the 3x3 neighbourhood) and its floor region row are ready. That is a lag of 1-2 tile rows, more at a
   region boundary.
4. **Runs and union-find:** runs are extracted per row and joined across rows top-down with NAPA's exact merge
   loop. A blob's box and count are kept at its root, and merged when roots join.
5. **Finalize:** a blob with no run in the next labeled row is final. It goes through NAPA's candidate filter.
   Its extreme points are rebuilt from its runs in raster order, so they are identical. Then rough quad,
   border probe, first fit, early decode (with the quiet-zone rescue), refinement, final decode, side repair
   and the clipping bias run immediately, and the result is kept.
6. **`finish()`:** the kept candidates are replayed per level in NAPA's order (root run index), with the
   gates that depend on order applied there: `covered`, `failed_before` / `remember_failure` and
   `already_found`.

That is why the results are identical: everything per blob is a pure function of the blob and the image, and
everything order-dependent is replayed in order.

**The one non-causal input** is each floor-measuring level's frame-wide floor. It is the median over the whole
level, which caps every region's floor and decides the noisy-frame box re-rake. The stream assumes the
previous frame's values. At `finish()` it checks the frame's own values: the effective floor of every region,
the noisy decision, and L1's re-measure decision. If any of them differs, it reprocesses the frame with the
correct values (up to 3 times, then plain `napa_detect`; never needed). A camera's noise floor is stable, so
this happened on 20 of about 70,000 frames.

**The candidate body is a copy** of `napa_detect`'s per-blob code; refactoring upstream's would break
`tests/napa-profile/napa-profile.patch`. On a NAPA upgrade, re-sync it and rerun `run.sh identity`.

Not done: (3) the wider threshold context from a tile-statistics pyramid was skipped for time.

## Files

- `napa_stream_replay.cc` is the harness: identity mode and paced timing mode.
- `build.sh` builds it (Jetson), or compile-checks with a cross toolchain.
- `run.sh identity|timing` runs the checks. Timing sets clocks full and restores auto, and pins to core 3.

Reproduce on the Jetson:

```
build.sh
run.sh identity
python3 ../napa-profile/same.py /data/scratch/txman1/replay whole16 stream16   (and wholefar streamfar)
run.sh timing
```

## In PhotonVision (2026-11-02, fork `photonvision-104`, off by default)

**Switch:** `SPECTRUM_NAPA_STREAM=1` in the PhotonVision drop-in, or `napaStream` in HardwareSettings
(the variable wins). It needs the streaming decoder (`SPECTRUM_JPEG_DECODER=stream`, the default) and a
pipeline with "Tags on CPU (NAPA)". The NAPA settings are unchanged: min tag 16, hamming 1, early slack 2,
far search on or off. Pose, multi-tag and Tag FPS max work as before.

### How it is wired

- **`libspectrum-stream.so`:** the streaming decoder (`detector/stream_decode.cc`) is now its own small
  library, with libjpeg-turbo only and no CUDA. The GPU library links it. The NAPA library opens it with
  `dlopen` when streaming is on, and gets the same copy. A CPU-only machine builds it with
  `07-build-napa-detector.sh`. Its plain C API is in `stream_decode.h`:
  `spectrum_stream_decode_gray`, `_take` and `_detach`, plus a `spectrum_band_sink` with
  begin, feed, finish and free_result.
- **Per camera:**
  1. The first `detectStreamed()` attaches the handle's sink to the watcher that decoded the frame.
  2. From the next frame on, the watcher thread calls `Begin()` at the frame's SOI, with its own gray
     buffer.
  3. It calls `Feed(rows)` after every `jpeg_read_scanlines` (8-row bands), and `Finish()` when the last
     row is in.
  4. The tags are kept with the decoded frame.
  5. `detectStreamed()` takes them, about 0.03 ms of JNI.

  The pipeline's Mat is a copy of the decoded image, so `take` finds the frame by pointer on the decoding
  thread or, failing that, by content (every 16th row compared).
- **Each sink has its own `napa_far::Detector`.** Its config is copied from the handle and applied at the
  next `Begin()`.
- **Fallbacks:** a frame that wasn't streamed (decoder miss or mismatch, sink not attached yet, a frame
  skipped as below) gets whole-frame NAPA on the handle's detector, as before.
  - The log line every 10 s counts both kinds: `NAPA streaming: N streamed, M whole-frame ...`.
  - The watcher's line adds `band sink fed N frames (skipped K for the frame-rate cap), finish p50 ...`.
- **Tag FPS max and idle mode:** `VisionRunner` passes when it next takes a frame (`FrameRateCap.nextWantedNanos`).
  The watcher doesn't feed a frame that will be complete more than a frame period + 1.5 ms before then.
  - At Tag FPS max 50 with 2 cameras, 16% of frames were skipped and 0.4% fell back to whole-frame. The
    rule is conservative; a tighter one could skip about half of the frames.
- **Identity, live:** every 64th streamed frame, the same Y image is re-detected whole on a nice-19 thread
  and compared field by field, corners as raw doubles. Differences are logged (`differ`). With far search
  on, the check is skipped and counted: tracks and the sweep schedule are per detector.
- **Thread placement:** NAPA runs on the camera's watcher thread. `SPECTRUM_STREAM_CPUS=camera` (new) pins
  each watcher to the cores of the thread that takes its frames, which is its VisionRunner core with
  `photonvision-102`. The default stays `all`; see the results below.
- **CPU-only (SystemCore):** `USBFrameProvider`'s CPU-decode path calls `NapaDetectorJNI.streamDecodeGray`
  first when streaming NAPA is on. That starts the watchers without the CUDA library. It compiles, but has
  not been run on a SystemCore.

### Live results (bench Jetson, clocks full, 2 Thriftiest Cams at 122 fps, urb_packets=4, stream decoder both sides)

`tests/latency-breakdown/run.sh 20 napa-1 napastream-1 napa-2 napastream-2 napayolo-1 napastreamyolo-1
napayolo-2 napastreamyolo-2`, 2 rounds of 20 s. "yolo" is AprilTag + Object with yolo11n at Object FPS max
30. **The bench has no tags**, so NAPA's work is the no-tag work (1.07 ms whole-frame). Times are ms
p50 / p95 / p99. Each cell shows round 1, then round 2.

| Condition | mid-exposure → pose | tail: last packet → tags | CPU % of 6 cores | drops |
|---|---|---|---|---|
| NAPA, 1 cam | 14.30/14.53/15.02 · 14.18/14.49/15.06 | 1.44/1.63/2.21 · 1.45/1.67/2.23 | 14.1 · 14.7 | 0 |
| **stream, 1 cam** | **13.36/13.58/14.20 · 13.24/13.45/14.45** | **0.52/0.76/1.39 · 0.53/0.79/1.80** | 14.0 · 20.4 | 0 |
| NAPA, 2 cams | 14.26/14.57/15.75 · 13.94/14.18/15.14 | 1.49/1.76/2.90 · 1.47/1.68/2.57 | 25.5 · 24.6 | 0 |
| **stream, 2 cams** | **13.31/13.58/15.04 · 13.00/13.26/14.34** | **0.53/0.88/2.32 · 0.53/0.87/1.87** | 28.8 · 27.9 | 0 |
| NAPA + yolo, 1 cam | 14.33/14.58/15.09 · 14.07/14.29/14.77 | 1.48/1.71/2.26 · 1.47/1.66/2.04 | 15.3 · 16.6 | 0 |
| **stream + yolo, 1 cam** | **13.14/13.34/14.52 · 13.00/13.19/13.88** | **0.55/0.80/1.89 · 0.53/0.75/1.38** | 16.0 · 17.3 | 0 |
| NAPA + yolo, 2 cams | 14.26/14.54/17.33 · 14.15/14.49/17.09 | 1.53/1.78/4.67 · 1.51/1.75/4.21 | 26.6 · 29.9 | 0 |
| **stream + yolo, 2 cams** | **13.29/13.57/15.48 · 13.07/13.43/14.62** | **0.59/0.90/2.80 · 0.57/0.90/2.02** | 31.4 · 31.2 | 0 |
| stream, 2 cams, `SPECTRUM_STREAM_CPUS=camera` | 13.12/13.33/14.11 | 0.53/0.79/1.53 | 26.9 | 0 |
| stream + yolo, 2 cams, `camera` | 13.06/14.54/15.38 | 0.57/2.08/2.85 | 28.7 | 0 |

- **Latency:** about 0.95-1.2 ms less at p50 in every condition, and 0.8-2.5 ms less at p99. The largest
  p99 cut is with yolo on 2 cameras (17.3 → 15.0).
  - The tail after the last packet drops from about 1.45 to about 0.53 ms.
  - The tail that is left is mostly the decoder's own: its last rows and the 1 MB copy, 0.30 ms p50, up
    0.1 ms from feeding the last bands. NAPA's `Finish()` takes 0.006-0.007 ms. Detection in the pipeline
    is 0.04 ms (JNI and the content match).
- **CPU:** about +1 to +3 points of 6 cores at 2 cameras (24.6-25.5 → 27.9-28.8; with yolo 26.6-29.9 →
  31.2-31.4). That is the stream's extra ~30% NAPA work (above), plus the first frames' whole-frame
  detects. The 1-camera numbers are within run-to-run noise.
- **Max temperature:** 78.8 C.
- **Identity:** with no cap, every frame was streamed (1 whole-frame fallback in all runs). Every 64th
  frame was checked live, 94 checks per camera per run: **0 differ** in every run.
  - Because the bench has no tags, the same `Begin/Feed/Finish` path was also replayed on TXMAN1 at the
    decoder's band shapes: 16-row and 8-row bands, min 16 and far. The first session of each of the 6
    matches (15,101 frames, 13,422 sightings at margin ≥ 15) gave **0 mismatches** and no reruns. The
    full 13-session identity is above.
- **Placement:** the `camera` pinning was no better: equal without yolo, and worse at p95 with yolo
  (2.08 vs 0.90 ms tail), because the watcher shares the core with the VisionRunner. The default stays
  `all`.

### SystemCore (Raspberry Pi CM5, 4x A76, CPU path)

- **Builds:** the patch is plain C99 with NEON or a scalar fallback, and has no CUDA or Jetson code. It
  compile-checks with WPILib's `aarch64-bookworm-linux-gnu-gcc`, both through `build.sh` (cross mode) and as
  the full `libspectrum-napa-apriltag.so` (`07-build-napa-detector.sh`). `napa_test` has to be run on the
  target.
- **Stream decoder:** done. `libspectrum-stream.so` is built by `07-build-napa-detector.sh` when the
  target has `jpeglib.h`, and is opened by the NAPA library at run time.
- **Coarser USB transfers:** stock `uvcvideo` delivers in larger URBs than our patched one, so bands arrive in
  bigger chunks and the tail grows by about one URB's worth of rows.
- **More overlap at lower fps:** the camera streams each frame more slowly (longer line time), so more of
  NAPA's work hides inside the arrival window.
- **Expected tail:** similar or smaller relative to the frame. The CM5 is slower per row, but the tail is
  only the last 32 L0 rows plus the back end. Measure there with `run.sh timing` (it needs `taskset` and a
  Rewind session).

## Recommendation

- **Turn streaming NAPA on by default on the NAPA path.** It saves about 1 ms at p50 and up to 2.5 ms at
  p99. Results are identical (live checks and replay), and there were no drops. It costs about 1-3 points
  of the 6 cores at 2 cameras.
- **Before flipping it, run 2 checks:**
  - a run with real tags in view (pose path, live identity counters);
  - one SystemCore run of the CPU-only path.
- **Still open:**
  - stream the far crops (above);
  - a tighter Tag FPS max skip rule.
