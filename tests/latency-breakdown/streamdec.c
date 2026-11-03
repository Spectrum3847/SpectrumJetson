// Streaming (overlapped) CPU MJPEG decode test for tests/latency-breakdown.
// Can libjpeg-turbo decode a Thriftiest frame while its USB packets are still arriving, and how
// long is the tail after the last packet? Reads a raw MJPEG capture (v4l2-ctl --stream-to), and
// for each frame:
//   whole:  decode to gray in one go after all bytes are there (what a CPU decoder does today)
//   stream: the bytes are released in CHUNKS equal pieces over SPREAD_US (real time, like the
//           camera's ~8 ms readout over USB); a suspending source lets libjpeg decode every
//           complete MCU row as soon as its bytes are present, and it waits for the next piece
//           when it runs out. tail = last piece released -> last row decoded.
// Output: p50/p95/p99 of whole decode, stream tail, stream CPU per frame (thread CPU time).
// IFAST=1: the fast integer IDCT (default: the accurate one, as OpenCV uses).
// Build: gcc -O2 -o streamdec streamdec.c -ljpeg   Usage: streamdec FILE [CHUNKS] [SPREAD_US]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <setjmp.h>
#include <jpeglib.h>

static long now_ns(clockid_t c) { struct timespec t; clock_gettime(c, &t); return t.tv_sec * 1000000000L + t.tv_nsec; }

typedef struct { struct jpeg_source_mgr pub; const unsigned char *buf; size_t avail, fed; } src_t;
static void init_src(j_decompress_ptr d) { (void)d; }
static boolean fill(j_decompress_ptr d) { (void)d; return FALSE; }  // suspend: no more bytes yet
static void skip(j_decompress_ptr d, long n) {
  struct jpeg_source_mgr *s = d->src;
  if ((size_t)n <= s->bytes_in_buffer) { s->next_input_byte += n; s->bytes_in_buffer -= n; }
  else { s->next_input_byte += s->bytes_in_buffer; s->bytes_in_buffer = 0; }  // rare; fine for a test
}
static void term(j_decompress_ptr d) { (void)d; }
// more bytes arrived: extend the window (the buffer is the whole frame, so nothing moves)
static void feed(src_t *s, size_t upto) {
  size_t used = s->fed - s->pub.bytes_in_buffer;  // bytes libjpeg consumed so far
  s->fed = upto;
  s->pub.next_input_byte = s->buf + used;
  s->pub.bytes_in_buffer = upto - used;
}

typedef struct { struct jpeg_error_mgr pub; jmp_buf jb; } err_t;
static void on_err(j_common_ptr c) { longjmp(((err_t *)c->err)->jb, 1); }

static int cmp(const void *a, const void *b) { long x = *(long *)a, y = *(long *)b; return x < y ? -1 : x > y; }
static void stats(const char *name, long *v, int n) {
  qsort(v, n, sizeof *v, cmp);
  printf("%-28s n=%d p50 %.3f p95 %.3f p99 %.3f ms\n", name, n, v[n / 2] / 1e6, v[n * 95 / 100] / 1e6, v[n * 99 / 100] / 1e6);
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s FILE [CHUNKS] [SPREAD_US]\n", argv[0]); return 2; }
  int chunks = argc > 2 ? atoi(argv[2]) : 32;
  long spread = (argc > 3 ? atol(argv[3]) : 8000) * 1000L;
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
  unsigned char *all = malloc(len); if (fread(all, 1, len, f) != (size_t)len) return 1; fclose(f);
  int maxf = 4000, nf = 0; long *whole = calloc(maxf, 8), *tail = calloc(maxf, 8), *cpu = calloc(maxf, 8), *wcpu = calloc(maxf, 8);
  unsigned char *out = malloc(1280 * 800 * 3);
  for (long i = 0; i + 4 < len && nf < maxf;) {
    if (!(all[i] == 0xff && all[i + 1] == 0xd8)) { i++; continue; }
    long e = i + 2; while (e + 1 < len && !(all[e] == 0xff && all[e + 1] == 0xd9)) e++;
    if (e + 1 >= len) break;
    const unsigned char *jp = all + i; size_t n = e + 2 - i; i = e + 2;
    for (int mode = 0; mode < 2; mode++) {
      struct jpeg_decompress_struct d; err_t je; src_t s = {0};
      d.err = jpeg_std_error(&je.pub); je.pub.error_exit = on_err;
      if (setjmp(je.jb)) { jpeg_destroy_decompress(&d); fprintf(stderr, "bad frame %d\n", nf); goto next; }
      jpeg_create_decompress(&d);
      s.pub.init_source = init_src; s.pub.fill_input_buffer = fill; s.pub.skip_input_data = skip;
      s.pub.resync_to_restart = jpeg_resync_to_restart; s.pub.term_source = term; s.buf = jp;
      d.src = &s.pub;
      long t0 = now_ns(CLOCK_MONOTONIC), c0 = now_ns(CLOCK_THREAD_CPUTIME_ID);
      int k = mode ? 1 : chunks;  // whole: everything at once
      feed(&s, mode ? n / chunks : n);
      long last_release = t0;
      int state = 0;  // 0 header, 1 start, 2 rows
      while (1) {
        int progressed = 0;
        if (state == 0 && jpeg_read_header(&d, TRUE) == JPEG_HEADER_OK) { d.out_color_space = JCS_GRAYSCALE; d.dct_method = getenv("IFAST") ? JDCT_IFAST : JDCT_ISLOW; state = 1; progressed = 1; }
        if (state == 1 && jpeg_start_decompress(&d)) { state = 2; progressed = 1; }
        while (state == 2 && d.output_scanline < d.output_height) {
          JSAMPROW rows[16]; for (int r = 0; r < 16; r++) rows[r] = out + (size_t)(d.output_scanline + r) * d.output_width;
          int got = jpeg_read_scanlines(&d, rows, 16);
          if (!got) break;
          progressed = 1;
        }
        if (state == 2 && d.output_scanline >= d.output_height) break;
        {  // out of bytes (or done with what is there)
          if (k >= chunks) { if (!progressed) { fprintf(stderr, "stuck frame %d\n", nf); break; } continue; }
          // wait for the next piece's release time, then release it
          long rel = t0 + spread * k / chunks;
          while (now_ns(CLOCK_MONOTONIC) < rel) { struct timespec ts = {0, 20000}; nanosleep(&ts, NULL); }
          k++; feed(&s, k >= chunks ? n : n * k / chunks); last_release = now_ns(CLOCK_MONOTONIC);
        }
      }
      long t1 = now_ns(CLOCK_MONOTONIC), c1 = now_ns(CLOCK_THREAD_CPUTIME_ID);
      (void)jpeg_finish_decompress(&d);
      jpeg_destroy_decompress(&d);
      if (mode == 0) { whole[nf] = t1 - t0; wcpu[nf] = c1 - c0; }
      else { tail[nf] = t1 - last_release; cpu[nf] = c1 - c0; }
    }
    nf++;
  next:;
  }
  printf("frames %d, %d pieces over %.1f ms\n", nf, chunks, spread / 1e6);
  stats("whole decode (wall)", whole, nf);
  stats("whole decode (CPU)", wcpu, nf);
  stats("stream tail after last byte", tail, nf);
  stats("stream decode CPU/frame", cpu, nf);
  return 0;
}
