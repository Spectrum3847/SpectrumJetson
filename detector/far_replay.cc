// far_replay: replays a whole Rewind session (every camera, merged in recording-time order) through
// the 971 detector, as PhotonVision runs it, with the far-tag search (far_search.h) deciding on each
// frame exactly as it does live: its good-view / starved policy spans all cameras, so this replays
// them together, on the recording's own clock.
//
//   far_replay SESSION_DIR [--out OUT.csv] [--budget N] [--off] [--every N] [--threads N]
//              [--calib CAMERA=fx,fy,cx,cy,k1,k2,p1,p2,k3,k4,k5,k6]... [--mwbd N] [--mse X]
//              [--exclude ID,ID...] [--mcp N] [--fullres | --half] [--edge N]
//
// SESSION_DIR: a Rewind session (one folder per camera, docs/REWIND.md). --budget: full-size
// searches a second (default 30, as live). --off: the far search switched off, for a baseline.
// --every N: every Nth frame of each camera (the policy's timings stay on the recording's clock).
// --calib: a camera's lens calibration by folder name; without one, no undistortion (as in
// PhotonVision before a calibration). --exclude: PhotonVision's excluded tags, which don't count
// toward a good view (photonvision-69). --mcp: min_cluster_pixels (the 971 detector's floor is 24).
// --fullres: the normal search at full resolution (the frame upscaled 2x in tiles, as the far
// search's full-size search does) instead of the detector's half-resolution quad search.
// --half: the frame downscaled 2x (2x2 average) first, as a 640x400 camera mode; corners and sizes
// are reported in full-frame pixels (X = 2U, the 971 detector's pixel-edge convention).
//
// OUT.csv, one row per detection: camera,frame,jetson_us,id,margin,side_px,source,x0,y0,...,x3,y3
// (source: normal or far). Summary on stdout: tag sightings (camera x frame x tag) by the normal
// search and with the far search, the tags only the far search found and how small they were,
// time starved, full-size searches and crops, and what they cost, and the slowest frames.
// --edge N: drop tags whose blob comes within N full-frame pixels of the image edge (bos-12,
// SPECTRUM_971_EDGE_BORDER_PX live; default 0 = off). Normal search only, not the far search's crops.
// With --half, N/2 rounded up in the small frame; ignored with --fullres.
// --trace: each frame's far-search time on stderr as it goes (to find a frame that stalls).
// Accuracy knobs (tests/field-replay/accuracy/; all off by default, output unchanged without them):
// --subpix W: each reported corner refined with OpenCV's cornerSubPix on the full-res gray frame,
// window (2W+1)^2. --edgefit: each corner re-found as the intersection of lines fitted to the
// strongest gradient across each tag edge (subpixel peak, every ~1.5 px along the edge);
// --edgefit-undist: the same, with the lines fitted in undistorted coordinates (needs --calib).
// --no-refine-edges: the detector's own RefineEdges off. --cos X: qtp.cos_critical_rad.
// --nmaxima N: qtp.max_nmaxima (bos compiles it in as 10: any other value CHECK-fails). Refinement time goes on its own "Refine:" line.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <cuda_runtime.h>
#include <opencv2/core/mat.hpp>
#include <opencv2/imgproc.hpp>

#include "absl/status/status.h"
#include "apriltag/apriltag.h"
#include "apriltag/tag36h11.h"
#include "far_search.h"
#include "rewind_reader.h"
#include "third_party/971apriltag/apriltag.h"

namespace fs = std::filesystem;

