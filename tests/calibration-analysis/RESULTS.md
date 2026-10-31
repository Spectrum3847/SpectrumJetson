# Calibration analysis: does calibration explain the ~1.3 px TXMAN1 corner error?

**Answer: yes, at the image edges and in the tail, and partly in the median.** Inside the area the
snapshots covered, the calibrations fit to about 0.1 px. But the snapshots never reached the outer
ring of the image, and the deployed 8-coefficient rational models **fold over** (their radial curve
turns back) just beyond the data. On the field, the error grows with image radius exactly where
coverage ends. Swapping in a refit of the *same snapshots* (one that doesn't fold) cuts the
TXMAN1 in-frame error from **median 1.21 → 0.97 px and p90 8.2 → 4.9 px**. Better coverage
should cut it further.

Data: `calibrations/SJ-TC01-1280x800.json` (orin-left, 124 snapshots) and `SJ-TC02-1280x800.json`
(orin-right, 102). These are exactly the fx/cx/dist values in the TXMAN1 replays' `cameras.json`
(checked). The six TXMAN1 replays' `out/base` detections are 18,936 checkable sightings.

Files: `calib_lib.py` (loader; our own bundle adjustment with OpenCV projection, 5/8/12/14 coeffs,
mrcal-style 2-parameter board warp, global or per snapshot; mrcal-style rotation-compensated
projection diff; a Newton unprojection that detects the fold), `analyze.py` (items 1-4 →
`analysis.json`, `fits.npz`, `TC0x_*.png`), `field_tie.py` (item 5 → `field_tie.json`,
`field_orin-*.png`). Deps: numpy, scipy, opencv, matplotlib (pip `--target`; mrcal is not
pip-installable here, so the splined model wasn't tried). Run: `python3 analyze.py --boot 20`
(~15 min), then `python3 field_tie.py <replay dir>` (~5 min).

File-format notes: `cornersUsed` is indexed by **board corner id** (88 = 11x8), not by detection;
undetected corners are False too. `reprojectionErrors` is shorter than the detections and doesn't
line up with them. PV's "mean error" (0.58 / 0.72 px) comes from that list. Re-solving the poses
with the deployed model gives **0.150 / 0.223 px rms** on the inliers.

## 1. Coverage (`TC0x_coverage.png`)

| | TC01 (left) | TC02 (right) |
|---|---|---|
| Corners detected / mrcal outliers | 8,423 / 136 (1.6%) | 8,208 / 71 (0.9%) |
| Snapshots with a partial board (<88 corners) | 104 / 124 | 84 / 102 |
| 10x8 cells empty / with <20 corners | 16 / 38 | 21 / 35 |
| **Outer-ring cells (32): empty / <20** | **16 / 32** | **21 / 32** |
| Median corners: centre cell / ring cell | 134 / 1 | 110 / 0 |
| Corners in the four 2x2 image-corner blocks | 12, 3, 54, 20 | 7, 3, 41, 11 |
| Inliers within 40 px / 80 px of the border | 0 / 28 | 0 / 5 |
| Image beyond the largest observed radius | 8% | 12% |
| Image beyond the 99th-percentile radius | 32% | 28% |
| Board distance (min/median/max) | 0.43 / 0.64 / 0.73 m | 0.32 / 0.49 / 0.74 m |
| Board tilt median / max | 15° / 31° | 10° / 44° |

The few corners that did reach the edges are mostly the **outliers** (red in the plots). mrcal
rejected them because the model was fitted to the centre.

**Model range:** the deployed rational models stop increasing at normalized radius **1.009
(TC01)** and **0.917 (TC02)**. The image corners sit at 0.96–1.09. So 0.7% of TC01's image and
**4.0% of TC02's (its right edge and all four corners) have no valid ray at all**. A point that
should land there projects somewhere else. OpenCV's own `undistortPoints` silently returns wrong
answers there (tens of px).

## 2. Residual structure (`TC0x_residuals.png`)

- Mean residual per 16x10 cell (the systematic part): **0.066 px rms (TC01), 0.098 (TC02)**.
  The total rms is 0.150 / 0.223. Median radial residual vs radius stays within ±0.07 px out to
  r≈0.6, then reaches -0.13/-0.19 px and +0.34 px in the last sparse bins. So within the
  coverage the model is fine and the residual is mostly noise. The edges are where it bends.
- Per-snapshot rms doesn't depend on tilt (corr -0.02 / 0.14) or distance (-0.12 / -0.30). The
  snapshots are a narrow family anyway: near (≤0.74 m), mostly face-on (47% / 80% under 15°).
- **Board flatness (the board is an aluminium-sandwich commercial board).** Global warp fit:
  0.004/0.06 mm (TC01) and 0.21/0.02 mm (TC02) deflection across the board. Flat vs warped
  rms: 0.1361 vs 0.1358 and 0.2191 vs 0.2182 px. A free per-snapshot paraboloid (2 params per
  snapshot) gains only 0.001–0.004 px with a median of 0.11–0.15 mm, which is fitting noise. That's
  physically plausible for such a panel (≤0.2 mm over 330 mm) and irrelevant to the error. The
  board is not the problem.

## 3. Uncertainty (`TC0x_uncertainty.png`)

The snapshots were bootstrapped (20 resamples), each refit with the 8-coefficient model and
compared mrcal-style (best rotation fitted over the inner 90% of the observed radius; rotation
only, so range doesn't matter):

| rms projection shift | TC01 | TC02 |
|---|---|---|
| inside the observed radius (median) | 0.59 px | 0.35 px |
| beyond it | 1.58 px | 0.67 px |
| centre cells / ring cells | 0.47 / 0.81 | 0.28 / 0.48 |
| worst image-corner cell | **4.5 px** | 1.1 px |

The absolute level includes the focal-length/distortion trade-off that near, face-on boards leave
loose: refits move fx by up to 7 px with the same rms. The pattern is the point: the
edges and corners are 2–10x worse pinned than the centre.

## 4. Model check (`TC0x_model_diff.png`, `analysis.json` → fits)

| Refit (same snapshots) | TC01 rms in / ring / outliers | TC02 rms in / ring / outliers | Folds at r |
|---|---|---|---|
| deployed (PV/mrcal, 8) | 0.150 / - / 1.24 | 0.223 / - / 2.72 | 1.01 / 0.92 |
| 5 coeffs | 0.152 / 0.253 / 1.41 | 0.224 / 0.381 / 3.01 | 0.98 / 0.90 |
| 8 coeffs (our refit) | 0.136 / 0.160 / 0.39 | 0.218 / 0.243 / 0.66 | 1.35 / 2.62 |
| 8, outliers kept | 0.138 / 0.170 / 0.23 | 0.219 / 0.247 / 0.43 | 2.64 / 2.72 |
| 12 (thin prism) | 0.136 / 0.168 / 0.35 | 0.216 / 0.280 / 0.68 | 2.33 / 2.87 |
| 14 (tilted) | 0.135 / 0.162 / 0.32 | 0.215 / 0.273 / 0.68 | 2.53 / 2.93 |

- 5 coefficients are too few: the ring residual is 1.6x worse and the outliers are badly explained.
  Higher models all fit the data equally (0.135–0.138). Outside the data they disagree by
  **7–15 px median (TC01), 10–13 px (TC02)**, and by thousands of px where the deployed model
  folds. That means the edge behaviour is set by luck, not by data.
- Our 8-coefficient refit converges a bit lower than the deployed solve (0.136 vs 0.150) with very
  different coefficients (k2 2.7 vs 0.03). The rational model is degenerate with this data.
- Keeping mrcal's outliers barely changes the inlier fit (+0.002 px). The outliers fit at 0.23 /
  0.43 px, so they were mostly **good edge corners thrown away**, not bad detections.

## 5. Tie to the field (`field_orin-*.png`, `field_tie.json`)

judge.py's in-frame (leave-one-tag-out) measure on the base detections, keeping each corner's
image position:

Median corner error by normalized radius (deployed calibration):

| radius | 0–0.2 | 0.2–0.4 | 0.4–0.6 | 0.6–max observed | max obs.–0.95 | >0.95 |
|---|---|---|---|---|---|---|
| orin-left (max obs. 0.88) | 0.67 | 0.72 | 1.15 | 1.96 | **5.9** | **14.7** |
| orin-right (max obs. 0.83) | 1.14 | 1.06 | 1.12 | 2.55 | **7.1** | — |

- **It isn't tag size.** Beyond the calibrated radius, error is 5.6–8.7 px at *every* tag size
  (20–30, 30–50, 50+ px). Inside, those same sizes give 0.76–1.6 px.
- Per 10x8 cell, the field error ranks with the calibration's bootstrap uncertainty (Spearman
  **0.56 left, 0.51 right**) and inversely with calibration corner count (0.50 / 0.29). Against
  tag size the correlation is only 0.18 / 0.12. Ring cells median 2.19 / 1.81 px vs centre 1.17 / 1.49.
- **Direct test: re-solve the field with the refits instead of the deployed calibration**
  (same detections):

| calibration used | all: median / p90 | orin-left median / p90 | orin-right median / p90 |
|---|---|---|---|
| deployed | 1.205 / 8.15 | 1.04 / 6.32 | 1.51 / 10.96 |
| 5-coef refit | 1.222 / 8.69 | 1.05 / 6.60 | 1.52 / 12.30 |
| 8-coef refit | 1.040 / 5.21 | 0.95 / 5.12 | 1.18 / 5.44 |
| 12 / 14-coef refit | 1.03 / 5.15–5.16 | 0.92–0.93 | 1.19 |
| **8-coef, outliers kept** | **0.974 / 4.95** | **0.89 / 4.93** | **1.10 / 4.98** |

  The two calibrations that fold (or are too stiff) at the edge are the two worst. orin-right's
  p90 halves. The detector also uses the calibration to undistort tag edges during refinement,
  so a re-run of the replays with a new calibration may gain slightly more. The remaining
  ~1 px median includes the centre floor (0.67–1.1 px), which is layout/mount/per-tag bias plus
  the poorly-pinned focal length.
- Caveats: judge.py's median of 1.28 px covers a slightly different sighting set (paired
  variants); here it's 1.21 px. The leave-one-out pose comes from the other tags, so an error
  at the edge also shifts the pose used for central tags.

## 6. Recommendations

The board is a flat, accurately printed commercial panel; keep it. The fixes are coverage,
distribution, and the model:

1. **Cover the whole image, especially the outer ring and the four corners.** Target: every
   10x8 cell, ring included, has ≥3 snapshots and ≥50 corners. Each image-corner 2x2 block needs
   ≥150 corners (today: 3–54). Get corners to within ~10 px of the border. **Keep partial boards**:
   ChArUco identifies every corner, so a board hanging off the edge is the *only* way to get
   corners into the extreme corners. The old 42% outlier rate likely reflects a model fitted to the centre rather than
   bad detections: here the outliers fit at 0.23 px once they are kept (§4).
2. **Distribution:** about 60–100 snapshots total. About 40% should be centre/mid at varied tilt,
   and about 60% should deliberately target edges/corners. Board distance should span 0.4–1.5 m (today ≤0.74 m):
   far snapshots fill corners with small, dense corner sets. Use tilts of 20–45° about both axes in
   ≥30% of snapshots (today 0–1% beyond 35°). That pins fx vs distortion (the 7 px fx spread).
3. **Model:** keep the 8-coefficient rational model, or a splined model if mrcal's full solver
   becomes available. **Reject any calibration that folds inside the image**: check that the
   radial curve increases monotonically out past the image-corner radius (`calib_lib.max_radius`
   > max corner radius + margin). Never use 5 coefficients for this lens. Turn mrcal's outlier
   rejection threshold up, or re-admit rejected edge corners once coverage is there; review
   outlier *positions*, not just the rate.
4. **Accept a calibration only if:** inlier rms ≤0.25 px, no empty cell, the model doesn't fold,
   bootstrap uncertainty ≤0.3 px over ≥95% of the image (≤0.6 px at the corners), and fx stable to
   ±1 px across bootstrap resamples.
5. **Scale check:** not needed for the board. Do a quick one anyway after any recalibration: a
   tag at a measured 2.00 m should read 2.00 ±0.01 m.
6. **Immediate step, no new snapshots:** re-solve the existing snapshots with outliers kept and a
   fold check (the "8, outliers kept" fit here). That gives −0.23 px median and −40% p90 on the
   TXMAN1 replays. Then recalibrate properly with the UI below.

### Calibration UI requirements

1. **Full-screen live view** at the calibration resolution, not a thumbnail. Detected corners are
   drawn live, partial boards are accepted, and the current board's corners are shown in a
   distinct colour.
2. **Coverage overlay:** a 10x8 grid (or finer) tinted by accumulated inlier corners per cell,
   with targets as above. The outer ring and the four 2x2 corner blocks are outlined, with a
   numeric count per cell on demand.
3. **"Move board here" guidance:** highlight the emptiest cell, show the target pose (position,
   distance band, tilt axis/angle as a ghost board outline), and tick it off when matched. Also
   prompt for far (≥1.2 m) and tilted (≥30°) shots until each has its quota.
4. **Auto-capture** when the board is still (corner motion <0.3 px/frame for ~0.3 s) and adds new
   coverage. Reject blurred frames and near-duplicates, and allow manual capture.
5. **Live quality readout** after each snapshot (run the solve in the background): inlier rms;
   outlier count and an outlier-position map; coverage % of cells meeting target; fx/cx/cy with
   bootstrap ±; projection-uncertainty heatmap (toggle overlay); and a **model-fold check**
   (red banner if the model folds inside the image).
6. **Pass/fail gate** with the acceptance criteria in §6.4, plus a per-criterion "what to do
   next" hint. Save is blocked (or needs an explicit override) when it fails.
7. Show the **snapshot list** with per-snapshot rms, distance, tilt and coverage contribution, and
   let the user delete a snapshot.
8. **Export** the full observations (with correctly aligned per-corner residuals and outlier
   flags) so this analysis can be re-run on the result.
