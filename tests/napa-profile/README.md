# NAPA profile and speed-ups (2026-11-02)

Where NAPA (the CPU AprilTag detector, `third_party/napa`, v0.5.1 `de613ad`, GPL-3.0-only, credit Zachary
Wilson) spends its time on real TXMAN1 frames, its early-decode slack exposed as a setting, and speed-ups
that keep every detection identical. Jetson Orin Nano Cortex-A78AE at 1.73 GHz (full clocks), one thread
pinned to cores 0-3, 1280x800 gray frames, JPEG decode not included.

## How NAPA changes are kept

`third_party/napa` stays the unmodified upstream file. Our changes are patches applied at build time:
- `patches/napa-01-early-slack.patch`: `napa_set_early_slack(det, 0..3)`. The default is 2, NAPA's
  built-in value.
- `patches/napa-02-speed.patch`: the speed-ups below.

`scripts/jetson/napa-src.sh DIR` copies the vendored source and applies `patches/napa-*.patch` in name
order. Both `scripts/jetson/07-build-napa-detector.sh` (the library PhotonVision loads) and
`tests/napa-eval/build.sh` use it. To upgrade NAPA, replace `third_party/napa` and check that each patch
still applies.

## Files

| File | What |
|---|---|
| `napa-profile.patch` | Profile build only (`-DNAPA_PROFILE`): finer stage timers than upstream's, per-level times and candidate counts per stage. Thread-local |
| `build.sh` | On the Jetson: `napa_replay` (-O3 -g, frame pointers, for perf), `napa_replay_prof` (with the profile patch), and `NAPA_EXPERIMENTS="NAME=a.patch ..."` builds in `exp-NAME/` |
| `profile.sh`, `prof.py` | Stage timers on the timing frames (`../napa-eval/timing.sh`'s 4,517; far config every frame, 18,057), and `perf record -g` of Q24 |
| `exp.sh`, `same.py`, `abtime.py` | Experiment A/B. Accuracy replays of all 13 sessions, then `same.py` checks every sighting and corner against the unchanged build (must print IDENTICAL). Then timing with builds alternating over rounds |
| `experiments/` | Every speed patch tried (on top of `napa-01`), kept and rejected |
| `results/` | Outputs of this run |

Reproduce on the Jetson, after `../napa-eval/build.sh`:
1. `build.sh`
2. `profile.sh`, then `prof.py ~/build/napa-profile/profile`
3. `NAPA_EXPERIMENTS=... build.sh`, then `exp.sh DATA NAME...`
4. The slack sweep: `WORK=~/build/napa-profile ../napa-eval/run.sh DATA napa16_s0 ... napafar_s3`, then
   `judge.py REPLAY --base napa16_s2 --variants napa16_s0,napa16_s1,napa16_s3` (likewise for napafar)

Every script waits until no PhotonVision, replay or graph_bench is running and the temperature is below
85 C. Every script has a hard deadline and prints TIMEOUT if it hits it.

## 1. Early-decode slack

NAPA decodes each quad once on its first, unrefined edge fit. That early decode allows `slack` more dark
border cells and corrected bits than the final decode does. Only quads that pass get the refinement
passes. The slack was fixed at 2 bits. It is now a setting:
- `napa_far::Config::early_slack`
- the JNI method `setEarlySlack(handle, slack)`
- `napa_replay --early-slack N`

The slack-2 build with the patch is byte-identical to the old build (44,954 sightings, every corner
equal).

All 13 TXMAN1 sessions, judged against slack 2 (`results/judge-slack16.txt`, `judge-slackfar.txt`):

| Config | Slack | Sightings | Lost (in-frame median, >20.4 px) | Gained (median, >20.4 px) | Common: jitter / in-frame p50 / p75 / p90 | ms/frame mean |
|---|---|---|---|---|---|---|
| min 16 | 0 | 44,593 | 361 (3.85, 30 of 200) | 0 | unchanged (CI 0) | 2.31 |
| min 16 | 1 | 44,904 | 50 (5.57, 3 of 23) | 0 | unchanged | 2.32 |
| min 16 | **2** | **44,954** | | | | 2.32 |
| min 16 | 3 | 44,969 | 0 | 15 (1.98, 1 of 8) | unchanged | 2.33 |
| far (32 + 16) | 0 | 42,726 | 332 (4.72, 27 of 184) | 1 | unchanged | 1.237 |
| far | 1 | 43,006 | 51 (3.43, 2 of 17) | 0 | unchanged | 1.241 |
| far | **2** | **43,057** | | | | 1.242 |
| far | 3 | 43,074 | 0 | 17 (4.29, 0 of 4) | unchanged | 1.247 |

- **Keep 2.**
  - Lower slack only loses tags: 0.8% at slack 0, 0.1% at slack 1. The lost tags are mixed quality,
    about half under 5 px in-frame error, so slack is not a useful quality filter.
  - Slack 3 adds 0.03-0.04% sightings, a few of them poor.
  - Corners of common sightings never change. The judge's paired CIs are exactly 0.
- **Time barely depends on slack** (within ±0.5%, the timing noise). Early decode, refinement and final decode together are under 3% of
  the frame (section 2).
- The bad share (robot-pose labels) can't move measurably: at most 361 sightings out of 45k change.
- **Fork (not done yet):**
  - Add `static native void setEarlySlack(long handle, int slack)` to `NapaDetectorJNI.java`.
  - Add a pipeline setting "NAPA early-decode slack" (0-3, default 2) that calls it after `setParams`,
    like the other NAPA settings. The native side is in `detector/napa/NapaDetectorJNI.cc`.

## 2. Where the time goes

Stage timers (`results/profile.txt`). The profile build is about 12% slower than the normal build,
mostly because of the per-row timers inside the run/union loop, so its absolute times are high. The
shares are what matter.

| Stage | min 32 ms (share) | min 16 ms (share) | far 32 + 16 ms (share) |
|---|---|---|---|
| Rake (sampling; at stride 1 a memcpy of the frame) | 0.097 (17%) | 0.176 (7%) | 0.152 (11%) |
| Noise floors (+ box re-rake) | 0.015 (3%) | 0.123 (5%) | 0.057 (4%) |
| Tile min/max + 3x3 + threshold | 0.091 (16%) | 0.530 (20%) | 0.270 (19%) |
| Dark bits + run extraction | 0.102 (18%) | 0.637 (24%) | 0.304 (21%) |
| Union-find (row linking) | 0.115 (20%) | 0.512 (20%) | 0.266 (19%) |
| Component resolve | 0.030 (5%) | 0.165 (6%) | 0.080 (6%) |
| Blob filter + extreme points | 0.033 (6%) | 0.199 (8%) | 0.118 (8%) |
| Rough quad + fill/area filter | 0.009 (2%) | 0.075 (3%) | 0.037 (3%) |
| Border probe (stride ≤ 2) | 0 | 0.092 (4%) | 0.018 (1%) |
| First edge fit | 0.032 (6%) | 0.040 (2%) | 0.052 (4%) |
| Early decode (+ quiet-zone rescue) | 0.007 (1%) | 0.019 (1%) | 0.014 (1%) |
| Refinement fits | 0.027 (5%) | 0.038 (1%) | 0.046 (3%) |
| Final decode + repairs | 0.004 (1%) | 0.006 (0.2%) | 0.007 (0.5%) |
| **Total (profile build)** | **0.56** | **2.61** | **1.42** |

Per pyramid level at min 16, with mean counts per frame:

| Level | ms | runs | blobs | candidates | rough quads | past probe | first fits | early pass | tags |
|---|---|---|---|---|---|---|---|---|---|
| L0 (stride 1) | 1.75 | 21,814 | 871 | 117 | 94 | 10.3 | 2.5 | 0.9 | 0.8 |
| L1 (stride 2) | 0.59 | 8,856 | 358 | 37 | 29 | 4.3 | 1.1 | 0.2 | 0.1 |
| L2 (stride 4) | 0.20 | 3,115 | 132 | 9 | 7 | 7 | 0.3 | 0 | 0 |
| L3 (stride 8) | 0.07 | 955 | 38 | 3 | 2 | 2 | 0 | 0 | 0 |
| all | 2.61 | 34,740 | 1,399 | 166 | 132 | 23 | 3.9 | 1.1 | 0.9 |

At min 32 (stride 3 and 6): 6,400 runs, 255 blobs, 22 candidates, 1.3 first fits, 0.7 tags a frame.

perf (`results/perf16-*.txt`, frame pointers, Q24, normal -O3 build):
- `threshold_level` (everything from tile min/max to union-find) takes 64% of NAPA at min 16 and 55% at
  far.
- `napa_detect` itself takes 27%: rake memcpy, resolve, blob filter, quads, fits, decode.
- `contrast_floors` takes 5%.

Inside `threshold_level`, by source line:
- the row-linking merge loop: 28%
- `extract_runs`: 20%
- tile min/max and 3x3 neighbourhood: 15%
- `dark_bits`: 5%

**What this means:**
- NAPA on real field frames is a run-length labeler. About 85% of its time is the pixel and run front
  end, and it scales with texture: carpet, bumpers and crowd make 35k runs a frame.
- The geometric back end (fits, decodes, the early-decode gate) is under 10%. The early decode already
  cuts 3.9 first fits down to 1.1 refinements, which is why slack doesn't matter for time.
- Of the 166 candidates a frame, the border probe removes 82% at stride 1. The early decode then
  removes 70% of the first fits.

## 3. Speed-ups tried

Each experiment was replayed on all 13 sessions (min 16 and far) and compared with `same.py`. Every one
below is **IDENTICAL**: the same 44,954 / 43,057 sightings, and no corner moved (to the CSV's 1e-4
precision). Timing as `../napa-eval/timing.sh` (4,517 frames; far 18,057 every frame, 2 sessions), builds
alternating. The final row is a clean 3-round re-run (`results/timing-final.txt`); earlier rounds are in
`results/timing-round*.txt`.

| Patch | What | min 16 mean ms | min 32 | far | Kept? |
|---|---|---|---|---|---|
| base | napa-01 only | 2.32 | 0.488 | 1.243 | |
| A | `dark_bits` on aarch64: 64 samples to one 64-bit mask with 3 `vpaddq` rounds (was a movemask emulation per 16) | 2.19 (−5.8%) | 0.471 (−3%) | 1.186 (−5%) | yes |
| B | Stride-1 level reads the frame in place (no 1 MB memcpy); padded copy of the last row for the SIMD over-read | +A: 2.12–2.14 (−8%) | 0.47 (−3%) | 1.18 (−5%) | yes |
| C | Union merge: always advance the run that ends first, only the join branches | +AB: 2.18 (slower than AB) | 0.478 | 1.204 | no |
| D | `extract_runs`: branch-free edge list, then pair | +AB: 2.17 (slower) | 0.482 | 1.207 | no |
| H | Tile min/max horizontal reduce: 16 tiles at a time with `vpminq`/`vpmaxq` | +AB: 2.09 (−10%) | 0.469 (−4%) | 1.164 (−6%) | yes |
| **napa-02 = A+B+H, final** | clean re-run | **2.091 (−9.9%)**, p95 2.67 → 2.44 | **0.469 (−3.5%)** | **1.164 (−6.4%)**, p95 1.63 → 1.56 | **in `patches/napa-02-speed.patch`** |

- C and D remove branches that the A78AE predicts well: runs alternate start/end, and in the merge the
  overlap pattern is regular on textured frames. The extra work costs more than the mispredicts saved.
- Speed-ups are largest at min 16, where the stride-1 level dominates. B only acts at stride 1, so it
  saves nothing at min 32 (stride 3).

### Ideas measured but not built

- **Multi-thread split per frame, for one camera's latency.** Levels are independent up to their
  candidate lists. Only the back end needs the finer levels' results (`covered`, `failed_before`).
  - Running L0's front end on one thread and L1-L3's on another, then the back end in order, would give
    identical results. Front-end times: L0 ≈ 1.5 ms, L1-L3 ≈ 0.75 ms. So min-16 latency would go from
    about 2.1 to about 1.4-1.5 ms (−30%), at about +0.05 ms of extra CPU per frame for the thread
    handoff.
  - It needs per-level buffers: L1 is currently gathered from L0's buffer in place.
  - Splitting one level into bands would change the noise floors and blob merges at band edges, so it
    would not be identical.
  - Not worth it now: at 2 ms NAPA's latency is under 15% of a 15 ms frame. More cameras already use
    more cores.
- **Flat-tile skipping tuned for real frames.** Bands with no contrast already skip runs (`if (!any)`).
  On TXMAN1, 69% of level-0 tiles are active (`../napa-eval` section 5), so a finer skip saves under 10%
  of the tile stage.
- **Cheaper union-find.** The merge loop is the largest single cost after H. A different labeler
  (bitmask-parallel overlap of adjacent rows' masks, joining runs by word) could halve it, but that is a
  rewrite of NAPA's core and its outputs would need the same CSV identity check.
- **ROI/crop cost (far config).** The crops and the sweep band run the full pipeline on a sub-image at
  stride 1. B helps them through the same in-place read (the far config improves 5-6%). Crops are cheap:
  the far config's back end is 8% of its time.
- **Buffer reuse** is already per handle in NAPA (`ensure_buffers` only grows), so there is nothing to
  gain.

## 4. CM5 (SystemCore, 4x Cortex-A76 at 2.4 GHz)

- **A and H are NEON.** The A76 has the same 128-bit NEON with `vpaddq`/`vpminq`, so expect about the
  same relative gain (−6 to −10% at min 16).
- **B saves a 1 MB copy and the matching extra read per frame.** It should matter **more** on the CM5,
  whose LPDDR4X-4267 32-bit bus has about a quarter of the Orin's bandwidth. On the Orin it is about 3% of
  min 16; on the CM5, expect about 4-6%.
- The front end streams the frame about twice at stride 1 (tile min/max, then dark bits). With smaller
  caches (the CM5 has no system cache), a band-at-a-time fusion of those two passes is the next thing to
  try there, not on the Orin.
- Not measured on a CM5. Confirm with `../napa-eval/timing.sh` on a real SystemCore.

## Recommendations

1. **Ship `patches/napa-02-speed.patch`**: −10% at min 16 and −6% for the far config, with identical
   detections. It is in the library build now; rebuild with `scripts/jetson/07-build-napa-detector.sh`
   (`napa_test` passes).
2. **Keep early slack at 2.** Expose it in the fork only as an advanced setting, if at all (see section 1).
3. Next, if NAPA's CPU cost ever matters (CM5 with 4+ cameras):
   - a word-parallel row labeler (the union loop, about 20%);
   - the two-thread level split, for latency;
   - fusing tile min/max with dark bits per band, for memory traffic on the CM5.
