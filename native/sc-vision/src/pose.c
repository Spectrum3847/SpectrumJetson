// sc-vision IPPE-square pose. See pose.h.
#include "pose.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void undistort(const cam_model *c, double u, double v, double *xo, double *yo) {
  double x0 = (u - c->cx) / c->fx, y0 = (v - c->cy) / c->fy, x = x0, y = y0;
  const double *k = c->k;
  for (int it = 0; it < 20; it++) {
    double r2 = x * x + y * y;
    double icdist = (1 + ((k[7] * r2 + k[6]) * r2 + k[5]) * r2) / (1 + ((k[4] * r2 + k[1]) * r2 + k[0]) * r2);
    if (icdist < 0) {  // as OpenCV: give up on a diverging point
      x = x0, y = y0;
      break;
    }
    double dx = 2 * k[2] * x * y + k[3] * (r2 + 2 * x * x);
    double dy = k[2] * (r2 + 2 * y * y) + 2 * k[3] * x * y;
    x = (x0 - dx) * icdist;
    y = (y0 - dy) * icdist;
  }
  *xo = x, *yo = y;
}

static void project(const cam_model *c, const double P[3], double *u, double *v) {
  double x = P[0] / P[2], y = P[1] / P[2], r2 = x * x + y * y;
  const double *k = c->k;
  double rad = (1 + ((k[4] * r2 + k[1]) * r2 + k[0]) * r2) / (1 + ((k[7] * r2 + k[6]) * r2 + k[5]) * r2);
  double xd = x * rad + 2 * k[2] * x * y + k[3] * (r2 + 2 * x * x);
  double yd = y * rad + k[2] * (r2 + 2 * y * y) + 2 * k[3] * x * y;
  *u = c->fx * xd + c->cx;
  *v = c->fy * yd + c->cy;
}

// Solve A x = b (n x n, in place), partial pivoting. 0 or -1.
static int solve(double *A, double *b, int n) {
  for (int c = 0; c < n; c++) {
    int p = c;
    for (int r = c + 1; r < n; r++)
      if (fabs(A[r * n + c]) > fabs(A[p * n + c])) p = r;
    if (fabs(A[p * n + c]) < 1e-15) return -1;
    if (p != c) {
      for (int k = 0; k < n; k++) {
        double t = A[c * n + k];
        A[c * n + k] = A[p * n + k];
        A[p * n + k] = t;
      }
      double t = b[c];
      b[c] = b[p];
      b[p] = t;
    }
    for (int r = c + 1; r < n; r++) {
      double f = A[r * n + c] / A[c * n + c];
      for (int k = c; k < n; k++) A[r * n + k] -= f * A[c * n + k];
      b[r] -= f * b[c];
    }
  }
  for (int c = n - 1; c >= 0; c--) {
    double s = b[c];
    for (int k = c + 1; k < n; k++) s -= A[c * n + k] * b[k];
    b[c] = s / A[c * n + c];
  }
  return 0;
}

// Translation minimizing the normalized-image error for rotation R (linear least squares, as OpenCV's IPPE).
static int translation(const double R[9], const double obj[4][2], const double img[4][2], double t[3]) {
  double A[9] = {0}, b[3] = {0};
  for (int i = 0; i < 4; i++) {
    double X = obj[i][0], Y = obj[i][1], u = img[i][0], v = img[i][1];
    double Px = R[0] * X + R[1] * Y, Py = R[3] * X + R[4] * Y, Pz = R[6] * X + R[7] * Y;
    // rows: [1 0 -u] t = u Pz - Px ; [0 1 -v] t = v Pz - Py
    double r1[3] = {1, 0, -u}, r2[3] = {0, 1, -v}, b1 = u * Pz - Px, b2 = v * Pz - Py;
    for (int a = 0; a < 3; a++) {
      for (int c = 0; c < 3; c++) A[a * 3 + c] += r1[a] * r1[c] + r2[a] * r2[c];
      b[a] += r1[a] * b1 + r2[a] * b2;
    }
  }
  if (solve(A, b, 3)) return -1;
  t[0] = b[0], t[1] = b[1], t[2] = b[2];
  return 0;
}

