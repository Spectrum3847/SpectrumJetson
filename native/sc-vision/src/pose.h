// sc-vision: single-tag pose, IPPE for a square (Collins & Bartoli 2014, as OpenCV's SOLVEPNP_IPPE_SQUARE),
// analytic, no iterations, after undistorting the 4 corners (OpenCV's 8-coefficient rational model).
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  double fx, fy, cx, cy;
  double k[8];  // k1 k2 p1 p2 k3 k4 k5 k6 (OpenCV order)
} cam_model;

typedef struct {
  double R[9];   // tag -> camera rotation, row-major, OpenCV camera frame (x right, y down, z forward)
  double t[3];   // tag centre in the camera frame, metres
  double err;    // RMS reprojection error, pixels
} tag_pose;

// corners: 4 image points (x0,y0..x3,y3) in OpenCV corner order (NAPA's / ArUco's): the tag's top-left,
// top-right, bottom-right, bottom-left as printed, i.e. object points (-s/2, s/2), (s/2, s/2), (s/2, -s/2),
// (-s/2, -s/2). Writes the better solution to best and the other to alt (alt->err >= best->err).
// Returns 0, or -1 for a degenerate quad.
int pose_ippe_square(const cam_model *cam, const double corners[8], double size_m, tag_pose *best,
                     tag_pose *alt);

// Parse a PhotonVision calibration JSON (cameraIntrinsics.data, distCoeffs.data). 0 or -1.
int cam_model_load(const char *path, cam_model *cam);

#ifdef __cplusplus
}
#endif
