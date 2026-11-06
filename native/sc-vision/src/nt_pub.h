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
                   int n);
void nt_pub_destroy(NtPub *p);
