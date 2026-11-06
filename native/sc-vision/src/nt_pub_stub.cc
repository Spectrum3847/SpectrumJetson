// No publisher (build without ntcore).
#include "nt_pub.h"
struct NtPub {};
NtPub *nt_pub_create(const char *, const char *) { return nullptr; }
void nt_pub_result(NtPub *, int64_t, const napa_detection *, const tag_pose *, const tag_pose *, int) {}
void nt_pub_config(NtPub *, const cam_model *, double, int64_t) {}
void nt_pub_destroy(NtPub *) {}
