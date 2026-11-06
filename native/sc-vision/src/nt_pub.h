// sc-vision: publish results (nt_pub.cc: NetworkTables, PhotonVision-compatible; nt_pub_stub.cc: none).
#pragma once
#include <stdint.h>
extern "C" {
#include "napa_core.h"
#include "pose.h"
}
struct NtPub;
NtPub *nt_pub_create(const char *host, const char *camera);
// t_first_ns: CLOCK_MONOTONIC of the frame's first USB packet.
void nt_pub_result(NtPub *p, int64_t t_first_ns, const napa_detection *d, const tag_pose *best, const tag_pose *alt,
                   int n, const int64_t *tag_row_ns = nullptr);
// Camera model (yaw/pitch), tag size, and first packet -> mid-exposure offset for the capture timestamp.
void nt_pub_config(NtPub *p, const cam_model *cam, double tag_size_m, int64_t mid_offset_ns);
void nt_pub_destroy(NtPub *p);
// NAPA's corners (OpenCV order) -> AprilTag's order, which PhotonVision's pose and corners use.
inline void napa_to_apriltag_order(const double *in, double *out) {
  static const int perm[4] = {1, 0, 3, 2};
  for (int j = 0; j < 4; j++) out[2 * j] = in[2 * perm[j]], out[2 * j + 1] = in[2 * perm[j] + 1];
}
