# Full-tag refinement ("tagfit"): fitting every bit edge, not just the outline

Status (2026-11-06, pass 3): wired into sc-vision and PhotonVision's native NAPA path behind `SPECTRUM_TAGFIT=1`,
off by default; branch `sc/tagfit` (off `sc/mjpeg-napa`). Code: `native/sc-vision/src/tagfit.{c,h}` and `native/sc-vision/tools/tagfit_bench.cc`. Build
both with `native/sc-vision/build.sh`. Lens helpers `pose_undistort_px` and `pose_distort_px` were added to
`pose.{c,h}`.

**Pass 3 (section 00: speedups, the switch, live A/B) and pass 2 (section 0) supersede the defaults and CPU figures in sections 3–5.**

## 00. Pass 3: speedups and the live switch (off by default)

All µs figures here were **measured on the Pi 5** (Raspberry Pi 5 Model B Rev 1.1, kernel 6.12, governor
`performance`, `max_current` 5000). Nothing was emulated. The robot program was running; PhotonVision was
stopped. The figures are synthetic medians from `tagfit_bench`: 800 frames as 80 motion sequences of 10
frames (`--seq 10`), 696 tags. Each test run also times and compares the double-precision cold reference
(the pass 2 default) on the same tag. Live numbers use NAPA min_tag 22.

### Switches

| where | switch | default |
|---|---|---|
| sc-vision | `SPECTRUM_TAGFIT=1` or `--tagfit` (needs `--calib`) | off |
| PhotonVision native path (`libspectrum-napa-apriltag.so`, StreamSink) | `SPECTRUM_TAGFIT=1` in PhotonVision's environment | off |
| both | `SPECTRUM_TAGFIT_WARM` (1), `SPECTRUM_TAGFIT_WARM_ITERS` (1), `SPECTRUM_TAGFIT_FAST` (1: float32 + LUT), `SPECTRUM_TAGFIT_ITERS` (2), `SPECTRUM_TAGFIT_MAX_CELL` (0: all sizes) | as shown |

- **Published frames only.** The refinement runs where a frame's tags are final and about to be published:
  - sc-vision: between NAPA and the pose. Full-scale frames only.
  - JNI: in the StreamSink's `finish`. It runs before the native publish and before the tags are handed to
    Java, so it applies whether the result is published natively or by Java.
  - Both pipelines publish every frame they process. Frames the policy skips are never decoded. So the
    rule reduces to "never anywhere else", and the identity checks matter here.
  - The identity checks still compare NAPA's own unrefined corners. Both pipelines keep a copy for them.
    (Live check: 149 + 151 ok, 0 differ.)
- **Camera model.** The JNI path takes the calibration that Java hands to `setNativePublish`. With no
  calibration, there is no fit.
- **No PhotonVision Java change and no NT topics.** The switch is an environment variable read by the
  native library.

### Speedups, per tag (µs, Pi 5, synthetic motion sequences)

| cell px | reference (double, exact lens, 2 iters) | float32 + NEON, no LUT | float32, no NEON | float32 + NEON + LUT | + warm start, 1 iter | cold, 1 iter (not used) |
|---|---|---|---|---|---|---|
| < 2.5 | 83 | 71 | 75 | 72 | 72 (stays cold) | 50 |
| 2.5–4 | 89 | 78 | 84 | 75 | **59** | 54 |
| 4–6 | 101 | 85 | 93 | 83 | **62** | 58 |
| 6–9 | 134 | 112 | 124 | 108 | **78** | 76 |
| 9–14 | 174 | 146 | 152 | 136 | **97** | 92 |
| ≥ 14 | 248 | 213 | 216 | 188 | **143** | 129 |

- **float32 + NEON** (the `fast` path, homography fit only):
  - The measurement loop runs in float, with analytic edge normals from the homography's derivative.
  - The normal equations are accumulated as an upper triangle and solved in double.
  - Gain: 1.15–1.30×. NEON contributes about half of that: 1.07–1.15× without it.
  - The per-sample cost is the 17-point bilinear profile. NEON has no gather, so the four pixel loads per
    point stay scalar.
