// mjdec_bench: identity and speed of the sc-vision luma decoder against libjpeg-turbo (JCS_GRAYSCALE, ISLOW).
//   mjdec_bench FILE.mjpeg [--iters N] [--chunk BYTES] [--cpu K] [--dump-diff]
// FILE: concatenated JPEG frames (v4l2-ctl --stream-to, or a Rewind .mjpeg). Prints per-frame identity (every
// byte of Y), and decode CPU time p50/p95/p99 for libjpeg-turbo whole-frame, mjdec whole-frame, and mjdec fed in
// CHUNK-byte pieces (the streaming path: the work left after the last chunk = the tail).
// Also self-tests the NEON IDCT against the scalar one on random blocks.
#define _GNU_SOURCE
#include <sched.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <jpeglib.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/mjdec.h"

void mjdec_idct_ref(const int32_t *blk, uint8_t *out, int stride);
void mjdec_idct_fast(const int32_t *blk, uint8_t *out, int stride);
extern int mjdec_prof_no_idct;

static double now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
}
static double mono_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
}

struct jerr {
  struct jpeg_error_mgr m;
  jmp_buf j;
};
static void jerr_exit(j_common_ptr c) { longjmp(((struct jerr *)c->err)->j, 1); }
static void jerr_msg(j_common_ptr c, int lvl) { (void)c; (void)lvl; }

