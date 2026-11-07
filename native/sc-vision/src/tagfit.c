// sc-vision full-tag refinement. See tagfit.h and docs/FULL-TAG-REFINEMENT.md.
#include "tagfit.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__aarch64__) && defined(__ARM_NEON) && !defined(TAGFIT_NO_NEON)
#include <arm_neon.h>
#define TAGFIT_NEON 1
#endif

void tagfit_defaults(tagfit_params *p) {
  p->iters = 2;
  p->min_cell_px = 2.0;
  p->max_cell_px = 0;
  p->fit_bias = 1;
  p->samples_max = 3;
  p->sample_px = 99;  // one sample per interior edge segment
  p->pose = 0;
  p->outline_px = 3;
  p->bias_axes = 0;
  p->edges = 0;
  p->fit_kappa = 0;
  p->max_samples = 0;
  p->branch_amb = 0;
  p->seg_mode = 0;
  p->max_segments = 0;
  p->lobe_cells = 0;
  p->min_run = 0;
  p->min_run_below = 1e9;
  p->fast = 0;
  p->lut = NULL;
  p->warm_iters = 1;
}

// ------------------------------------------------------------------------------------------- lens LUT
// The lens model's radial factor (the rational polynomial in r^2 and its division) tabulated against r^2, linear
// between entries; the tangential terms stay exact (a few multiplies). A 2-D grid of offsets was tried first: its
// bilinear error near the sensor corners (8-coefficient model) was 0.16 / 0.04 / 0.01 px at 16 / 8 / 4 px nodes.
struct tagfit_lut {
  cam_model cam;
  double r2max, inv;  // table spans r^2 in [0, r2max]
  int n;
  float *rad;
  double max_err;
  double ifx, ify;
};

static double radial(const cam_model *c, double r2) {
  const double *k = c->k;
  return (1 + ((k[4] * r2 + k[1]) * r2 + k[0]) * r2) / (1 + ((k[7] * r2 + k[6]) * r2 + k[5]) * r2);
}

static void lut_build(tagfit_lut *L, int w, int h, int n) {
  const cam_model *c = &L->cam;
  // r^2 of the sensor's corners (normalised pinhole), plus 50%: tags partly off the sensor still map
  double r2 = 0;
  for (int k = 0; k < 4; k++) {
    double u, v;
    pose_undistort_px(c, k & 1 ? w - 1 : 0, k & 2 ? h - 1 : 0, &u, &v);
    double x = (u - c->cx) / c->fx, y = (v - c->cy) / c->fy;
    if (isfinite(x) && isfinite(y)) r2 = fmax(r2, x * x + y * y);
  }
  if (!(r2 > 0) || r2 > 4) r2 = 4;
  L->r2max = 1.5 * r2;
  L->n = n;
  L->inv = (n - 1) / L->r2max;
  free(L->rad);
  L->rad = (float *)malloc(sizeof(float) * (n + 1));
  for (int i = 0; i <= n; i++) L->rad[i] = (float)radial(c, i / L->inv);
  L->ifx = 1 / c->fx, L->ify = 1 / c->fy;
}

// pinhole -> image through the table; 0 beyond it
static inline int lut_map(const tagfit_lut *L, double u, double v, double *xo, double *yo) {
  const cam_model *c = &L->cam;
  double x = (u - c->cx) * L->ifx, y = (v - c->cy) * L->ify, r2 = x * x + y * y, g = r2 * L->inv;
  if (!(g < L->n - 1)) return 0;
  int i = (int)g;
  double f = g - i, rad = L->rad[i] + f * (L->rad[i + 1] - L->rad[i]);
  double xd = x * rad + 2 * c->k[2] * x * y + c->k[3] * (r2 + 2 * x * x);
  double yd = y * rad + c->k[2] * (r2 + 2 * y * y) + 2 * c->k[3] * x * y;
  *xo = c->fx * xd + c->cx, *yo = c->fy * yd + c->cy;
  return 1;
}

static inline int lut_mapf(const tagfit_lut *L, float u, float v, float *xo, float *yo) {
  const cam_model *c = &L->cam;
  const float k2 = (float)c->k[2], k3 = (float)c->k[3];
  float x = (u - (float)c->cx) * (float)L->ifx, y = (v - (float)c->cy) * (float)L->ify, r2 = x * x + y * y;
  float g = r2 * (float)L->inv;
  if (!(g < L->n - 1)) return 0;
  int i = (int)g;
  float f = g - i, rad = L->rad[i] + f * (L->rad[i + 1] - L->rad[i]);
  float xd = x * rad + 2 * k2 * x * y + k3 * (r2 + 2 * x * x);
  float yd = y * rad + k2 * (r2 + 2 * y * y) + 2 * k3 * x * y;
  *xo = (float)c->fx * xd + (float)c->cx, *yo = (float)c->fy * yd + (float)c->cy;
  return 1;
}

// worst error (px) over the sensor, every 2 px, against pose_distort_px (float path)
static double lut_check(const tagfit_lut *L, int w, int h) {
  double worst = 0;
  for (int py = 0; py < h; py += 2)
    for (int px = 0; px < w; px += 2) {
      double u, v, x, y;
      pose_undistort_px(&L->cam, px, py, &u, &v);
      if (!isfinite(u) || !isfinite(v)) continue;
      pose_distort_px(&L->cam, u, v, &x, &y);
      if (fabs(x - px) > 0.01 || fabs(y - py) > 0.01) continue;  // undistortion did not converge here
      float xf, yf;
      if (!lut_mapf(L, (float)u, (float)v, &xf, &yf)) continue;
      worst = fmax(worst, hypot(xf - x, yf - y));
    }
  return worst;
}

tagfit_lut *tagfit_lut_create(const cam_model *cam, int w, int h, double entries) {
  tagfit_lut *L = (tagfit_lut *)calloc(1, sizeof *L);
  L->cam = *cam;
  lut_build(L, w, h, entries > 0 ? (int)entries : 1024);
  L->max_err = lut_check(L, w, h);
  if (getenv("TAGFIT_DEBUG"))
    fprintf(stderr, "lut n %d r2max %g rad0 %g radn %g k0 %g\n", L->n, L->r2max, L->rad[0], L->rad[L->n - 1], L->cam.k[0]);
  return L;
}

