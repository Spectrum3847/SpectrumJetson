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

## Wiring into PhotonVision (not done)

1. The stream decoder (`detector/stream_decode.cc`) produces Y in 8-row restart bands. Per camera:
   - at the frame's start, call `Begin(frame_y_buffer, w, h, stride, t)`;
   - after each decoded band, call `Feed(rows_done)` on the decoder thread, or hand it to a per-camera NAPA
     thread;
   - at the end of the frame, call `Finish()`.

   The Y buffer must stay valid until `Finish()`. `Detect()` stays as the non-streaming path.
2. **JNI shape:** the cleanest option is to do the whole streaming loop natively, so no Java calls happen per
   band: the native frame-grab-and-decode loop calls `Feed` itself, and Java sees one
   `detectStreamed(handle) -> tags` per frame. A smaller step is `beginFrame(handle, ...)`,
   `feedRows(handle, rows)` and `finishFrame(handle)` natives on `NapaDetectorJNI`, called from wherever the
   decoder is driven.
3. Settings stay as today. Streaming changes no results, so it can be a plain on/off option ("stream NAPA with
   decode").

### SystemCore (Raspberry Pi CM5, 4x A76, CPU path)

- **Builds:** the patch is plain C99 with NEON or a scalar fallback, and has no CUDA or Jetson code. It
  compile-checks with WPILib's `aarch64-bookworm-linux-gnu-gcc`, both through `build.sh` (cross mode) and as
  the full `libspectrum-napa-apriltag.so` (`07-build-napa-detector.sh`). `napa_test` has to be run on the
  target.
- **Move the stream decoder:** `stream_decode.cc` is now linked into the CUDA lib (`libspectrum-gpu-apriltag`).
  Move it, or a copy, into the non-CUDA NAPA lib, so that a CPU-only target gets streaming decode and detect
  together in one native loop (libjpeg-turbo only).
- **Coarser USB transfers:** stock `uvcvideo` delivers in larger URBs than our patched one, so bands arrive in
  bigger chunks and the tail grows by about one URB's worth of rows.
- **More overlap at lower fps:** the camera streams each frame more slowly (longer line time), so more of
  NAPA's work hides inside the arrival window.
- **Expected tail:** similar or smaller relative to the frame. The CM5 is slower per row, but the tail is
  only the last 32 L0 rows plus the back end. Measure there with `run.sh timing` (it needs `taskset` and a
  Rewind session).

## Recommendation

Adopt streaming for the NAPA path once PhotonVision runs the stream decoder: it cuts about 1.9 ms of
detection latency at min 16 (2.0 → 0.11 ms p50) with identical results, for about +0.6 ms of CPU per frame.
For the far config, also stream the crops: start them on the previous frame's tracks and check them against
the base pass in `Finish()`. That would bring its p95 tail down from about 0.5 ms.
