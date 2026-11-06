// tagfit_bench: full-tag refinement (src/tagfit.c) off vs on, offline. Two modes:
//
//   tagfit_bench synth CALIB.json [--n 2000] [--seed 1] [--noise 2.5] [--blur 0.8] [--jpeg 85] [--bloom 0]
//       Renders single tags (official 36h11 cells via NAPA's layout) at random poses through CALIB's lens with
//       blur, noise and a JPEG round trip, so the true corners and pose are known. Per cell-size bin: corner
//       RMS error, range and rotation error, IPPE ambiguity, reprojection error, fit success and time.
//   tagfit_bench replay FILE.mjpeg CALIB.json [--max N] [--min-tag 16]
//       A recorded session (Rewind .mjpeg): per tag ID, frame-to-frame jitter (std) of corners, range and
//       rotation, ambiguity and reprojection error, fit off vs on. Meant for static captures.
//
// Common: [--iters 2] [--no-bias] [--min-cell 2] [--max-cell 0] [--no-cam] (fit in raw pixels) [--pose] (6-DoF fit)
//         [--sample-px 3] [--samples-max 3]. Build: native/sc-vision/build.sh; run on the SystemCore.
#include <stdio.h>
#include <stdlib.h>
// (jpeglib.h needs size_t and FILE first)
#include <jpeglib.h>
#include <math.h>
#include <setjmp.h>
#include <string.h>
#include <time.h>

#include <algorithm>
#include <map>
#include <random>
#include <string>
#include <vector>

#include "napa_core.h"
#include "pose.h"
#include "tagfit.h"

static const double TAG = 0.1651;
static napa_family_layout L;

static double now_us() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

// (W + 2)^2 colours, 1 = white: quiet zone white, border black, payload from the code.
static void tag_cells(int id, std::vector<uint8_t> &c) {
  const int W = L.width, S = W + 2;
  c.assign(S * S, 1);
  for (int j = 0; j < W; j++)
    for (int i = 0; i < W; i++) c[(j + 1) * S + i + 1] = 0;
  uint64_t code = 0;
  napa_tag36h11_code(id, &code);
  for (int k = 0; k < L.nbits; k++) {
    int x = L.x[k], y = L.y[k];
    if (x < -1 || y < -1 || x > W || y > W) continue;
    c[(y + 1) * S + x + 1] = (code >> (L.nbits - 1 - k)) & 1;
  }
}

// ------------------------------------------------------------------------------------------- JPEG
struct JErr {
  jpeg_error_mgr m;
  jmp_buf j;
};
static void jerr_exit(j_common_ptr c) { longjmp(reinterpret_cast<JErr *>(c->err)->j, 1); }
static void jerr_msg(j_common_ptr, int) {}

static bool jpeg_gray(const uint8_t *j, size_t n, std::vector<uint8_t> &y, int &w, int &h) {
  jpeg_decompress_struct c;
  JErr e;
  c.err = jpeg_std_error(&e.m);
  e.m.error_exit = jerr_exit;
  e.m.emit_message = jerr_msg;
  if (setjmp(e.j)) {
    jpeg_destroy_decompress(&c);
    return false;
  }
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, j, n);
  if (jpeg_read_header(&c, TRUE) != JPEG_HEADER_OK) return jpeg_destroy_decompress(&c), false;
  c.out_color_space = JCS_GRAYSCALE;
  jpeg_start_decompress(&c);
  w = c.output_width, h = c.output_height;
  y.resize((size_t)w * h);
  while (c.output_scanline < c.output_height) {
    JSAMPROW r = y.data() + (size_t)c.output_scanline * w;
    jpeg_read_scanlines(&c, &r, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  return true;
}

static void jpeg_roundtrip(std::vector<uint8_t> &img, int w, int h, int q) {
  jpeg_compress_struct c;
  jpeg_error_mgr e;
  c.err = jpeg_std_error(&e);
  jpeg_create_compress(&c);
  unsigned char *buf = nullptr;
  unsigned long len = 0;
  jpeg_mem_dest(&c, &buf, &len);
  c.image_width = w, c.image_height = h, c.input_components = 1, c.in_color_space = JCS_GRAYSCALE;
  jpeg_set_defaults(&c);
  jpeg_set_quality(&c, q, TRUE);
  jpeg_start_compress(&c, TRUE);
  while (c.next_scanline < c.image_height) {
    JSAMPROW r = img.data() + (size_t)c.next_scanline * w;
    jpeg_write_scanlines(&c, &r, 1);
  }
  jpeg_finish_compress(&c);
  jpeg_destroy_compress(&c);
  int w2, h2;
  jpeg_gray(buf, len, img, w2, h2);
  free(buf);
}

// ------------------------------------------------------------------------------------------- math
static void matmul(const double A[9], const double B[9], double C[9]) {
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) C[i * 3 + j] = A[i * 3] * B[j] + A[i * 3 + 1] * B[3 + j] + A[i * 3 + 2] * B[6 + j];
}
static void rot(int axis, double a, double R[9]) {
  double c = cos(a), s = sin(a);
  double X[9] = {1, 0, 0, 0, c, -s, 0, s, c}, Y[9] = {c, 0, s, 0, 1, 0, -s, 0, c}, Z[9] = {c, -s, 0, s, c, 0, 0, 0, 1};
  memcpy(R, axis == 0 ? X : axis == 1 ? Y : Z, sizeof X);
}
// log map of A^T B (rotation vector, radians)
static void rel_rotvec(const double A[9], const double B[9], double w[3]) {
  double M[9];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) M[i * 3 + j] = A[i] * B[j] + A[3 + i] * B[3 + j] + A[6 + i] * B[6 + j];
  double c = std::clamp((M[0] + M[4] + M[8] - 1) / 2, -1.0, 1.0), th = acos(c);
  double k = th < 1e-9 ? 0.5 : th / (2 * sin(th));
  w[0] = k * (M[7] - M[5]), w[1] = k * (M[2] - M[6]), w[2] = k * (M[3] - M[1]);
}
static double rot_angle_deg(const double A[9], const double B[9]) {
  double w[3];
  rel_rotvec(A, B, w);
  return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) * 180 / M_PI;
}