void tagfit_lut_destroy(tagfit_lut *L) {
  if (!L) return;
  free(L->rad);
  free(L);
}

double tagfit_lut_max_err(const tagfit_lut *L) { return L ? L->max_err : NAN; }

// Solve A x = b, n x n (n <= 9), partial pivoting, in place. 0 or -1.
static int solve_n(double *A, double *b, int n) {
  for (int c = 0; c < n; c++) {
    int pv = c;
    for (int r = c + 1; r < n; r++)
      if (fabs(A[r * n + c]) > fabs(A[pv * n + c])) pv = r;
    if (fabs(A[pv * n + c]) < 1e-14) return -1;
    if (pv != c) {
      for (int k = 0; k < n; k++) {
        double t = A[c * n + k];
        A[c * n + k] = A[pv * n + k], A[pv * n + k] = t;
      }
      double t = b[c];
      b[c] = b[pv], b[pv] = t;
    }
    for (int r = c + 1; r < n; r++) {
      double f = A[r * n + c] / A[c * n + c];
      if (f == 0) continue;
      for (int k = c; k < n; k++) A[r * n + k] -= f * A[c * n + k];
      b[r] -= f * b[c];
    }
  }
  for (int r = n - 1; r >= 0; r--) {
    double s = b[r];
    for (int k = r + 1; k < n; k++) s -= A[r * n + k] * b[k];
    b[r] = s / A[r * n + r];
  }
  return 0;
}

// Homography (h8 = 1) taking the model square (-0.5, -0.5) (0.5, -0.5) (0.5, 0.5) (-0.5, 0.5) to q[0..3].
static int square_h(const double q[8], double H[9]) {
  static const double m[4][2] = {{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}};
  double A[64], b[8];
  for (int i = 0; i < 4; i++) {
    double X = m[i][0], Y = m[i][1], u = q[2 * i], v = q[2 * i + 1];
    double *r = A + 16 * i, *s = r + 8;
    r[0] = X, r[1] = Y, r[2] = 1, r[3] = 0, r[4] = 0, r[5] = 0, r[6] = -u * X, r[7] = -u * Y;
    s[0] = 0, s[1] = 0, s[2] = 0, s[3] = X, s[4] = Y, s[5] = 1, s[6] = -v * X, s[7] = -v * Y;
    b[2 * i] = u, b[2 * i + 1] = v;
  }
  if (solve_n(A, b, 8)) return -1;
  memcpy(H, b, sizeof b);
  H[8] = 1;
  return 0;
}

static inline void hproj(const double H[9], double a, double b, double *x, double *y) {
  double z = H[6] * a + H[7] * b + 1;
  *x = (H[0] * a + H[1] * b + H[2]) / z;
  *y = (H[3] * a + H[4] * b + H[5]) / z;
}

typedef struct {
  const uint8_t *p;
  int w, h, stride;
} view;

static inline int bilin(const view *im, double x, double y, double *out) {
  if (!(x >= 0 && y >= 0 && x < im->w - 1 && y < im->h - 1)) return 0;
  int ix = (int)x, iy = (int)y;
  double fx = x - ix, fy = y - iy;
  const uint8_t *r = im->p + (size_t)iy * im->stride + ix;
  double a = r[0] + fx * (r[1] - r[0]);
  double b = r[im->stride] + fx * (r[im->stride + 1] - r[im->stride]);
  *out = a + fy * (b - a);
  return 1;
}

// Working image: pinhole pixels relative to o (the input corners' centre); to_img maps one to a raw pixel.
typedef struct {
  const cam_model *cam;
  double ox, oy;
  const tagfit_lut *lut;
} frame;

static inline void to_img(const frame *f, double qx, double qy, double *x, double *y) {
  if (f->cam) {
    if (f->lut && lut_map(f->lut, qx + f->ox, qy + f->oy, x, y)) return;
    pose_distort_px(f->cam, qx + f->ox, qy + f->oy, x, y);
  } else {
    *x = qx + f->ox, *y = qy + f->oy;
  }
}

enum { MAXK = 41 };

// Sub-pixel position (along n, px from x0) of the rising (dark to light) edge nearest the expected place: the
// centroid of the directional-gradient lobe with the highest peak within +-R. Returns 0 if none above floor.
static int edge_offset(const view *im, double x0, double y0, double nx, double ny, double R, double ap,
                       double floor, double maxw, double *s_out) {
  const double st = 0.25;
  const int na = (int)lround(ap / st);
  const int K = (int)(R / st);
  const int N = 2 * (K + na) + 1;
  if (N > MAXK + 2 * 8) return 0;
  double prof[MAXK + 16], g[MAXK];
  for (int i = 0; i < N; i++) {
    double s = (i - K - na) * st;
    if (!bilin(im, x0 + s * nx, y0 + s * ny, &prof[i])) return 0;
  }
  int nk = 2 * K + 1, bj = -1;
  double best = floor;
  for (int j = 0; j < nk; j++) {
    g[j] = prof[j + 2 * na] - prof[j];
    if (g[j] > best) best = g[j], bj = j;
  }
  if (bj < 0) return 0;
  int jl = bj, jr = bj;
  // the lobe, at most maxw px either side of its peak (a neighbouring edge's lobe must not leak in)
  const int mw = maxw > 0 ? (int)(maxw / st) : nk;
  while (jl > 0 && bj - jl < mw && g[jl - 1] > 0.2 * best && g[jl - 1] <= g[jl]) jl--;
  while (jr < nk - 1 && jr - bj < mw && g[jr + 1] > 0.2 * best && g[jr + 1] <= g[jr]) jr++;
  double sg = 0, sj = 0;
  for (int j = jl; j <= jr; j++) {
    double v = g[j] - 0.2 * best;
    sg += v, sj += v * j;
  }
  *s_out = (sj / sg - K) * st;
  return 1;
}

static inline int cell_white(const uint8_t *white, int W, int i, int j) {
  return white[(j + 1) * (W + 2) + (i + 1)];
}

