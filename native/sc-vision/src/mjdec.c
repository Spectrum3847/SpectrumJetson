// sc-vision luma-only streaming JPEG decoder. See mjdec.h.
//
// How it is fast:
//  - Restart intervals are unstuffed (FF 00 -> FF) into a padded scratch buffer while the bytes arrive, so the
//    Huffman decoder reads plain big-endian words: no marker checks in the inner loop, refills are one load.
//  - Luma AC: a 9-bit lookahead table that decodes code + magnitude + run in one step for the common short
//    symbols (stb_image's fast_ac idea), canonical decode for the rest.
//  - Chroma is skipped: when every chroma block of an MCU is "DC difference 0, EOB" (a mono sensor's normal
//    case) and those codes are all-zero bit patterns, one peek skips all of them; otherwise a skip table
//    consumes code + magnitude bits without building values.
//  - IDCT: libjpeg-turbo's accurate integer IDCT (jidctint.c, the same constants, rounding and order), in NEON
//    with 32-bit lanes: bit-identical to libjpeg-turbo's ISLOW. DC-only blocks (common: flat areas) are a
//    constant fill, which is exactly what ISLOW computes for them.
#include "mjdec.h"

#include <stdlib.h>
#include <string.h>

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#define MJ_NEON 1
#else
#define MJ_NEON 0
#endif

#define LB 9  // lookahead bits
#define PAD 64

typedef struct {
  uint16_t lut[1 << LB];  // (len << 8) | sym for codes of len <= LB; 0 = longer code
  int16_t fac[1 << LB];   // AC: (value << 8) | (run << 4) | (len + size), when it fits; 0 = no
  uint16_t skip[1 << LB]; // AC skip: (kadv << 8) | (len + size), kadv 0 = EOB; 0 = longer code
  int32_t maxcode[18];
  int32_t valoff[17];     // vals index of the first code of each length, minus that code
  uint8_t vals[256];
  int zero_dc0, zero_eob; // bits of the DC category-0 code / of EOB, when that code is all zeros; else 0
  uint8_t src[17 + 256];  // the DHT bits + vals it was built from
  int srclen, valid;
} huff;

typedef struct {
  int id, h, v, tq, td, ta;
  int nblocks;   // blocks per MCU
} comp;

struct mjdec {
  // frame
  const uint8_t *jpeg;
  size_t cap;
  uint8_t *out;
  int width, height, stride;
  // header
  int hdr_done;
  size_t pos;  // next raw byte to look at
  int ncomp, ns, scomp[4];
  comp c[4];
  int hmax, vmax, mcuw, mcuh, mcux, mcuy, mcus;
  int dri;
  uint16_t qt[4][64];  // zigzag order, as in DQT
  int qvalid[4];
  huff dc[4], ac[4];
  // scan
  int mcu;          // next MCU to decode
  int next_rst;     // expected RST number
  int rows_done;
  size_t end;
  int err;
  int chroma_zero_bits;  // bits all chroma blocks of an MCU take when all are empty (0: no fast path)
  uint8_t *scr;
  size_t scr_n, scr_cap;
  // stats
  uint64_t st_dc, st_blocks;
};

static const uint8_t kZigzag[64 + 16] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
    30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    // a run past 63 (corrupt data) lands here, harmlessly
    63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63};

mjdec *mjdec_create(void) {
  mjdec *d = (mjdec *)calloc(1, sizeof(mjdec));
  return d;
}

void mjdec_destroy(mjdec *d) {
  if (!d) return;
  free(d->scr);
  free(d);
}

void mjdec_stats(const mjdec *d, uint64_t *dc_only, uint64_t *blocks) {
  if (dc_only) *dc_only = d->st_dc;
  if (blocks) *blocks = d->st_blocks;
}

size_t mjdec_end(const mjdec *d) { return d->end; }

// ---------------------------------------------------------------------------------------------- Huffman tables

static int build_huff(huff *t, const uint8_t *bits16, const uint8_t *vals, int ac) {
  int n = 0;
  for (int l = 0; l < 16; l++) n += bits16[l];
  if (n > 256) return -1;
  memset(t->lut, 0, sizeof t->lut);
  memset(t->fac, 0, sizeof t->fac);
  memset(t->skip, 0, sizeof t->skip);
  memcpy(t->vals, vals, (size_t)n);
  int code = 0, k = 0;
  t->zero_dc0 = t->zero_eob = 0;
  for (int l = 1; l <= 16; l++) {
    int cnt = bits16[l - 1];
    t->valoff[l] = k - code;
    for (int i = 0; i < cnt; i++, k++, code++) {
      int sym = vals[k];
      if (code == 0) {  // the all-zero code of this length
        if (!ac && sym == 0) t->zero_dc0 = l;
        if (ac && sym == 0) t->zero_eob = l;
      }
      if (l <= LB) {
        int lo = code << (LB - l), hi = (code + 1) << (LB - l);
        for (int x = lo; x < hi; x++) {
          t->lut[x] = (uint16_t)((l << 8) | sym);
          if (ac) {
            int r = sym >> 4, s = sym & 15;
            if (sym == 0) {
              t->skip[x] = (uint16_t)l;  // EOB: kadv 0
            } else if (sym == 0xF0) {
              t->skip[x] = (uint16_t)((16 << 8) | l);
            } else {
              t->skip[x] = (uint16_t)(((r + 1) << 8) | (l + s));
            }
            if (s && l + s <= LB) {
              int v = (x >> (LB - l - s)) & ((1 << s) - 1);
              if (v < (1 << (s - 1))) v += 1 - (1 << s);
              if (v >= -128 && v <= 127) t->fac[x] = (int16_t)(v * 256 + (r << 4) + (l + s));
            }
          }
        }
      }
    }
    t->maxcode[l] = cnt ? code - 1 : -1;
    code <<= 1;
  }
  t->maxcode[17] = 0x7fffffff;
  t->valid = 1;
  return 0;
}

