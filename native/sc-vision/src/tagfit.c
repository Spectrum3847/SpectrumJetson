// sc-vision full-tag refinement. See tagfit.h and docs/FULL-TAG-REFINEMENT.md.
#include "tagfit.h"

#include <math.h>
#include <string.h>

void tagfit_defaults(tagfit_params *p) {
  p->iters = 2;
  p->min_cell_px = 2.0;
  p->max_cell_px = 0;
  p->fit_bias = 1;
  p->samples_max = 3;
  p->sample_px = 3;
  p->pose = 0;
}

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
} frame;

static inline void to_img(const frame *f, double qx, double qy, double *x, double *y) {
  if (f->cam) pose_distort_px(f->cam, qx + f->ox, qy + f->oy, x, y);
  else *x = qx + f->ox, *y = qy + f->oy;
}

enum { MAXK = 41 };

// Sub-pixel position (along n, px from x0) of the rising (dark to light) edge nearest the expected place: the
// centroid of the directional-gradient lobe with the highest peak within +-R. Returns 0 if none above floor.
static int edge_offset(const view *im, double x0, double y0, double nx, double ny, double R, double ap,
                       double floor, double *s_out) {
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
  while (jl > 0 && g[jl - 1] > 0.2 * best && g[jl - 1] <= g[jl]) jl--;
  while (jr < nk - 1 && g[jr + 1] > 0.2 * best && g[jr + 1] <= g[jr]) jr++;
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

int tagfit_refine(const uint8_t *img, int w, int h, int stride, const uint8_t *white, int W, const cam_model *cam,
                  const double corners[8], const tagfit_params *pp, tagfit_result *r) {
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
  frame fr = {cam, 0, 0};
  double q[8];
  for (int k = 0; k < 4; k++) {
    if (cam) pose_undistort_px(cam, corners[2 * k], corners[2 * k + 1], &q[2 * k], &q[2 * k + 1]);
    else q[2 * k] = corners[2 * k], q[2 * k + 1] = corners[2 * k + 1];
    fr.ox += q[2 * k] / 4, fr.oy += q[2 * k + 1] / 4;
  }
  for (int k = 0; k < 4; k++) q[2 * k] -= fr.ox, q[2 * k + 1] -= fr.oy;
  model M;
  memset(&M, 0, sizeof M);
  if (p.pose && cam) {
    tag_pose b;
    if (pose_ippe_square(cam, corners, 1.0, &b, NULL)) return 0;
    M.kind = 1;
    memcpy(M.R, b.R, sizeof b.R);
    memcpy(M.t, b.t, sizeof b.t);
    M.fx = cam->fx, M.fy = cam->fy, M.cx = cam->cx, M.cy = cam->cy, M.ox = fr.ox, M.oy = fr.oy;
  } else if (square_h(q, M.H)) {
    return 0;
  }
  const double iW = 1.0 / W;

  // Black and white levels from cell centres (border and payload): the gradient floor.
  double sb = 0, sw = 0;
  int nb = 0, nw = 0;
  for (int j = 0; j < W; j++)
    for (int i = 0; i < W; i++) {
      double x, y, v, qx, qy;
      mapq(&M, (i + 0.5) * iW - 0.5, (j + 0.5) * iW - 0.5, &qx, &qy);
      to_img(&fr, qx, qy, &x, &y);
      if (!bilin(&im, x, y, &v)) return 0;
      if (cell_white(white, W, i, j)) sw += v, nw++;
      else sb += v, nb++;
    }
  if (!nb || !nw) return 0;
  const double contrast = sw / nw - sb / nb;
  if (contrast < 10) return 0;
  const double floor = 0.2 * contrast;
  const double R = fmin(1.5, fmax(0.75, 0.4 * cell)), ap = fmin(0.5, fmax(0.25, 0.25 * cell));
  int ns = (int)(cell / (p.sample_px > 0.5 ? p.sample_px : 0.5));
  if (ns < 1) ns = 1;
  if (ns > p.samples_max) ns = p.samples_max;
  const int nm = M.kind ? 6 : 8, np = nm + (p.fit_bias ? 1 : 0);
  double bias = 0, rms_first = NAN, rms_last = NAN;
  int used = 0;
  // passes 0 .. iters-1 measure and step; the last pass only measures (the residual after the fit).
  for (int it = 0; it <= p.iters; it++) {
    double A[81] = {0}, b[9] = {0}, ss = 0, sw2 = 0;
    double D[4] = {1, 0, 0, 1};  // d(image)/d(pinhole) at the tag's centre
    if (cam) {
      double cx, cy, x0c, y0c, xa, ya, xb, yb;
      mapq(&M, 0, 0, &cx, &cy);
      to_img(&fr, cx, cy, &x0c, &y0c);
      to_img(&fr, cx + 1, cy, &xa, &ya);
      to_img(&fr, cx, cy + 1, &xb, &yb);
      D[0] = xa - x0c, D[2] = ya - y0c, D[1] = xb - x0c, D[3] = yb - y0c;
    }
    used = 0;
    for (int axis = 0; axis < 2; axis++)  // 0: edges at u = e (vertical in the model), 1: at v = e
      for (int e = 0; e <= W; e++)        // edge line index
        for (int c = 0; c < W; c++) {     // cell along the edge
          int i0 = axis ? c : e - 1, j0 = axis ? e - 1 : c;  // cell before the edge
          int i1 = axis ? c : e, j1 = axis ? e : c;          // cell after
          int w0 = cell_white(white, W, i0, j0), w1 = cell_white(white, W, i1, j1);
          if (w0 == w1) continue;
          for (int k = 0; k < ns; k++) {
            double t = c + 0.2 + 0.6 * (k + 0.5) / ns;  // along the edge, clear of the junctions
            double a = (axis ? t : e) * iW - 0.5, bb = (axis ? e : t) * iW - 0.5;
            double da = axis ? 0.1 * iW : 0, db = axis ? 0 : 0.1 * iW;  // along the edge
            double qx, qy, x, y, qx2, qy2;
            mapq(&M, a, bb, &qx, &qy);
            to_img(&fr, qx, qy, &x, &y);  // exact position through the lens
            // directions through the lens's local Jacobian D (one per pass: it varies little across a tag)
            mapq(&M, a + da, bb + db, &qx2, &qy2);
            double tx = D[0] * (qx2 - qx) + D[1] * (qy2 - qy), ty = D[2] * (qx2 - qx) + D[3] * (qy2 - qy);
            double tl = hypot(tx, ty);
            if (tl < 1e-12) continue;
            double nx = -ty / tl, ny = tx / tl;
            // orient n from black to white: toward the white cell's side
            double sgn = w1 ? 1 : -1;
            double wa = a + (axis ? 0 : sgn * 0.1 * iW), wb = bb + (axis ? sgn * 0.1 * iW : 0), qwx, qwy;
            mapq(&M, wa, wb, &qwx, &qwy);
            double wx = D[0] * (qwx - qx) + D[1] * (qwy - qy), wy = D[2] * (qwx - qx) + D[3] * (qwy - qy);
            if (nx * wx + ny * wy < 0) nx = -nx, ny = -ny;
            double s;
            if (!edge_offset(&im, x, y, nx, ny, R, ap, floor, &s)) continue;
            // model: s = J . d - bias (black shrinks: the edge moves toward black, i.e. -n)
            double res = s + bias;  // residual of the current model (d = 0)
            double wt = fabs(res) < 0.5 ? 1 : 0.5 / fabs(res);  // Huber
            ss += wt * res * res, sw2 += wt;
            used++;
            if (it == p.iters) continue;
            double J[9];
            jrow(&M, a, bb, qx, qy, nx * D[0] + ny * D[2], nx * D[1] + ny * D[3], J);
            J[nm] = -1;
            for (int m = 0; m < np; m++) {
              for (int n2 = 0; n2 < np; n2++) A[m * np + n2] += wt * J[m] * J[n2];
              b[m] += wt * J[m] * s;
            }
          }
        }
    double rms = used ? sqrt(ss / sw2) : NAN;
    if (it == 0) rms_first = rms;
    rms_last = rms;
    if (it == p.iters) break;
    if (used < 24) return 0;
    for (int m = 0; m < np; m++) A[m * np + m] *= 1 + 1e-6;
    if (solve_n(A, b, np)) return 0;
    double before[8], moved = 0;
    for (int k = 0; k < 4; k++) {
      double a, bb;
      corner_ab(k, &a, &bb);
      mapq(&M, a, bb, &before[2 * k], &before[2 * k + 1]);
    }
    step(&M, b);
    for (int k = 0; k < 4; k++) {
      double a, bb, x, y;
      corner_ab(k, &a, &bb);
      mapq(&M, a, bb, &x, &y);
      moved = fmax(moved, hypot(x - before[2 * k], y - before[2 * k + 1]));
    }
    if (moved < 0.005) it = p.iters - 1;  // converged: go straight to the measuring pass
    if (p.fit_bias) bias = b[nm];
    if (!(fabs(bias) < 0.35 * cell)) return 0;
  }
  if (used < 24 || !(rms_last <= rms_first * 1.05 + 0.02)) return 0;
  double out[8];
  for (int k = 0; k < 4; k++) {
    double a, bb, qx, qy;
    corner_ab(k, &a, &bb);
    mapq(&M, a, bb, &qx, &qy);
    if (!(hypot(qx - q[2 * k], qy - q[2 * k + 1]) < fmin(3.0, 0.35 * cell))) return 0;  // bounded move
    to_img(&fr, qx, qy, &out[2 * k], &out[2 * k + 1]);
  }
  memcpy(r->corners, out, sizeof out);
  r->ok = 1;
  r->samples = used;
  r->rms0 = rms_first;
  r->rms = rms_last;
  r->bias = bias;
  return 1;
}