// The tag's geometry: model square (a, b) in [-0.5, 0.5]^2 (b down, from the top-left corner) to pinhole pixels
// relative to the frame's origin. kind 0: a homography (8 parameters); kind 1: a rigid pose with the camera
// matrix (6 parameters: tag side 1, X = a, Y = -b, Z = 0, as pose_ippe_square's object points).
typedef struct {
  int kind;
  double H[9];
  double R[9], t[3], fx, fy, cx, cy, ox, oy;
} model;

static inline void mapq(const model *M, double a, double b, double *qx, double *qy) {
  if (M->kind == 0) {
    hproj(M->H, a, b, qx, qy);
    return;
  }
  const double *R = M->R;
  double P0 = R[0] * a - R[1] * b + M->t[0], P1 = R[3] * a - R[4] * b + M->t[1], P2 = R[6] * a - R[7] * b + M->t[2];
  *qx = M->fx * P0 / P2 + M->cx - M->ox;
  *qy = M->fy * P1 / P2 + M->cy - M->oy;
}

// d(n . q)/d(parameters) for (mx, my) = n^T D at model point (a, b), whose pinhole position is (qx, qy).
static inline void jrow(const model *M, double a, double b, double qx, double qy, double mx, double my, double *J) {
  if (M->kind == 0) {
    const double *H = M->H;
    double z = H[6] * a + H[7] * b + 1;
    J[0] = mx * a / z, J[1] = mx * b / z, J[2] = mx / z, J[3] = my * a / z, J[4] = my * b / z, J[5] = my / z;
    J[6] = -(mx * qx + my * qy) * a / z, J[7] = -(mx * qx + my * qy) * b / z;
    return;
  }
  const double *R = M->R;
  double V[3] = {R[0] * a - R[1] * b, R[3] * a - R[4] * b, R[6] * a - R[7] * b};  // R X
  double P[3] = {V[0] + M->t[0], V[1] + M->t[1], V[2] + M->t[2]}, iz = 1 / P[2];
  double g[3] = {mx * M->fx * iz, my * M->fy * iz, -(mx * M->fx * P[0] + my * M->fy * P[1]) * iz * iz};  // d/dP
  J[0] = V[1] * g[2] - V[2] * g[1], J[1] = V[2] * g[0] - V[0] * g[2], J[2] = V[0] * g[1] - V[1] * g[0];  // V x g
  J[3] = g[0], J[4] = g[1], J[5] = g[2];
}

static void step(model *M, const double *d) {
  if (M->kind == 0) {
    for (int m = 0; m < 8; m++) M->H[m] += d[m];
    return;
  }
  double th = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]), E[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  if (th > 1e-15) {
    double kx = d[0] / th, ky = d[1] / th, kz = d[2] / th, c = cos(th), s = sin(th), C = 1 - c;
    double e[9] = {c + kx * kx * C,      kx * ky * C - kz * s, kx * kz * C + ky * s,
                   ky * kx * C + kz * s, c + ky * ky * C,      ky * kz * C - kx * s,
                   kz * kx * C - ky * s, kz * ky * C + kx * s, c + kz * kz * C};
    memcpy(E, e, sizeof e);
  }
  double R[9];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      R[i * 3 + j] = E[i * 3] * M->R[j] + E[i * 3 + 1] * M->R[3 + j] + E[i * 3 + 2] * M->R[6 + j];
  memcpy(M->R, R, sizeof R);
  for (int k = 0; k < 3; k++) M->t[k] += d[3 + k];
}

static inline void corner_ab(int k, double *a, double *b) {
  *a = k == 1 || k == 2 ? 0.5 : -0.5;
  *b = k >= 2 ? 0.5 : -0.5;
}

// One unit cell edge between differently coloured cells: line index e on axis (0: u = e, 1: v = e), cell c along it.
typedef struct {
  uint8_t axis, e, c, w1, outline;
} seg;

// Everything one fit needs besides the model.
typedef struct {
  const seg *segs;
  int nseg;
  const view *im;
  const frame *fr;
  const cam_model *cam;
  const uint8_t *white;
  int W, ns, nso, nb2, nk_;
  double iW, R, ap, floor, cell;
  const tagfit_params *p;
  int iters;          // Gauss-Newton steps for this fit (p->iters, or p->warm_iters when warm)
  double bias0;       // starting bias (warm start)
} ctx;

typedef struct {
  double rms0, rms, biasv[2], kappa;
  int used, steps;
} fitstat;