// ---------------------------------------------------------------------------------------------- IDCT
// libjpeg-turbo jidctint.c (jpeg_idct_islow), CONST_BITS 13, PASS1_BITS 2.
#define FIX_0_298631336 2446
#define FIX_0_390180644 3196
#define FIX_0_541196100 4433
#define FIX_0_765366865 6270
#define FIX_0_899976223 7373
#define FIX_1_175875602 9633
#define FIX_1_501321110 12299
#define FIX_1_847759065 15137
#define FIX_1_961570560 16069
#define FIX_2_053119869 16819
#define FIX_2_562915447 20995
#define FIX_3_072711026 25172

static inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

// Scalar reference, the same arithmetic as jidctint.c (blk: dequantized, natural order).
static void idct_islow_c(const int32_t *blk, uint8_t *out, int stride) {
  int32_t ws[64];
  for (int c = 0; c < 8; c++) {
    const int32_t *in = blk + c;
    int32_t z1, z2, z3, z4, z5, tmp0, tmp1, tmp2, tmp3, tmp10, tmp11, tmp12, tmp13;
    z2 = in[16];
    z3 = in[48];
    z1 = (z2 + z3) * FIX_0_541196100;
    tmp2 = z1 + z3 * -FIX_1_847759065;
    tmp3 = z1 + z2 * FIX_0_765366865;
    z2 = in[0];
    z3 = in[32];
    tmp0 = (z2 + z3) * (1 << 13);
    tmp1 = (z2 - z3) * (1 << 13);
    tmp10 = tmp0 + tmp3;
    tmp13 = tmp0 - tmp3;
    tmp11 = tmp1 + tmp2;
    tmp12 = tmp1 - tmp2;
    tmp0 = in[56];
    tmp1 = in[40];
    tmp2 = in[24];
    tmp3 = in[8];
    z1 = tmp0 + tmp3;
    z2 = tmp1 + tmp2;
    z3 = tmp0 + tmp2;
    z4 = tmp1 + tmp3;
    z5 = (z3 + z4) * FIX_1_175875602;
    tmp0 *= FIX_0_298631336;
    tmp1 *= FIX_2_053119869;
    tmp2 *= FIX_3_072711026;
    tmp3 *= FIX_1_501321110;
    z1 *= -FIX_0_899976223;
    z2 *= -FIX_2_562915447;
    z3 *= -FIX_1_961570560;
    z4 *= -FIX_0_390180644;
    z3 += z5;
    z4 += z5;
    tmp0 += z1 + z3;
    tmp1 += z2 + z4;
    tmp2 += z2 + z3;
    tmp3 += z1 + z4;
    ws[c + 0] = (tmp10 + tmp3 + (1 << 10)) >> 11;
    ws[c + 56] = (tmp10 - tmp3 + (1 << 10)) >> 11;
    ws[c + 8] = (tmp11 + tmp2 + (1 << 10)) >> 11;
    ws[c + 48] = (tmp11 - tmp2 + (1 << 10)) >> 11;
    ws[c + 16] = (tmp12 + tmp1 + (1 << 10)) >> 11;
    ws[c + 40] = (tmp12 - tmp1 + (1 << 10)) >> 11;
    ws[c + 24] = (tmp13 + tmp0 + (1 << 10)) >> 11;
    ws[c + 32] = (tmp13 - tmp0 + (1 << 10)) >> 11;
  }
  for (int r = 0; r < 8; r++) {
    const int32_t *w = ws + r * 8;
    uint8_t *o = out + (size_t)r * stride;
    int32_t z1, z2, z3, z4, z5, tmp0, tmp1, tmp2, tmp3, tmp10, tmp11, tmp12, tmp13;
    z2 = w[2];
    z3 = w[6];
    z1 = (z2 + z3) * FIX_0_541196100;
    tmp2 = z1 + z3 * -FIX_1_847759065;
    tmp3 = z1 + z2 * FIX_0_765366865;
    tmp0 = (w[0] + w[4]) * (1 << 13);
    tmp1 = (w[0] - w[4]) * (1 << 13);
    tmp10 = tmp0 + tmp3;
    tmp13 = tmp0 - tmp3;
    tmp11 = tmp1 + tmp2;
    tmp12 = tmp1 - tmp2;
    tmp0 = w[7];
    tmp1 = w[5];
    tmp2 = w[3];
    tmp3 = w[1];
    z1 = tmp0 + tmp3;
    z2 = tmp1 + tmp2;
    z3 = tmp0 + tmp2;
    z4 = tmp1 + tmp3;
    z5 = (z3 + z4) * FIX_1_175875602;
    tmp0 *= FIX_0_298631336;
    tmp1 *= FIX_2_053119869;
    tmp2 *= FIX_3_072711026;
    tmp3 *= FIX_1_501321110;
    z1 *= -FIX_0_899976223;
    z2 *= -FIX_2_562915447;
    z3 *= -FIX_1_961570560;
    z4 *= -FIX_0_390180644;
    z3 += z5;
    z4 += z5;
    tmp0 += z1 + z3;
    tmp1 += z2 + z4;
    tmp2 += z2 + z3;
    tmp3 += z1 + z4;
    const int R = 1 << 17;
    o[0] = clamp8(((tmp10 + tmp3 + R) >> 18) + 128);
    o[7] = clamp8(((tmp10 - tmp3 + R) >> 18) + 128);
    o[1] = clamp8(((tmp11 + tmp2 + R) >> 18) + 128);
    o[6] = clamp8(((tmp11 - tmp2 + R) >> 18) + 128);
    o[2] = clamp8(((tmp12 + tmp1 + R) >> 18) + 128);
    o[5] = clamp8(((tmp12 - tmp1 + R) >> 18) + 128);
    o[3] = clamp8(((tmp13 + tmp0 + R) >> 18) + 128);
    o[4] = clamp8(((tmp13 - tmp0 + R) >> 18) + 128);
  }
}

