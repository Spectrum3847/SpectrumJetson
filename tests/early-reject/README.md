# Early non-tag reject in the GPU detector (`detector-20`, 2026-11-01)

`../nontag-quads` found that ~95% of the quads the 971 detector hands to `RefineEdges` + decode are not
tags. `patches/detector-20-early-reject.patch` adds a cheap check on each quad's **unrefined** corners
(border rings + payload sampled through the quad's homography, compared with the fitted threshold, N errors
of slack) and drops quads that can't be tags before `RefineEdges`. Survivors are refined and decoded as
before (hamming policy unchanged). Off unless `SPECTRUM_DETECTOR_EARLY_REJECT=N` is set; with it unset the
output is unchanged.

- `SPECTRUM_DETECTOR_EARLY_REJECT=N`: slack N (border errors + payload distance to the nearest codeword).
- `SPECTRUM_DETECTOR_EARLY_MODE=border`: border rings only (payload not checked); `scales`: also tries the
  quad shrunk/grown 8%.
- `SPECTRUM_DETECTOR_EARLY_STATS=FILE`: per-DecodeTags quads, survivors, worker thread CPU (measurement only).

## Files

| File | What |
|---|---|
| `build.sh` | Builds `detector-replay` with the patch on the Jetson (`~/build/early-reject`), from a copy of `~/build/bos` |
| `run.sh` | All 13 TXMAN1 sessions per variant, installed settings: mwbd 20, mse 10, far search on, CPU RefineEdges (ladder level 3), calibrations (`*_nocal`: without) |
| `retime.sh` | Timing cross-check: base, s3, b4, s4 interleaved on 3 sessions, 2 rounds (`~/build/early-reject/retime`) |
| `analyze.py` | Variant vs base: sightings lost/gained, quads passed, non-tags passed, worker CPU, wall |
| `results/analyze.txt` | The table below plus up to 200 lost sightings per variant (b4: all 179) |
| `results/judge.txt` | `../field-replay/accuracy/judge.py` of s2, s3, s4, b4 against base |

## Results (13 TXMAN1 sessions, 54,420 frames, 2 cameras)

CPU = decode workers' thread CPU per busy frame (every field frame has quads), summed over the 4 workers.
"Wall" = `DecodeTags` wall per frame and the replay's detect wall per frame.

| Variant | Real tags kept | Sightings lost (gained) | Non-tags passed | Early | Refine | Decode | Total | CPU saved | DecodeTags wall | Detect wall |
|---|---|---|---|---|---|---|---|---|---|---|
| base | 100% | 0 | 100% | 0 | 550 µs | 120 µs | 670 µs | — | 212 µs | 1.863 ms |
| s0 (slack 0) | 83.1% | 6,715 (821) | 0.04% | 89 | 18 | 9 | 116 µs | 555 µs | 77 µs | 1.757 ms |
| s1 | 90.5% | 3,793 (493) | 0.05% | 90 | 19 | 10 | 118 µs | 552 µs | 78 µs | 1.754 ms |
| s2 | 93.9% | 2,430 (374) | 0.08% | 90 | 20 | 10 | 120 µs | 551 µs | 78 µs | 1.758 ms |
| s3 | 96.3% | 1,485 (213) | 0.12% | 91 | 20 | 10 | 121 µs | 549 µs | 78 µs | 1.747 ms |
| s4 | 97.6% | 953 (134) | 0.19% | 92 | 21 | 11 | 124 µs | 547 µs | 79 µs | 1.758 ms |
| k2 (scales, 2) | 95.0% | 1,990 (314) | 0.09% | 183 | 20 | 11 | 214 µs | 457 µs | 108 µs | 1.801 ms |
| b2 (border, 2) | 98.9% | 440 (78) | 3.5% | 86 | 38 | 16 | 140 µs | 531 µs | 85 µs | 1.763 ms |
| **b4 (border, 4)** | **99.55%** | **179 (22)** | 5.4% | 87 | 48 | 19 | 153 µs | **518 µs (77%)** | 88 µs | 1.767 ms |
| base_nocal | 100% | 0 | 100% | 0 | 345 | 121 | 466 µs | — | 166 µs | 1.840 ms |
| s2_nocal | 93.8% | 2,494 (349) | 0.03% | 91 | 14 | 10 | 115 µs | 351 µs | 82 µs | 1.762 ms |
| s3_nocal | 96.2% | 1,537 (208) | 0.08% | 91 | 15 | 10 | 116 µs | 350 µs | 75 µs | 1.757 ms |

"Real tags kept" = the base's sightings (camera x frame x tag x source) the variant still reports.
"Non-tags passed" = survivors of the early check that the base's full decode rejected.

### Which runs the CPU numbers come from

- All at `spectrum-clocks mode full` (GPU 1020 / CPU 1728 / EMC 3199), one replay at a time, PhotonVision
  stopped, nice 19, tj 76-78 °C.
- The first `base` and `s2` passes (00:08-00:28 UTC Nov 2) and the first `s1` pass (01:37-02:04, overlapped
  other timing) gave inflated CPU (base refine 2,288 µs, detect 6.8 ms): **discarded for timing**. `base`, `s2`
  and `s1` were re-run 02:43-03:02 (`out_t`); sightings were identical to the first passes, so only timing
  changed. s0, s3, s4, b2, b4, k2 (02:04-02:25) and the `_nocal` variants (02:25-02:36) are from the first pass.