// Gauss-Newton from M (updated in place). 1 if it converged within the guards, 0 if not.
static int fit(const ctx *C, model *M, fitstat *st) {
  const tagfit_params *p = C->p;
  const int W = C->W, nb2 = C->nb2, nk_ = C->nk_;
  const double iW = C->iW;
  const int nm = M->kind ? 6 : 8, np = nm + nb2 + nk_;
  double kappa = 0, biasv[2] = {C->bias0, C->bias0}, rms_first = NAN, rms_last = NAN;
  int used = 0, steps = 0;
  const int iters = C->iters;
  // passes 0 .. iters-1 measure and step; the last pass only measures (the residual after the fit).
  for (int it = 0; it <= iters; it++) {
    double A[121] = {0}, b[11] = {0}, ss = 0, sw2 = 0;
    double D[4] = {1, 0, 0, 1};  // d(image)/d(pinhole) at the tag's centre
    if (C->cam) {
      double cx, cy, x0c, y0c, xa, ya, xb, yb;
      mapq(M, 0, 0, &cx, &cy);
      to_img(C->fr, cx, cy, &x0c, &y0c);
      to_img(C->fr, cx + 1, cy, &xa, &ya);
      to_img(C->fr, cx, cy + 1, &xb, &yb);
      D[0] = xa - x0c, D[2] = ya - y0c, D[1] = xb - x0c, D[3] = yb - y0c;
    }
    used = 0;
    for (int si = 0; si < C->nseg; si++) {
          const int axis = C->segs[si].axis, e = C->segs[si].e, c = C->segs[si].c, w1 = C->segs[si].w1;
          const int outline = C->segs[si].outline;
          const int nk = outline ? C->nso : C->ns;
          // along the edge, clear of the junctions (the outline has none inside the tag's side)
          const double t0 = outline ? 0.1 : 0.2, tw = outline ? 0.8 : 0.6;
          for (int k = 0; k < nk; k++) {
            double t = c + t0 + tw * (k + 0.5) / nk;
            double a = (axis ? t : e) * iW - 0.5, bb = (axis ? e : t) * iW - 0.5;
            double da = axis ? 0.1 * iW : 0, db = axis ? 0 : 0.1 * iW;  // along the edge
            double qx, qy, x, y, qx2, qy2;
            mapq(M, a, bb, &qx, &qy);
            to_img(C->fr, qx, qy, &x, &y);  // exact position through the lens
            // directions through the lens's local Jacobian D (one per pass: it varies little across a tag)
            mapq(M, a + da, bb + db, &qx2, &qy2);
            double tx = D[0] * (qx2 - qx) + D[1] * (qy2 - qy), ty = D[2] * (qx2 - qx) + D[3] * (qy2 - qy);
            double tl = hypot(tx, ty);
            if (tl < 1e-12) continue;
            double nx = -ty / tl, ny = tx / tl;
            // orient n from black to white: toward the white cell's side
            double sgn = w1 ? 1 : -1;
            double wa = a + (axis ? 0 : sgn * 0.1 * iW), wb = bb + (axis ? sgn * 0.1 * iW : 0), qwx, qwy;
            mapq(M, wa, wb, &qwx, &qwy);
            double wx = D[0] * (qwx - qx) + D[1] * (qwy - qy), wy = D[2] * (qwx - qx) + D[3] * (qwy - qy);
            if (nx * wx + ny * wy < 0) nx = -nx, ny = -ny;
            double s;
            if (!edge_offset(C->im, x, y, nx, ny, C->R, C->ap, C->floor, p->lobe_cells * C->cell, &s)) continue;
            // kappa (diagnostic): the border's inner edge sits kappa cells further in than the model's
            double jk = 0;
            if (nk_ && (e == 1 || e == W - 1) && c > 0 && c < W - 1) {
              double dir = e == 1 ? iW : -iW, qkx, qky;
              mapq(M, a + (axis ? 0 : dir), bb + (axis ? dir : 0), &qkx, &qky);
              jk = nx * (D[0] * (qkx - qx) + D[1] * (qky - qy)) + ny * (D[2] * (qkx - qx) + D[3] * (qky - qy));
            }
            // model: s = J . d + jk kappa - bias (black shrinks: the edge moves toward black, i.e. -n)
            const int bx = p->bias_axes ? axis : 0;
            double res = s + biasv[bx] - jk * kappa;  // residual of the current model (d = 0)
            double wt = fabs(res) < 0.5 ? 1 : 0.5 / fabs(res);  // Huber
            ss += wt * res * res, sw2 += wt;
            used++;
            if (it == iters) continue;
            double J[11] = {0};
            jrow(M, a, bb, qx, qy, nx * D[0] + ny * D[2], nx * D[1] + ny * D[3], J);
            if (nb2) J[nm + bx] = -1;
            if (nk_) J[nm + nb2] = jk;
            for (int m = 0; m < np; m++) {
              for (int n2 = 0; n2 < np; n2++) A[m * np + n2] += wt * J[m] * J[n2];
              b[m] += wt * J[m] * s;
            }
          }
    }
    double rms = used ? sqrt(ss / sw2) : NAN;
    if (it == 0) rms_first = rms;
    rms_last = rms;
    if (it == iters) break;
    if (used < 24) return 0;
    for (int m = 0; m < np; m++) A[m * np + m] *= 1 + 1e-6;
    if (solve_n(A, b, np)) return 0;
    double before[8], moved = 0;
    for (int k = 0; k < 4; k++) {
      double a, bb;
      corner_ab(k, &a, &bb);
      mapq(M, a, bb, &before[2 * k], &before[2 * k + 1]);
    }
    step(M, b);
    steps++;
    for (int k = 0; k < 4; k++) {
      double a, bb, x, y;
      corner_ab(k, &a, &bb);
      mapq(M, a, bb, &x, &y);
      moved = fmax(moved, hypot(x - before[2 * k], y - before[2 * k + 1]));
    }
    if (moved < 0.005) it = iters - 1;  // converged: go straight to the measuring pass
    for (int k = 0; k < nb2; k++) biasv[k] = b[nm + k];
    if (nb2 == 1) biasv[1] = biasv[0];
    if (nk_) kappa = b[nm + nb2];
    if (!(fabs(biasv[0]) < 0.35 * C->cell && fabs(biasv[1]) < 0.35 * C->cell)) return 0;
  }
  st->rms0 = rms_first, st->rms = rms_last, st->used = used, st->kappa = kappa, st->steps = steps;
  st->biasv[0] = biasv[0], st->biasv[1] = biasv[1];
  return used >= 24 && rms_last <= rms_first * 1.05 + 0.02;
}

// ------------------------------------------------------------------------------------------- fast path
// The same measurement and model as fit() (homography only), in float32: positions through the LUT, the edge
// normal from the analytic derivative of the homography (fit() takes a 0.1-cell finite difference: the same
// direction to ~1e-3 rad), the profile and lobe in float, NEON for the profile's bilinear arithmetic and the
// gradient. The normal equations are accumulated (upper triangle) and solved in double.

static inline void to_imgf(const frame *f, float qx, float qy, float *x, float *y) {
  if (f->cam) {
    if (f->lut && lut_mapf(f->lut, qx + (float)f->ox, qy + (float)f->oy, x, y)) return;
    double xd, yd;
    pose_distort_px(f->cam, qx + f->ox, qy + f->oy, &xd, &yd);
    *x = (float)xd, *y = (float)yd;
  } else {
    *x = qx + (float)f->ox, *y = qy + (float)f->oy;
  }
}