#if MJ_NEON
// One 1-D pass on 4 lanes. SPARSE: x[4..7] are zero (the compiler drops their terms; the integer result is the
// same, so the output stays bit-identical).
static inline __attribute__((always_inline)) void idct_1d(const int32x4_t *x, int32x4_t *y, const int sparse) {
  const int32x4_t zero = vdupq_n_s32(0);
  const int32x4_t x4 = sparse ? zero : x[4], x5 = sparse ? zero : x[5], x6 = sparse ? zero : x[6],
                  x7 = sparse ? zero : x[7];
  int32x4_t z1, z2, z3, z4, z5, t0, t1, t2, t3, t10, t11, t12, t13;
  z1 = vmulq_n_s32(vaddq_s32(x[2], x6), FIX_0_541196100);
  t2 = sparse ? z1 : vmlaq_n_s32(z1, x6, -FIX_1_847759065);
  t3 = vmlaq_n_s32(z1, x[2], FIX_0_765366865);
  t0 = vshlq_n_s32(vaddq_s32(x[0], x4), 13);
  t1 = sparse ? t0 : vshlq_n_s32(vsubq_s32(x[0], x4), 13);
  t10 = vaddq_s32(t0, t3);
  t13 = vsubq_s32(t0, t3);
  t11 = vaddq_s32(t1, t2);
  t12 = vsubq_s32(t1, t2);
  z1 = vaddq_s32(x7, x[1]);
  z2 = vaddq_s32(x5, x[3]);
  z3 = vaddq_s32(x7, x[3]);
  z4 = vaddq_s32(x5, x[1]);
  z5 = vmulq_n_s32(vaddq_s32(z3, z4), FIX_1_175875602);
  t0 = vmulq_n_s32(x7, FIX_0_298631336);
  t1 = vmulq_n_s32(x5, FIX_2_053119869);
  t2 = vmulq_n_s32(x[3], FIX_3_072711026);
  t3 = vmulq_n_s32(x[1], FIX_1_501321110);
  z1 = vmulq_n_s32(z1, -FIX_0_899976223);
  z2 = vmulq_n_s32(z2, -FIX_2_562915447);
  z3 = vmlaq_n_s32(z5, z3, -FIX_1_961570560);
  z4 = vmlaq_n_s32(z5, z4, -FIX_0_390180644);
  t0 = vaddq_s32(t0, vaddq_s32(z1, z3));
  t1 = vaddq_s32(t1, vaddq_s32(z2, z4));
  t2 = vaddq_s32(t2, vaddq_s32(z2, z3));
  t3 = vaddq_s32(t3, vaddq_s32(z1, z4));
  y[0] = vaddq_s32(t10, t3);
  y[7] = vsubq_s32(t10, t3);
  y[1] = vaddq_s32(t11, t2);
  y[6] = vsubq_s32(t11, t2);
  y[2] = vaddq_s32(t12, t1);
  y[5] = vsubq_s32(t12, t1);
  y[3] = vaddq_s32(t13, t0);
  y[4] = vsubq_s32(t13, t0);
}

