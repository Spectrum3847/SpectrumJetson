// SpectrumJetson: streaming MJPEG -> gray decode, overlapped with the USB transfer
// (SPECTRUM_JPEG_DECODER=stream; off by default). See stream_decode.cc.
#pragma once
#include <cstddef>
#include <cstdint>

namespace spectrum_stream {

// The frame PhotonVision just got (cscore's copy of a dequeued V4L2 buffer): if a watcher decoded
// these exact bytes while they were arriving, copy its gray image into out (width x height,
// stride bytes a row) and return 0. Waits up to ~3 ms for a decode still finishing its last rows.
// Returns 1 when there is no such decode (the caller decodes the frame itself).
int DecodeGray(const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height,
               size_t stride);

}  // namespace spectrum_stream