static double median(std::vector<double> v) {
  if (v.empty()) return NAN;
  std::sort(v.begin(), v.end());
  size_t n = v.size();
  return n & 1 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}
static double pct(std::vector<double> v, double p) {
  if (v.empty()) return NAN;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, (size_t)(p * (v.size() - 1) + 0.5))];
}
[[maybe_unused]] static double rms(const std::vector<double> &v) {
  double s = 0;
  for (double x : v) s += x * x;
  return v.empty() ? NAN : sqrt(s / v.size());
}

// ------------------------------------------------------------------------------------------- options
struct Opt {
  tagfit_params fp;
  bool use_cam = true;
  int n = 2000, seed = 1, jpeg = 85, maxf = 1000000, min_tag = 16;
  double noise = 2.5, blur = 0.8, bloom = 0;
};

// Pose of one corner set: best/alt, ambiguity, reprojection error.
struct PoseOut {
  tag_pose b, a;
  bool ok;
  double amb;
};
static PoseOut pose_of(const cam_model &cam, const double c[8]) {
  PoseOut o{};
  o.ok = pose_ippe_square(&cam, c, TAG, &o.b, &o.a) == 0;
  o.amb = o.ok && o.a.err > 0 ? o.b.err / o.a.err : NAN;
  return o;
}