static inline void transpose4(int32x4_t *a, int32x4_t *b, int32x4_t *c, int32x4_t *e) {
  int32x4x2_t p = vtrnq_s32(*a, *b), q = vtrnq_s32(*c, *e);
  *a = vcombine_s32(vget_low_s32(p.val[0]), vget_low_s32(q.val[0]));
  *b = vcombine_s32(vget_low_s32(p.val[1]), vget_low_s32(q.val[1]));
  *c = vcombine_s32(vget_high_s32(p.val[0]), vget_high_s32(q.val[0]));
  *e = vcombine_s32(vget_high_s32(p.val[1]), vget_high_s32(q.val[1]));
}

// Pass 2 on 4 rows (lanes) and the output: x[c] = workspace column c of those rows. 4 rows -> out rows.
static inline __attribute__((always_inline)) void pass2_store(const int32x4_t *x, uint8_t *out, int stride,
                                                              const int sparse) {
  int32x4_t y[8];
  idct_1d(x, y, sparse);
  // y[j]: output column j for these 4 rows. -> 16-bit, +128, saturate to bytes, then 4x8 transpose.
  const int16x8_t c128 = vdupq_n_s16(128);
  int16x8_t c01 = vcombine_s16(vqmovn_s32(vrshrq_n_s32(y[0], 18)), vqmovn_s32(vrshrq_n_s32(y[1], 18)));
  int16x8_t c23 = vcombine_s16(vqmovn_s32(vrshrq_n_s32(y[2], 18)), vqmovn_s32(vrshrq_n_s32(y[3], 18)));
  int16x8_t c45 = vcombine_s16(vqmovn_s32(vrshrq_n_s32(y[4], 18)), vqmovn_s32(vrshrq_n_s32(y[5], 18)));
  int16x8_t c67 = vcombine_s16(vqmovn_s32(vrshrq_n_s32(y[6], 18)), vqmovn_s32(vrshrq_n_s32(y[7], 18)));
  // bytes: lane r of col j, for j 0..7 r 0..3 (each u8x8 = two columns: [col j rows0-3, col j+1 rows 0-3])
  uint8x8_t b01 = vqmovun_s16(vaddq_s16(c01, c128)), b23 = vqmovun_s16(vaddq_s16(c23, c128));
  uint8x8_t b45 = vqmovun_s16(vaddq_s16(c45, c128)), b67 = vqmovun_s16(vaddq_s16(c67, c128));
  // Gather row r: [c0 r, c1 r, ..., c7 r]. Use a table lookup over the 32 bytes.
  uint8x16x2_t tab = {{vcombine_u8(b01, b23), vcombine_u8(b45, b67)}};
  // byte index of (col j, row r): (j/2)*8 + (j%2)*4 + r, in the 32-byte table
  static const uint8_t kIdx[32] = {0, 4, 8, 12, 16, 20, 24, 28, 1, 5, 9, 13, 17, 21, 25, 29,
                                   2, 6, 10, 14, 18, 22, 26, 30, 3, 7, 11, 15, 19, 23, 27, 31};
  uint8x16_t r01 = vqtbl2q_u8(tab, vld1q_u8(kIdx)), r23 = vqtbl2q_u8(tab, vld1q_u8(kIdx + 16));
  vst1_u8(out, vget_low_u8(r01));
  vst1_u8(out + stride, vget_high_u8(r01));
  vst1_u8(out + 2 * (size_t)stride, vget_low_u8(r23));
  vst1_u8(out + 3 * (size_t)stride, vget_high_u8(r23));
}

static inline __attribute__((always_inline)) void idct_neon_impl(const int32_t *blk, uint8_t *out, int stride,
                                                                 const int sparse) {
  int32x4_t x[8], yl[8], yh[8];
  // pass 1, columns 0-3: row r of the block is lanes = columns. SPARSE: rows 4-7 and columns 4-7 are zero.
  for (int r = 0; r < (sparse ? 4 : 8); r++) x[r] = vld1q_s32(blk + r * 8);
  idct_1d(x, yl, sparse);
  for (int r = 0; r < 8; r++) yl[r] = vrshrq_n_s32(yl[r], 11);
  if (!sparse) {
    for (int r = 0; r < 8; r++) x[r] = vld1q_s32(blk + r * 8 + 4);
    idct_1d(x, yh, 0);
    for (int r = 0; r < 8; r++) yh[r] = vrshrq_n_s32(yh[r], 11);
  }
  // workspace ws[r][c]: yl[r] cols 0-3, yh[r] cols 4-7. Transpose quadrants so lanes = rows.
  transpose4(&yl[0], &yl[1], &yl[2], &yl[3]);
  transpose4(&yl[4], &yl[5], &yl[6], &yl[7]);
  int32x4_t w[8];
  // rows 0-3: column c = yl[c] (c < 4), yh[c] (c >= 4 -> after transposing yh[0..3])
  if (!sparse) {
    transpose4(&yh[0], &yh[1], &yh[2], &yh[3]);
    transpose4(&yh[4], &yh[5], &yh[6], &yh[7]);
  }
  for (int c = 0; c < 4; c++) w[c] = yl[c];
  if (!sparse)
    for (int c = 0; c < 4; c++) w[4 + c] = yh[c];
  pass2_store(w, out, stride, sparse);
  for (int c = 0; c < 4; c++) w[c] = yl[4 + c];
  if (!sparse)
    for (int c = 0; c < 4; c++) w[4 + c] = yh[4 + c];
  pass2_store(w, out + 4 * (size_t)stride, stride, sparse);
}

