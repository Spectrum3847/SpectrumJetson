// SpectrumJetson: streaming MJPEG -> gray decode, overlapped with the USB transfer, as its own small
// library, libspectrum-stream.so (stream_decode.cc; libjpeg-turbo only, no CUDA or OpenCV), so the CUDA
// detector library and the CPU-only NAPA library share one set of watcher threads. The GPU library
// links it; the NAPA library opens it with dlopen when streaming NAPA is on (it is then the same copy).
//
// Band sinks (streaming NAPA, tests/napa-stream): a consumer can attach a sink to the watcher that
// decoded its camera's frames. The watcher then calls begin() at each frame's start with the frame's
// gray buffer, feed(rows) after every decoded band (rows [0, rows) are final), and finish() when the
// last row is in, on the watcher thread, and keeps finish()'s result with the decoded frame. The
// consumer takes it with spectrum_stream_take() once it has the frame (DecodeGray). A plain C API so
// that libraries built separately (different compilers, the SystemCore toolchain) can use it.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spectrum_band_sink {
  void *ctx;
  // A frame starts: img is width x height, stride bytes a row, rows still landing. Nonzero: feed it.
  int (*begin)(void *ctx, const uint8_t *img, int width, int height, int stride);
  void (*feed)(void *ctx, int rows);
  void *(*finish)(void *ctx);         // the frame's result (also called to reset after an abort)
  void (*free_result)(void *result);  // must not need ctx (the sink may be gone)
  // Optional (may be null): at a frame's start, before any decoding: 0 skip the frame (not decoded at all), else
  // the decode scale 1, 2 or 4 (begin() then gets a width/scale x height/scale image). Only honoured with the
  // mjdec decoder and the image copy off (nobody watches the stream); otherwise frames are full size.
  int (*plan)(void *ctx);
} spectrum_band_sink;

// The frame PhotonVision just got (cscore's copy of a dequeued V4L2 buffer): if a watcher decoded
// these exact bytes while they were arriving, copy its gray image into out (width x height, stride
// bytes a row) and return 0. Waits up to ~3 ms for a decode still finishing its last rows. Returns 1
// when there is no such decode (the caller decodes the frame itself).
int spectrum_stream_decode_gray(const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height,
                                size_t stride);

// After spectrum_stream_decode_gray() returned 0 into a gray image, with that image or a copy of it
// as `out` (found by pointer on the decoding thread, else by content, every 16th row):
// attach `sink` to the watcher that decoded that frame (moving it from any other watcher), note that
// the consumer next wants a frame completing at or after want_after_ns (CLOCK_MONOTONIC; 0: every
// frame) so the watcher skips frames it would drop, and hand over that frame's sink result.
// Returns 1 with *result set (caller frees it with sink->free_result), 0 when the frame was streamed
// but not through this sink (the caller detects on the whole frame), -1 when out wasn't streamed.
int spectrum_stream_take(const uint8_t *out, int width, int height, size_t stride,
                         const spectrum_band_sink *sink, int64_t want_after_ns, void **result);

// Detach ctx's sink from every watcher; on return no watcher calls it any more.
void spectrum_stream_detach(void *ctx);

// 0: spectrum_stream_decode_gray() doesn't copy the decoded image (nobody looks at it; the band sink's result is
// what's used): it writes a small tag into the image's first row instead, which spectrum_stream_take() reads.
// 1 (default): copy. spectrum_stream_refs(): frames handed over by tag so far.
void spectrum_stream_set_copy(int on);

// Stops and unmaps the watchers of a device (its /dev path; NULL: all), so another owner (the native camera
// backend) can allocate its buffers. Returns how many.
int spectrum_stream_release(const char *dev);
long spectrum_stream_refs(void);

#ifdef __cplusplus
}

namespace spectrum_stream {
inline int DecodeGray(const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height,
                      size_t stride) {
  return spectrum_stream_decode_gray(jpeg, size, out, width, height, stride);
}
}  // namespace spectrum_stream
#endif
