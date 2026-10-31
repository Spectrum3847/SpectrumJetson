# Field replay accuracy judge: TXMAN1 detector settings by corner accuracy

The first study (`../RESULTS.md`) scored settings by sighting counts and a coarse good/bad label.
That can't see ~1 px accuracy differences. This one measures corner accuracy directly, without
the robot pose, and compares each variant to the base **paired, on the sightings both found**.
Written as checkpoints while the work runs.

Files: `judge.py` (the judge; runs on the Jetson, needs cv2), `run_variants.sh` (the new knobs'
replays, one far_replay at a time on the Jetson, tj rules as `../run.sh`). New `far_replay`
options (off by default; output unchanged without them): `--subpix W`, `--edgefit`,
`--edgefit-undist`, `--no-refine-edges`, `--cos X`, `--nmaxima N`.

## Checkpoint 1: the judge, and its resolution

Three measures:

1. **In-frame consistency (the main score).** Per frame, using only tags both variants found:
   each tag's corners reprojected from the camera pose solved (SQPnP) from the other tags; rms px.
   18,936 common sightings for near-identical variants. The error has a floor (layout,
   calibration, other tags) shared by both variants, so the *paired difference* is what counts.
2. **Static jitter.** Still stretches (10+ frames), corner robust std per tag. The robot's
   odometry/gyro can't find them: they read ~0 through stretches where the tags moved 20–270 px
   (median drift 42 px). So stillness comes from the images (median tag-centroid step
   < 0.3 px/frame in the base, common-mode drift checked < 1 px). That gives only 13 stretches /
   32 tag-stretches across 6 matches (Q19, Q32, r19). Slight selection bias toward the base.
3. **Smoothness** while moving slowly: residual of a 7-frame quadratic per corner coordinate.
   Base 1.14 px: dominated by real camera motion (vibration), so it's a weak judge (it misses
   0.2 px of added noise). Reported but not used for decisions.

Validation (degraded variants, paired against the base, 95% bootstrap CIs over frames/stretches):

| Variant | In-frame p50 | p75 | p90 | Static jitter median |
|---|---|---|---|---|
| base | 1.284 px | 3.64 | 9.14 | 0.084 px |
| base + 0.1 px noise | +0.066 (CI +0.050..+0.081) | +0.13 | +0.41 | +0.050 (CI +0.034..+0.058) |
| base + 0.2 px noise | +0.23 (CI +0.21..+0.25) | +0.56 | +1.6 | +0.136 (CI +0.117..+0.147) |
| base + 0.5 px noise | +0.99 (CI +0.96..+1.02) | +1.8 | +6.7 | |
| half (640x400), 7,396 common | 1.358 -> 1.615 (+0.26, CI +0.21..+0.30) | +0.66 | +2.4 | n/a (9 tag-stretches) |

- **Resolution:** the in-frame median resolves about **±0.02 px** (CI half-width on a paired
  difference), and 0.1 px of added corner noise is clearly detected. The jitter measure resolves
  ~±0.015 px but on few stretches.
- **The base's corner noise is tiny: ~0.08 px static jitter.** So the 1.3 px in-frame median is
  almost all systematic (layout/calibration/mount of the field tags, per-tag corner bias), not
  detection noise. Settings that only change noise can't move it much; ones that change the
  corner *bias* (refinement) can.
- The old study's "640x400 corners move 0.27 px" is real accuracy loss: +0.26 px in-frame median.

## Checkpoint 2: the existing variants, re-scored

Paired against the base (mse 10, mwbd 20, half-res quad search, far off). "Lost" and "gained" are
sightings only one side has, with their own in-frame error (all of that variant's tags in the
frame). The base's in-frame error over all checkable sightings is median 1.28 px, p90 9.14.