static void idct_islow_neon(const int32_t *blk, uint8_t *out, int stride) { idct_neon_impl(blk, out, stride, 0); }
static void idct_islow_neon4(const int32_t *blk, uint8_t *out, int stride) { idct_neon_impl(blk, out, stride, 1); }
#define IDCT idct_islow_neon
#define IDCT4 idct_islow_neon4
#else
#define IDCT idct_islow_c
#define IDCT4 idct_islow_c
#endif

int mjdec_prof_no_idct = 0;  // profiling only: skip the IDCT/fill

// Exposed for the test: the scalar and the NEON IDCT on the same block.
void mjdec_idct_ref(const int32_t *blk, uint8_t *out, int stride) { idct_islow_c(blk, out, stride); }
void mjdec_idct_fast(const int32_t *blk, uint8_t *out, int stride) {
  int sparse = 1;
  for (int i = 0; i < 64; i++)
    if (blk[i] && ((i & 4) || (i & 32))) sparse = 0;
  if (sparse) IDCT4(blk, out, stride);
  else IDCT(blk, out, stride);
}

// What ISLOW gives a block with only a DC term: pass 1 makes every column (dc << 2), pass 2 descales by 5.
static inline void fill_dc(int32_t dq, uint8_t *out, int stride) {
  int v = (((dq * 4) + 16) >> 5) + 128;
  uint8_t p = clamp8(v);
#if MJ_NEON
  uint8x8_t pv = vdup_n_u8(p);
  for (int r = 0; r < 8; r++) vst1_u8(out + (size_t)r * stride, pv);
#else
  for (int r = 0; r < 8; r++) memset(out + (size_t)r * stride, p, 8);
#endif
}

// ---------------------------------------------------------------------------------------------- bit reader

typedef struct {
  uint64_t bb;
  int bits;
  const uint8_t *p;
} bitr;

static inline uint32_t load_be32(const uint8_t *p) {
  uint32_t w;
  memcpy(&w, p, 4);
  return __builtin_bswap32(w);
}

static inline uint64_t load_be64(const uint8_t *p) {
  uint64_t w;
  memcpy(&w, p, 8);
  return __builtin_bswap64(w);
}

// Branchless refill to 56..63 valid bits (F. Giesen's "variant 4"): the scratch buffer is padded, so the 8-byte
// load never runs past it; bytes already in the buffer are OR-ed in again at the same place.
#define REFILL(b)                                    do {                                                 (b).bb |= load_be64((b).p) >> (b).bits;            (b).p += (63 - (b).bits) >> 3;                     (b).bits |= 56;                                  } while (0)
#define PEEK(b, n) ((uint32_t)((b).bb >> (64 - (n))))
#define DROP(b, n) \
  do {             \
    (b).bb <<= (n); \
    (b).bits -= (n); \
  } while (0)

static inline int extend(uint32_t v, int s) { return (int)v < (1 << (s - 1)) ? (int)v - (1 << s) + 1 : (int)v; }

// A symbol with a code longer than LB bits (or any code, slow path). Returns sym, or -1.
static inline int slow_sym(const huff *t, bitr *b) {
  uint32_t c16 = PEEK(*b, 16);
  for (int l = LB + 1; l <= 16; l++) {
    int32_t code = (int32_t)(c16 >> (16 - l));
    if (code <= t->maxcode[l]) {
      DROP(*b, l);
      return t->vals[t->valoff[l] + code];
    }
  }
  return -1;
}

static inline int dec_sym(const huff *t, bitr *b) {
  uint16_t e = t->lut[PEEK(*b, LB)];
  if (e) {
    DROP(*b, e >> 8);
    return e & 0xff;
  }
  return slow_sym(t, b);
}

// Decode one luma block into blk (dequantized, natural order). Returns the number of coefficients after the DC
// that were written (0: DC only), or -1. nz[]: the natural indices written (for clearing).
static inline int dec_block(const huff *dct, const huff *act, const uint16_t *q, bitr *b, int *pred,
                            int32_t *blk, uint8_t *nz) {
  REFILL(*b);
  int s = dec_sym(dct, b);
  if (s < 0 || s > 11) return -1;
  int diff = 0;
  if (s) {
    diff = extend(PEEK(*b, s), s);
    DROP(*b, s);
  }
  *pred += diff;
  blk[0] = *pred * q[0];
  int n = 0;
  int k = 1;
  while (k < 64) {
    REFILL(*b);
    uint32_t idx = PEEK(*b, LB);
    int f = act->fac[idx];
    if (f) {
      k += (f >> 4) & 15;
      DROP(*b, f & 15);
      int z = kZigzag[k];
      blk[z] = (f >> 8) * q[k & 63];
      nz[n++] = (uint8_t)z;
      k++;
      continue;
    }
    int sym;
    uint16_t e = act->lut[idx];
    if (e) {
      DROP(*b, e >> 8);
      sym = e & 0xff;
    } else {
      sym = slow_sym(act, b);
      if (sym < 0) return -1;
    }
    int r = sym >> 4, sz = sym & 15;
    if (sz) {
      k += r;
      int v = extend(PEEK(*b, sz), sz);
      DROP(*b, sz);
      int z = kZigzag[k];
      blk[z] = v * q[k & 63];
      nz[n++] = (uint8_t)z;
      k++;
    } else if (r == 15) {
      k += 16;
    } else {
      break;  // EOB
    }
  }
  if (k > 64) return -1;
  return n;
}

