# NAPA evaluation (2026-11-01)

NAPA (github.com/zwatx/NAPA, v0.5.1, commit `de613ad`) is a new CPU AprilTag detector. Its benchmarks
claim it is 25x faster than WPILib's defaults, finds tags down to 22 px and has 0.020 px corner error,
all on rendered frames and a single-threaded i7. Two questions:

1. Should it be the CPU detector on SystemCore (CM5, 4x Cortex-A76) and the fork's other CPU targets?
2. Can its ideas speed up our CUDA GPU detector?

All results are on the real TXMAN1 field recordings: all 6 matches, 13 sessions, 54k camera frames at
1280x800. They are scored by the same judge (`../field-replay/accuracy/judge.py`) and range/label
analysis (`../field-replay/analyze.py`) as the GPU detector studies. The CPU is the Jetson's
Cortex-A78AE at 1.73 GHz (spectrum-clocks full), standing in for the CM5.

## Files

| File | What |
|---|---|
| `napa_replay.cc` | NAPA or AprilTag 3 (CPU) on a Rewind session. Frames decoded as detector-replay decodes them; writes detector-replay's CSV, so the judge and analyze read it as just another variant |
| `build.sh` | Builds it on the Jetson from the vendored NAPA (`third_party/napa`, same commit), `detector/napa/napa_far.cc` and `~/build/apriltag-src`. `napa_replay_stats` is NAPA with tile counters added |
| `run.sh` | Accuracy replays of all TXMAN1 sessions (`out/<variant>/`), with variants napa, napa22, napa16, napa_h3, at3_d2, at3_d1, and (named on the command line) napafar, napafar12: `--backend napafar` runs `detector/napa/napa_far.cc`, what PhotonVision's NAPA backend runs, one detector per camera fed its frames in order |
| `timing.sh`, `timing.py` | Per-frame time, pinned to 4 cores, 4,517 frames (Q17 session 2 and Q24, every 4th frame; napafar cases every frame, 18,057). `timing.sh DATA OUT CASE...` runs only those cases |
| `tiles.sh`, `tiles.py` | Share of tiles that are not flat on real frames (the GPU idea) |
| `motion.py` | Recall and corner agreement against the GPU detector, by image motion and robot speed |
| `results/` | Judge, motion, range and timing outputs from this run |

To reproduce on the Jetson, after `../field-replay/run.sh` has prepared `/data/scratch/txman1/replay`:
`build.sh`, `run.sh`, `timing.sh`, `tiles.sh`. Then:
- `judge.py REPLAY --base d15s_far --variants napa,...`
- `analyze.py REPLAY --base d15s_far --variants V --compare V`
- `motion.py REPLAY`

Every script has a hard deadline and prints TIMEOUT if it hits it.

Settings:
- **Base:** the GPU detector as installed: mwbd 20, mse 10, far search on (`d15s_far`, from Checkpoint 5).
- **NAPA:** `max_hamming` 1 (like the GPU detector) except `napa_h3`. min_contrast 20, min_border_cells 22,
  sharpening 0.25 (NAPA's defaults). `min_tag_px` is 32 (NAPA's default), 22 or 16.
- **AprilTag 3:** PhotonVision's AprilTagPipeline settings (refine edges, sharpening 0.25, no blur), 1
  corrected bit, decimate 2 or 1.
- **All detectors:** decision margin of 15 or more, as detector-replay.

## 1. Where NAPA's speed comes from

It comes from the algorithm, not from SIMD or threads. The whole detector is one portable C99 file
(`napa_core.c`, 2,100 lines). It is single-threaded: one handle per thread or camera. NEON/SSE is used
only for a few small kernels: gathering samples, comparing them to the threshold, and pixel-pair
differences for the noise floor.

The pipeline:
1. **Sparse grid ("rake").** It samples one pixel every 3/4 of the smallest cell:
   `stride = min_tag_px * 3 / 32`, so 3 px at the default 32 and every pixel at 16. Each coarser level
   doubles the stride and takes every second sample of the level before. Levels continue until the
   frame is under 144 samples across, and each level keeps blobs 7 to 192 samples wide.
2. **Tile threshold with a flat-tile skip.** 4x4-sample tiles get min/max over a 3x3-tile neighbourhood.
   The threshold is (min+max)/2 if the range clears a noise floor, otherwise 0, and the tile's samples
   are never dark. The floor is noise-adaptive: per 64-sample region, 6 sigmas (7 at stride 1) of the
   median neighbour difference, at least `min_contrast` 20 and at most 64. A noisy frame is re-sampled
   with block averaging. Dark samples are turned into run bitmasks by SIMD compares, and runs are joined
   into blobs with union-find.