- **Lens LUT.** The tabulated part is the radial factor against r², 1024 entries; the tangential terms stay
  exact. Worst error over the sensor is 0.00024 px.
  - A 2-D grid of offsets was tried first and rejected. With the 8-coefficient model, its bilinear error at
    the sensor corners was 0.16, 0.04 and 0.01 px at 16, 8 and 4 px nodes.
  - Gain: only 2–3% in the float path. In the double path it was 3–9% *slower*. The exact rational model is
    one division and about 25 flops, so it was never the third of the cost that pass 2 estimated.
- **Warm start.**
  - Start from this frame's NAPA corners plus the previous frame's correction (refined − NAPA) for the same
    id, and from the previous bias. Then run 1 Gauss-Newton step instead of 2.
  - Gates: the previous frame (or the one before it), the centre moved under 2 cells, the size changed
    under 15%, and cells of at least 2.5 px.
  - The move guard is still measured from NAPA's corners.
  - Result: 1.5–1.8× faster than the reference, and 1.3× faster than the fast path alone.
  - Live, 98% of fits started warm.

### Accuracy against the reference and against truth

- **fast + LUT vs the double reference:**
  - Synthetic, clean and with noise 5 / blur 1.2: corner difference median 0.00002–0.00004 px, p99
    ≤ 0.03 px, and no difference in which tags are accepted.
  - The few 0.02–0.08 px outliers occur where the reference itself flips: the early exit at 0.005 px of
    motion, or a lobe edge tie. They also appear in a double-precision run with the LUT.
  - Real static sessions: corner, range and rotation jitter are identical to the reference, to the last
    digit or one count. Tagdist tags 3, 10 and 11 give range std 0.39 / 1.38 / 7.59 mm on both.
  - Moving sessions: live2 median 0.046 px and TXMAN1 Q17 median 0.00004 px. Blurred lobes make single
    samples flip.
- **Warm 1 step vs cold 2 steps,** synthetic motion against truth (corner median / p90 px):

  | cell px | cold 2 | warm 1 |
  |---|---|---|
  | 2.5–4 | 0.053 / 0.122 | 0.054 / 0.105 |
  | 4–6 | 0.044 / 0.283 | 0.044 / 0.278 |
  | 9–14 | 0.022 / 0.039 | 0.021 / 0.037 |
  | ≥ 14 | 0.019 / 0.040 | 0.017 / 0.027 |

  - Range and rotation errors are equal or better.
  - Flips at 2.5–4 px: 2 cold, 3 warm.
  - Below 2.5 px cells, warm was worse (corner p90 0.148 → 0.175), hence the 2.5 px gate.
  - Cold 1 step, by contrast, is clearly worse: ≥ 14 px p90 0.078, and < 2.5 px median 0.150.
- **Warm 1 step, real static sessions:**

  | session (min tag 22) | reference range std mm | warm 1 range std mm |
  |---|---|---|
  | tagdist tag 3 (0.8 m) | 0.39 | 0.25 |
  | tagdist tag 10 (1.64 m) | 1.38 | 1.26 |
  | tagdist tag 11 (3.33 m) | 7.60 | 7.26 |
  | cd-ctrl | 0.98 | 0.97 |
  | e2_g128 | 1.16 | 1.16 |

  - Rotation std: equal or lower.

### Live A/B (sc-vision, both cameras at once, 40 s each)

Setup:
- Thriftiest: core 3, FIFO 40, exposure 50, gain 32.
- Swyft: core 2, FIFO 40, exposure 10, calibration from PhotonVision's database.
- Both at 120 fps, min tag 22, a static scene with 2.4–2.9 tags per frame.
- Latency is to the pose (`t_pose`). CPU is the per-frame CPU of the vision thread.

| camera | tagfit | last packet → pose p50 / p99 ms | first packet → pose p50 / p99 ms | CPU (% of a core) | fit µs/tag |
|---|---|---|---|---|---|
| Thriftiest | off | 0.092 / 0.129 | 7.656 / 7.764 | 34.0 | – |
| Thriftiest | on (warm) | 0.379 / 0.464 | 7.965 / 8.095 | 36.6 | 115 |
| Thriftiest | on, cold | 0.484 / 0.596 | 8.074 / 8.225 | 37.9 | 180 |
| Swyft | off | 0.131 / 0.212 | 7.663 / 7.787 | 32.6 | – |
| Swyft | on (warm) | 0.406 / 0.501 | 7.934 / 8.065 | 35.8 | 97 |
| Swyft | on, cold | 0.537 / 0.631 | 8.064 / 8.199 | 37.6 | 141 |