// Skip one block's Huffman data (chroma). Returns 0 or -1.
static inline int skip_block(const huff *dct, const huff *act, bitr *b) {
  REFILL(*b);
  int s = dec_sym(dct, b);
  if (s < 0 || s > 11) return -1;
  DROP(*b, s);
  int k = 1;
  while (k < 64) {
    REFILL(*b);
    uint32_t idx = PEEK(*b, LB);
    uint16_t e = act->skip[idx];
    if (e) {
      DROP(*b, e & 0xff);
      int kadv = e >> 8;
      if (!kadv) return 0;  // EOB
      k += kadv;
      continue;
    }
    int sym = slow_sym(act, b);
    if (sym < 0) return -1;
    int r = sym >> 4, sz = sym & 15;
    if (sz) {
      DROP(*b, sz);
      k += r + 1;
    } else if (r == 15) {
      k += 16;
    } else {
      return 0;
    }
  }
  return k > 64 ? -1 : 0;
}

// ---------------------------------------------------------------------------------------------- scan

// Decode the MCUs [d->mcu, end) from the unstuffed interval in d->scr (d->scr_n bytes + PAD zero bytes).
static int decode_interval(mjdec *d, int end) {
  memset(d->scr + d->scr_n, 0, PAD);
  bitr b = {0, 0, d->scr};
  int pred[4] = {0, 0, 0, 0};
  int32_t blk[64];
  uint8_t nz[64];
  memset(blk, 0, sizeof blk);
  const int czb = d->chroma_zero_bits;
  for (int m = d->mcu; m < end; m++) {
    const int mx = m % d->mcux, my = m / d->mcux;
    for (int si = 0; si < d->ns; si++) {
      const comp *c = &d->c[d->scomp[si]];
      const huff *dct = &d->dc[c->td], *act = &d->ac[c->ta];
      if (si == 0) {  // luma
        for (int by = 0; by < c->v; by++) {
          for (int bx = 0; bx < c->h; bx++) {
            int n = dec_block(dct, act, d->qt[c->tq], &b, &pred[0], blk, nz);
            if (n < 0) return MJDEC_EBAD;
            int x = mx * d->mcuw + bx * 8, y = my * d->mcuh + by * 8;
            uint8_t *o = d->out + (size_t)y * d->stride + x;
            d->st_blocks++;
            if (mjdec_prof_no_idct) {
              for (int i = 0; i < n; i++) blk[nz[i]] = 0;
            } else if (n == 0) {
              fill_dc(blk[0], o, d->stride);
              d->st_dc++;
            } else {
              int wide = 0;  // any coefficient in rows 4-7 or columns 4-7?
              for (int i = 0; i < n; i++) wide |= nz[i] & 0x24;
              if (wide) IDCT(blk, o, d->stride);
              else IDCT4(blk, o, d->stride);
              for (int i = 0; i < n; i++) blk[nz[i]] = 0;
            }
            blk[0] = 0;
          }
        }
      } else {
        if (czb && si == 1) {  // czb covers all chroma blocks of the MCU, so only at the first
          REFILL(b);
          if (PEEK(b, czb) == 0) {  // every chroma block of this MCU: DC difference 0, then EOB
            DROP(b, czb);
            break;  // chroma components are last in the scan
          }
        }
        for (int k = 0; k < c->nblocks; k++)
          if (skip_block(dct, act, &b) < 0) return MJDEC_EBAD;
      }
    }
  }
  // Bits read past the data: only the zero padding (a decoder reading into the next interval is corrupt).
  if (b.p - d->scr > (ptrdiff_t)(d->scr_n + PAD - 8)) return MJDEC_EBAD;
  d->mcu = end;
  return 0;
}

static inline uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