static int edge_offset_f(const view *im, float x0, float y0, float nx, float ny, int K, int na, float floor_,
                         int mw, float *s_out) {
  const float st = 0.25f;
  const int N = 2 * (K + na) + 1;
  if (N > MAXK + 2 * 8) return 0;
  // the whole profile must be inside (then no per-point bounds checks)
  const float s0 = -(K + na) * st, s1 = (K + na) * st;
  const float xa = x0 + s0 * nx, ya = y0 + s0 * ny, xb = x0 + s1 * nx, yb = y0 + s1 * ny;
  if (!(xa >= 0 && ya >= 0 && xb >= 0 && yb >= 0 && xa < im->w - 1 && xb < im->w - 1 && ya < im->h - 1 &&
        yb < im->h - 1))
    return 0;
  float prof[MAXK + 20], g[MAXK + 4];
  const uint8_t *base = im->p;
  const int stride = im->stride;
  int i = 0;
#ifdef TAGFIT_NEON
  const float32x4_t vstep = {0, 1, 2, 3};
  for (; i + 4 <= N; i += 4) {
    float32x4_t s = vmulq_n_f32(vaddq_f32(vdupq_n_f32((float)(i - K - na)), vstep), st);
    float32x4_t x = vfmaq_n_f32(vdupq_n_f32(x0), s, nx), y = vfmaq_n_f32(vdupq_n_f32(y0), s, ny);
    int32x4_t ix = vcvtq_s32_f32(x), iy = vcvtq_s32_f32(y);  // truncation: x, y >= 0
    float32x4_t fx = vsubq_f32(x, vcvtq_f32_s32(ix)), fy = vsubq_f32(y, vcvtq_f32_s32(iy));
    int32x4_t off = vmlaq_n_s32(ix, iy, stride);
    int o[4];
    vst1q_s32(o, off);
    float p00[4], p01[4], p10[4], p11[4];
    for (int k = 0; k < 4; k++) {
      const uint8_t *r = base + o[k];
      p00[k] = r[0], p01[k] = r[1], p10[k] = r[stride], p11[k] = r[stride + 1];
    }
    float32x4_t a00 = vld1q_f32(p00), a01 = vld1q_f32(p01), a10 = vld1q_f32(p10), a11 = vld1q_f32(p11);
    float32x4_t a = vfmaq_f32(a00, fx, vsubq_f32(a01, a00)), b = vfmaq_f32(a10, fx, vsubq_f32(a11, a10));
    vst1q_f32(prof + i, vfmaq_f32(a, fy, vsubq_f32(b, a)));
  }
#endif
  for (; i < N; i++) {
    float s = (i - K - na) * st, x = x0 + s * nx, y = y0 + s * ny;
    int ix = (int)x, iy = (int)y;
    float fx = x - ix, fy = y - iy;
    const uint8_t *r = base + (size_t)iy * stride + ix;
    float a = r[0] + fx * (r[1] - r[0]), b = r[stride] + fx * (r[stride + 1] - r[stride]);
    prof[i] = a + fy * (b - a);
  }
  const int nk = 2 * K + 1;
  int j = 0;
#ifdef TAGFIT_NEON
  for (; j + 4 <= nk; j += 4) vst1q_f32(g + j, vsubq_f32(vld1q_f32(prof + j + 2 * na), vld1q_f32(prof + j)));
#endif
  for (; j < nk; j++) g[j] = prof[j + 2 * na] - prof[j];
  int bj = -1;
  float best = floor_;
  for (j = 0; j < nk; j++)
    if (g[j] > best) best = g[j], bj = j;
  if (bj < 0) return 0;
  int jl = bj, jr = bj;
  const float lo = 0.2f * best;
  while (jl > 0 && bj - jl < mw && g[jl - 1] > lo && g[jl - 1] <= g[jl]) jl--;
  while (jr < nk - 1 && jr - bj < mw && g[jr + 1] > lo && g[jr + 1] <= g[jr]) jr++;
  float sg = 0, sj = 0;
  for (j = jl; j <= jr; j++) {
    float v = g[j] - lo;
    sg += v, sj += v * j;
  }
  *s_out = (sj / sg - K) * st;
  return 1;
}