At 2.5–3 tags per frame, tagfit with the warm start adds about 0.28 ms to the latency to pose, and 2.6–3.2
points of one core per camera at 120 fps (about half of that at 60 fps). The cold fit adds about 0.4 ms.

### Still to do

- PhotonVision's native path is built (`scripts/systemcore/build-napa.sh`) and `napa_test` passes on the Pi.
  It has not been run live under PhotonVision with `SPECTRUM_TAGFIT=1`.
- Camera calibration is deferred. As section 0 notes, the reprojection error and ambiguity gates should
  wait for it.
- Further CPU savings:
  - Skip the final measuring pass on warm fits. It is only the rms guard, about a third of a warm fit.
  - A fixed-point or 8-bit profile, so the gather is cheaper.
  - `SPECTRUM_TAGFIT_MAX_CELL` (e.g. 9) to fit only far and mid tags.

## 0. Pass 2: why tagfit looked worse, and the cheaper default

The SystemCore was unreachable for this pass. Everything ran on the laptop: the aarch64 `tagfit_bench`
under qemu in Docker, against the WPILib SystemCore sysroot.
- **Data:** the static recordings in `bench-archive-20261106/results`: `ctrl/cd`, `sweep1/e2_g128`,
  `sweep1/e50_g32`, and `tagdist/thr`, which has tags 3, 10 and 11 at 0.8, 1.64 and 3.33 m. Calibration: the
  SystemCore's `calib.json`, copied verbatim.
- **Synthetic:** 4 seeds × 250 frames, 862 tags, cached with `--cache`.
- **µs:** qemu time ÷ 17.4. That factor was measured against the earlier on-Pi run, and it held to ±3% in
  every size bin.

### Root causes

| symptom | cause | evidence | status |
|---|---|---|---|
| Real recordings: range differs from NAPA's by up to ±0.75% | **NAPA's edges carry an uncorrected black/white bias from the camera's tone curve.** tagfit measures that bias (δ) and removes it. NAPA's `border_bias` only runs when it sees clipping (white ≥ 250 or black ≤ 4). | Fitted δ = −0.21 px on ctrl and tagdist and +0.07 to +0.12 px on the sweep sessions. The range shift follows the sign of δ in all 5 tags. Synthetic with a gamma 2.2 tone curve: NAPA range error +0.27 to +1.46% by bin, tagfit **+0.01 to +0.06% at 4 px cells and up**. κ (border width vs payload cells) fits to 0.000 to 0.003 cell, so the printed tag is fine. | Not a tagfit fault; NAPA is the one that is off |
| Real recordings: reprojection error +0.03 to +0.07 px, ambiguity up | **These metrics compare against each method's own corners under the calibration.** Ambiguity is best/alt reprojection, so it rises with reprojection error. A 6-DoF pose fit to the edges has 0.171 px edge RMS against 0.142 px for the 8-DoF homography: the image departs from "calibrated camera + flat square" by about 0.1 px RMS. That points to calibration error, which the 100 edges show and 4 corners hide. | In synthetic (exact calibration, with or without gamma), tagfit lowers both. | Not an accuracy loss. Recommend refitting the intrinsics before relying on reprojection or ambiguity gates. |
| e2_g128 rotation jitter 0.137° → 0.177° | **Too few outline samples.** Tilt is carried by the outline's lever arm, and the old default sampled 3 per cell (24 per side) against NAPA's ~100. | With dense outline samples (`--outline-px 3`) and one sample per interior segment: **0.137° → 0.078°**. The previous default gives 0.128° with the current code. | Fixed in the default |
| Synthetic 4–9 px cells: median range error 0.047 → 0.058% (linear render only) | A residual scale bias in the edge estimator, about 0.006 px per side (signed range −0.013 → −0.040%). Limiting the lobe width (`--lobe-cells`) or dropping 1-cell features (`--min-run`) did not remove it, and the latter made things worse. | It appears only with an ideal linear sensor. With any tone curve, NAPA's own bias is 20–40× larger, and tagfit wins (1.12% → 0.06%). | Explained, not fixed; too small to matter |