// ------------------------------------------------------------------------------------------- synth
static int synth(const cam_model &cam, const Opt &o) {
  const int w = 1280, h = 800, W = L.width;
  std::mt19937_64 rng(o.seed);
  std::uniform_real_distribution<double> U(0, 1);
  std::normal_distribution<double> N01(0, 1);
  napa_detector *det = napa_create();
  napa_params np{std::min(o.min_tag, 10), 1, 20, 22, 25};
  std::vector<uint8_t> img(w * h), cells;
  std::vector<double> tmp(w * h);
  struct Bin {
    std::vector<double> ce0, ce1, re0, re1, ro0, ro1, am0, am1, rp0, rp1, us, bias;
    int n = 0, ok = 0, flip0 = 0, flip1 = 0, worse = 0, better = 0;
  };
  const double edges[] = {0, 2.5, 4, 6, 9, 14, 1e9};
  const int NB = 6;
  Bin bins[NB];
  int rendered = 0, found = 0, rot_bad = 0;
  for (int f = 0; f < o.n; f++) {
    // pose: log-uniform range 0.6..8 m, anywhere in the image, turned up to 60 deg yaw, 25 pitch, 15 roll
    double range = exp(log(0.6) + U(rng) * (log(8.0) - log(0.6)));
    double px = 120 + U(rng) * (w - 240), py = 100 + U(rng) * (h - 200), ux, uy;
    pose_undistort_px(&cam, px, py, &ux, &uy);
    double d[3] = {(ux - cam.cx) / cam.fx, (uy - cam.cy) / cam.fy, 1}, dn = sqrt(d[0] * d[0] + d[1] * d[1] + 1);
    double t[3] = {d[0] / dn * range, d[1] / dn * range, d[2] / dn * range};
    double R0[9] = {1, 0, 0, 0, -1, 0, 0, 0, -1}, Ry[9], Rx[9], Rz[9], T1[9], T2[9], R[9];
    rot(1, (U(rng) * 2 - 1) * 60 * M_PI / 180, Ry);
    rot(0, (U(rng) * 2 - 1) * 25 * M_PI / 180, Rx);
    rot(2, (U(rng) * 2 - 1) * 15 * M_PI / 180, Rz);
    matmul(R0, Ry, T1);
    matmul(T1, Rx, T2);
    matmul(T2, Rz, R);
    int id = (int)(U(rng) * 32);
    tag_cells(id, cells);
    // true corners: object (-s/2, s/2) (s/2, s/2) (s/2, -s/2) (-s/2, -s/2), through the lens
    static const double ob[4][2] = {{-1, 1}, {1, 1}, {1, -1}, {-1, -1}};
    double tc[8], bx0 = 1e9, by0 = 1e9, bx1 = -1e9, by1 = -1e9;
    bool vis = true;
    for (int k = 0; k < 4; k++) {
      for (double m : {1.0, 1.6}) {  // corners and the quiet zone's extent
        double X = ob[k][0] * TAG / 2 * m, Y = ob[k][1] * TAG / 2 * m, P[3];
        for (int r = 0; r < 3; r++) P[r] = R[3 * r] * X + R[3 * r + 1] * Y + t[r];
        if (P[2] < 0.1) vis = false;
        double u, v;
        pose_distort_px(&cam, cam.fx * P[0] / P[2] + cam.cx, cam.fy * P[1] / P[2] + cam.cy, &u, &v);
        if (m == 1.0) tc[2 * k] = u, tc[2 * k + 1] = v;
        bx0 = std::min(bx0, u), by0 = std::min(by0, v), bx1 = std::max(bx1, u), by1 = std::max(by1, v);
      }
    }
    if (!vis || bx0 < 4 || by0 < 4 || bx1 > w - 5 || by1 > h - 5) continue;
    // render: background, then the tag region supersampled 4 x 4
    double black = 15 + U(rng) * 35, white = 150 + U(rng) * 80, bg = 60 + U(rng) * 80;
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) tmp[(size_t)y * w + x] = bg + 12 * sin(x * 0.05) * cos(y * 0.07);
    const double nrm[3] = {R[2], R[5], R[8]}, nt = nrm[0] * t[0] + nrm[1] * t[1] + nrm[2] * t[2];
    for (int y = (int)by0 - 2; y <= (int)by1 + 2; y++)
      for (int x = (int)bx0 - 2; x <= (int)bx1 + 2; x++) {
        double acc = 0;
        int inside = 0;
        for (int sy = 0; sy < 4; sy++)
          for (int sx = 0; sx < 4; sx++) {
            double u, v;
            pose_undistort_px(&cam, x - 0.375 + 0.25 * sx, y - 0.375 + 0.25 * sy, &u, &v);
            double r3[3] = {(u - cam.cx) / cam.fx, (v - cam.cy) / cam.fy, 1};
            double lam = nt / (nrm[0] * r3[0] + nrm[1] * r3[1] + nrm[2] * r3[2]);
            double P[3] = {lam * r3[0] - t[0], lam * r3[1] - t[1], lam * r3[2] - t[2]};
            double X = R[0] * P[0] + R[3] * P[1] + R[6] * P[2], Y = R[1] * P[0] + R[4] * P[1] + R[7] * P[2];
            double cu = (X / TAG + 0.5) * W, cv = (0.5 - Y / TAG) * W;
            int ci = (int)floor(cu), cj = (int)floor(cv);
            if (ci < -2 || cj < -2 || ci > W + 1 || cj > W + 1) {
              acc += tmp[(size_t)y * w + x];
              continue;
            }
            inside++;
            int wc = (ci < -1 || cj < -1 || ci > W || cj > W) ? 1 : cells[(cj + 1) * (W + 2) + ci + 1];
            acc += wc ? white : black;
          }
        if (inside) tmp[(size_t)y * w + x] = acc / 16;
      }
    // bloom: white spreads into black by blurring then clipping (brightens dark edges)
    if (o.blur > 0) {
      int r = (int)ceil(3 * o.blur);
      std::vector<double> k(2 * r + 1), t2(tmp.size());
      double ks = 0;
      for (int i = -r; i <= r; i++) ks += k[i + r] = exp(-0.5 * i * i / (o.blur * o.blur));
      for (double &v : k) v /= ks;
      int x0 = std::max(r, (int)bx0 - 8), x1 = std::min(w - r - 1, (int)bx1 + 8);
      int y0 = std::max(r, (int)by0 - 8), y1 = std::min(h - r - 1, (int)by1 + 8);
      t2 = tmp;
      for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
          double s = 0;
          for (int i = -r; i <= r; i++) s += k[i + r] * tmp[(size_t)y * w + x + i];
          t2[(size_t)y * w + x] = s;
        }
      for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
          double s = 0;
          for (int i = -r; i <= r; i++) s += k[i + r] * t2[(size_t)(y + i) * w + x];
          tmp[(size_t)y * w + x] = s;
        }
    }
    for (size_t i = 0; i < img.size(); i++) {
      double v = tmp[i] * (1 + o.bloom) + o.noise * N01(rng);
      img[i] = (uint8_t)std::clamp(lround(v), 0L, 255L);
    }
    if (o.jpeg > 0) jpeg_roundtrip(img, w, h, o.jpeg);
    rendered++;
    napa_detection dd[8];
    int nd = napa_detect(det, img.data(), w, h, w, &np, dd, 8);
    const napa_detection *hit = nullptr;
    for (int i = 0; i < nd; i++)
      if (dd[i].id == id) hit = &dd[i];
    if (!hit) continue;
    found++;
    double e0 = 0;
    for (int k = 0; k < 8; k++) e0 += (hit->corners[k] - tc[k]) * (hit->corners[k] - tc[k]);
    if (sqrt(e0 / 4) > 5) {  // corner order disagrees with the renderer (orientation check)
      rot_bad++;
      continue;
    }
    tagfit_result fr;
    double t0 = now_us();
    tagfit_refine(img.data(), w, h, w, cells.data(), W, o.use_cam ? &cam : nullptr, hit->corners, &o.fp, &fr);
    double us = now_us() - t0;
    PoseOut p0 = pose_of(cam, hit->corners), p1 = pose_of(cam, fr.corners);
    int b = 0;
    while (b < NB - 1 && fr.cell_px >= edges[b + 1]) b++;
    Bin &B = bins[b];
    B.n++;
    B.ok += fr.ok;
    if (fr.ok) B.us.push_back(us), B.bias.push_back(fr.bias);
    double e1 = 0;
    for (int k = 0; k < 8; k++) e1 += (fr.corners[k] - tc[k]) * (fr.corners[k] - tc[k]);
    B.ce0.push_back(sqrt(e0 / 4)), B.ce1.push_back(sqrt(e1 / 4));
    B.worse += sqrt(e1 / 4) > sqrt(e0 / 4) + 0.1, B.better += sqrt(e1 / 4) < sqrt(e0 / 4) - 0.1;
    if (getenv("TAGFIT_DEBUG") && sqrt(e1 / 4) > sqrt(e0 / 4) + 0.1)
      fprintf(stderr, "worse: frame %d id %d cell %.1f err %.3f -> %.3f rms %.3f -> %.3f bias %.3f n %d\n", f, id,
              fr.cell_px, sqrt(e0 / 4), sqrt(e1 / 4), fr.rms0, fr.rms, fr.bias, fr.samples);
    double tr = sqrt(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]);
    if (p0.ok && p1.ok) {
      auto rg = [](const tag_pose &p) { return sqrt(p.t[0] * p.t[0] + p.t[1] * p.t[1] + p.t[2] * p.t[2]); };
      B.re0.push_back(100 * fabs(rg(p0.b) - tr) / tr), B.re1.push_back(100 * fabs(rg(p1.b) - tr) / tr);
      double a0 = rot_angle_deg(p0.b.R, R), a1 = rot_angle_deg(p1.b.R, R);
      B.ro0.push_back(a0), B.ro1.push_back(a1);
      B.flip0 += a0 > 10, B.flip1 += a1 > 10;
      B.am0.push_back(p0.amb), B.am1.push_back(p1.amb);
      B.rp0.push_back(p0.b.err), B.rp1.push_back(p1.b.err);
    }
  }
  printf("synth: %d rendered, %d detected, %d with a corner order unlike the renderer's (skipped)\n", rendered, found,
         rot_bad);
  printf("noise %.1f blur %.2f jpeg %d bloom %.2f iters %d bias %d cam %d\n", o.noise, o.blur, o.jpeg, o.bloom,
         o.fp.iters, o.fp.fit_bias, o.use_cam);
  printf("%-10s %5s %5s %9s | %-15s | %-15s | %-15s | %-15s | %-11s | %-15s | %-13s | %s\n", "cell px", "n", "fit%", "+/->0.1px",
         "corner med px", "corner p90 px", "range err % med", "rot err deg med", "flips>10deg", "ambiguity med",
         "reproj px med", "us/tag med p90, bias px");
  for (int b = 0; b < NB; b++) {
    Bin &B = bins[b];
    if (!B.n) continue;
    char lab[32];
    snprintf(lab, sizeof lab, "%.1f-%.1f", edges[b], edges[b + 1] > 1e8 ? 99.0 : edges[b + 1]);
    printf("%-10s %5d %5.0f %4d/%4d | %6.3f -> %6.3f | %6.3f -> %6.3f | %6.3f -> %6.3f | %6.3f -> %6.3f | %4d -> %4d | %6.3f -> "
           "%6.3f | %5.3f->%5.3f | %4.0f %4.0f, %+.3f\n",
           lab, B.n, 100.0 * B.ok / B.n, B.better, B.worse, median(B.ce0), median(B.ce1), pct(B.ce0, 0.9), pct(B.ce1, 0.9), median(B.re0),
           median(B.re1), median(B.ro0), median(B.ro1), B.flip0, B.flip1, median(B.am0), median(B.am1), median(B.rp0),
           median(B.rp1), median(B.us), pct(B.us, 0.9), median(B.bias));
  }
  napa_destroy(det);
  return 0;
}