3. **Shape filter.** Each blob keeps its extreme points in 16 directions. The largest quad from them is
   the rough quad. A blob is rejected when it is more than about 85% filled (no tag36h11 code is) or its
   quad covers under 30% of its box. Below stride 3, an 8-point border/quiet-zone contrast probe
   follows.
4. **Edges at full resolution.** Each side gets intensity profiles along its normal, bilinear sampled
   in fixed point, one every 1.5 px (up to 96). The edge is the gradient's centre of mass, or the
   midpoint crossing when the ramp is wider than 0.6 cell (blur). It fits weighted lines and intersects
   them for corners. A first rough fit is decoded right away with 2 bits of slack, and only quads that
   pass are refined coarse to fine. A quad within 0.3 px of one that already failed is skipped.
5. **Decode.** The border cells and quiet ring are read first, then the payload, sharpened at 0.25.
   Multi-index hashing finds the nearest codeword. NAPA's recommended `max_hamming` for 36h11 is 3, but
   a 3-bit correction is accepted only if the wrong cells touch (8-connected). The decision margin is
   AprilTag's definition.
6. **Repairs:** a dark quiet zone, a side fitted one cell out, and edges biased by clipped exposure.

**Clutter:** handled by the noise floor, the fill and area limits, the border probe and the cheap early
decode. NAPA's own benchmarks show the early decode rejecting about 98.5% of random quads.

**License:** GPL-3.0-only, or a commercial license, for v0.5.0 and later. Releases before 0.5.0 were
PolyForm Noncommercial, so don't use them. PhotonVision is GPLv3, so a GPL-3.0-only library can be
combined with it and the result is distributed under GPLv3. The added section 7(b) term requires
keeping NAPA's notice and crediting Zachary Wilson in the fork's legal notices and about page.

## 2-3. Accuracy on TXMAN1 (all 13 sessions)

The base is the GPU detector with far search on: 39,844 sightings, in-frame error median 1.27 px
(p90 9.0), static jitter 0.084 px. Columns:
- **Lost / gained:** sightings only the base or only the variant found, with their own in-frame error
  (median px, and how many exceed 20.4 px).
- **Common, in-frame:** the change in error on sightings both found, paired, with the 95% bootstrap
  CI.
- **Bad:** the share of sightings the robot-pose check calls bad (wrong ID, or large shape, in-frame or
  pose error), as analyze.py labels them.
- **ms/frame:** the timing below, one thread.

| Variant | Sightings | Lost (median, >20.4) | Gained (median, >20.4) | Common in-frame p50 change (CI) | p75 change (CI) | Static jitter (base 0.084) | Bad | Good side p1 / min px | Range p99 / max m | ms/frame |
|---|---|---|---|---|---|---|---|---|---|---|
| GPU (base) | 39,844 | | | | | | 10.6% | 18.5 / 15.7 | 7.72 / 9.24 | GPU |
| NAPA min 32 | 34,625 (−13%) | 7,083 (1.35, 186) | 1,864 (**6.79**, 173) | +0.018 (−0.006..+0.037) | **+0.22 (+0.09..+0.32)** | 0.084, n.s. | 12.0% | 20.2 / 16.5 | 7.31 / 8.60 | **0.48** |
| NAPA min 22 | 40,894 (+2.6%) | 1,982 (1.24, 27) | 3,032 (**4.39**, 256) | +0.013 (−0.006..+0.029) | **+0.16 (+0.06..+0.25)** | 0.084, n.s. | 11.9% | 17.7 / 15.4 | 7.90 / 9.41 | ~0.9 |
| NAPA min 16 | **44,954 (+12.8%)** | 584 (2.43, 9) | 5,694 (2.23, 340) | +0.012 (−0.004..+0.026) | **+0.18 (+0.08..+0.28)** | 0.085, n.s. | 11.5% | 17.4 / 15.4 | 7.89 / 9.40 | **2.38** |
| NAPA min 16, hamming 3 | 47,118 (+18%) | 361 (2.40, 6) | 7,635 (2.36, 461) | +0.013 (−0.002..+0.027) | **+0.18 (+0.08..+0.27)** | 0.085, n.s. | 11.6% | 16.5 / 14.2 | 8.06 / 9.68 | ~2.3 |
| AprilTag 3, decimate 2 | 38,916 (−2.3%) | 1,597 (1.14, 17) | 669 (**16.5**, 122) | −0.010 (−0.026..0.000) | +0.06 (−0.04..+0.13) | **0.073 (better)** | 11.6% | 18.5 / 15.4 | 7.73 / 9.15 | 17.2 |
| AprilTag 3, decimate 1 | 42,182 (+5.9%) | 1,213 (3.27, 23) | 3,551 (1.52, 212) | −0.010 (−0.023..+0.006) | +0.08 (−0.01..+0.14) | **0.070 (better)** | 11.0% | 18.3 / 15.8 | 7.77 / 9.43 | 20.8 (4 threads) |