static int fit_f32(const ctx *C, model *M, fitstat *st) {
  const tagfit_params *p = C->p;
  const int nb2 = C->nb2, np = 8 + nb2, iters = C->iters;
  const float iW = (float)C->iW;
  const float st_ = 0.25f;
  const int na = (int)lround(C->ap / st_), K = (int)(C->R / st_);
  const int mw = p->lobe_cells > 0 ? (int)(p->lobe_cells * C->cell / st_) : 2 * K + 1;
  const float floor_ = (float)C->floor;
  double biasv[2] = {C->bias0, C->bias0}, rms_first = NAN, rms_last = NAN;
  int used = 0, steps = 0;
  for (int it = 0; it <= iters; it++) {
    double A[100] = {0}, b[10] = {0}, ss = 0, sw2 = 0;
    float D[4] = {1, 0, 0, 1};
    if (C->cam) {
      double cx, cy, x0c, y0c, xa, ya, xb, yb;
      mapq(M, 0, 0, &cx, &cy);
      to_img(C->fr, cx, cy, &x0c, &y0c);
      to_img(C->fr, cx + 1, cy, &xa, &ya);
      to_img(C->fr, cx, cy + 1, &xb, &yb);
      D[0] = (float)(xa - x0c), D[2] = (float)(ya - y0c), D[1] = (float)(xb - x0c), D[3] = (float)(yb - y0c);
    }
    float H[8];
    for (int k = 0; k < 8; k++) H[k] = (float)M->H[k];
    const float bv[2] = {(float)biasv[0], (float)biasv[1]};
    const int last = it == iters;
    used = 0;
    for (int si = 0; si < C->nseg; si++) {
      const seg sg = C->segs[si];
      const int axis = sg.axis, nk = sg.outline ? C->nso : C->ns;
      const float t0 = sg.outline ? 0.1f : 0.2f, tw = sg.outline ? 0.8f : 0.6f, sgn = sg.w1 ? 1.f : -1.f;
      const int bx = p->bias_axes ? axis : 0;
      for (int k = 0; k < nk; k++) {
        float t = sg.c + t0 + tw * (k + 0.5f) / nk;
        float a = (axis ? t : sg.e) * iW - 0.5f, bb = (axis ? sg.e : t) * iW - 0.5f;
        float iz = 1.f / (H[6] * a + H[7] * bb + 1.f);
        float qx = (H[0] * a + H[1] * bb + H[2]) * iz, qy = (H[3] * a + H[4] * bb + H[5]) * iz;
        // d q / d a and d q / d b (analytic), through the lens Jacobian
        float qax = (H[0] - qx * H[6]) * iz, qay = (H[3] - qy * H[6]) * iz;
        float qbx = (H[1] - qx * H[7]) * iz, qby = (H[4] - qy * H[7]) * iz;
        float ax = D[0] * qax + D[1] * qay, ay = D[2] * qax + D[3] * qay;
        float bxx = D[0] * qbx + D[1] * qby, byy = D[2] * qbx + D[3] * qby;
        float tx = axis ? ax : bxx, ty = axis ? ay : byy;  // along the edge
        float wx = axis ? bxx : ax, wy = axis ? byy : ay;  // across it, toward +model axis
        float tl2 = tx * tx + ty * ty;
        if (tl2 < 1e-20f) continue;
        float il = 1.f / sqrtf(tl2), nx = -ty * il, ny = tx * il;
        if ((nx * wx + ny * wy) * sgn < 0) nx = -nx, ny = -ny;  // black to white
        float x, y, s;
        to_imgf(C->fr, qx, qy, &x, &y);
        if (!edge_offset_f(C->im, x, y, nx, ny, K, na, floor_, mw, &s)) continue;
        float res = s + bv[bx];
        float wt = fabsf(res) < 0.5f ? 1.f : 0.5f / fabsf(res);
        ss += wt * res * res, sw2 += wt;
        used++;
        if (last) continue;
        float mx = nx * D[0] + ny * D[2], my = nx * D[1] + ny * D[3];
        float mq = -(mx * qx + my * qy);
        double J[10] = {mx * a * iz, mx * bb * iz, mx * iz, my * a * iz, my * bb * iz, my * iz, mq * a * iz,
                        mq * bb * iz, 0, 0};
        if (nb2) J[8 + bx] = -1;
        for (int m = 0; m < np; m++) {
          const double wj = wt * J[m];
          for (int n2 = m; n2 < np; n2++) A[m * np + n2] += wj * J[n2];
          b[m] += wj * s;
        }
      }
    }
    double rms = used ? sqrt(ss / sw2) : NAN;
    if (it == 0) rms_first = rms;
    rms_last = rms;
    if (last) break;
    if (used < 24) return 0;
    for (int m = 0; m < np; m++)
      for (int n2 = 0; n2 < m; n2++) A[m * np + n2] = A[n2 * np + m];
    for (int m = 0; m < np; m++) A[m * np + m] *= 1 + 1e-6;
    if (solve_n(A, b, np)) return 0;
    double before[8], moved = 0;
    for (int k = 0; k < 4; k++) {
      double a, bb;
      corner_ab(k, &a, &bb);
      mapq(M, a, bb, &before[2 * k], &before[2 * k + 1]);
    }
    step(M, b);
    steps++;
    for (int k = 0; k < 4; k++) {
      double a, bb, x, y;
      corner_ab(k, &a, &bb);
      mapq(M, a, bb, &x, &y);
      moved = fmax(moved, hypot(x - before[2 * k], y - before[2 * k + 1]));
    }
    if (moved < 0.005) it = iters - 1;
    for (int k = 0; k < nb2; k++) biasv[k] = b[8 + k];
    if (nb2 == 1) biasv[1] = biasv[0];
    if (!(fabs(biasv[0]) < 0.35 * C->cell && fabs(biasv[1]) < 0.35 * C->cell)) return 0;
  }
  st->rms0 = rms_first, st->rms = rms_last, st->used = used, st->kappa = 0, st->steps = steps;
  st->biasv[0] = biasv[0], st->biasv[1] = biasv[1];
  return used >= 24 && rms_last <= rms_first * 1.05 + 0.02;
}

