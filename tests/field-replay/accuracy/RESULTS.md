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

## Checkpoint 4: detector internals, the cos_critical x mse sweep, the mse curve

What bos honours on the GPU path (third_party/971apriltag): `min_white_black_diff`,
`min_cluster_pixels` (floor 24), `max_line_fit_mse`, `cos_critical_rad` (the quad fit),
`refine_edges` (CPU decode). `quad_sigma` (pre-blur) and `decode_sharpening` aren't used
anywhere. `max_nmaxima` is compiled in as 10, and any other value CHECK-fails, so `--nmaxima`
is a no-op in practice. A base re-run (`a_base`) gives bit-identical output, so the replay is
deterministic.

**Timing:** today's replays (all variants, `a_base` included) ran at 5.8–6.4 ms detect/frame against 3.1 ms
for the original base. That's the conditions (clocks/load), not the knobs: `a_base` itself is
5.98 ms. Against it, no mse/cos variant costs anything measurable (±0.4 ms, which is noise).

**max_line_fit_mse curve** (cos_critical default, cos 10° = 0.985). Lost/gained are relative to mse 10, with in-frame error
(median px; base all-sightings median 1.28):

| mse | Sightings | Lost vs 10 (checkable: median, >20.4 px) | Gained vs 10 | Corners on common sightings |
|---|---|---|---|---|
| 2.5 | 38,383 | 107 (32: **6.2 px**, 2) | 1 (10.8 px) | identical |
| 5 | 38,468 | 22 (5: 7.0 px, 1) | 1 | identical |
| 7.5 | 38,483 | 6 (3: 3.6 px, 0) | 0 | identical |
| **10 (base)** | 38,489 | | | |
| 15 | 38,493 | 0 | 4 (none checkable) | identical (p90 −0.002, n.s.) |
| 20 | 38,496 | 0 | 7 (1: 10.6 px) | identical (p90 −0.002, n.s.) |

**cos_critical_rad x mse** (0.94 = 20°, default 0.985, 0.996 = 5°): cos changes 0–8 sightings in
any column (mse 2.5: 107/111/107 lost; mse 20: +7/+8/+7 gained). Corners are identical on common
sightings. It's a gate like mse.

## Recommendations

1. **Settings that don't matter for accuracy:** max_line_fit_mse (2.5–20), cos_critical_rad
   (0.94–0.996), min_white_black_diff (5–30), min_cluster_pixels (24–100). They never move a
   corner; they only gate quads. Over 6 matches, mse moves 6–107 sightings out of 38,489 (≤0.3%).
   The ones dropped below 10 are poor (median 3.6–7 px, 5x typical) but rarely wild (≤2 over
   20 px). Keep mse 10: the curve is flat from 7.5 to 20. mse 5–7.5 would trim 6–22 poor
   sightings at no accuracy cost, but it's a wash.
2. **Settings that do matter, by measured accuracy:**
   - **RefineEdges ON (current): worth 0.73 px of median in-frame error.** Never turn it off.
   - **1280x800, not 640x400: 0.26 px** (plus 42% more sightings).
   - Full-res quad search: −0.03 px on common corners (slightly worse) but +4,500 good
     sightings, at 3.5x the detect time. The far search's finds are the most accurate
     (0.95 px median).
3. **Don't add a post-refinement.** cornerSubPix (+0.25 to +1.0 px) and the edge-line fit
   (+0.46 px, either undistortion order) are both worse than the detector's corners.
4. **Where the error actually is:** corner noise is ~0.08 px static, but the in-frame error is 1.28 px
   median / 9.1 px p90, and 5.6 px within 10 px of the edge. So it's systematic: field layout
   (tag positions), lens calibration (worse at the edges), and maybe per-tag corner bias from
   blur/JPEG. The next accuracy gains are in calibration (more edge coverage) and the field map
   (`field-map` / fieldcal), not detector knobs.