namespace {

struct Camera {
  std::string name;
  std::vector<recording::Frame> frames;
  int width = 0, height = 0;
  apriltag_family_t *family = nullptr;
  apriltag_detector_t *td = nullptr;
  frc::apriltag::GpuDetector *gpu = nullptr;
  frc::apriltag::CameraMatrix cm{1, 1, 1, 1};  // as the live wrapper before a calibration
  frc::apriltag::DistCoeffs dc{};
  // Results
  long frames_done = 0, normal_sightings = 0, far_sightings = 0, bad_jpegs = 0;
  std::map<int, long> far_only;           // tag -> frames only the far search found it
  std::map<int, double> far_only_min_px;  // tag -> smallest side it was found at
  // --fullres: one detector per tile (the frame upscaled 2x), and the tiles' x origins.
  std::vector<frc::apriltag::GpuDetector *> tiles;
  std::vector<int> tile_x0;
  int tile_w = 0;
  std::vector<uint8_t> up, small;
};

constexpr int kTileSide = 1024;  // frame pixels; upscaled 2x, the 971 detector's 2048 limit

void Upscale2x(const uint8_t *src, int stride, int x0, int w, int h, uint8_t *dst) {
  const size_t dw = 2 * static_cast<size_t>(w);
  for (int y = 0; y < h; ++y) {
    const uint8_t *s = src + static_cast<size_t>(y) * stride + x0;
    uint8_t *d = dst + 2 * static_cast<size_t>(y) * dw;
    for (int x = 0; x < w; ++x) d[2 * x] = d[2 * x + 1] = s[x];
    std::memcpy(d + dw, d, dw);
  }
}

// A detection from an image scaled by 1/k (k = 0.5: upscaled 2x) and offset x0, back to the frame:
// X = k U + x0 (pixel edges at whole numbers, as far_search.cc's Unscale).
far_search::Det Rescale(const far_search::Det &d, double k, double x0) {
  far_search::Det o = d;
  for (int i = 0; i < 4; ++i) {
    o.p[2 * i] = d.p[2 * i] * k + x0;
    o.p[2 * i + 1] = d.p[2 * i + 1] * k;
  }
  o.c[0] = d.c[0] * k + x0;
  o.c[1] = d.c[1] * k;
  for (int col = 0; col < 3; ++col) {
    o.H[0 * 3 + col] = d.H[0 * 3 + col] * k + x0 * d.H[2 * 3 + col];
    o.H[1 * 3 + col] = d.H[1 * 3 + col] * k;
  }
  return o;
}

struct Item {
  int camera;
  size_t frame;
  long long jetson_us;
};

// Accuracy knobs: the lens model (OpenCV's rational model, 8 coefficients) and corner refiners.
// Corners in and out in the detector's convention (pixel edges at whole numbers); the refiners
// work in OpenCV's (pixel centres), x_cv = x - 0.5.
struct Lens {
  bool valid = false;
  double fx = 1, fy = 1, cx = 0, cy = 0, k[8] = {};
  void Distort(double x, double y, double *u, double *v) const {
    const double r2 = x * x + y * y;
    const double rad = (1 + k[0] * r2 + k[1] * r2 * r2 + k[4] * r2 * r2 * r2) /
                       (1 + k[5] * r2 + k[6] * r2 * r2 + k[7] * r2 * r2 * r2);
    const double xd = x * rad + 2 * k[2] * x * y + k[3] * (r2 + 2 * x * x);
    const double yd = y * rad + k[2] * (r2 + 2 * y * y) + 2 * k[3] * x * y;
    *u = fx * xd + cx;
    *v = fy * yd + cy;
  }
  // Pixel -> normalized undistorted (fixed-point iteration, as cv::undistortPoints).
  void Undistort(double u, double v, double *x, double *y) const {
    const double xd = (u - cx) / fx, yd = (v - cy) / fy;
    double X = xd, Y = yd;
    for (int it = 0; it < 20; ++it) {
      const double r2 = X * X + Y * Y;
      const double icdist = (1 + k[5] * r2 + k[6] * r2 * r2 + k[7] * r2 * r2 * r2) /
                            (1 + k[0] * r2 + k[1] * r2 * r2 + k[4] * r2 * r2 * r2);
      const double dx = 2 * k[2] * X * Y + k[3] * (r2 + 2 * X * X);
      const double dy = k[2] * (r2 + 2 * Y * Y) + 2 * k[3] * X * Y;
      X = (xd - dx) * icdist;
      Y = (yd - dy) * icdist;
    }
    *x = X;
    *y = Y;
  }
};

double Bilinear(const cv::Mat &img, double x, double y) {
  if (x < 0 || y < 0 || x > img.cols - 1.001 || y > img.rows - 1.001) return -1;
  const int x0 = static_cast<int>(x), y0 = static_cast<int>(y);
  const double fx = x - x0, fy = y - y0;
  const uint8_t *r0 = img.ptr<uint8_t>(y0), *r1 = img.ptr<uint8_t>(y0 + 1);
  return (1 - fy) * ((1 - fx) * r0[x0] + fx * r0[x0 + 1]) + fy * ((1 - fx) * r1[x0] + fx * r1[x0 + 1]);
}

void SubpixRefine(const cv::Mat &img, far_search::Det &d, int w) {
  std::vector<cv::Point2f> pts;
  for (int i = 0; i < 4; ++i) pts.emplace_back(d.p[2 * i] - 0.5, d.p[2 * i + 1] - 0.5);
  for (auto &q : pts)
    if (q.x < w + 1 || q.y < w + 1 || q.x > img.cols - w - 2 || q.y > img.rows - w - 2) return;
  cv::cornerSubPix(img, pts, cv::Size(w, w), cv::Size(-1, -1),
                   cv::TermCriteria(cv::TermCriteria::EPS + cv::TermCriteria::COUNT, 30, 0.01));
  for (int i = 0; i < 4; ++i) {
    const double dx = pts[i].x + 0.5 - d.p[2 * i], dy = pts[i].y + 0.5 - d.p[2 * i + 1];
    if (std::hypot(dx, dy) > w + 1) continue;  // ran off: keep the detector's corner
    d.p[2 * i] = pts[i].x + 0.5;
    d.p[2 * i + 1] = pts[i].y + 0.5;
  }
}

// Edge fit: along each edge, the strongest gradient across it (subpixel, parabola through the
// peak), weighted by gradient strength; a total-least-squares line per edge; corners where
// neighbouring lines meet. With a lens (undist), the edge points are undistorted before the
// line fit (tag edges are straight only there) and the corners distorted back.
void EdgeFit(const cv::Mat &img, far_search::Det &d, const Lens *lens) {
  double cxy[4][2];
  for (int i = 0; i < 4; ++i) cxy[i][0] = d.p[2 * i] - 0.5, cxy[i][1] = d.p[2 * i + 1] - 0.5;
  double line[4][3];  // a x + b y = c, in pixels or normalized coordinates
  for (int e = 0; e < 4; ++e) {
    const double *A = cxy[e], *B = cxy[(e + 1) % 4];
    const double ex = B[0] - A[0], ey = B[1] - A[1], len = std::hypot(ex, ey);
    if (len < 6) return;
    const double tx = ex / len, ty = ey / len, nx = -ty, ny = tx;
    const double reach = std::clamp(0.08 * len, 1.5, 4.0), step = 0.25;
    const int ns = static_cast<int>(2 * reach / step) + 1;
    const int np = std::max(6, static_cast<int>(len / 1.5));
    double sw = 0, sx = 0, sy = 0;
    std::vector<double> px, py, pw;
    std::vector<double> prof(ns + 2);
    for (int s = 0; s < np; ++s) {
      const double f = 0.12 + 0.76 * s / (np - 1);
      const double bx = A[0] + f * ex, by = A[1] + f * ey;
      bool okp = true;
      for (int j = 0; j < ns + 2 && okp; ++j) {
        const double o = -reach - step + j * step;
        prof[j] = Bilinear(img, bx + o * nx, by + o * ny);
        okp = prof[j] >= 0;
      }
      if (!okp) continue;
      int best = -1;
      double g = 0;
      std::vector<double> gr(ns);
      for (int j = 0; j < ns; ++j) {
        gr[j] = std::abs(prof[j + 2] - prof[j]);
        if (gr[j] > g) g = gr[j], best = j;
      }
      if (best <= 0 || best >= ns - 1 || g < 4) continue;
      const double den = gr[best - 1] - 2 * gr[best] + gr[best + 1];
      const double off = den < 0 ? 0.5 * (gr[best - 1] - gr[best + 1]) / den : 0;
      const double o = -reach + (best + off) * step;
      double X = bx + o * nx, Y = by + o * ny;
      if (lens) lens->Undistort(X, Y, &X, &Y);
      px.push_back(X), py.push_back(Y), pw.push_back(g);
      sw += g, sx += g * X, sy += g * Y;
    }
    if (px.size() < 4) return;
    const double mx = sx / sw, my = sy / sw;
    double sxx = 0, sxy = 0, syy = 0;
    for (size_t j = 0; j < px.size(); ++j) {
      const double dx = px[j] - mx, dy = py[j] - my;
      sxx += pw[j] * dx * dx, sxy += pw[j] * dx * dy, syy += pw[j] * dy * dy;
    }
    // Normal = eigenvector of the smaller eigenvalue.
    const double th = 0.5 * std::atan2(2 * sxy, sxx - syy);
    const double a = -std::sin(th), b = std::cos(th);
    line[e][0] = a, line[e][1] = b, line[e][2] = a * mx + b * my;
  }
  double out[4][2];
  for (int i = 0; i < 4; ++i) {
    const double *l1 = line[(i + 3) % 4], *l2 = line[i];  // corner i: edges (i-1) and i
    const double det = l1[0] * l2[1] - l1[1] * l2[0];
    if (std::abs(det) < 1e-9) return;
    double X = (l1[2] * l2[1] - l1[1] * l2[2]) / det, Y = (l1[0] * l2[2] - l1[2] * l2[0]) / det;
    if (lens) lens->Distort(X, Y, &X, &Y);
    if (std::hypot(X - cxy[i][0], Y - cxy[i][1]) > 3) return;  // implausible: keep the detector's
    out[i][0] = X, out[i][1] = Y;
  }
  for (int i = 0; i < 4; ++i) d.p[2 * i] = out[i][0] + 0.5, d.p[2 * i + 1] = out[i][1] + 0.5;
}

double EnvOr(const char *name, double fallback) {
  const char *v = std::getenv(name);
  return v && *v ? std::atof(v) : fallback;
}

}  // namespace