static int refine(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                  const double corners[8], const tagfit_params *pp, const tagfit_warm *warm, tagfit_result *r) {
  tagfit_params p;
  if (pp) p = *pp;
  else tagfit_defaults(&p);
  memset(r, 0, sizeof *r);
  memcpy(r->corners, corners, sizeof r->corners);
  r->rms0 = r->rms = NAN;
  if (W < 3 || W > 16) return 0;
  double side = 0;
  for (int k = 0; k < 4; k++)
    side += hypot(corners[2 * ((k + 1) & 3)] - corners[2 * k], corners[2 * ((k + 1) & 3) + 1] - corners[2 * k + 1]);
  const double cell = side / 4 / W;
  r->cell_px = cell;
  if (cell < p.min_cell_px || (p.max_cell_px > 0 && cell > p.max_cell_px)) return 0;
  const view im = {img, w, h, stride};
  frame fr = {cam, 0, 0, cam ? p.lut : NULL};
  // warm start: this frame's corners plus the previous frame's correction (gates: same place and size)
  int use_warm = 0;
  double start[8];
  memcpy(start, corners, sizeof start);
  if (warm && warm->valid && !p.pose) {
    double cx = 0, cy = 0;
    for (int k = 0; k < 4; k++) cx += corners[2 * k] / 4, cy += corners[2 * k + 1] / 4;
    // (not below 2.5 px cells: there one warm step measured worse than two cold ones, synthetic --seq 10)
    if (cell >= 2.5 && hypot(cx - warm->cx, cy - warm->cy) < 2 * cell && fabs(warm->cell_px / cell - 1) < 0.15) {
      use_warm = 1;
      for (int k = 0; k < 8; k++) start[k] += warm->dc[k];
    }
  }
  double q[8], qn[8];  // start, and the input corners (the move guard is from the input), pinhole
  for (int k = 0; k < 4; k++) {
    if (cam) {
      pose_undistort_px(cam, start[2 * k], start[2 * k + 1], &q[2 * k], &q[2 * k + 1]);
      if (use_warm) pose_undistort_px(cam, corners[2 * k], corners[2 * k + 1], &qn[2 * k], &qn[2 * k + 1]);
    } else {
      q[2 * k] = start[2 * k], q[2 * k + 1] = start[2 * k + 1];
      qn[2 * k] = corners[2 * k], qn[2 * k + 1] = corners[2 * k + 1];
    }
    if (!use_warm) qn[2 * k] = q[2 * k], qn[2 * k + 1] = q[2 * k + 1];
    fr.ox += q[2 * k] / 4, fr.oy += q[2 * k + 1] / 4;
  }
  for (int k = 0; k < 4; k++) q[2 * k] -= fr.ox, q[2 * k + 1] -= fr.oy, qn[2 * k] -= fr.ox, qn[2 * k + 1] -= fr.oy;
  r->warm = use_warm;
  // Up to two starting models: the homography, or the pose from IPPE (and its other solution when ambiguous).
  model M[2];
  int nmod = 1;
  memset(M, 0, sizeof M);
  if (p.pose && cam) {
    tag_pose b, alt;
    if (pose_ippe_square(cam, corners, 1.0, &b, &alt)) return 0;
    for (int k = 0; k < 2; k++) {
      const tag_pose *s = k ? &alt : &b;
      M[k].kind = 1;
      memcpy(M[k].R, s->R, sizeof s->R);
      memcpy(M[k].t, s->t, sizeof s->t);
      M[k].fx = cam->fx, M[k].fy = cam->fy, M[k].cx = cam->cx, M[k].cy = cam->cy, M[k].ox = fr.ox, M[k].oy = fr.oy;
    }
    if (p.branch_amb > 0 && alt.err > 0 && b.err / alt.err > p.branch_amb && alt.t[2] > 0) nmod = 2;
  } else if (square_h(q, M[0].H)) {
    return 0;
  }
  const double iW = 1.0 / W;

  // Black and white levels from cell centres (border and payload): the gradient floor.
  double sb = 0, sw = 0;
  int nb = 0, nw = 0, n_in = 0;
  for (int j = 0; j < W; j++)
    for (int i = 0; i < W; i++) {
      double x, y, v, qx, qy;
      mapq(&M[0], (i + 0.5) * iW - 0.5, (j + 0.5) * iW - 0.5, &qx, &qy);
      to_img(&fr, qx, qy, &x, &y);
      if (!bilin(&im, x, y, &v)) return 0;
      if (cell_white(white, W, i, j)) sw += v, nw++;
      else sb += v, nb++;
      // interior transitions (to the right and below), for the sample budget
      if (i + 1 < W && cell_white(white, W, i, j) != cell_white(white, W, i + 1, j)) n_in++;
      if (j + 1 < W && cell_white(white, W, i, j) != cell_white(white, W, i, j + 1)) n_in++;
    }
  if (!nb || !nw) return 0;
  const double contrast = sw / nw - sb / nb;
  if (contrast < 10) return 0;
  // Segments, by priority: the outline always; then (seg_mode 2) the border's inner edges; then the rest by
  // distance from the centre plus the length of the same-coloured runs on both sides (less blur bias).
  seg segs[2 * 17 * 16];
  double pri[2 * 17 * 16];
  int nseg = 0;
  for (int axis = 0; axis < 2; axis++)
    for (int e = 0; e <= W; e++)
      for (int c = 0; c < W; c++) {
        int i0 = axis ? c : e - 1, j0 = axis ? e - 1 : c, i1 = axis ? c : e, j1 = axis ? e : c;
        int w0 = cell_white(white, W, i0, j0), w1 = cell_white(white, W, i1, j1);
        if (w0 == w1) continue;
        int outline = e == 0 || e == W, inner = !outline && (e == 1 || e == W - 1) && c > 0 && c < W - 1;
        if ((p.edges == 1 && !outline) || (p.edges == 2 && outline)) continue;
        if (p.seg_mode == 1 && !outline) continue;
        if (p.seg_mode == 2 && !outline && !inner) continue;
        // run lengths across the edge: cells of the same colour on each side, along the normal
        int run0 = 0, run1 = 0;
        for (int k = 0; k < 3; k++) {
          int a0 = axis ? c : e - 1 - k, b0 = axis ? e - 1 - k : c, a1 = axis ? c : e + k, b1 = axis ? e + k : c;
          if (run0 == k && a0 >= -1 && b0 >= -1 && cell_white(white, W, a0, b0) == w0) run0++;
          if (run1 == k && a1 <= W && b1 <= W && cell_white(white, W, a1, b1) == w1) run1++;
        }
        if (!outline && p.min_run > 0 && (run0 < run1 ? run0 : run1) < p.min_run && cell < p.min_run_below) continue;
        double dist = fabs(e - 0.5 * W) / (0.5 * W);  // 1 at the outline
        segs[nseg] = (seg){(uint8_t)axis, (uint8_t)e, (uint8_t)c, (uint8_t)w1, (uint8_t)outline};
        pri[nseg] = outline ? 1e9 : inner ? 1e6 + dist : dist + 0.25 * (run0 < run1 ? run0 : run1);
        nseg++;
      }
  if (p.max_segments > 0 && nseg > p.max_segments) {  // keep the top max_segments by priority
    for (int i = 1; i < nseg; i++)
      for (int j = i; j > 0 && pri[j] > pri[j - 1]; j--) {
        double tp = pri[j];
        pri[j] = pri[j - 1], pri[j - 1] = tp;
        seg ts = segs[j];
        segs[j] = segs[j - 1], segs[j - 1] = ts;
      }
    nseg = p.max_segments;
  }
  r->segments = nseg;
  ctx C = {segs, nseg, &im, &fr, cam, white, W, 0, 0, 0, 0, iW, 0, 0, 0.2 * contrast, cell, &p, 0, 0};
  C.R = fmin(1.5, fmax(0.75, 0.4 * cell));
  C.ap = fmin(0.5, fmax(0.25, 0.25 * cell));
  int ns = (int)(cell / (p.sample_px > 0.5 ? p.sample_px : 0.5));
  if (ns < 1) ns = 1;
  if (ns > p.samples_max) ns = p.samples_max;
  int nso = ns;  // samples per cell along the outline (denser: it carries the perspective)
  if (p.outline_px > 0) {
    nso = (int)(cell / p.outline_px);
    if (nso < ns) nso = ns;
    if (nso > 16) nso = 16;
  }
  // Sample budget: interior edges first down to one sample each, then the outline (never below one).
  if (p.max_samples > 0) {
    const int n_out = 4 * W;
    while (ns > 1 && n_in * ns + n_out * nso > p.max_samples) {
      if (nso > ns) nso--;
      else ns--, nso = nso > ns ? nso : ns;
    }
    while (nso > 1 && n_in * ns + n_out * nso > p.max_samples) nso--;
  }
  C.ns = ns, C.nso = nso;
  C.nb2 = p.fit_bias ? (p.bias_axes ? 2 : 1) : 0;
  C.nk_ = p.fit_kappa ? 1 : 0;
  C.iters = use_warm ? p.warm_iters : p.iters;
  C.bias0 = use_warm && C.nb2 ? warm->bias : 0;
  const int fast = p.fast && M[0].kind == 0 && !C.nk_;
  fitstat st[2];
  int ok[2] = {0, 0};
  for (int k = 0; k < nmod; k++) ok[k] = fast ? fit_f32(&C, &M[k], &st[k]) : fit(&C, &M[k], &st[k]);
  int best = 0;
  if (nmod == 2 && ok[1] && (!ok[0] || st[1].rms < st[0].rms)) best = 1;
  r->branches = nmod;
  r->branch = best;
  if (!ok[best]) return 0;
  double out[8];
  for (int k = 0; k < 4; k++) {
    double a, bb, qx, qy;
    corner_ab(k, &a, &bb);
    mapq(&M[best], a, bb, &qx, &qy);
    // bounded move (the other IPPE branch moves corners legitimately: allow it a cell)
    double lim = best ? fmin(6.0, 1.0 * cell) : fmin(3.0, 0.35 * cell);
    if (!(hypot(qx - qn[2 * k], qy - qn[2 * k + 1]) < lim)) return 0;
    to_img(&fr, qx, qy, &out[2 * k], &out[2 * k + 1]);
  }
  memcpy(r->corners, out, sizeof out);
  r->ok = 1;
  r->samples = st[best].used;
  r->rms0 = st[best].rms0;
  r->rms = st[best].rms;
  r->bias = 0.5 * (st[best].biasv[0] + st[best].biasv[1]);
  r->bias_v = st[best].biasv[0], r->bias_h = st[best].biasv[1];
  r->kappa = st[best].kappa;
  r->iters_run = st[best].steps;
  return 1;
}