// ------------------------------------------------------------------------------------------- replay
struct Acc {
  int n = 0, ok = 0;
  double cell = 0;
  std::vector<double> c0[8], c1[8], r0, r1, w0[3], w1[3], am0, am1, rp0, rp1, us;
  double Rref[9];
  bool have_ref = false;
};
static double stdev(const std::vector<double> &v) {
  if (v.size() < 2) return NAN;
  double m = 0, s = 0;
  for (double x : v) m += x;
  m /= v.size();
  for (double x : v) s += (x - m) * (x - m);
  return sqrt(s / (v.size() - 1));
}

static int replay(const char *path, const cam_model &cam, const Opt &o) {
  FILE *f = fopen(path, "rb");
  if (!f) return perror(path), 1;
  std::vector<uint8_t> all;
  fseek(f, 0, SEEK_END);
  all.resize(ftell(f));
  fseek(f, 0, SEEK_SET);
  if (fread(all.data(), 1, all.size(), f) != all.size()) return fclose(f), 1;
  fclose(f);
  std::vector<std::pair<size_t, size_t>> fr;
  for (size_t i = 0; i + 1 < all.size(); i++)
    if (all[i] == 0xFF && all[i + 1] == 0xD8) {
      size_t j = i + 2;
      while (j + 1 < all.size() && !(all[j] == 0xFF && all[j + 1] == 0xD9)) j++;
      fr.push_back({i, j + 2 - i});
      i = j + 1;
    }
  napa_detector *det = napa_create();
  napa_params np{o.min_tag, 1, 20, 22, 25};
  std::vector<uint8_t> img, cells;
  std::map<int, Acc> acc;
  int frames = 0;
  for (auto &[off, len] : fr) {
    if (frames >= o.maxf) break;
    int w, h;
    if (!jpeg_gray(all.data() + off, len, img, w, h)) continue;
    frames++;
    napa_detection dd[32];
    int nd = napa_detect(det, img.data(), w, h, w, &np, dd, 32);
    for (int i = 0; i < nd; i++) {
      tag_cells(dd[i].id, cells);
      tagfit_result r;
      double t0 = now_us();
      tagfit_refine(img.data(), w, h, w, cells.data(), L.width, o.use_cam ? &cam : nullptr, dd[i].corners, &o.fp, &r);
      double us = now_us() - t0;
      PoseOut p0 = pose_of(cam, dd[i].corners), p1 = pose_of(cam, r.corners);
      if (!p0.ok || !p1.ok) continue;
      Acc &A = acc[dd[i].id];
      A.n++;
      A.ok += r.ok;
      A.cell += r.cell_px;
      if (r.ok) A.us.push_back(us);
      for (int k = 0; k < 8; k++) A.c0[k].push_back(dd[i].corners[k]), A.c1[k].push_back(r.corners[k]);
      auto rg = [](const tag_pose &p) { return sqrt(p.t[0] * p.t[0] + p.t[1] * p.t[1] + p.t[2] * p.t[2]); };
      A.r0.push_back(rg(p0.b)), A.r1.push_back(rg(p1.b));
      if (!A.have_ref) memcpy(A.Rref, p0.b.R, sizeof A.Rref), A.have_ref = true;
      double a[3], b[3];
      rel_rotvec(A.Rref, p0.b.R, a);
      rel_rotvec(A.Rref, p1.b.R, b);
      for (int k = 0; k < 3; k++) A.w0[k].push_back(a[k] * 180 / M_PI), A.w1[k].push_back(b[k] * 180 / M_PI);
      A.am0.push_back(p0.amb), A.am1.push_back(p1.amb);
      A.rp0.push_back(p0.b.err), A.rp1.push_back(p1.b.err);
    }
  }
  printf("replay %s: %d frames, iters %d bias %d cam %d\n", path, frames, o.fp.iters, o.fp.fit_bias, o.use_cam);
  printf("%4s %5s %6s %5s | %-15s | %-17s | %-15s | %-15s | %-15s | %s\n", "id", "n", "cellpx", "fit%",
         "corner std px", "range std mm", "rot std deg", "ambiguity med", "reproj px med", "us/tag med");
  for (auto &[id, A] : acc) {
    if (A.n < frames / 2) continue;  // static tags seen in most frames
    auto cstd = [](std::vector<double> *c) {
      double s = 0;
      for (int k = 0; k < 8; k++) s += stdev(c[k]) * stdev(c[k]);
      return sqrt(s / 8);
    };
    auto wstd = [](std::vector<double> *w) {
      double s = 0;
      for (int k = 0; k < 3; k++) s += stdev(w[k]) * stdev(w[k]);
      return sqrt(s);
    };
    printf("%4d %5d %6.1f %5.0f | %6.4f -> %6.4f | %7.2f -> %7.2f | %6.4f -> %6.4f | %6.3f -> %6.3f | %6.3f -> %6.3f | "
           "%.0f  (range %.2f m)\n",
           id, A.n, A.cell / A.n, 100.0 * A.ok / A.n, cstd(A.c0), cstd(A.c1), 1000 * stdev(A.r0), 1000 * stdev(A.r1),
           wstd(A.w0), wstd(A.w1), median(A.am0), median(A.am1), median(A.rp0), median(A.rp1), median(A.us),
           median(A.r0));
  }
  napa_destroy(det);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: tagfit_bench synth CALIB.json [opts] | replay FILE.mjpeg CALIB.json [opts]\n");
    return 2;
  }
  napa_family_info("tag36h11", &L);
  Opt o;
  tagfit_defaults(&o.fp);
  std::string mode = argv[1];
  int a0 = mode == "synth" ? 3 : 4;
  const char *calib = mode == "synth" ? argv[2] : argv[3];
  for (int i = a0; i < argc; i++) {
    std::string a = argv[i];
    auto nx = [&]() { return i + 1 < argc ? argv[++i] : (char *)"0"; };
    if (a == "--n") o.n = atoi(nx());
    else if (a == "--seed") o.seed = atoi(nx());
    else if (a == "--noise") o.noise = atof(nx());
    else if (a == "--blur") o.blur = atof(nx());
    else if (a == "--jpeg") o.jpeg = atoi(nx());
    else if (a == "--bloom") o.bloom = atof(nx());
    else if (a == "--max") o.maxf = atoi(nx());
    else if (a == "--min-tag") o.min_tag = atoi(nx());
    else if (a == "--iters") o.fp.iters = atoi(nx());
    else if (a == "--no-bias") o.fp.fit_bias = 0;
    else if (a == "--min-cell") o.fp.min_cell_px = atof(nx());
    else if (a == "--max-cell") o.fp.max_cell_px = atof(nx());
    else if (a == "--no-cam") o.use_cam = false;
    else if (a == "--sample-px") o.fp.sample_px = atof(nx());
    else if (a == "--samples-max") o.fp.samples_max = atoi(nx());
    else if (a == "--pose") o.fp.pose = 1;
    else return fprintf(stderr, "unknown option %s\n", a.c_str()), 2;
  }
  cam_model cam;
  if (cam_model_load(calib, &cam)) return fprintf(stderr, "can't read %s\n", calib), 1;
  return mode == "synth" ? synth(cam, o) : replay(argv[2], cam, o);
}
