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