| Variant | Sightings | Common: in-frame p50 / p90 change | Lost: n (checkable, median px, >20.4 px) | Gained: n (checkable, median, >20.4) |
|---|---|---|---|---|
| mse 2.5 | 38,383 | **0.000 / 0.000** (identical corners) | 107 (32, 6.2, 2) | 1 (1, 10.8, 0) |
| mse 15 | 38,493 | 0.000 / 0.000 | 0 | 4 (0 checkable) |
| mse 20 | 38,496 | 0.000 / 0.000 | 0 | 7 (1, 10.6, 0) |
| mwbd 5 / 10 | 38,483 | 0.000 / 0.000 | 7 (4, 6.1, 0) | 1 (1, 14.5, 0) |
| mwbd 30 | 38,482 | +0.002 / 0.000 | 11 (2, 6.1, 0) | 4 (1, 7.7, 0) |
| mcp 50 | 38,489 | identical output | 0 | 0 |
| mcp 100 | 35,130 | 0.000 / 0.000 | 3,359 (1,250, **1.9**, 112) | 0 |
| fullres | 41,711 | **+0.032 (CI +0.019..+0.050)** / −0.06 (n.s.) | 1,278 (495, 3.3, 24) | 4,500 (2,220, **1.18**, 66) |
| far | 40,217 | 0.000 / 0.000 | 0 | 1,728 (540, **0.95**, 22) |
| half (640x400) | 22,384 | **+0.26 (CI +0.21..+0.30)** / +2.4 | 16,369 | 264 |

- **mse, mwbd and min_cluster_pixels never move a corner.** On every common sighting the
  corners are bit-identical (static jitter identical too). They only decide which quads survive,
  so they can't improve accuracy. "Already optimal" was the right answer for them, and now it's
  measured, not inferred.
- What they gate: mse 2.5 drops 107 sightings with median in-frame error 6.2 px (5x typical), so
  they are poor but mostly not wild (2 of 32 checkable > 20.4 px). mse 15/20 add 4/7 sightings,
  too few to matter. mcp 100 drops 3,359 sightings that are as good as average (median 1.9 px).
- **Full-res search:** corners on common tags are very slightly *worse* (+0.03 px median), and
  its extra finds are good (median 1.18 px). Far search's finds are better still (0.95 px).
- Static jitter is the same for everything here (0.084 px), the far search included.

## Checkpoint 3: corner refinement knobs

The same base settings plus one refinement after detection. Every sighting is common: refinement
moves corners and never adds or drops a tag (except refine_edges off, which changes decoding).
Refine time is CPU, one thread, per frame (2 cameras' tags).

| Variant | In-frame p50 change (CI) | p90 change | Static jitter (base 0.084 px) | Refine ms/frame |
|---|---|---|---|---|
| cornerSubPix 3x3 (`--subpix 1`) | +0.25 (+0.23..+0.27) | +2.1 | 0.128 | 0.05 |
| cornerSubPix 5x5 (`--subpix 2`) | +0.99 (+0.96..+1.03) | +7.2 | 0.241 | 0.04 |
| cornerSubPix 7x7 (`--subpix 3`) | +0.80 (+0.75..+0.85) | +5.7 | 0.180 | 0.03 |
| edge-line fit, pixel space (`--edgefit`) | +0.46 (+0.43..+0.48) | +2.3 | 0.164 | 0.11 |
| edge-line fit, undistorted (`--edgefit-undist`) | +0.46 (+0.44..+0.49) | +2.1 | 0.164 | 0.17 |
| edgefit-undist + subpix 2 | +1.16 (+1.11..+1.20) | +7.5 | 0.257 | 0.22 |
| detector's RefineEdges OFF (`--no-refine-edges`) | **+0.73 (+0.69..+0.75)** | +5.8 | 0.111 | (−0.3 ms detect) |

- **Every post-refinement makes corners worse.** cornerSubPix assumes a saddle (checkerboard)
  corner. A tag corner is an L-corner on a black square, so it gets pulled off it. The edge-line
  fit (strongest gradient, subpixel, weighted line fit, intersect) doubles the jitter and adds
  +0.46 px.
- **Undistortion order doesn't matter:** fitting the edge lines in undistorted or pixel space
  differs by < 0.01 px at the median. Lens curvature over one tag edge is negligible here.
- **The 971 detector's own RefineEdges is worth 0.73 px of median error** (and refine off also
  swaps 1,353 good-ish sightings for 741 bad ones, median 17 px). It's already on and is the best
  corner estimate tried. Nothing cheap to add after it.