static double reproj_err(const cam_model *c, const double R[9], const double t[3], const double obj[4][2],
                         const double px[8]) {
  double s = 0;
  for (int i = 0; i < 4; i++) {
    double P[3];
    for (int r = 0; r < 3; r++) P[r] = R[r * 3] * obj[i][0] + R[r * 3 + 1] * obj[i][1] + t[r];
    if (P[2] <= 0) return 1e9;
    double u, v;
    project(c, P, &u, &v);
    s += (u - px[2 * i]) * (u - px[2 * i]) + (v - px[2 * i + 1]) * (v - px[2 * i + 1]);
  }
  return sqrt(s / 4);
}

// R <- exp([w]x) R (Rodrigues)
static void rot_update(double R[9], const double w[3]) {
  double th = sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
  double E[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  if (th > 1e-15) {
    double k[3] = {w[0] / th, w[1] / th, w[2] / th}, c = cos(th), sn = sin(th), v = 1 - c;
    E[0] = c + k[0] * k[0] * v, E[1] = k[0] * k[1] * v - k[2] * sn, E[2] = k[0] * k[2] * v + k[1] * sn;
    E[3] = k[1] * k[0] * v + k[2] * sn, E[4] = c + k[1] * k[1] * v, E[5] = k[1] * k[2] * v - k[0] * sn;
    E[6] = k[2] * k[0] * v - k[1] * sn, E[7] = k[2] * k[1] * v + k[0] * sn, E[8] = c + k[2] * k[2] * v;
  }
  double N[9];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) N[i * 3 + j] = E[i * 3] * R[j] + E[i * 3 + 1] * R[3 + j] + E[i * 3 + 2] * R[6 + j];
  memcpy(R, N, sizeof N);
}

static void residuals(const cam_model *c, const double R[9], const double t[3], const double obj[4][2],
                      const double px[8], double r[8]) {
  for (int i = 0; i < 4; i++) {
    double P[3];
    for (int k = 0; k < 3; k++) P[k] = R[k * 3] * obj[i][0] + R[k * 3 + 1] * obj[i][1] + t[k];
    double u, v;
    project(c, P, &u, &v);
    r[2 * i] = u - px[2 * i], r[2 * i + 1] = v - px[2 * i + 1];
  }
}

// Gauss-Newton on the pixel reprojection error (with distortion): the maximum-likelihood pose for Gaussian
// corner noise. IPPE's analytic pose is the start; 4 iterations, numeric Jacobian (6 parameters, 8 residuals).
static void refine(const cam_model *c, const double obj[4][2], const double px[8], tag_pose *p) {
  for (int it = 0; it < 4; it++) {
    double r0[8], J[8][6];
    residuals(c, p->R, p->t, obj, px, r0);
    for (int k = 0; k < 6; k++) {
      double R[9], t[3], d[3] = {0, 0, 0}, r[8];
      memcpy(R, p->R, sizeof R), memcpy(t, p->t, sizeof t);
      const double h = k < 3 ? 1e-6 : 1e-6 * (fabs(p->t[2]) + 1e-3);
      if (k < 3) d[k] = h, rot_update(R, d);
      else t[k - 3] += h;
      residuals(c, R, t, obj, px, r);
      for (int i = 0; i < 8; i++) J[i][k] = (r[i] - r0[i]) / h;
    }
    double A[36] = {0}, g[6] = {0};
    for (int i = 0; i < 8; i++)
      for (int a = 0; a < 6; a++) {
        g[a] -= J[i][a] * r0[i];
        for (int b = 0; b < 6; b++) A[a * 6 + b] += J[i][a] * J[i][b];
      }
    for (int a = 0; a < 6; a++) A[a * 6 + a] *= 1 + 1e-9;
    if (solve(A, g, 6)) return;
    rot_update(p->R, g);
    p->t[0] += g[3], p->t[1] += g[4], p->t[2] += g[5];
    if (fabs(g[0]) + fabs(g[1]) + fabs(g[2]) < 1e-10) break;
  }
}

int pose_refine = 1;  // Gauss-Newton after IPPE (sc-vision --no-refine turns it off)

