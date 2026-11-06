// The tester's decoder ABI (tests/systemcore-mjpeg-napa/bench.cc "builder", SCMN_BUILDER_LIB) over mjdec.
#include <stddef.h>
#include <stdint.h>

#include "../src/mjdec.h"

__attribute__((visibility("default"))) void *scmn_dec_create(void) { return mjdec_create(); }
__attribute__((visibility("default"))) void scmn_dec_destroy(void *d) { mjdec_destroy((mjdec *)d); }
__attribute__((visibility("default"))) int scmn_dec_begin(void *d, const uint8_t *jpeg, size_t cap, uint8_t *out,
                                                          int w, int h) {
  return mjdec_begin((mjdec *)d, jpeg, cap, out, w, h, w) < 0 ? -1 : 0;
}
__attribute__((visibility("default"))) int scmn_dec_feed(void *d, size_t avail) {
  int r = mjdec_feed((mjdec *)d, avail);
  return r < 0 ? -1 : r;
}
__attribute__((visibility("default"))) const char *scmn_dec_name(void) { return "scvision-mjdec"; }
