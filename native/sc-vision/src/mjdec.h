// sc-vision: a luma-only, streaming baseline-JPEG decoder for UVC MJPEG cameras (built for the Thriftiest Cam on
// the SystemCore's Cortex-A76: 1280x800, 4:2:2, a restart marker every MCU row, standard Huffman tables).
//
// Output: the Y plane only, bit-identical to libjpeg-turbo's JCS_GRAYSCALE + JDCT_ISLOW decode (the same
// integer IDCT, NEON). Chroma Huffman data is skipped without building coefficients (Cb/Cr are never
// inverse-transformed). Decodes restart interval by restart interval as the bytes arrive: feed() after more
// bytes land and it decodes every interval whose terminating marker is in; the caller gets rows in 8- or
// 16-row bands as they are final.
//
// Supports: baseline sequential 8-bit Huffman (SOF0/SOF1), 1 or 3 components, Y sampling 1x1, 2x1, 2x2 with
// 1x1 chroma, any DRI (0 = no restarts: the whole scan is one interval and decodes when EOI arrives), DQT and
// DHT tables given per frame (rebuilt only when they change). Anything else: mjdec_feed returns MJDEC_EUNSUP
// and the caller falls back to libjpeg-turbo.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mjdec mjdec;

enum {
  MJDEC_EBAD = -1,    // corrupt data (bad marker, Huffman code, RST out of sequence, size mismatch)
  MJDEC_EUNSUP = -2,  // valid JPEG this decoder doesn't do (progressive, 12-bit, other sampling)
};

mjdec *mjdec_create(void);
void mjdec_destroy(mjdec *d);

// Start a frame. jpeg: the buffer the frame's bytes land in (from offset 0 = SOI), cap its size. out: the luma
// plane, width x height, stride bytes a row (width, height: what the caller expects; a frame of another size
// is MJDEC_EBAD).
int mjdec_begin(mjdec *d, const uint8_t *jpeg, size_t cap, uint8_t *out, int width, int height, int stride);

// Bytes [0, avail) of the frame are valid now. Decodes every complete restart interval. Returns the number of
// output rows that are final (0..height), or a negative error. Rows == height: the frame is done.
int mjdec_feed(mjdec *d, size_t avail);

// After the frame is done: the offset just past its EOI (0 if not seen yet).
size_t mjdec_end(const mjdec *d);

// Decode a whole frame in one call (feed with everything). Returns 0 or a negative error.
int mjdec_decode(mjdec *d, const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height, int stride);

// Statistics since create: blocks decoded with only a DC term, and all luma blocks.
void mjdec_stats(const mjdec *d, uint64_t *dc_only, uint64_t *blocks);

// Output scale for the next frames (set before mjdec_begin; width/height stay the JPEG's, stride is the scaled
// image's): 1 (default, full size, bit-identical to libjpeg-turbo
// ISLOW), 2, 4 or 8: the image is width/scale x height/scale (out/stride describe that image), each 8x8 block
// reconstructed at (8/scale)^2 pixels from its lowest coefficients. Huffman decoding is unchanged (all of it);
// the IDCT gets cheaper. mjdec_feed() then returns scaled rows. -1 for another value.
int mjdec_set_scale(mjdec *d, int scale);

#ifdef __cplusplus
}
#endif