### Edge-segment sweep (synthetic medians, NAPA → fit; real = tagdist tag 3, 19 px cells)

| segments | 2.5–4 px corner | 4–6 px corner | ≥ 14 px corner p90 | far flips (2.5–4) | real rot std ° | µs, 4–6 / ≥ 14 px |
|---|---|---|---|---|---|---|
| NAPA | 0.123 | 0.051 | 0.412 | 11 | 0.408 | – |
| outline only (32) | 0.105 | 0.048 | 0.087 | 7 | 0.213 | 48 / 123 |
| + inner border (~56) | 0.079 | 0.045 | 0.041 | 5 | 0.164 | 64 / 169 |
| top 48 | 0.076 | 0.045 | 0.041 | 9 | 0.161 | 69 / 183 |
| top 64 | 0.069 | 0.043 | 0.035 | 7 | – | 90 / 241 |
| all (~100), 3 per segment (pass 1 default) | 0.069 | 0.039 | 0.035 | 6 | 0.137 | 94 / 260 |
| **all, 1 per interior segment, outline every 3 px (new default)** | **0.069** | **0.039** | **0.033** | **6** | 0.160 (e2_g128: **0.078**) | **79 / 213** |

- **Optimum: all segments.** Each segment that is dropped costs accuracy at every size. "Far from the centre"
  and "long runs" ordering (`--max-seg`) is the best way to cut segments if they must be cut, but it saves
  little, because each interior segment costs only one sample.
- **Joint grid lines are already the model.** Fitting the 9 + 9 grid lines jointly is what the homography
  does: every segment on a line shares the model.
- **The real cost is samples per segment.** One sample per interior segment plus a dense outline keeps
  accuracy and saves 15–45%.

### CPU per tag

Pi-equivalent µs (qemu ÷ 17.4), median, by cell size:

| config | < 2.5 | 2.5–4 | 4–6 | 6–9 | 9–14 | ≥ 14 |
|---|---|---|---|---|---|---|
| pass 1 default | 76 | 86 | 94 | 175 | 260 | 260 |
| **new default** | **64** | **72** | **79** | **107** | **142** | **213** |
| new default, 1 iteration | 39 | 43 | 48 | 64 | 83 | 129 |

With 1 iteration instead of 2:
- Synthetic is near-equal for cells under 9 px. The ≥ 14 px corner p90 rises from 0.033 to 0.072 px.
- The real tag 3 gets worse: range std 0.40 → 0.97 mm.
- Use 1 iteration only with a warm start from the previous frame's fit, which is not built yet.

**Not done in this pass:** float32/NEON, an undistortion LUT, and the warm start. The lens call is one exact
`pose_distort_px` per sample, roughly a third of the per-sample cost.

**Two IPPE branches with the 6-DoF fit (`--pose --branch-amb 0.2`)** gave no reduction in flips (13 vs 14
for 1 branch, against 11 for the homography). At small tags the edges do not separate the branches either.
It is dropped.

### Recommendation (updated)

- Use the new default for **all tag sizes**: homography, lens model, bias term, every segment, one sample per
  interior segment, outline every 3 px, 2 iterations.
- It is equal to or better than NAPA on every accuracy measure in every regime tested, except the
  0.006 px/side linear-render case above.
- **Gate on ambiguity and reprojection error only after refitting the intrinsics.**
- Next steps for CPU: the warm start with 1 iteration (about −40%), refining only published frames, and NEON.

## 1. Where the idea comes from: Eagle Eye