int pose_ippe_square(const cam_model *cam, const double corners[8], double size_m, tag_pose *best,
                     tag_pose *alt) {
  const double h = size_m / 2;
  const double obj[4][2] = {{-h, h}, {h, h}, {h, -h}, {-h, -h}};
  double img[4][2];
  for (int i = 0; i < 4; i++) undistort(cam, corners[2 * i], corners[2 * i + 1], &img[i][0], &img[i][1]);
  // Homography plane -> normalized image (h22 = 1), 8x8 DLT.
  double A[64], b[8];
  for (int i = 0; i < 4; i++) {
    double X = obj[i][0], Y = obj[i][1], u = img[i][0], v = img[i][1];
    double *r = A + (2 * i) * 8, *q = A + (2 * i + 1) * 8;
    r[0] = X, r[1] = Y, r[2] = 1, r[3] = 0, r[4] = 0, r[5] = 0, r[6] = -u * X, r[7] = -u * Y;
    q[0] = 0, q[1] = 0, q[2] = 0, q[3] = X, q[4] = Y, q[5] = 1, q[6] = -v * X, q[7] = -v * Y;
    b[2 * i] = u, b[2 * i + 1] = v;
  }
  if (solve(A, b, 8)) return -1;
  const double H[9] = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 1.0};
  // Jacobian of the homography at the plane origin; v = image of the origin.
  double p = H[2], q = H[5];
  double j00 = H[0] - H[6] * p, j01 = H[1] - H[7] * p, j10 = H[3] - H[6] * q, j11 = H[4] - H[7] * q;
  // Rv: rotates (p, q, 1) onto the z axis.
  double ax = p, ay = q, az = 1, n = sqrt(ax * ax + ay * ay + az * az);
  ax /= n, ay /= n, az /= n;
  double Rv[9];
  double s = sqrt(ax * ax + ay * ay), c = az;
  if (s < 1e-12) {
    const double I[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    memcpy(Rv, I, sizeof I);
  } else {
    double kx = ay / s, ky = -ax / s, cc = 1 - c;
    Rv[0] = c + kx * kx * cc, Rv[1] = kx * ky * cc, Rv[2] = ky * s;
    Rv[3] = kx * ky * cc, Rv[4] = c + ky * ky * cc, Rv[5] = -kx * s;
    Rv[6] = -ky * s, Rv[7] = kx * s, Rv[8] = c;
  }
  // J = (1/tz) [I2 | -v] R(:, 0:2). With R(:, 0:2) = Rv^T M: [I2 | -v] Rv^T = [B | 0] (Rv^T z is along (p, q, 1)),
  // so M's top 2x2 = tz B^-1 J. B: the first two columns of [I2 | -v] Rv^T.
  double b00 = Rv[0] - p * Rv[2], b01 = Rv[3] - p * Rv[5], b10 = Rv[1] - q * Rv[2], b11 = Rv[4] - q * Rv[5];
  double det = b00 * b11 - b01 * b10;
  if (fabs(det) < 1e-15) return -1;
  double i00 = b11 / det, i01 = -b01 / det, i10 = -b10 / det, i11 = b00 / det;
  double a00 = i00 * j00 + i01 * j10, a01 = i00 * j01 + i01 * j11, a10 = i10 * j00 + i11 * j10,
         a11 = i10 * j01 + i11 * j11;
  double ata00 = a00 * a00 + a01 * a01, ata01 = a00 * a10 + a01 * a11, ata11 = a10 * a10 + a11 * a11;
  double gamma = sqrt(0.5 * (ata00 + ata11 + sqrt((ata00 - ata11) * (ata00 - ata11) + 4 * ata01 * ata01)));
  if (gamma < 1e-15) return -1;
  double r00 = a00 / gamma, r01 = a01 / gamma, r10 = a10 / gamma, r11 = a11 / gamma;
  double bb0 = 1 - r00 * r00 - r10 * r10, bb1 = 1 - r01 * r01 - r11 * r11;
  double c0 = sqrt(bb0 > 0 ? bb0 : 0), c1 = sqrt(bb1 > 0 ? bb1 : 0);
  if (-r00 * r01 - r10 * r11 < 0) c1 = -c1;
  tag_pose sol[2];
  for (int k = 0; k < 2; k++) {
    double sg = k ? -1 : 1, e0 = sg * c0, e1 = sg * c1;
    // Rtilde: columns (r00 r10 e0), (r01 r11 e1), and their cross product
    double Rt[9] = {r00, r01, r10 * e1 - e0 * r11, r10, r11, e0 * r01 - r00 * e1, e0, e1, r00 * r11 - r10 * r01};
    // R = Rv^T * Rt   (Rv^T maps z back to the viewing direction of the plane origin)
    double *R = sol[k].R;
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++) R[i * 3 + j] = Rv[0 * 3 + i] * Rt[0 * 3 + j] + Rv[1 * 3 + i] * Rt[1 * 3 + j] +
                                                 Rv[2 * 3 + i] * Rt[2 * 3 + j];
    if (translation(R, obj, img, sol[k].t)) return -1;
    sol[k].err = reproj_err(cam, R, sol[k].t, obj, corners);
  }
  // The two IPPE solutions and their errors decide best vs alt and the ambiguity (as PhotonVision's
  // best/alt). Only the best is refined: refining the alt from its own start can slide it into the best's
  // minimum, which made best_err/alt_err ~1 and every single-tag frame look ambiguous (tester entry 11).
  int bi = sol[0].err <= sol[1].err ? 0 : 1;
  *best = sol[bi];
  if (alt) *alt = sol[1 - bi];
  if (pose_refine) {
    refine(cam, obj, corners, best);
    double e = reproj_err(cam, best->R, best->t, obj, corners);
    if (e <= best->err) best->err = e;
    else *best = sol[bi];  // (never seen) refinement made it worse: keep IPPE's
  }
  return 0;
}