int main(int argc, char **argv) {
  setvbuf(stdout, nullptr, _IOLBF, 0);
  if (argc < 2) {
    std::cerr << "usage: far_replay SESSION_DIR [--out OUT.csv] [--budget N] [--off] [--every N] [--threads N]"
                 " [--calib CAMERA=fx,fy,cx,cy,k1,k2,p1,p2,k3,k4,k5,k6]... [--mwbd N] [--mse X]"
                 " [--exclude ID,ID...]\n";
    return 2;
  }
  const fs::path session = fs::path(argv[1]).lexically_normal().string().back() == '/'
                               ? fs::path(argv[1]).lexically_normal().parent_path()
                               : fs::path(argv[1]).lexically_normal();
  std::string out_path;
  double budget = 30;
  bool off = false, trace = false, fullres = false, half = false;
  int mcp = -1;
  int edge = 0;
  int every = 1, threads = 5;
  int subpix = 0, nmaxima = -1;
  bool edgefit = false, edgefit_undist = false, no_refine_edges = false;
  double cos_crit = -1;
  double mwbd = EnvOr("SPECTRUM_971_MIN_WHITE_BLACK_DIFF", 5), mse = EnvOr("SPECTRUM_971_MAX_LINE_FIT_MSE", 10);
  std::map<std::string, std::vector<double>> calibs;
  std::vector<int> excluded;
  for (int i = 2; i < argc; ++i) {
    const std::string a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (a == "--out") out_path = v, ++i;
    else if (a == "--budget") budget = std::atof(v), ++i;
    else if (a == "--off") off = true;
    else if (a == "--trace") trace = true;
    else if (a == "--fullres") fullres = true;
    else if (a == "--half") half = true;
    else if (a == "--edge") edge = std::max(0, std::atoi(v)), ++i;
    else if (a == "--mcp") mcp = std::atoi(v), ++i;
    else if (a == "--every") every = std::max(1, std::atoi(v)), ++i;
    else if (a == "--threads") threads = std::max(1, std::atoi(v)), ++i;
    else if (a == "--mwbd") mwbd = std::atof(v), ++i;
    else if (a == "--mse") mse = std::atof(v), ++i;
    else if (a == "--subpix") subpix = std::max(1, std::atoi(v)), ++i;
    else if (a == "--edgefit") edgefit = true;
    else if (a == "--edgefit-undist") edgefit_undist = true;
    else if (a == "--no-refine-edges") no_refine_edges = true;
    else if (a == "--cos") cos_crit = std::atof(v), ++i;
    else if (a == "--nmaxima") nmaxima = std::atoi(v), ++i;
    else if (a == "--exclude") {
      std::stringstream ss(v);
      std::string t;
      while (std::getline(ss, t, ',')) excluded.push_back(std::atoi(t.c_str()));
      ++i;
    }
    else if (a == "--calib") {
      const std::string c = v;
      const auto eq = c.find('=');
      std::vector<double> k;
      std::stringstream ss(eq == std::string::npos ? "" : c.substr(eq + 1));
      std::string t;
      while (std::getline(ss, t, ',')) k.push_back(std::atof(t.c_str()));
      if (eq == std::string::npos || k.size() < 4) {
        std::cerr << "--calib needs CAMERA=fx,fy,cx,cy[,k1,k2,p1,p2,k3,k4,k5,k6]\n";
        return 2;
      }
      calibs[c.substr(0, eq)] = k;
      ++i;
    } else {
      std::cerr << "unknown option " << a << "\n";
      return 2;
    }
  }

  // Every camera folder with frames.
  std::vector<Camera> cams;
  for (auto &e : fs::directory_iterator(session)) {
    if (!e.is_directory()) continue;
    auto frames = recording::ReadIndex(e.path());
    if (frames.empty()) continue;
    Camera c;
    c.name = e.path().filename().string();
    for (size_t i = 0; i < frames.size(); i += every) c.frames.push_back(frames[i]);
    c.width = c.frames[0].width;
    c.height = c.frames[0].height;
    cams.push_back(std::move(c));
  }
  std::sort(cams.begin(), cams.end(), [](const Camera &a, const Camera &b) { return a.name < b.name; });
  if (cams.empty() || static_cast<int>(cams.size()) > far_search::kMaxCameras) {
    std::cerr << "no camera folders with frames in " << session << " (or more than " << far_search::kMaxCameras
              << ")\n";
    return 1;
  }

  // A detector per camera, with PhotonVision's settings (GpuDetectorJNI.cc's MakeTagDetector).
  for (auto &c : cams) {
    c.family = tag36h11_create();
    c.td = apriltag_detector_create();
    apriltag_detector_add_family_bits(c.td, c.family, 1);
    c.td->nthreads = 6;
    c.td->wp = workerpool_create(c.td->nthreads);
    c.td->qtp.min_white_black_diff = static_cast<int>(mwbd);
    c.td->qtp.max_line_fit_mse = static_cast<float>(mse);
    if (mcp > 0) c.td->qtp.min_cluster_pixels = mcp;
    if (cos_crit >= 0) c.td->qtp.cos_critical_rad = static_cast<float>(cos_crit);
    if (nmaxima > 0) c.td->qtp.max_nmaxima = nmaxima;
    if (no_refine_edges) c.td->refine_edges = false;
    c.td->debug = false;
    c.dc.num_params = 5;
    if (auto it = calibs.find(c.name); it != calibs.end()) {
      const auto &k = it->second;
      c.cm = frc::apriltag::CameraMatrix{k[0], k[2], k[1], k[3]};  // {fx, cx, fy, cy}
      double *d[] = {&c.dc.k1, &c.dc.k2, &c.dc.p1, &c.dc.p2, &c.dc.k3, &c.dc.k4, &c.dc.k5, &c.dc.k6};
      for (size_t j = 4; j < k.size() && j - 4 < 8; ++j) *d[j - 4] = k[j];
      if (k.size() >= 12) c.dc.num_params = 8;  // PhotonVision's 8-coefficient calibrations
    }
    if (half) {
      // 2x2 average: OpenCV-convention centres move as x' = (x + 0.5) / 2 - 0.5.
      auto cm = c.cm;
      if (calibs.count(c.name)) cm = {c.cm.fx / 2, (c.cm.cx + 0.5) / 2 - 0.5, c.cm.fy / 2, (c.cm.cy + 0.5) / 2 - 0.5};
      c.small.resize(static_cast<size_t>(c.width / 2) * (c.height / 2));
      c.gpu = new frc::apriltag::GpuDetector(c.width / 2, c.height / 2, c.td, cm, c.dc, vision::ImageFormat::MONO8);
      c.gpu->SetEdgeBorder((edge + 1) / 2);
    } else if (fullres) {
      if (edge > 0 && &c == &cams[0]) std::cerr << "--edge is ignored with --fullres\n";
      if (c.height > kTileSide || c.width > 2 * kTileSide) {
        std::cerr << "--fullres: frame too big\n";
        return 2;
      }
      c.tile_w = std::min(c.width, kTileSide);
      c.tile_x0 = {0};
      if (c.width > kTileSide) c.tile_x0.push_back(c.width - kTileSide);
      c.up.resize(static_cast<size_t>(4) * c.tile_w * c.height);
      for (int x0 : c.tile_x0) {
        auto cm = c.cm;
        if (calibs.count(c.name)) cm = {2 * c.cm.fx, 2 * (c.cm.cx - x0), 2 * c.cm.fy, 2 * c.cm.cy};
        c.tiles.push_back(
            new frc::apriltag::GpuDetector(2 * c.tile_w, 2 * c.height, c.td, cm, c.dc, vision::ImageFormat::MONO8));
      }
    } else {
      c.gpu = new frc::apriltag::GpuDetector(c.width, c.height, c.td, c.cm, c.dc, vision::ImageFormat::MONO8);
      c.gpu->SetEdgeBorder(edge);
    }
  }

  // All frames, merged in recording-time order.
  std::vector<Item> items;
  for (int ci = 0; ci < static_cast<int>(cams.size()); ++ci)
    for (size_t fi = 0; fi < cams[ci].frames.size(); ++fi) items.push_back({ci, fi, cams[ci].frames[fi].jetson_us});
  std::sort(items.begin(), items.end(), [](const Item &a, const Item &b) { return a.jetson_us < b.jetson_us; });
  const double seconds = items.size() > 1 ? (items.back().jetson_us - items.front().jetson_us) / 1e6 : 0;

  std::printf("%s: %zu cameras, %zu frames, %.1f s; far search %s (%.0f full-size searches a second)%s\n",
              session.filename().c_str(), cams.size(), items.size(), seconds, off ? "OFF" : "on", budget,
              fullres ? "; normal search at FULL resolution" : half ? "; frames downscaled 2x" : "");
  for (auto &c : cams)
    std::printf("  %s: %zu frames %dx%d%s\n", c.name.c_str(), c.frames.size(), c.width, c.height,
                calibs.count(c.name) ? ", calibrated" : "");
  far_search::SetConfig({!off, budget});
  far_search::SetExcluded(excluded);

  std::ofstream out;
  if (!out_path.empty()) {
    out.open(out_path);
    out << "camera,frame,jetson_us,id,margin,side_px,source,x0,y0,x1,y1,x2,y2,x3,y3\n";
  }

  // Decode ahead in batches on CPU threads; detect in order on the GPU.
  const size_t batch = static_cast<size_t>(threads) * 8;
  std::vector<std::vector<uint8_t>> gray(batch);
  std::vector<char> ok(batch);
  auto t_start = std::chrono::steady_clock::now();
  double detect_ms = 0, far_ms = 0;
  // The slowest frames for the far search: a full-size search can't be cut short, so one slow scene
  // is one camera's frame late. Kept to report the worst.
  struct Slow {
    double ms;
    std::string camera;
    int frame;
  };
  std::vector<Slow> slow;
  double refine_ms = 0;
  std::map<std::string, Lens> lenses;
  for (auto &[name, k] : calibs) {
    Lens l;
    l.valid = true;
    l.fx = k[0], l.fy = k[1], l.cx = k[2], l.cy = k[3];
    for (size_t j = 4; j < k.size() && j - 4 < 8; ++j) l.k[j - 4] = k[j];
    lenses[name] = l;
  }
  if (edgefit_undist && lenses.empty()) std::cerr << "--edgefit-undist without --calib: lines fitted in pixels\n";
  for (size_t b0 = 0; b0 < items.size(); b0 += batch) {
    const size_t n = std::min(batch, items.size() - b0);
    std::atomic<size_t> next{0};
    std::vector<std::thread> workers;
    for (int t = 0; t < threads; ++t) {
      workers.emplace_back([&] {
        std::vector<unsigned char> jpeg;
        for (size_t k = next++; k < n; k = next++) {
          const Item &it = items[b0 + k];
          const Camera &c = cams[it.camera];
          ok[k] = recording::ReadJpeg(c.frames[it.frame], jpeg) && recording::DecodeGray(jpeg, gray[k], c.width, c.height);
        }
      });
    }
    for (auto &w : workers) w.join();
    for (size_t k = 0; k < n; ++k) {
      const Item &it = items[b0 + k];
      Camera &c = cams[it.camera];
      if (!ok[k]) {
        ++c.bad_jpegs;
        continue;
      }
      cv::Mat img(c.height, c.width, CV_8UC1, gray[k].data());
      auto t0 = std::chrono::steady_clock::now();
      std::vector<far_search::Det> normal;
      if (half) {
        const int w2 = c.width / 2, h2 = c.height / 2;
        const uint8_t *g = gray[k].data();
        for (int y = 0; y < h2; ++y)
          for (int x = 0; x < w2; ++x) {
            const uint8_t *s = g + static_cast<size_t>(2 * y) * c.width + 2 * x;
            c.small[static_cast<size_t>(y) * w2 + x] = static_cast<uint8_t>((s[0] + s[1] + s[c.width] + s[c.width + 1] + 2) / 4);
          }
        if (!c.gpu->Detect(c.small.data(), nullptr).ok()) continue;
        for (const auto &d : far_search::Copy(c.gpu->Detections())) normal.push_back(Rescale(d, 2, 0));
      } else if (fullres) {
        for (size_t t = 0; t < c.tiles.size(); ++t) {
          Upscale2x(gray[k].data(), c.width, c.tile_x0[t], c.tile_w, c.height, c.up.data());
          if (!c.tiles[t]->Detect(c.up.data(), nullptr).ok()) continue;
          for (const auto &d : far_search::Copy(c.tiles[t]->Detections())) {
            auto o = Rescale(d, 0.5, c.tile_x0[t]);
            auto it = std::find_if(normal.begin(), normal.end(), [&](const far_search::Det &e) { return e.id == o.id; });
            if (it == normal.end()) normal.push_back(o);
            else if (o.margin > it->margin) *it = o;
          }
        }
      } else {
        if (!c.gpu->Detect(gray[k].data(), nullptr).ok()) continue;
        normal = far_search::Copy(c.gpu->Detections());
      }
      auto t1 = std::chrono::steady_clock::now();
      if (trace) std::fprintf(stderr, "trace %s frame %d...", c.name.c_str(), c.frames[it.frame].index);
      auto far = far_search::Process(it.camera, img, normal, c.td, c.cm, c.dc, it.jetson_us);
      if (trace)
        std::fprintf(stderr, " %.1f ms\n",
                     std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count());
      auto t2 = std::chrono::steady_clock::now();
      if (subpix > 0 || edgefit || edgefit_undist) {
        const Lens *lens = nullptr;
        if (edgefit_undist)
          if (auto li = lenses.find(c.name); li != lenses.end()) lens = &li->second;
        for (auto *v : {&normal, &far})
          for (auto &d : *v) {
            if (d.margin < 15) continue;
            if (edgefit || edgefit_undist) EdgeFit(img, d, lens);
            if (subpix > 0) SubpixRefine(img, d, subpix);
          }
        refine_ms += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t2).count();
      }
      detect_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
      const double this_far_ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
      far_ms += this_far_ms;
      if (this_far_ms > 20) slow.push_back({this_far_ms, c.name, c.frames[it.frame].index});
      ++c.frames_done;
      // As PhotonVision keeps them: decision margin 15 or more.
      std::set<int> normal_ids;
      for (const auto &d : normal)
        if (d.margin >= 15) normal_ids.insert(d.id);
      c.normal_sightings += static_cast<long>(normal_ids.size());
      std::set<int> all_ids = normal_ids;
      for (const auto &d : far) {
        if (d.margin < 15) continue;
        if (all_ids.insert(d.id).second) {
          c.far_only[d.id]++;
          auto m = c.far_only_min_px.find(d.id);
          if (m == c.far_only_min_px.end() || d.side() < m->second) c.far_only_min_px[d.id] = d.side();
        }
      }
      c.far_sightings += static_cast<long>(all_ids.size());
      if (out) {
        auto row = [&](const far_search::Det &d, const char *src) {
          out << c.name << ',' << c.frames[it.frame].index << ',' << it.jetson_us << ',' << d.id << ',' << d.margin << ','
              << d.side() << ',' << src;
          for (double v : d.p) out << ',' << v;
          out << '\n';
        };
        for (const auto &d : normal)
          if (d.margin >= 15) row(d, "normal");
        for (const auto &d : far)
          if (d.margin >= 15) row(d, "far");
      }
    }
    if ((b0 / batch) % 50 == 49) {
      std::printf("  ... %zu of %zu frames\n", b0 + n, items.size());
    }
  }
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();

  const auto fc = far_search::GetCounters();
  long normal_total = 0, far_total = 0, frames_total = 0;
  std::printf("\nPer camera (tag sightings: frames x tags, decision margin 15+):\n");
  for (auto &c : cams) {
    normal_total += c.normal_sightings;
    far_total += c.far_sightings;
    frames_total += c.frames_done;
    std::printf("  %-12s %6ld frames: %6ld sightings by the normal search, %6ld with the far search (+%ld)%s\n",
                c.name.c_str(), c.frames_done, c.normal_sightings, c.far_sightings,
                c.far_sightings - c.normal_sightings, c.bad_jpegs ? " (some bad JPEGs skipped)" : "");
    for (auto &[id, count] : c.far_only)
      std::printf("      tag %d: %ld frames only the far search found it (smallest %.1f px)\n", id, count,
                  c.far_only_min_px[id]);
  }
  std::printf("\nTotal: %ld sightings normal, %ld with the far search (+%.1f%%)\n", normal_total, far_total,
              normal_total ? 100.0 * (far_total - normal_total) / normal_total : 0);
  std::printf("Far search: starved %.1f s of %.1f s; %ld full-size searches (%.2f ms each), %ld crops (%.2f ms each)\n",
              fc.starved_ms / 1000.0, seconds, fc.sweeps, fc.sweeps ? fc.sweep_ms / fc.sweeps : 0, fc.crops,
              fc.crops ? fc.crop_ms / fc.crops : 0);
  std::printf("Time: detect %.2f ms a frame, far search %.2f ms a frame on average; replay took %.0f s\n",
              frames_total ? detect_ms / frames_total : 0, frames_total ? far_ms / frames_total : 0, wall);
  if (subpix > 0 || edgefit || edgefit_undist)
    std::printf("Refine: %.3f ms a frame (CPU, one thread)\n", frames_total ? refine_ms / frames_total : 0);
  std::sort(slow.begin(), slow.end(), [](const Slow &a, const Slow &b) { return a.ms > b.ms; });
  std::printf("Frames where the far search took over 20 ms: %zu", slow.size());
  for (size_t i = 0; i < slow.size() && i < 5; ++i)
    std::printf("%s %s frame %d %.0f ms", i ? "," : ";", slow[i].camera.c_str(), slow[i].frame, slow[i].ms);
  std::printf("\n");
  cudaDeviceSynchronize();
  return 0;
}
