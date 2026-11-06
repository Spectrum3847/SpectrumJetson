// PhotonPipelineResult in the Spectrum PhotonVision fork's serde (photonstruct:PhotonPipelineResult:fd353b11...),
// little-endian Packet encoding, from tags with AprilTag-order corners and IPPE poses. Header-only, no NT
// dependency: used by sc-vision (nt_pub.cc) and by PhotonVision's native publish (detector/napa/NapaDetectorJNI.cc).
//
// Conventions (checked live against the fork: same quaternion within IPPE vs orthogonal iteration, corners within
// 0.03 px, yaw/pitch/area equal to 0.01):
//  - corners in AprilTag order (NAPA's OpenCV order permuted {1, 0, 3, 2});
//  - pose: IPPE with AprilTag's tag coordinates -> R_h; published camera-to-target = EDN->NWU of (t, R_h Rz(180))
//    with the tag frame turned 180 degrees about its NWU y axis (what PhotonVision publishes);
//  - yaw/pitch from the undistorted tag centre (intersection of the diagonals), degrees;
//  - poseAmbiguity = best/alt reprojection error (PhotonVision: orthogonal-iteration object-space errors);
//  - minAreaRectCorners = the detected corners; skew 0; no multi-tag result.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

#include <vector>

extern "C" {
#include "pose.h"
}

namespace pvpack {

inline const char *kUuid = "fd353b11f3a818e9c5b457c7dc5a8f5c";

struct Packet {
  std::vector<uint8_t> &b;
  template <class T>
  void put(T v) {
    uint8_t x[sizeof(T)];
    memcpy(x, &v, sizeof(T));  // aarch64 / x86 are little-endian, as PhotonVision's Packet
    b.insert(b.end(), x, x + sizeof(T));
  }
};

// Rotation matrix -> quaternion (w, x, y, z), as WPILib's Rotation3d(Matrix).
inline void quat(const double R[9], double q[4]) {
  double tr = R[0] + R[4] + R[8];
  if (tr > 0) {
    double s = 0.5 / sqrt(tr + 1.0);
    q[0] = 0.25 / s, q[1] = (R[7] - R[5]) * s, q[2] = (R[2] - R[6]) * s, q[3] = (R[3] - R[1]) * s;
  } else if (R[0] > R[4] && R[0] > R[8]) {
    double s = 2.0 * sqrt(1.0 + R[0] - R[4] - R[8]);
    q[0] = (R[7] - R[5]) / s, q[1] = 0.25 * s, q[2] = (R[1] + R[3]) / s, q[3] = (R[2] + R[6]) / s;
  } else if (R[4] > R[8]) {
    double s = 2.0 * sqrt(1.0 + R[4] - R[0] - R[8]);
    q[0] = (R[2] - R[6]) / s, q[1] = (R[1] + R[3]) / s, q[2] = 0.25 * s, q[3] = (R[5] + R[7]) / s;
  } else {
    double s = 2.0 * sqrt(1.0 + R[8] - R[0] - R[4]);
    q[0] = (R[3] - R[1]) / s, q[1] = (R[2] + R[6]) / s, q[2] = (R[5] + R[7]) / s, q[3] = 0.25 * s;
  }
}

// IPPE pose (homography frame) -> PhotonVision's published camera-to-target (NWU) translation + quaternion.
inline void to_photon(const tag_pose &p, double t[3], double q[4]) {
  double R[9] = {-p.R[0], -p.R[1], p.R[2], -p.R[3], -p.R[4], p.R[5], -p.R[6], -p.R[7], p.R[8]};
  static const double C[9] = {0, 0, 1, -1, 0, 0, 0, -1, 0};
  double CR[9], Rn[9];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) {
      CR[i * 3 + j] = 0;
      for (int k = 0; k < 3; k++) CR[i * 3 + j] += C[i * 3 + k] * R[k * 3 + j];
    }
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) {
      Rn[i * 3 + j] = 0;
      for (int k = 0; k < 3; k++) Rn[i * 3 + j] += CR[i * 3 + k] * C[j * 3 + k];
    }
  for (int i = 0; i < 3; i++) Rn[i * 3 + 0] = -Rn[i * 3 + 0], Rn[i * 3 + 2] = -Rn[i * 3 + 2];
  for (int i = 0; i < 3; i++) t[i] = C[i * 3] * p.t[0] + C[i * 3 + 1] * p.t[1] + C[i * 3 + 2] * p.t[2];
  quat(Rn, q);
}