// --------------------------------------------------------------------------------------- calibration JSON

static int read_array(const char *js, const char *key, double *out, int n) {
  const char *p = strstr(js, key);
  if (!p) return -1;
  p = strstr(p, "\"data\"");
  if (!p) return -1;
  p = strchr(p, '[');
  if (!p) return -1;
  p++;
  for (int i = 0; i < n; i++) {
    char *e;
    out[i] = strtod(p, &e);
    if (e == p) return i ? i : -1;
    p = e;
    while (*p == ',' || *p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++;
    if (*p == ']') return i + 1;
  }
  return n;
}

static double reproj_px(const cam_model *c, const tag_pose *p, const double und[8], double size_m) {
  static const double obj[4][2] = {{-1, 1}, {1, 1}, {1, -1}, {-1, -1}};
  if (!p) return NAN;
  double sum = 0;
  for (int i = 0; i < 4; i++) {
    const double X = obj[i][0] * size_m / 2, Y = obj[i][1] * size_m / 2;
    double P[3];
    for (int r = 0; r < 3; r++) P[r] = p->R[3 * r] * X + p->R[3 * r + 1] * Y + p->t[r];
    if (P[2] <= 1e-6) return NAN;
    const double du = c->fx * P[0] / P[2] + c->cx - und[2 * i], dv = c->fy * P[1] / P[2] + c->cy - und[2 * i + 1];
    sum += du * du + dv * dv;
  }
  return sqrt(sum / 4);
}

void pose_tag_quality(const cam_model *cam, const double corners[8], double size_m, const tag_pose *best,
                      const tag_pose *alt, double out[3]) {
  double und[8], moved = 0;
  for (int i = 0; i < 4; i++) {
    double x, y;
    undistort(cam, corners[2 * i], corners[2 * i + 1], &x, &y);
    und[2 * i] = cam->fx * x + cam->cx, und[2 * i + 1] = cam->fy * y + cam->cy;
    const double d = hypot(und[2 * i] - corners[2 * i], und[2 * i + 1] - corners[2 * i + 1]);
    if (d > moved) moved = d;
  }
  out[0] = moved;
  out[1] = reproj_px(cam, best, und, size_m);
  out[2] = reproj_px(cam, alt, und, size_m);
}

int cam_model_load(const char *path, cam_model *cam) {
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *js = (char *)malloc((size_t)n + 1);
  size_t got = fread(js, 1, (size_t)n, f);
  fclose(f);
  js[got] = 0;
  double K[9], D[8] = {0};
  int ok = read_array(js, "\"cameraIntrinsics\"", K, 9) == 9;
  int nd = read_array(js, "\"distCoeffs\"", D, 8);
  free(js);
  if (!ok || nd < 4) return -1;
  memset(cam, 0, sizeof *cam);
  cam->fx = K[0], cam->cx = K[2], cam->fy = K[4], cam->cy = K[5];
  for (int i = 0; i < nd && i < 8; i++) cam->k[i] = D[i];
  return 0;
}

void pose_undistort_px(const cam_model *cam, double u, double v, double *uo, double *vo) {
  double x, y;
  undistort(cam, u, v, &x, &y);
  *uo = cam->fx * x + cam->cx, *vo = cam->fy * y + cam->cy;
}

void pose_distort_px(const cam_model *cam, double u, double v, double *uo, double *vo) {
  const double P[3] = {(u - cam->cx) / cam->fx, (v - cam->cy) / cam->fy, 1.0};
  project(cam, P, uo, vo);
}