static int turbo_gray(const uint8_t *jpg, size_t n, uint8_t *out, int *w, int *h) {
  struct jpeg_decompress_struct c;
  struct jerr e;
  c.err = jpeg_std_error(&e.m);
  e.m.error_exit = jerr_exit;
  e.m.emit_message = jerr_msg;
  if (setjmp(e.j)) {
    jpeg_destroy_decompress(&c);
    return -1;
  }
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, jpg, n);
  jpeg_read_header(&c, TRUE);
  c.out_color_space = JCS_GRAYSCALE;
  c.dct_method = JDCT_ISLOW;
  jpeg_start_decompress(&c);
  *w = c.output_width;
  *h = c.output_height;
  while (c.output_scanline < c.output_height) {
    JSAMPROW r = out + (size_t)c.output_scanline * c.output_width;
    jpeg_read_scanlines(&c, &r, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  return 0;
}

static int cmpd(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static void pr(const char *name, double *v, int n) {
  if (!n) return;
  qsort(v, n, sizeof *v, cmpd);
  printf("%-34s n=%5d  p50 %7.3f  p95 %7.3f  p99 %7.3f ms\n", name, n, v[n / 2] / 1e6, v[(int)(n * .95)] / 1e6,
         v[(int)(n * .99)] / 1e6);
}

static int idct_selftest(void) {
  int32_t blk[64];
  uint8_t a[64], b[64];
  unsigned s = 12345;
  int bad = 0;
  for (int it = 0; it < 200000; it++) {
    memset(blk, 0, sizeof blk);
    int nnz = 1 + (it % 64);
    for (int k = 0; k < nnz; k++) {
      s = s * 1103515245 + 12345;
      int pos = (s >> 8) % 64;
      s = s * 1103515245 + 12345;
      int range = (it & 3) == 0 ? 2000 : (it & 3) == 1 ? 200 : 40;
      blk[pos] = (int)((s >> 8) % (2 * range + 1)) - range;
    }
    mjdec_idct_ref(blk, a, 8);
    mjdec_idct_fast(blk, b, 8);
    if (memcmp(a, b, 64)) bad++;
  }
  printf("IDCT NEON vs scalar: %d of 200000 random blocks differ\n", bad);
  {  // speed of the IDCT paths on one block (full 8x8, 4x4-sparse), stored into a 1280-wide image
    static uint8_t img[1280 * 16];
    int32_t full[64], sparse[64];
    for (int i = 0; i < 64; i++) full[i] = (i * 37) % 21 - 10, sparse[i] = ((i & 4) || (i & 32)) ? 0 : full[i];
    for (int pass = 0; pass < 2; pass++) {
      const int32_t *blk = pass ? sparse : full;
      double t0 = now_ns();
      for (int it = 0; it < 1000000; it++) mjdec_idct_fast(blk, img + (it % 160) * 8, 1280);
      printf("IDCT %s: %.1f ns/block (with the sparsity scan)\n", pass ? "4x4 sparse" : "full", (now_ns() - t0) / 1e6);
    }
  }
  return bad;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: mjdec_bench FILE.mjpeg [--iters N] [--chunk BYTES] [--cpu K] [--max N]\n");
    return 2;
  }
  int iters = 3, chunk = 2048, cpu = -1, maxf = 1 << 30, dump = 0;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--iters")) iters = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--chunk")) chunk = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--cpu")) cpu = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--max")) maxf = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--dump-diff")) dump = 1;
    else if (!strcmp(argv[i], "--no-idct")) mjdec_prof_no_idct = 1;  // profiling: Huffman only (output wrong)
  }
  if (cpu >= 0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof set, &set);
  }
  int bad_idct = idct_selftest();
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    perror(argv[1]);
    return 1;
  }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *all = malloc(sz);
  if (fread(all, 1, sz, f) != (size_t)sz) return 1;
  fclose(f);
  // split at SOI after EOI
  size_t *off = malloc(sizeof(size_t) * (sz / 1000 + 16)), *len = malloc(sizeof(size_t) * (sz / 1000 + 16));
  int nf = 0;
  for (long p = 0; p + 1 < sz && nf < maxf;) {
    if (all[p] == 0xFF && all[p + 1] == 0xD8) {
      long q = p + 2;
      while (q + 1 < sz && !(all[q] == 0xFF && all[q + 1] == 0xD9)) q++;
      off[nf] = p;
      len[nf] = q + 2 - p;
      nf++;
      p = q + 2;
    } else {
      p++;
    }
  }
  int w = 0, h = 0;
  uint8_t *ref = malloc(4096 * 4096), *got = malloc(4096 * 4096);
  if (turbo_gray(all + off[0], len[0], ref, &w, &h)) {
    fprintf(stderr, "libjpeg can't decode frame 0\n");
    return 1;
  }
  printf("%d frames, %dx%d, first %zu bytes\n", nf, w, h, len[0]);
  mjdec *d = mjdec_create();
  double *tt = malloc(sizeof(double) * nf * iters), *tm = malloc(sizeof(double) * nf * iters),
         *ts = malloc(sizeof(double) * nf * iters), *tail = malloc(sizeof(double) * nf * iters);
  int ntt = 0, ntm = 0, nts = 0, differ = 0, errs = 0;
  for (int it = 0; it < iters; it++) {
    for (int i = 0; i < nf; i++) {
      const uint8_t *j = all + off[i];
      double t0 = now_ns();
      int tw, th;
      if (turbo_gray(j, len[i], ref, &tw, &th)) {
        errs++;
        continue;
      }
      double t1 = now_ns();
      tt[ntt++] = t1 - t0;
      memset(got, 0x55, (size_t)w * h);
      t0 = now_ns();
      int r = mjdec_decode(d, j, len[i], got, w, h, w);
      t1 = now_ns();
      if (r < 0) {
        if (it == 0) printf("frame %d: mjdec error %d\n", i, r);
        errs++;
        continue;
      }
      tm[ntm++] = t1 - t0;
      if (it == 0 && memcmp(ref, got, (size_t)w * h)) {
        differ++;
        if (dump || differ < 4) {
          size_t k = 0;
          while (ref[k] == got[k]) k++;
          printf("frame %d differs: first at row %zu col %zu (%d vs %d)\n", i, k / w, k % w, ref[k], got[k]);
        }
      }
      // streaming: feed CHUNK bytes at a time; CPU for all; tail = the work in the last feed
      memset(got, 0x55, (size_t)w * h);
      mjdec_begin(d, j, len[i], got, w, h, w);
      double s0 = now_ns(), lastfeed = 0;
      for (size_t a = chunk; ; a += chunk) {
        size_t av = a < len[i] ? a : len[i];
        double f0 = mono_ns();
        int rr = mjdec_feed(d, av);
        lastfeed = mono_ns() - f0;
        if (rr < 0 || av == len[i]) break;
      }
      ts[nts] = now_ns() - s0;
      tail[nts++] = lastfeed;
      if (it == 0 && memcmp(ref, got, (size_t)w * h)) {
        differ++;
        printf("frame %d: streamed decode differs\n", i);
      }
    }
  }
  uint64_t dco, blocks;
  mjdec_stats(d, &dco, &blocks);
  printf("identity: %d frames, %d differ, %d errors; DC-only luma blocks %.1f%%\n", nf, differ, errs,
         blocks ? 100.0 * dco / blocks : 0);
  pr("libjpeg-turbo gray (whole frame)", tt, ntt);
  pr("mjdec (whole frame)", tm, ntm);
  pr("mjdec streamed, CPU total", ts, nts);
  pr("mjdec streamed, tail (last feed)", tail, nts);
  mjdec_destroy(d);
  return (differ || bad_idct) ? 1 : 0;
}