inline void put_transform(Packet &k, const tag_pose *p) {
  double t[3] = {0, 0, 0}, q[4] = {1, 0, 0, 0};
  if (p) to_photon(*p, t, q);
  for (double v : t) k.put(v);
  for (double v : q) k.put(v);
}

// Yaw/pitch (degrees) of a tag's centre as PhotonVision computes them.
inline void yaw_pitch(const cam_model *m, const double c[8], double *yaw, double *pitch) {
  *yaw = *pitch = 0;
  if (!m) return;
  double x1 = c[0], y1 = c[1], x2 = c[4], y2 = c[5], x3 = c[2], y3 = c[3], x4 = c[6], y4 = c[7];
  double den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
  double cx = (x1 + x2 + x3 + x4) / 4, cy = (y1 + y2 + y3 + y4) / 4;
  if (fabs(den) > 1e-9) {
    double a = x1 * y2 - y1 * x2, b = x3 * y4 - y3 * x4;
    cx = (a * (x3 - x4) - (x1 - x2) * b) / den;
    cy = (a * (y3 - y4) - (y1 - y2) * b) / den;
  }
  double x0 = (cx - m->cx) / m->fx, y0 = (cy - m->cy) / m->fy, x = x0, y = y0;
  for (int it = 0; it < 30; it++) {
    double r2 = x * x + y * y;
    double ic = (1 + ((m->k[7] * r2 + m->k[6]) * r2 + m->k[5]) * r2) / (1 + ((m->k[4] * r2 + m->k[1]) * r2 + m->k[0]) * r2);
    double dx = 2 * m->k[2] * x * y + m->k[3] * (r2 + 2 * x * x);
    double dy = m->k[2] * (r2 + 2 * y * y) + 2 * m->k[3] * x * y;
    x = (x0 - dx) * ic, y = (y0 - dy) * ic;
  }
  double ux = x * m->fx + m->cx, uy = y * m->fy + m->cy;
  double yw = atan((ux - m->cx) / m->fx);
  *pitch = atan((m->cy - uy) / (m->fy / cos(yw))) * 180 / M_PI;
  *yaw = yw * 180 / M_PI;
}

// Appends one PhotonPipelineResult to out. corners: 8 per tag, AprilTag order, raw pixels. best/alt: per tag or
// null. first: the first tag's yaw/pitch/area (for the target* topics), may be null.
inline void pack_result(std::vector<uint8_t> &out, int64_t seq, int64_t capture_ns, int64_t publish_ns,
                        int64_t since_pong, const cam_model *cam, int width, int height, int n, const int *ids,
                        const double *corners, const tag_pose *best, const tag_pose *alt, double first[3]) {
  Packet k{out};
  k.put<int64_t>(seq);
  k.put<int64_t>(capture_ns);
  k.put<int64_t>(publish_ns);
  k.put<int64_t>(since_pong);
  if (n > 127) n = 127;
  k.put<int8_t>((int8_t)n);
  if (first) first[0] = first[1] = first[2] = 0;
  for (int i = 0; i < n; i++) {
    const double *c = corners + 8 * i;
    double yaw, pitch;
    yaw_pitch(cam, c, &yaw, &pitch);
    double area = 0;
    for (int j = 0; j < 4; j++) {
      int q = (j + 1) % 4;
      area += c[2 * j] * c[2 * q + 1] - c[2 * q] * c[2 * j + 1];
    }
    area = fabs(area) / 2 / ((double)width * height) * 100;
    if (i == 0 && first) first[0] = yaw, first[1] = pitch, first[2] = area;
    k.put<double>(yaw);
    k.put<double>(pitch);
    k.put<double>(area);
    k.put<double>(0.0);  // skew
    k.put<int32_t>(ids[i]);
    k.put<int32_t>(-1);
    k.put<float>(-1.0f);
    put_transform(k, best ? &best[i] : nullptr);
    put_transform(k, alt ? &alt[i] : nullptr);
    double amb = (best && alt && alt[i].err > 0) ? best[i].err / alt[i].err : -1;
    k.put<double>(amb);
    for (int rep = 0; rep < 2; rep++) {  // minAreaRectCorners, detectedCorners
      k.put<int8_t>(4);
      for (int j = 0; j < 8; j++) k.put<double>(c[j]);
    }
  }
  k.put<int8_t>(0);  // no multitag result
}

}  // namespace pvpack
