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

struct tagfit_lut;

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int iters;           // Gauss-Newton steps (default 2; 3 measured no better)
  double min_cell_px;  // skip tags whose mean cell side is smaller than this (default 2.0)
  double max_cell_px;  // skip tags whose mean cell side is larger (0: no limit), e.g. far tags only
  int fit_bias;        // 1 (default): estimate the black-shrink bias with the geometry
  int samples_max;     // most samples along one cell edge (default 3)
  double sample_px;    // interior: one sample per this many px of cell edge (default 99: one per segment)
  int pose;            // 1: fit a rigid 6-DoF pose (needs cam) instead of the 8-DoF homography (default 0)
  double outline_px;   // outline sample spacing in px (default 3; 0: as interior edges)
  int bias_axes;       // 1: separate bias for the tag's vertical and horizontal edges (anisotropic blur)
  int edges;           // 0 all edges, 1 outline only, 2 interior only (diagnostics)
  int fit_kappa;       // diagnostic: also fit kappa, how far (cells) the border's inner edge sits inward
  int max_samples;     // edge samples per pass at most (0: no cap); interior edges thin out first
  double branch_amb;   // pose fit: also fit IPPE's other solution when ambiguity exceeds this (0: never)
  int seg_mode;        // 0 all edge segments, 1 the outline only, 2 the outline + the border's inner edges
  int max_segments;    // keep at most this many unit edge segments (0: all): the outline, then the border's
                       // inner edges, then the rest by distance from the centre and same-colour run length
  double lobe_cells;   // gradient lobe at most this many cells either side of its peak (0: no limit)
  int min_run;         // skip interior edges with a same-colour run shorter than this (cells) on either side...
  double min_run_below;  // ...on tags whose cells are smaller than this (px)
  // Speed (pass 3). None changes the model; each is checked against the double-precision reference in tagfit_bench.
  int fast;                       // 1: float32 measurement loop (NEON on aarch64), analytic edge normals, symmetric
                                  // normal equations (accumulated and solved in double); homography fit only
  const struct tagfit_lut *lut;   // lens model as a lookup table (tagfit_lut_create) instead of the exact
                                  // pose_distort_px per sample (NULL: exact)
  int warm_iters;                 // Gauss-Newton steps when started warm (tagfit_refine_warm; default 1)
} tagfit_params;

typedef struct {
  double corners[8];  // refined corners (the input's when ok == 0)
  int ok;             // 1 refined; 0 skipped (size gate) or rejected (kept the input)
  int samples;        // edge samples used in the last pass
  double rms0, rms;   // RMS edge residual (px) at the input corners and after the fit
  double bias;        // black-shrink bias (px), 0 without fit_bias
  double bias_v, bias_h;  // per edge direction (model vertical / horizontal edges); both = bias unless bias_axes
  double kappa;           // fit_kappa: border inner-edge offset, cells
  int branches, branch;   // pose fit: starting poses tried (1 or 2) and the one kept (1: IPPE's alternative)
  int segments;           // unit edge segments used
  double cell_px;     // mean cell side (px)
  int warm;           // 1: started from the previous frame's fit (tagfit_refine_warm)
  int iters_run;      // Gauss-Newton steps taken
} tagfit_result;

// Warm start: the previous frame's fit of the same tag, as the correction it made to the detector's corners.
// Applied to this frame's detector corners as the starting point (the correction is mostly systematic: lens
// curvature and the black/white bias), then warm_iters steps instead of iters.
typedef struct {
  int valid;
  double dc[8];       // refined - input corners (raw px), previous frame
  double cx, cy;      // previous input corners' centre (raw px)
  double cell_px;     // previous cell size
  double bias;        // previous bias (px)
} tagfit_warm;

// The lens model (pinhole pixel -> image pixel) with its radial factor tabulated against r^2 (float).
// Built once per camera (entries: table size, 0: 1024); tagfit_lut_max_err: worst error over the sensor, px.
typedef struct tagfit_lut tagfit_lut;
tagfit_lut *tagfit_lut_create(const cam_model *cam, int w, int h, double entries);
void tagfit_lut_destroy(tagfit_lut *lut);
double tagfit_lut_max_err(const tagfit_lut *lut);

void tagfit_defaults(tagfit_params *p);

// img: 8-bit luma, w x h, stride bytes per row. white: the tag's colours as (W + 2) x (W + 2) bytes, row-major,
// 1 = white, for cells -1 .. W across and down from the detected square's top-left cell (row -1 and column -1
// and row W and column W: the white quiet zone); W: cells across the detected square (8 for tag36h11).
// corners: x0, y0 .. x3, y3, the detected square's corners in OpenCV order (top-left, top-right, bottom-right,
// bottom-left of the cell grid), pixel-centre coordinates. cam: NULL to fit in raw pixels.
// Returns 1 if refined, 0 if not (r->corners = corners either way).
int tagfit_refine(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                  const double corners[8], const tagfit_params *p, tagfit_result *r);
// As tagfit_refine, started from warm (may be NULL or invalid: a cold start) when its gates pass: the tag's centre
// moved under 2 cells, its size under 15%, and cells of 2.5 px or more. Fills next with this frame's warm state (invalid if not refined).
int tagfit_refine_warm(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                       const double corners[8], const tagfit_params *p, const tagfit_warm *warm, tagfit_warm *next,
                       tagfit_result *r);

// ---- live use (sc-vision, the NAPA JNI): one per camera ----
// Per-id warm state (frame-to-frame), the camera's LUT, and the params. Switch: env SPECTRUM_TAGFIT (0 off, the
// default; 1 on). SPECTRUM_TAGFIT_WARM (default 1): warm start with warm_iters 1. SPECTRUM_TAGFIT_FAST (default 1):
// float32 + LUT. SPECTRUM_TAGFIT_ITERS (default 2), SPECTRUM_TAGFIT_MAX_CELL (px, default 0: all sizes).
typedef struct tagfit_live tagfit_live;
int tagfit_env_enabled(void);  // SPECTRUM_TAGFIT=1
tagfit_live *tagfit_live_create(const cam_model *cam, int w, int h);  // reads the SPECTRUM_TAGFIT_* settings
void tagfit_live_destroy(tagfit_live *t);
// One tag of frame `frame` (a counter that rises by 1 per processed frame). white: as tagfit_refine (W x W tag
// plus its quiet zone). corners: NAPA's order, refined in place. Returns 1 if refined.
int tagfit_live_refine(tagfit_live *t, const uint8_t *img, int w, int h, int stride, int id, const uint8_t *white,
                       int W, double corners[8], long frame);
// Totals since create: tags tried, refined, warm-started, and CPU us spent.
void tagfit_live_stats(const tagfit_live *t, long *tried, long *refined, long *warm, double *us);

#ifdef __cplusplus
}
#endif