// Parse markers from d->pos up to SOS. Returns 1 when the scan starts, 0 for more bytes, <0 error.
static int parse_header(mjdec *d, size_t avail) {
  const uint8_t *j = d->jpeg;
  if (d->pos == 0) {
    if (avail < 2) return 0;
    if (j[0] != 0xFF || j[1] != 0xD8) return MJDEC_EBAD;
    d->pos = 2;
  }
  for (;;) {
    size_t p = d->pos;
    while (p < avail && j[p] == 0xFF && p + 1 < avail && j[p + 1] == 0xFF) p++;  // fill bytes
    if (p + 4 > avail) return 0;
    if (j[p] != 0xFF) return MJDEC_EBAD;
    int m = j[p + 1];
    size_t len = be16(j + p + 2);
    if (len < 2) return MJDEC_EBAD;
    if (p + 2 + len > avail) return 0;
    const uint8_t *s = j + p + 4;
    size_t n = len - 2;
    switch (m) {
      case 0xC0:
      case 0xC1: {  // SOF0/1, 8-bit
        if (n < 6 || s[0] != 8) return MJDEC_EUNSUP;
        int h = be16(s + 1), w = be16(s + 3), nc = s[5];
        if ((nc != 1 && nc != 3) || n < 6 + 3u * nc) return MJDEC_EUNSUP;
        if (w != d->width || h != d->height) return MJDEC_EBAD;
        d->ncomp = nc;
        d->hmax = d->vmax = 1;
        for (int i = 0; i < nc; i++) {
          d->c[i].id = s[6 + 3 * i];
          d->c[i].h = s[7 + 3 * i] >> 4;
          d->c[i].v = s[7 + 3 * i] & 15;
          d->c[i].tq = s[8 + 3 * i] & 3;
          if (d->c[i].h > d->hmax) d->hmax = d->c[i].h;
          if (d->c[i].v > d->vmax) d->vmax = d->c[i].v;
        }
        if (nc == 1) d->c[0].h = d->c[0].v = d->hmax = d->vmax = 1;  // non-interleaved: 1-block MCUs
        // Y may be 1x1, 2x1, 2x2; chroma 1x1 (anything else: libjpeg-turbo)
        if (d->c[0].h > 2 || d->c[0].v > 2 || d->c[0].h != d->hmax || d->c[0].v != d->vmax) return MJDEC_EUNSUP;
        for (int i = 1; i < nc; i++)
          if (d->c[i].h != 1 || d->c[i].v != 1) return MJDEC_EUNSUP;
        for (int i = 0; i < nc; i++) d->c[i].nblocks = d->c[i].h * d->c[i].v;
        d->mcuw = 8 * d->hmax;
        d->mcuh = 8 * d->vmax;
        if (w % d->mcuw || h % d->mcuh) return MJDEC_EUNSUP;  // partial MCUs: not needed for our cameras
        d->mcux = w / d->mcuw;
        d->mcuy = h / d->mcuh;
        d->mcus = d->mcux * d->mcuy;
        break;
      }
      case 0xC2:
      case 0xC3:
      case 0xC5:
      case 0xC6:
      case 0xC7:
      case 0xC9:
      case 0xCA:
      case 0xCB:
      case 0xCD:
      case 0xCE:
      case 0xCF:
        return MJDEC_EUNSUP;
      case 0xDB: {  // DQT
        size_t i = 0;
        while (i < n) {
          int pq = s[i] >> 4, tq = s[i] & 15;
          if (pq != 0 || tq > 3 || i + 65 > n) return MJDEC_EUNSUP;
          for (int k = 0; k < 64; k++) d->qt[tq][k] = s[i + 1 + k];
          d->qvalid[tq] = 1;
          i += 65;
        }
        break;
      }
      case 0xC4: {  // DHT
        size_t i = 0;
        while (i < n) {
          if (i + 17 > n) return MJDEC_EBAD;
          int tc = s[i] >> 4, th = s[i] & 15;
          if (tc > 1 || th > 3) return MJDEC_EBAD;
          int cnt = 0;
          for (int l = 0; l < 16; l++) cnt += s[i + 1 + l];
          if (cnt > 256 || i + 17 + cnt > n) return MJDEC_EBAD;
          huff *t = tc ? &d->ac[th] : &d->dc[th];
          int sl = 16 + cnt;
          if (!t->valid || t->srclen != sl || memcmp(t->src, s + i + 1, (size_t)sl)) {
            if (build_huff(t, s + i + 1, s + i + 17, tc) < 0) return MJDEC_EBAD;
            memcpy(t->src, s + i + 1, (size_t)sl);
            t->srclen = sl;
          }
          i += 17 + cnt;
        }
        break;
      }
      case 0xDD:  // DRI
        if (n < 2) return MJDEC_EBAD;
        d->dri = be16(s);
        break;
      case 0xDA: {  // SOS
        if (!d->ncomp) return MJDEC_EBAD;
        int ns = s[0];
        if (ns != d->ncomp || n < 1 + 2u * ns + 3) return MJDEC_EUNSUP;  // one interleaved scan
        for (int i = 0; i < ns; i++) {
          int id = s[1 + 2 * i], k = -1;
          for (int q = 0; q < d->ncomp; q++)
            if (d->c[q].id == id) k = q;
          if (k < 0) return MJDEC_EBAD;
          d->scomp[i] = k;
          d->c[k].td = s[2 + 2 * i] >> 4;
          d->c[k].ta = s[2 + 2 * i] & 15;
          if (d->c[k].td > 3 || d->c[k].ta > 3 || !d->dc[d->c[k].td].valid || !d->ac[d->c[k].ta].valid ||
              !d->qvalid[d->c[k].tq])
            return MJDEC_EBAD;
        }
        if (d->scomp[0] != 0) return MJDEC_EUNSUP;  // luma first
        int ss = s[1 + 2 * ns], se = s[2 + 2 * ns], ahal = s[3 + 2 * ns];
        if (ss != 0 || se != 63 || ahal != 0) return MJDEC_EUNSUP;
        d->ns = ns;
        d->ncomp = ns;
        // fast path for empty chroma blocks
        d->chroma_zero_bits = 0;
        int z = 0, ok = ns > 1;
        for (int i = 1; i < ns && ok; i++) {
          const comp *c = &d->c[d->scomp[i]];
          int a = d->dc[c->td].zero_dc0, e = d->ac[c->ta].zero_eob;
          if (!a || !e) ok = 0;
          z += c->nblocks * (a + e);
        }
        if (ok && z <= 32) d->chroma_zero_bits = z;
        d->pos = p + 2 + len;
        return 1;
      }
      default:
        if (m < 0xC0 || m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0xD9) return MJDEC_EBAD;
        break;  // APPn, COM, ...: skipped
    }
    d->pos = p + 2 + len;
  }
}