- Cross-check (`retime.sh`, 3 sessions, 6,430 frames, base/s3/b4/s4 interleaved, 2 rounds): base 655/654 µs,
  b4 153/153, s3 120/121, s4 123/123; detect 1.86-1.87 ms base vs 1.77-1.79 ms with the check. Repeatable to
  ~1 µs CPU, ~20 µs wall.

### Lost sightings

Every mode loses some real tags; nothing is lossless. The losses are tags whose unrefined corners are off
(motion blur, partial occlusion, perspective): the full decode after `RefineEdges` reads them, the early
sample doesn't.

- **b4 (179 lost):** side 16-28 px (most), 64 with side > 40 px, largest 188 px (Q32 0014 orin-right frame
  2072 tag 17, margin 50.6). 11 from the far search. Spread over all sessions; most in Q17 0002 (54). Largest:

  | Session | Camera | Frame | Id | Source | Margin | Side px |
  |---|---|---|---|---|---|---|
  | TXMAN1_Q32/0014 | orin-right | 2072 | 17 | normal | 50.6 | 187.7 |
  | TXMAN1_Q32/0015 | orin-left | 806 | 8 | normal | 38.5 | 167.9 |
  | TXMAN1_Q27/0009 | orin-left | 978 | 8 | normal | 62.1 | 159.5 |
  | TXMAN1_Q17/0002 | orin-right | 1536 | 5 | normal | 52.5 | 128.6 |
  | TXMAN1_Q17/0002 | orin-left | 2105-2122 | 21 | normal | 31-64 | 92-106 (5 frames) |
  | TXMAN1_Q32/0013 | orin-left | 844 | 5 | normal | 71.2 | 104.5 |
  | TXMAN1_Test_r19/0025 | orin-right | 1545 | 25 | normal | 76.0 | 104.2 |

  The full list is in `results/analyze.txt` (`analyze.py OUT --lost N` on the Jetson).
- **s-modes:** the payload check costs far more tags: s3 loses 1,485, s4 953, mostly small (16-30 px)
  tags with good margins.
- Calibrated and uncalibrated lose the same tags (s2 2,430 vs 2,494, s3 1,485 vs 1,537): the check runs
  before undistortion either way.

### Accuracy (judge.py, against base, common sightings)

Corners of the sightings both find are unchanged (survivors are refined exactly as before): static jitter,
in-frame consistency and smoothness are identical (paired CIs 0 or within ±0.02 px) for s2, s3, s4 and b4.
The lost sightings are worse than average where checkable (in-frame median 2.1-3.4 px vs 1.27 for all base
sightings), but many are fine tags (b4: 72 checkable, 45 under 5 px).

## Calibrated vs uncalibrated

Uncalibrated `RefineEdges` (no undistortion) is cheaper: base 466 µs vs 670 µs. The check saves 350 µs
(75%) uncalibrated vs 518-550 µs (77-82%) calibrated. Same tag losses.

## Recommendation

- **Best variant: b4 (`EARLY_REJECT=4`, `EARLY_MODE=border`).** It keeps 99.55% of sightings and still saves
  77% of the worker CPU. The payload modes save ~30 µs more but lose 5-8x as many tags.
- **Expected live saving (ladder level 3, calibrated, 122 fps):** 518 µs x 122 = 63 ms/s, **~6% of a core
  per camera** (~0.25 cores for 4 cameras) in the replay. Live refine + decode runs ~1.3x the replay's
  (`../nontag-quads`), so up to ~8% per camera. Detect wall drops ~0.1 ms a frame (1.86 → 1.77 ms).
  Uncalibrated: ~4% of a core per camera. Levels 4/5 (GPU refine) aren't helped: the CPU is already ~134 µs
  there.
- **Not a default.** It drops ~0.45% of real sightings, including some large, close tags (up to 188 px).
  For pose that is small, but it is a real loss for ~6% of a core, and the recommended ladder default is
  moving to level 5, where it does nothing.
- **Add it to `scripts/jetson/08-select-detector.sh` as an opt-in option** (e.g. `--early-reject 4
  --early-mode border`, writing the two `Environment=` lines like `--gpu-refine`), default off, for a robot
  that has to stay on level 3 and is short on CPU. Not done in this change. Needs a live check on the bench
  first.
- If it's used, b4 only. Don't use the s-modes.

## Reproduce

```
# on the Jetson, after scripts/jetson/07-build-gpu-detector.sh
~/SpectrumJetson/tests/early-reject/build.sh
~/SpectrumJetson/tests/early-reject/run.sh                     # ~1 h at mode full, resumes
python3 ~/SpectrumJetson/tests/early-reject/analyze.py ~/build/early-reject/out
```

Note: `07-build-gpu-detector.sh` applies every `patches/detector-*.patch`, so a rebuilt `~/build/bos` already
includes `detector-20` (off unless the env var is set) and `build.sh` refuses to patch it twice; the
`detector-replay` that 07 builds then has the `--early-*` options itself.