- **Chief Delphi.** In the NAPA thread
  ([post 75](https://www.chiefdelphi.com/t/introducing-napa-a-faster-apriltag-detector/525801/75)),
  ElliotScully says his detector fits the whole tag, interior and exterior corners, while NAPA refines only
  the outline. The post includes a chart of the full fit off vs on, but gives no numbers. His project thread
  is ["EagleEye: PhotonVision alternative with 120 AprilTag FPS on RasPi 5"](https://www.chiefdelphi.com/t/eagleeye-photonvision-alternative-with-120-apriltag-fps-on-raspi-5/523976).
- **Repository.** Contrary to our first guess, the repo is
  [Scythe-Engineering/EagleEye-Vision-System](https://github.com/Scythe-Engineering/EagleEye-Vision-System)
  (docs: scythe-engineering.github.io/EagleEye-Docs).
  - `main` (Python, pupil-apriltags plus OpenCV `solvePnPRefineLM`) does not have the full fit.
  - The full fit is on branch `work/apriltag-optimization`, in a Rust detector:
    `src/rust_implementations/modules/custom_apriltag_detector/src/decode.rs`, function `refine_grid`.
- **License: PolyForm Noncommercial 1.0.0.** Its copyright line reads "ScytheEngineering", and commercial
  use needs a separate license. NAPA is GPL-3.0, and so is sc-vision because it links NAPA. GPL-3.0 does
  not allow the extra noncommercial restriction, so **no Eagle Eye code was copied**. tagfit is an
  independent implementation of the published idea. Fitting a model to all of a fiducial's edges is
  long-standing practice anyway: it is template or model-based edge alignment.
- **What `refine_grid` does** (read, not reused):
  - Runs after decoding, on tags with at least 1.5 px per cell.
  - At the midpoint of every unit cell edge whose two cells differ in colour, it searches ±min(1.5, 0.3·cell)
    px along the edge normal, in 0.25 px steps, for the gradient peak. It then takes a centroid of the
    gradient lobe as the sub-pixel offset.
  - Each offset is a point-to-line residual with an analytic Jacobian over the 8 homography parameters, in
    raw pixels with no lens model. It runs 2 unweighted Gauss-Newton iterations and needs at least 16 edges.
  - It gives up if any corner moves more than 0.25 cell. It re-decodes the refined quad and keeps the result
    only if the ID is the same and the Hamming distance is no worse.
  - We found no published accuracy or CPU numbers, beyond the chart and "120 fps on a Pi 5, 1280x800, one
    camera; 60 fps each with three". Those frame rates come from temporal ROI tracking (search only near
    last frame's tags, with a full-frame fallback), not from the fit.

**Eagle Eye compared with sc-vision.** Its 120 fps on a Pi 5 is whole-pipeline throughput with ROI
prediction; the thread gives no latency or CPU figures. sc-vision reaches pose about 8.2 ms after the
first USB packet and uses about 27% of one core per camera at 60 fps, decoding full frames with no ROI
prediction. The two are not directly comparable. Temporal ROI is a separate, orthogonal idea for us
(see VISION-RESEARCH.md).

## 2. What NAPA does today

- `fit_sides` (`third_party/napa/napa_core.c`) refines the four outline sides only.
  - It takes up to `NAPA_FINAL_POINTS` profiles per side, each a gradient-lobe centroid with a residual
    trim, and fits a straight line through them.
  - It runs coarse to fine, and finally fits again in a window just wide enough for the edge.
  - `border_bias` estimates how much clipping shrinks black regions and corrects for it.
- The corners are the intersections of the four lines, in raw (distorted) pixels.
- `pose.c` then runs IPPE-square on the undistorted corners, plus Gauss-Newton on the reprojection error.
- Limitations:
  - Only about 4×(side px / 1.5) edge samples are used, all on the outline. The ~60–100 interior bit edges
    are ignored.
  - The sides are fitted as straight lines in the distorted image. With our OV9281 lens (k1 = 0.11), a large
    tag's sides are visibly curved.

## 3. tagfit: our design

Inputs: the luma image, the decoded ID, NAPA's corners, and the camera model (optional).

1. **Model.** Build the tag's 10×10 cell colours (quiet zone, black border, payload) from NAPA's own
   `napa_family_info` and `napa_tag36h11_code`, so they always match what NAPA decoded.
   - On synthetic renders, 1281 of 1281 detections had NAPA corner 0 at layout cell (0, 0), so no rotation
     search is needed.
2. **Geometry**, either of two models:
   - (a) A homography from the model square to *undistorted* (pinhole) pixels. This is the default.
   - (b) A rigid 6-DoF pose with the camera matrix (`--pose`), started from IPPE.
   - In both, the edges are measured in the real image by pushing each model point through the lens
     model, so curved sides stay consistent with the fit.
3. **Edges.** Use every unit edge between differently coloured cells: the outline against the quiet zone,
   the inside of the border, and every payload bit edge.
   - That is typically 90–120 edges, against NAPA's 4 lines.
   - Each edge gets `max(1, min(3, cell/3))` samples, placed at 20–80% of its length to stay clear of
     the junctions.
4. **Measurement.** At each sample, search ±clamp(0.4·cell, 0.75, 1.5) px along the image normal, oriented
   black to white.
   - The profile is bilinear at 0.25 px steps. The gradient uses a ±clamp(0.25·cell, 0.25, 0.5) px aperture.
   - The offset is the centroid of the strongest dark-to-light lobe above 20% of the tag's black/white
     contrast. This is the same estimator family as NAPA's `lobe_centroid`.
5. **Solve.** Robust (Huber, 0.5 px) Gauss-Newton on the 8 homography parameters (or 6 pose parameters),
   **plus one shared bias δ**.
   - δ models "black shrinks by δ" from blooming, clipping or JPEG. Opposite edges of a black cell move in
     opposite directions, so δ separates cleanly from the geometry.
   - The lens Jacobian is taken once per pass at the tag centre (it changes little across a tag), while
     positions use the full lens model.
   - The default is 2 iterations plus a final measuring pass, with early exit below 0.005 px of corner motion.
6. **Guards.** The fit is rejected, keeping NAPA's corners, if any of these holds:
   - fewer than 24 edge samples
   - |δ| > 0.35 cell
   - a corner moves more than min(3 px, 0.35 cell)
   - the residual RMS after the fit is above 1.05× the starting value + 0.02 px

   Tags below `min_cell_px` (2.0) are skipped. Setting `max_cell_px` restricts the fit to far tags only.
7. **Output.** Four refined corners in NAPA's order and coordinates, so `pose_ippe_square`, PhotonVision's
   pipeline and the multi-tag solver use them unchanged.

## 4. Results

All runs are on the SystemCore (Cortex-A76 at 2.4 GHz), offline: no cameras, no PhotonVision restarts. The
binary is in `~/bench/tagfit`.

### 4.1 Synthetic, known ground truth

**Setup.** `tagfit_bench synth /opt/sc-vision/etc/calib.json --n 1500 --iters 2` renders one tag per frame.
- Tag: official 36h11 cells, 16× supersampled, through the real 8-coefficient lens model.
- Range: log-uniform from 0.6 to 8 m. Orientation: yaw ±60°, pitch ±25°, roll ±15°.
- Image: blur σ 0.8 px, noise σ 2.5, JPEG q85.
- Result: 1379 frames rendered, 1281 detected by NAPA (min tag 10 px).

**How to read the tables.** Each cell shows NAPA → NAPA + tagfit.
- "Corner" is the per-tag RMS error of the 4 corners against the truth.
- "Flips" counts tags with rotation error over 10° (the wrong IPPE branch).
- "Ambiguity" is best/alt reprojection, as PhotonVision computes it.
- "Better/worse" counts tags whose corner error changed by more than 0.1 px.

#### Default: homography fit, bias on, lens model on

| cell px | n | better/worse | corner med px | corner p90 px | range err % (med) | rot err ° (med) | flips >10° | ambiguity (med) | reproj px (med) | µs/tag med (p90) |
|---|---|---|---|---|---|---|---|---|---|---|
| < 2.5 | 83 | 44/1 | 0.232 → 0.117 | 0.302 → 0.237 | 0.81 → 0.35 | 1.22 → 0.63 | 16 → 10 | 0.57 → 0.43 | 0.093 → 0.054 | 78 (83) |
| 2.5–4 | 303 | 70/3 | 0.135 → 0.067 | 0.270 → 0.178 | 0.20 → 0.16 | 0.68 → 0.36 | 13 → 4 | 0.25 → 0.12 | 0.058 → 0.028 | 88 (97) |
| 4–6 | 226 | 16/5 | 0.054 → 0.043 | 0.185 → 0.105 | 0.050 → 0.068 | 0.20 → 0.15 | 0 → 0 | 0.048 → 0.033 | 0.025 → 0.018 | 96 (101) |
| 6–9 | 214 | 14/4 | 0.041 → 0.028 | 0.112 → 0.057 | 0.022 → 0.022 | 0.069 → 0.060 | 0 → 0 | 0.013 → 0.009 | 0.017 → 0.013 | 176 (187) |
| 9–14 | 228 | 49/2 | 0.057 → 0.021 | 0.251 → 0.042 | 0.028 → 0.012 | 0.049 → 0.029 | 0 → 0 | 0.006 → 0.003 | 0.016 → 0.009 | 257 (274) |
| ≥ 14 | 227 | 119/0 | 0.128 → 0.020 | 0.586 → 0.039 | 0.050 → 0.007 | 0.048 → 0.017 | 0 → 0 | 0.003 → 0.001 | 0.019 → 0.010 | 258 (282) |

The fit was accepted for 87% of tags in the < 2.5 bin and for 99–100% everywhere else.

**What the default fit does:**
- **Far tags (cells under 4 px, roughly 3.5–8 m):** corner error halves and rotation error halves.
  Wrong-branch flips fall from 29 to 14, and ambiguity halves. Range error falls 15–55%.
- **Near and large tags:** NAPA's p90 corner error of 0.25–0.59 px drops to about 0.04 px. Most of that is
  lens distortion: NAPA fits straight lines in the distorted image. Range error falls 2–7×, rotation error
  about 2–3×.
- **4–6 px cells:** range error is slightly worse (0.050 → 0.068%, about 1 mm at 2 m) while corners and
  rotation improve. This is within noise for practical purposes, but it is the one regression.

#### Ablations (same 1281 tags unless noted)

| variant | finding |
|---|---|
| `--no-cam` (homography in raw pixels, as Eagle Eye does) | Far tags gain the same, but **large tags get worse**: p90 corner error 0.59 → 0.97 px at ≥ 14 px cells, 70 tags worse. The lens model is essential. |
| `--no-bias`, clean render | About the same as the default. |
| `--bloom 0.4` (white clips and spreads), bias on | Corners improve in every bin: 4–6 px p90 0.200 → 0.073, range error 0.108 → 0.054%. Fitted δ = +0.03 to +0.08 px. |
| `--bloom 0.4 --no-bias` | **Worse than NAPA** at 4–14 px cells: range error 0.108 → 0.285%, 48 tags worse. NAPA's `border_bias` handles this, so the full fit must model it too. |
| `--iters 3` | Same accuracy as 2 iterations, 30% more CPU. The default is 2. |
| `--sample-px 6` (fewer samples) | 6–14 px cells lose about a third of the gain. CPU drops only at large cells (257 → 171 µs). |
| `--noise 5 --blur 1.2` (bad light) | Far tags gain more (2.5–4 px: corners 0.297 → 0.153, flips 43 → 20). At 4–9 px the homography fit is about neutral to slightly worse (range error 0.047 → 0.079%). |
| `--pose` (6-DoF fit), clean | Corners are better than the homography fit in every bin, e.g. ≥ 14 px median 0.016, 2.5–4 px 0.058. Flips are **not** reduced (13 → 13), because the fit stays in IPPE's chosen branch. Ambiguity and reprojection error read 0 by construction, so they are not meaningful here. |
| `--pose`, noise 5 / blur 1.2 | The 6-DoF fit is robust where the homography fit was not: 4–6 px corners 0.134 → 0.104, 6–9 px p90 0.225 → 0.156, 9–14 px p90 0.280 → 0.118. |

### 4.2 Recorded static captures (Thriftiest Cam, `/opt/sc-vision/etc/calib.json`)

**Setup.** `tagfit_bench replay FILE.mjpeg cal.json` measures frame-to-frame standard deviation for each tag
seen in most frames. Only tag 3 is in view, about 0.8 m away, with 19 px cells. `live2` and `txman1` are
moving sessions, so they cannot measure jitter.

| session | corner std px | range std mm | rot std ° | reproj px (med) | ambiguity (med) |
|---|---|---|---|---|---|
| cd-ctrl (300 frames) | 0.260 → 0.073 | 2.34 → 0.42 | 0.408 → 0.167 | 0.166 → 0.233 | 0.051 → 0.072 |
| sweep e2_g128 (high gain) | 0.066 → 0.055 | 0.54 → 0.23 | 0.137 → 0.177 | 0.169 → 0.210 | 0.052 → 0.064 |
| sweep e50_g32 | 0.072 → 0.065 | 0.24 → 0.09 | 0.130 → 0.115 | 0.187 → 0.227 | 0.057 → 0.069 |
| cd-ctrl, `--pose` | 0.260 → 0.060 | 2.34 → 0.43 | 0.408 → 0.156 | (0 by construction) | |

- **Range jitter falls 2–5×** on all three sessions, and cd-ctrl's corner jitter falls 3.5×.
- **Rotation jitter is mixed** (−59%, +29%, −11%). A near-frontal tag at 0.8 m constrains tilt weakly
  whatever the corners are, so rotation jitter there is dominated by that geometry.
- **Reprojection error and ambiguity rise slightly** on real data but not on synthetic. The refined corners
  agree less well with a perfect 0.1651 m square under this calibration. That suggests a small calibration
  or print-scale mismatch, which the 4 NAPA corners cannot reveal but the 100 edges can. It is worth
  checking against fieldcal.

### 4.3 CPU

Clean single-process run on the Cortex-A76, 2 iterations:

| cell size | samples per edge | edge samples per pass | CPU per tag |
|---|---|---|---|
| under 6 px | 1 | about 100 | **80–100 µs** |
| 6–9 px | 2 | | 176 µs |
| 9 px and up | 3 (capped) | | 260 µs |

- About 300 ns per edge sample (17 bilinear reads, one lens projection, a 9×9 normal-equation update) times
  3 passes, plus a 64-sample level estimate.
- **Context:** sc-vision uses about 4.5 ms of CPU per 60 fps frame per camera, so a frame with 2 far tags
  costs about 4% more and a frame with 4 large tags about 23% more.
- **Ways to cut it, not yet done:**
  - Cap total samples (about 120) for big tags. They are already the most accurate.
  - Use 2 passes (1 iteration plus measure) for cells of 9 px and up.
  - Use fixed-point bilinear reads.

## 5. Recommendation

1. **Adopt tagfit for far and medium tags first** (`max_cell_px` about 6, `min_cell_px` 2), with the lens
   model and bias on.
   - This is where pose quality is worst today and the gain is clearest: half the corner and rotation error,
     half the wrong-branch flips and ambiguity.
   - It costs about 90 µs per such tag on the A76.
   - Wire it in sc-vision after `napa_detect` (the cells come from `napa_tag36h11_code`) and before
     `pose_ippe_square`, behind `--tagfit`.
   - In PhotonVision's NAPA JNI (`NapaDetectorJNI.cc`), apply it to the corners before IPPE in the same place.
2. **Large near tags: enable too, if CPU allows.** The lens-aware fit removes NAPA's distortion bias, which
   is the largest corner error there: p90 0.59 → 0.04 px, range error 7× lower. At 260 µs, cap the samples
   first.
3. **Build the next version on the 6-DoF pose fit (`--pose`), and fit both IPPE branches when ambiguity is
   above about 0.2, keeping the branch with the lower edge residual.**
   - The pose fit is more accurate and more robust to noise than the homography fit.
   - The 100-edge residual should separate the branches far better than 4 corners, which would cut the flips
     the pose fit does not fix today. Not yet measured.
   - The pose fit can also feed the multi-tag solver directly.
4. **Do not ship without the bias term**, and do not fit in raw pixels: both ablations made results worse
   than NAPA alone.
5. **Before enabling it on the robot,** do a live A/B (on the bench, off-match) of static-pose jitter at 2–6 m
   with several tags. The recorded static captures we have are all at 0.8 m. Also check the slight rise in
   reprojection error against a fresh calibration.

## Reproduce

```
native/sc-vision/build.sh                       # laptop, WPILib SystemCore toolchain
scp ~/builder/sc-vision/tagfit_bench systemcore@172.26.0.1:bench/tagfit/
ssh systemcore@172.26.0.1
cd ~/bench/tagfit && cp /opt/sc-vision/etc/calib.json cal.json
./tagfit_bench synth cal.json --n 1500 [--pose] [--no-cam] [--no-bias] [--bloom 0.4] [--noise 5 --blur 1.2]
./tagfit_bench replay ~/bench/data/cd-ctrl/cam/0000.mjpeg cal.json [--pose]
```

Set `TAGFIT_DEBUG=1` to print every synthetic tag the fit made worse.