int mjdec_begin(mjdec *d, const uint8_t *jpeg, size_t cap, uint8_t *out, int width, int height, int stride) {
  d->jpeg = jpeg;
  d->cap = cap;
  d->out = out;
  d->width = width;
  d->height = height;
  d->stride = stride;
  d->hdr_done = 0;
  d->pos = 0;
  d->ncomp = d->ns = 0;
  d->dri = 0;
  d->mcu = 0;
  d->next_rst = 0;
  d->rows_done = 0;
  d->end = 0;
  d->err = 0;
  d->scr_n = 0;
  memset(d->qvalid, 0, sizeof d->qvalid);
  if (d->scr_cap < 65536) {
    free(d->scr);
    d->scr_cap = 65536;
    d->scr = (uint8_t *)malloc(d->scr_cap + PAD);
    if (!d->scr) return MJDEC_EBAD;
  }
  return 0;
}

static int scr_append(mjdec *d, const uint8_t *s, size_t n) {
  if (d->scr_n + n > d->scr_cap) {
    size_t nc = d->scr_cap * 2;
    while (nc < d->scr_n + n) nc *= 2;
    uint8_t *q = (uint8_t *)realloc(d->scr, nc + PAD);
    if (!q) return -1;
    d->scr = q;
    d->scr_cap = nc;
  }
  memcpy(d->scr + d->scr_n, s, n);
  d->scr_n += n;
  return 0;
}

static int rows_for(const mjdec *d) {
  int r = (d->mcu / d->mcux) * d->mcuh;
  return r > d->height ? d->height : r;
}

int mjdec_feed(mjdec *d, size_t avail) {
  if (d->err) return d->err;
  if (avail > d->cap) avail = d->cap;
  if (!d->hdr_done) {
    int r = parse_header(d, avail);
    if (r < 0) return d->err = r;
    if (r == 0) return 0;
    d->hdr_done = 1;
  }
  const uint8_t *j = d->jpeg;
  while (d->pos < avail && d->mcu < d->mcus) {
    const uint8_t *ff = (const uint8_t *)memchr(j + d->pos, 0xFF, avail - d->pos);
    size_t q = ff ? (size_t)(ff - j) : avail;
    if (q > d->pos) {
      if (scr_append(d, j + d->pos, q - d->pos) < 0) return d->err = MJDEC_EBAD;
      d->pos = q;
    }
    if (!ff || q + 1 >= avail) break;  // need the byte after the FF
    uint8_t m = j[q + 1];
    if (m == 0x00) {
      static const uint8_t kFF = 0xFF;
      if (scr_append(d, &kFF, 1) < 0) return d->err = MJDEC_EBAD;
      d->pos = q + 2;
      continue;
    }
    if (m == 0xFF) {  // fill byte before a marker
      d->pos = q + 1;
      continue;
    }
    int end;
    if (m >= 0xD0 && m <= 0xD7) {
      if ((m & 7) != d->next_rst || !d->dri) return d->err = MJDEC_EBAD;
      d->next_rst = (d->next_rst + 1) & 7;
      end = d->mcu + d->dri;
      if (end > d->mcus) return d->err = MJDEC_EBAD;
    } else if (m == 0xD9) {
      end = d->mcus;
      d->end = q + 2;
    } else {
      return d->err = MJDEC_EBAD;
    }
    if (d->dri && m == 0xD9 && end - d->mcu > d->dri) return d->err = MJDEC_EBAD;
    int r = decode_interval(d, end);
    if (r < 0) return d->err = r;
    d->scr_n = 0;
    d->pos = q + 2;
  }
  d->rows_done = rows_for(d);
  return d->rows_done;
}

int mjdec_decode(mjdec *d, const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height, int stride) {
  int r = mjdec_begin(d, jpeg, size, out, width, height, stride);
  if (r < 0) return r;
  r = mjdec_feed(d, size);
  if (r < 0) return r;
  return r == height ? 0 : MJDEC_EBAD;
}