5. **Needs new recordings** (can't be replayed from this data): exposure and gain (blur vs noise),
   JPEG quality (MJPEG artifacts at tag edges), and a deliberate still period on the field (the
   recordings have only 13 usable still stretches, and odometry can't find them). A one-minute
   still capture at 2–3 distances per camera, at two exposures and two JPEG qualities, would give
   the static-jitter judge thousands of tag-stretches instead of 32.

## Checkpoint 5: decimation 1.5, emulated (2026-10-31)

Would a quad search at 1/1.5 resolution (instead of the detector's fixed 1/2) be worth building?
Emulated with `detector-replay --scale 1.3333`: each frame resized 4/3 (bilinear, padded to
1712x1072) and the calibration with it, so the detector's /2 is /1.5 of the camera frame; corners
mapped back x3/4. The emulation also refines corners on the interpolated frame (a real dec-1.5
detector would refine at native resolution), so `basecorners.py` makes a "_bc" copy that takes the
base's corners wherever the base found the same tag: that isolates "finds more tags" from "moves
corners". All 6 matches (13 sessions), `--mwbd 20 --mse 10`, replays `run_variants.sh d15s_*` with a
fresh base and far run in the same conditions. Range from `../analyze.py --compare` (robot-pose
good/bad; single-tag distance).

| Variant (vs base, far off) | Sightings | Lost (checkable, in-frame median) | Gained (checkable, median, >20.4 px) | Common corners, in-frame p50 | Detect ms/frame |
|---|---|---|---|---|---|
| base (dec 2) | 38,489 | | | 1.269 | 6.03 |
| far search on | 39,844 (+3.5%) | 0 | 1,355 (383, **0.90 px**, 9) | identical | 6.07 + 2.37 far |
| dec 1.5 | 40,453 (+5.1%) | 802 (341, 3.11 px) | 2,766 (1,345, 1.09 px, 49) | 1.253 (CI −0.031..−0.003) | 12.80 (6.14 is the CPU resize) |
| dec 1.5, base corners | 40,453 | same | same (1.11 px) | identical | |
| dec 1.5 + far | 41,244 (+7.2%) | 748 (323, 3.18 px) | 3,503 (1,500, 1.10 px, 58) | 1.253 (CI −0.030..−0.002) | 14.71 + 2.30 far |
| dec 1.5 + far, vs dec 2 + far | +1,400 net | 1,023 (431, 2.52 px) | 2,423 (1,193, 1.19 px, 51) | 1.250 → 1.234 | |

Robot-pose labels: dec 1.5 has 29,668 good (base 27,869, far 28,942; +1,799 vs +1,073) and 4,314
bad (base 4,143). Static jitter unchanged (0.084 → 0.085 px, n.s.).

- **It doesn't add range.** Good side p1 18.8 px vs 18.5, range p99 7.57 m vs 7.73 m, max 9.20 vs
  9.24 m. The gained tags are mid-size (side p10/p50/p90 21/35/53 px, median 3.5 m), not the
  smallest; the lost ones are similar sizes (18/29/74 px) and poorer (in-frame 3.1 px). So it
  reshuffles which quads survive segmentation, with a net +5%, rather than seeing farther.
  The far search's finds are better (0.90 vs 1.09 px median) and it loses nothing.
- **Corners:** −0.016 px median on common sightings, but that's the interpolated-frame
  refinement; with the base's corners the gains are the same, so the count is the real effect.
- **Cost.** Replay: detect minus resize is 6.66 vs 6.03 ms (+0.6 ms, +10%), but replay times are
  dominated by CPU decode/refine. A real dec-1.5 detector runs its front end (threshold, labeling,
  `BlobDiff`, the sorts: most of the ~1.7 ms GPU per busy TXMAN frame, docs/TECHNICAL.md
  `detector-13`) on (2/1.5)² = 1.78x the pixels: roughly +1 ms GPU and +0.5–1 ms `Detect()` wall
  per camera, about +50% of the ~2 ms Detect, plus bos's hard-coded /2 to rework (threshold tiles,
  4 MP limit).
- **Verdict: don't build it.** +5% sightings (+1,400 over far search) for ~+50% detect time and a
  detector rework, with no range gain. The far search already gets the small/far tags more cheaply
  and more accurately.