int tagfit_refine(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                  const double corners[8], const tagfit_params *p, tagfit_result *r) {
  return refine(img, w, h, stride, white, W, cam, corners, p, NULL, r);
}

int tagfit_refine_warm(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                       const double corners[8], const tagfit_params *p, const tagfit_warm *warm, tagfit_warm *next,
                       tagfit_result *r) {
  int ok = refine(img, w, h, stride, white, W, cam, corners, p, warm, r);
  if (next) {
    memset(next, 0, sizeof *next);
    if (ok) {
      next->valid = 1;
      for (int k = 0; k < 8; k++) next->dc[k] = r->corners[k] - corners[k];
      for (int k = 0; k < 4; k++) next->cx += corners[2 * k] / 4, next->cy += corners[2 * k + 1] / 4;
      next->cell_px = r->cell_px;
      next->bias = r->bias;
    }
  }
  return ok;
}

// ------------------------------------------------------------------------------------------- live
enum { LIVE_IDS = 1024 };
struct tagfit_live {
  cam_model cam;
  tagfit_lut *lut;
  tagfit_params p;
  int warm_on;
  tagfit_warm warm[LIVE_IDS];
  long frame[LIVE_IDS];
  long tried, refined, nwarm;
  double us;
};

static double env_num(const char *k, double def) {
  const char *v = getenv(k);
  return v && *v ? atof(v) : def;
}

int tagfit_env_enabled(void) { return env_num("SPECTRUM_TAGFIT", 1) != 0; }

tagfit_live *tagfit_live_create(const cam_model *cam, int w, int h) {
  tagfit_live *t = (tagfit_live *)calloc(1, sizeof *t);
  if (!t) return NULL;
  t->cam = *cam;
  tagfit_defaults(&t->p);
  t->p.iters = (int)env_num("SPECTRUM_TAGFIT_ITERS", 2);
  t->p.max_cell_px = env_num("SPECTRUM_TAGFIT_MAX_CELL", 0);
  t->warm_on = env_num("SPECTRUM_TAGFIT_WARM", 1) != 0;
  t->p.warm_iters = (int)env_num("SPECTRUM_TAGFIT_WARM_ITERS", 1);
  if (env_num("SPECTRUM_TAGFIT_FAST", 1) != 0) {
    t->p.fast = 1;
    t->lut = tagfit_lut_create(&t->cam, w, h, 0);
    t->p.lut = t->lut;
  }
  return t;
}

void tagfit_live_destroy(tagfit_live *t) {
  if (!t) return;
  tagfit_lut_destroy(t->lut);
  free(t);
}

int tagfit_live_refine(tagfit_live *t, const uint8_t *img, int w, int h, int stride, int id, const uint8_t *white,
                       int W, double corners[8], long frame) {
  struct timespec a, b;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &a);
  const int slot = id >= 0 && id < LIVE_IDS ? id : -1;
  // warm only from the frame just before (or the one before that: a dropped frame)
  const tagfit_warm *wm = t->warm_on && slot >= 0 && t->warm[slot].valid && frame - t->frame[slot] >= 1 &&
                                  frame - t->frame[slot] <= 2
                              ? &t->warm[slot]
                              : NULL;
  tagfit_warm next;
  tagfit_result r;
  int ok = tagfit_refine_warm(img, w, h, stride, white, W, &t->cam, corners, &t->p, wm, &next, &r);
  if (slot >= 0) t->warm[slot] = next, t->frame[slot] = frame;
  if (ok) memcpy(corners, r.corners, sizeof r.corners);
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &b);
  t->tried++;
  t->refined += ok;
  t->nwarm += ok && r.warm;
  t->us += (b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3;
  return ok;
}

void tagfit_live_stats(const tagfit_live *t, long *tried, long *refined, long *warm, double *us) {
  *tried = t->tried, *refined = t->refined, *warm = t->nwarm, *us = t->us;
}
