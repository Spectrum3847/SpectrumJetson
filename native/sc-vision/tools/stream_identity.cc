// stream_identity: offline "fake camera" for the native backend's per-frame core (docs/SYSTEMCORE-NATIVE-BACKEND.md).
// Each frame of a recorded MJPEG arrives in USB-sized pieces (CHUNK bytes, 2 x 1600 by default: one 2-packet URB),
// is decoded as it lands (mjdec) and fed to streaming NAPA band by band, exactly as the backend will; the result
// must equal libjpeg-turbo + whole-frame napa_detect on the same frame (ids, order, corners bit for bit). With
// --scale 2 the streamed side decodes at half size and its corners are mapped back (x = 2x' + 0.5): then it
// reports agreement (ids found by both, corner differences) instead of identity.
//   stream_identity FILE.mjpeg [--min-tag 32] [--chunk 3200] [--scale 1|2] [--max N]
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <jpeglib.h>

#include <algorithm>
#include <cmath>
#include <vector>

extern "C" {
#include "mjdec.h"
#include "napa_core.h"
}

static double cpu_ms() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static bool turbo(const uint8_t *j, size_t n, std::vector<uint8_t> &y, int w, int h) {
  jpeg_decompress_struct c;
  jpeg_error_mgr e;
  c.err = jpeg_std_error(&e);
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, j, n);
  if (jpeg_read_header(&c, TRUE) != JPEG_HEADER_OK) return jpeg_destroy_decompress(&c), false;
  c.out_color_space = JCS_GRAYSCALE;
  c.dct_method = JDCT_ISLOW;
  jpeg_start_decompress(&c);
  if ((int)c.output_width != w || (int)c.output_height != h) return jpeg_destroy_decompress(&c), false;
  while (c.output_scanline < c.output_height) {
    JSAMPROW r = y.data() + (size_t)c.output_scanline * w;
    jpeg_read_scanlines(&c, &r, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  return true;
}

int main(int argc, char **argv) {
  if (argc < 2) return fprintf(stderr, "usage: stream_identity FILE.mjpeg [--min-tag N] [--chunk B] [--scale S] [--max N]\n"), 2;
  int min_tag = 32, chunk = 3200, scale = 1, maxf = 100000;
  for (int i = 2; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--min-tag")) min_tag = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--chunk")) chunk = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--scale")) scale = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--max")) maxf = atoi(argv[i + 1]);
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) return perror(argv[1]), 1;
  std::vector<uint8_t> all;
  for (int ch; (ch = fgetc(f)) != EOF;) all.push_back((uint8_t)ch);
  fclose(f);
  std::vector<std::pair<size_t, size_t>> fr;
  for (size_t p = 0; p + 1 < all.size() && (int)fr.size() < maxf;) {
    if (all[p] == 0xFF && all[p + 1] == 0xD8) {
      size_t q = p + 2;
      while (q + 1 < all.size() && !(all[q] == 0xFF && all[q + 1] == 0xD9)) q++;
      fr.push_back({p, q + 2 - p});
      p = q + 2;
    } else {
      p++;
    }
  }
  const int W = 1280, H = 800, Ws = W / scale, Hs = H / scale;
  std::vector<uint8_t> ref((size_t)W * H), img((size_t)W * H), buf(1 << 21);
  napa_detector *dw = napa_create(), *ds = napa_create();
  napa_stream *ns = napa_stream_create(ds);
  mjdec *dec = mjdec_create();
  mjdec_set_scale(dec, scale);
  napa_params pw{min_tag, 1, 20, 22, 25}, ps = pw;
  ps.min_tag_px = std::max(4, min_tag / scale);
  napa_detection a[64], b[64];
  long same = 0, differ = 0, bad = 0, tags_a = 0, tags_b = 0;
  double max_corner = 0, cpu_stream = 0;
  for (auto [off, len] : fr) {
    const uint8_t *j = all.data() + off;
    if (!turbo(j, len, ref, W, H)) {
      bad++;
      continue;
    }
    const int na = std::max(0, napa_detect(dw, ref.data(), W, H, W, &pw, a, 64));
    // the fake camera: the frame's bytes land CHUNK at a time in a "V4L2 buffer"; decode + NAPA as they arrive
    memset(buf.data(), 0xFF, std::min(buf.size(), len + 65536));
    const double c0 = cpu_ms();
    mjdec_begin(dec, buf.data(), buf.size(), img.data(), W, H, Ws);
    napa_stream_begin(ns, img.data(), Ws, Hs, Ws, &ps);
    int rows = 0;
    bool ok = true;
    for (size_t got = 0; got < len;) {
      const size_t n = std::min((size_t)chunk, len - got);
      memcpy(buf.data() + got, j + got, n);
      got += n;
      const int r = mjdec_feed(dec, got);
      if (r < 0) {
        ok = false;
        break;
      }
      if (r > rows) napa_stream_feed(ns, rows = r);
    }
    const int nb = ok && rows >= Hs ? std::max(0, napa_stream_finish(ns, b, 64)) : (napa_stream_finish(ns, b, 64), -1);
    cpu_stream += cpu_ms() - c0;
    if (nb < 0) {
      bad++;
      continue;
    }
    if (scale > 1)
      for (int i = 0; i < nb; i++)
        for (double &v : b[i].corners) v = v * scale + (scale - 1) * 0.5;
    tags_a += na, tags_b += nb;
    bool eq = na == nb;
    for (int i = 0; eq && i < na; i++) eq = a[i].id == b[i].id && !memcmp(a[i].corners, b[i].corners, sizeof a[i].corners);
    for (int i = 0; i < na; i++)
      for (int k = 0; k < nb; k++)
        if (a[i].id == b[k].id)
          for (int c = 0; c < 8; c++) max_corner = std::max(max_corner, std::fabs(a[i].corners[c] - b[k].corners[c]));
    (eq ? same : differ)++;
  }
  printf("%zu frames, min tag %d, chunk %d B, scale 1/%d: %ld identical, %ld differ, %ld undecodable; tags whole %ld, "
         "streamed %ld; max corner difference (same id) %.4f px; streamed decode+NAPA CPU %.3f ms/frame\n",
         fr.size(), min_tag, chunk, scale, same, differ, bad, tags_a, tags_b, max_corner,
         cpu_stream / std::max<long>(1, same + differ));
  return scale == 1 && differ ? 1 : 0;
}