What this shows:
- **NAPA's corners agree with ours to about 0.1 px** (median corner distance from the GPU detector
  0.12 px; AprilTag 3's is 0.09).
  - Median in-frame accuracy and static jitter are the same as the GPU detector's, within the judge's
    resolution.
  - The tail is worse: p75 in-frame error is +0.16 to +0.22 px, and the CI excludes 0 for every NAPA
    setting. Corner-for-corner, NAPA's p90 distance from the GPU detector is 0.33 px against AprilTag's
    0.21–0.24.
  - AprilTag 3 on the CPU is slightly *better* than the GPU detector in jitter (0.07 vs 0.084 px) and
    the same in error.
  - The rendered-frame claim (0.020 px against AprilTag's 0.04–0.1) doesn't carry over: on real frames
    the layout/calibration floor dominates, and NAPA is no better than AprilTag here, slightly worse in
    the tail.
- **The default `min_tag_px` 32 misses 18% of our tags.** Lost sightings are median 33 px with good
  in-frame error, so they are real tags. Its gains are mostly junk: median in-frame error 6.8 px, 173
  over 20.4 px. min 22 still has poor gains (4.4 px median).
- **min 16 is the setting to use.** It finds 98.5% of the GPU detector's sightings and adds 5,694. Those
  gains are as good as AprilTag decimate 1's (2.2 px median, 4,254 good / 829 bad by robot pose). That
  is +12.8% sightings against +5.9% for AprilTag decimate 1, and range p99 7.89 m against 7.72 m.
  - The "smallest tag" claim holds: good tags down to 15.4 px. For comparison, the GPU detector reaches
    15.7 px and AprilTag decimate 2 reaches 15.4 px.
- **Bad share:** NAPA min 16 is 11.5% against 10.6% for the GPU detector and 11.0% for AprilTag
  decimate 1. Hamming 3 adds 2,000 more sightings at the same bad share. Its smallest finds are lower
  quality, and 3 corrected bits on a 36h11 code is a wrong-ID risk that the robot-pose labels can't
  fully separate (they mix wrong IDs with poor poses). **Keep `max_hamming` at 1.**

### Motion blur (`motion.py`, `results/motion.txt`)

Results are split by how far the tag moved since the previous frame (px/frame), compared against the
GPU detector:

| Image step | NAPA16 recall | NAPA16 corner distance p50 / p90 | AprilTag decimate 1 recall | AprilTag decimate 1 p50 / p90 |
|---|---|---|---|---|
| 0–1 px | 99.9% | 0.10 / 0.17 | 99.8% | 0.07 / 0.14 |
| 3–8 px | 99.6% | 0.11 / 0.21 | 99.5% | 0.08 / 0.15 |
| 20+ px | 97.8% | 0.15 / **0.63** | 94.8% | 0.10 / 0.33 |
| fast robot (>1.5 m/s or >2 rad/s) | 98.1% | 0.13 / 0.42 | 95.9% | 0.09 / 0.24 |

- Blur doesn't cost NAPA detections: it keeps 97.8% on fast-moving tags, more than AprilTag decimate 1.
- Its corners diverge from the GPU/AprilTag answer about twice as much under fast motion. That is the
  README's weakness ("largest error 3.4 px against 2.2 px"). It is the p75 tail above.
- With no ground truth per frame, which detector is right on a blurred tag isn't settled. The in-frame
  judge, which covers all motion, says NAPA's tail is somewhat worse.

## 4. CPU timing (SystemCore proxy)

Jetson Orin Nano A78AE at 1.73 GHz, `taskset` to 4 cores, full clocks, 4,517 TXMAN1 frames at 1280x800,
decode not included. Values are ms per frame.

| Case | median | p95 | max | frames/s on 4 cores |
|---|---|---|---|---|
| NAPA min 32, 1 thread | **0.48** | 0.61 | 0.76 | ~2,000 per core |
| NAPA min 32, 4 frames at once (1 thread each) | 0.50 | 0.63 | 1.12 | ~8,000 |
| NAPA min 16, 1 thread | **2.38** | 2.68 | 3.30 | ~430 per core |
| NAPA min 16, 4 frames at once | 2.60 | 2.96 | 3.90 | ~1,570 |
| AprilTag 3 decimate 2, 1 thread | 17.2 | 21.8 | 32.9 | 57 |
| AprilTag 3 decimate 2, 4 threads | 7.2 | 8.9 | 12.6 | 138 |
| AprilTag 3 decimate 2, 4 frames at once | 17.8 | 22.4 | 33.7 | 222 |
| AprilTag 3 decimate 1, 4 threads | 20.8 | 24.4 | 31.4 | 48 |

- **NAPA min 16 is 7x faster than AprilTag decimate 2 on one thread** and 3x faster than decimate 2 on 4
  threads, while finding 15% more tags than decimate 2, with the same median accuracy.
- NAPA min 32 is 36x faster, the README's claim, but it loses tags on our frames.
- Four cameras at 30 fps with NAPA min 16 would use about 0.3 of one core. AprilTag decimate 2 needs
  about 2 of SystemCore's 4 cores for the same, and those cores are shared with robot code.
- NAPA has no internal threads, so one camera's latency can't drop below its single-thread time. At
  2.4 ms that doesn't matter.
- **CM5 caveats.** A76 at 2.4 GHz against the Orin's A78AE at 1.73 GHz:
  - The A76's per-clock speed is a little lower, so expect the same order of time, possibly faster.
  - The CM5 has much less memory bandwidth (LPDDR4X-4267, 32-bit) than the Orin (LPDDR5, 128-bit).
    NAPA's sparse reads favour it, and AprilTag's full-frame passes don't.
  - Decode isn't included. Decode was 9.4 ms colour or about 5 ms gray per frame on the Orin
    (`../systemcore-cpu`), which makes JPEG decode, not detection, the CPU cost with NAPA. Use half-res
    gray decode or YUYV where possible.
  - Confirm on a real CM5 before committing to it.

## 5. The GPU idea: skipping flat tiles

`tiles.sh` covered 27,215 frames, every 2nd frame of all sessions. It applied two tests:
- **GPU test:** our own threshold test. 4x4 tiles of the half-res frame (8x8 px), active when their 3x3
  neighbourhood spans 20 or more grey levels (mwbd 20).
- **NAPA test:** NAPA's own, at its first two levels.

| Test | Active tiles: mean | p10 | p50 | p90 |
|---|---|---|---|---|
| GPU test (8x8 px) | 57% | 25% | 65% | 74% |
| NAPA level 0 (12x12 px) | 69% | 35% | 78% | 87% |
| NAPA level 1 (24x24 px) | 83% | 53% | 93% | 98% |

On frames with a tag, 63% are active. Real field frames (carpet texture, people, bumpers, lights, the
crowd) are mostly not flat. The renders NAPA's claims come from are mostly flat background. So
compaction could remove **about 37–43% of tiles on a busy frame**, not 80–90%.

**What it would save.** The per-frame map in `docs/TECHNICAL.md` (`detector-13`) puts TXMAN GPU time at
~1.7 ms:

| Stage | Share of GPU time | Pixels or boundary points? | Saved by compaction |
|---|---|---|---|
| Radix sorts | 21–25% | boundary points | nothing |
| `BlobDiffCompact` | 14% | boundary points | nothing |
| Labeling | ~10% | pixels | ~40% of it |
| Threshold and min/max | a few % | pixels | most of the per-pixel part |
| Graph fills | 5% | | nothing |

The sorts and `BlobDiffCompact` already scale with boundary points between black and white components.
Flat tiles are "unknown" (127) after thresholding and produce none, so the detector already skips their
cost.
- Gross saving: ~12–15% of 1.7 ms × ~40% ≈ **70–100 µs per busy frame**.
- Overhead: a prefix-sum and indirect launches cost ~20–30 µs.
- **Net: ~50–80 µs, 3–5% of GPU time, about 2–4% of Detect wall time (2 ms).** Not worth a labeling
  rewrite.

**Design sketch, if it is ever wanted:**
1. The threshold kernel already computes the tile min/max. It also writes an active flag per 32x32-px
   block (any active 4x4 tile within 1 tile of it).
2. A CUB `DeviceSelect` turns the flags into a list of active blocks, and the count goes to an indirect
   launch, or a fixed grid that exits early.
3. Labeling (local union-find, then border merge) runs only over listed blocks. Inactive blocks are
   filled with 127 by one memset, and border merges skip edges where either side is inactive. Blob
   boundaries can't cross an inactive block, because unknown pixels form no boundary.
4. Output must be bit-identical, checked with `graph_bench --out` against the current build on the
   regression and TXMAN cameras.

**The NAPA idea that does transfer is the cheap early decode, on the CPU side.** Our decode workers
spend ~850 µs of CPU per TXMAN frame, mostly `RefineEdges` (19%) and `UnDistort` (13%), on every quad
that reaches the CPU. NAPA reads the border and quiet ring and makes a 2-bit-slack decode before
refining, and spends refinement only on quads that pass. In our pipeline that would mean testing the
border and code on the GPU's fitted quad first, then running `RefineEdges`, undistortion and the final
decode only on survivors. The quad count is in `../nontag-quads/README.md`: 95% of the quads are
non-tags, and an early decode would save ~350 µs of worker CPU per busy frame.

## Recommendation

1. **CPU detector (SystemCore and other CPU targets): yes, NAPA is the best CPU option we've measured.
   Use `min_tag_px` 16 and `max_hamming` 1.**
   - It is 7x faster than AprilTag decimate 2 on one thread, finds 15% more tags (98.5% of the GPU
     detector's plus 13%), and has the same median accuracy and jitter.
   - Caveats:
     - The in-frame tail is 0.2 px worse (p75), and its corners diverge more under fast motion.
     - Its bad share is ~1 point higher than the GPU detector's.
     - Never use the default min 32 or hamming 3 on our frames.
     - These are Orin A78AE numbers; confirm on a CM5.
   - For integration, the fork needs:
     - A JNI wrapper with one handle per camera, plus a corner-order and +0.5 conversion (as
       `napa_replay.cc`).
     - Its GPL notice and credit (the 7(b) term).
     - A switch that keeps AprilTag 3 available.
   - For multi-tag on SystemCore (robot-side multi-tag from corners), corner accuracy matters. The
     tail difference is small next to the 1.3 px layout/calibration floor, but it should be re-checked
     on the robot.
2. **GPU detector: no.** Flat tiles are only ~40% of real field frames, and the detector's largest
   costs (sorts, `BlobDiff`) already skip them, so compaction would save ~50–80 µs a frame (3–5% GPU).
   The useful NAPA idea is the early cheap decode before `RefineEdges`/undistort on the CPU side, worth
   a quad-count study first.

## 6. NAPA in PhotonVision and its far search (2026-11-01)

NAPA is now a CPU AprilTag backend of the fork (`detector/napa/`, `libspectrum-napa-apriltag.so`, built by
`scripts/jetson/07-build-napa-detector.sh`; see `docs/TECHNICAL.md` "NAPA: AprilTags on the CPU"). It
has its own far search (`detector/napa/napa_far.cc`). This is a small port of `far_search.cc`'s ideas, because
that file is tied to the 971 detector:
- the full frame at min 32 every frame;
- min 16 only in tracking crops (6x the side, at least 96 px) around tags under 48 px seen in the last 0.5 s;
- min 16 in one horizontal band (of 4, overlapping by 64 px) at most 60 times a second, and never sooner
  than 5x the last band's time after it (the time guard).

On all TXMAN1 sessions, scored as in section 2-3, with timing on one thread as in section 4:

| Variant | Sightings | Lost (median, >20.4) | Gained (median, >20.4) | Common in-frame p50 / p75 change | Bad | Good side p1 / min | Range p99 / max | ms/frame mean (p95) |
|---|---|---|---|---|---|---|---|---|
| GPU (base, d15s_far) | 39,844 | | | | 10.6% | 18.5 / 15.7 | 7.72 / 9.24 | GPU |
| NAPA min 32 | 34,625 | 7,083 | 1,864 (6.79) | +0.018 / +0.22 | 12.0% | 20.2 / 16.5 | 7.31 / 8.60 | 0.49 (0.61) |
| NAPA min 16 | 44,954 | 584 (2.43, 9) | 5,694 (2.23, 340) | +0.012 / +0.18 | 11.5% | 17.4 / 15.4 | 7.89 / 9.40 | 2.34 (2.70) |
| **NAPA far (32 + 16)** | **43,057 (+8.1%)** | 1,737 (1.88, 54) | 4,950 (2.41, 300) | +0.014 / +0.17 | **11.2%** | 17.6 / 15.7 | 7.86 / 9.26 | **1.25 (1.64)** |
| NAPA far (32 + 12) | 43,057 | same | same | same | 11.2% | same | same | 1.25 (1.63) |

- The far search keeps 82% of min 16's gain over min 32 (8,432 of 10,329 sightings), at 53% of min 16's
  time. Static jitter is unchanged (0.084 px), and so is in-frame accuracy (p75 CI excludes 0 as for every
  NAPA setting).
- It loses 1,153 more GPU sightings than min 16 does. These are small tags in parts of the frame that
  weren't being swept or tracked when they first appeared.
- Far min 12 is identical to 16. NAPA's grid stride is `min_tag_px * 3 / 32`, 1 px for both, so there is
  nothing lower to search.
- **Which to use:** min 16 full frame when the CPU can afford 2.3 ms per frame per camera (most CPU
  targets at ≤ 4 cameras). Far search when it can't, or at high frame rates: 1.25 ms per frame.

Outputs: `results/judge-far.txt`, `results/analyze-far.txt` (size/range part), `results/timing-far.txt`.

## 7. Live A/B at full clocks (2026-11-01)

`tests/object-detection/run.sh live` (now also logs CPU_GPU_CV rail power and PhotonVision's top threads),
`TAGS_ON_CPU=0/1`, `NAPA_FAR=0/1`, with `spectrum-clocks mode full` (GPU 1020 / CPU 1728 / EMC 3199 MHz,
verified before each condition). 2 Thriftiest cams 1280x800 at 122 fps, NVJPG decode, yolo11n at Object FPS
max 30 on the Jetson. GPU / NAPA min 16 / NAPA far interleaved, 2 rounds of 60 s, means of both rounds.
**No tags in view on the bench: base cost only.** The earlier auto-clock numbers are in `docs/TECHNICAL.md`.

| Condition | Tag latency p50 / p95 / max | Tag fps (per cam) | GPU | PhotonVision CPU | Top threads (cores) | YOLO batch / queue wait | VDD_IN | CPU_GPU_CV | tj max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GPU detector, tags only | 14.9 / 15.7 / 28.4 ms | 121.3 | 18% | 0.38 cores | decode 0.18, VisionRunner 0.09 | | 9.0 W | 2.75 W | 75 °C |
| NAPA min 16, tags only | 14.9 / 15.7 / 21.6 ms | 121.3 | 1% | 0.63 cores | VisionRunner 0.36, decode 0.19 | | 8.7 W | 2.56 W | 77 °C |
| NAPA far search, tags only | **13.8 / 15.0 / 20.3 ms** | 121.3 | 1% | 0.38 cores | decode 0.17, VisionRunner 0.13 | | **8.5 W** | **2.39 W** | 77 °C |
| GPU detector + yolo11n 30 fps | 14.8 / 16.1 / 28.2 ms | 121.3 | 42% | 0.67 cores | TensorRT 0.24, decode 0.19, VisionRunner 0.11 | 6.3 / 2.9 ms | 12.0 W | 4.58 W | 80 °C |
| NAPA min 16 + yolo11n 30 fps | 15.3 / 16.3 / 23.4 ms | 121.3 | 28% | 0.93 cores | VisionRunner 0.38, TensorRT 0.25, decode 0.21 | 6.1 / 2.9 ms | 12.0 W | 4.61 W | 79 °C |
| NAPA far + yolo11n 30 fps (extra) | 14.2 / 15.3 / 25.3 ms | 121.3 | 30% | 0.67 cores | TensorRT 0.23, decode 0.19, VisionRunner 0.15 | 5.5 / 3.6 ms | 11.4 W | 4.19 W | 80 °C |

- NAPA min 16 matches the GPU detector at p50/p95 at full clocks with a lower max, for ~0.25 more cores.
- The far search is the cheapest and fastest here: ~1 ms lower p50/p95, same CPU as the GPU detector, lowest
  power. With no tags in view it only does its min 32 pass and sweeps; expect more cost with tags.
- YOLO's batch time no longer depends on the tag backend at full clocks (~6 ms); the GPU has headroom.
- tj rose through the run (67 -> 80 °C); round 2 reads hotter for all conditions.
