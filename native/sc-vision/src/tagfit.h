// sc-vision: full-tag refinement ("tagfit"). After a detector has decoded a tag (so every cell's colour is
// known), fit one homography to every black/white edge of the tag, exterior and interior (the outline, the
// inner side of the black border and every payload bit edge), instead of only the four outline sides.
// Each edge is measured where it is expected, along its image normal, with a sub-pixel gradient-lobe
// centroid; a few robust Gauss-Newton steps then move the 8 homography parameters (and, optionally, one
// "black shrinks by delta" bias shared by all edges: blooming/clipping moves opposite edges of a black
// cell in opposite directions, so it separates from the geometry). With a camera model the homography
// lives in the undistorted (pinhole) image and the edges are measured in the real one, so lens
// distortion across a large tag does not bend the fit. Output: the refined four outline corners, in the
// same order and coordinates as the input, ready for pose_ippe_square. See docs/FULL-TAG-REFINEMENT.md.
#pragma once
#include <stdint.h>

#include "pose.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int iters;           // Gauss-Newton steps (default 2; 3 measured no better)
  double min_cell_px;  // skip tags whose mean cell side is smaller than this (default 2.0)
  double max_cell_px;  // skip tags whose mean cell side is larger (0: no limit), e.g. far tags only
  int fit_bias;        // 1 (default): estimate the black-shrink bias with the geometry
  int samples_max;     // most samples along one cell edge (default 3)
  double sample_px;    // one sample per this many pixels of cell edge (default 3)
  int pose;            // 1: fit a rigid 6-DoF pose (needs cam) instead of the 8-DoF homography (default 0)
} tagfit_params;

typedef struct {
  double corners[8];  // refined corners (the input's when ok == 0)
  int ok;             // 1 refined; 0 skipped (size gate) or rejected (kept the input)
  int samples;        // edge samples used in the last pass
  double rms0, rms;   // RMS edge residual (px) at the input corners and after the fit
  double bias;        // black-shrink bias (px), 0 without fit_bias
  double cell_px;     // mean cell side (px)
} tagfit_result;

void tagfit_defaults(tagfit_params *p);

// img: 8-bit luma, w x h, stride bytes per row. white: the tag's colours as (W + 2) x (W + 2) bytes, row-major,
// 1 = white, for cells -1 .. W across and down from the detected square's top-left cell (row -1 and column -1
// and row W and column W: the white quiet zone); W: cells across the detected square (8 for tag36h11).
// corners: x0, y0 .. x3, y3, the detected square's corners in OpenCV order (top-left, top-right, bottom-right,
// bottom-left of the cell grid), pixel-centre coordinates. cam: NULL to fit in raw pixels.
// Returns 1 if refined, 0 if not (r->corners = corners either way).
int tagfit_refine(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                  const double corners[8], const tagfit_params *p, tagfit_result *r);

#ifdef __cplusplus
}
#endif
