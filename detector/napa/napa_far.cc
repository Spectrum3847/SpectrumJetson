// SpectrumJetson: NAPA backend with far search. See napa_far.h.
#include "napa_far.h"

#include <algorithm>
#include <chrono>
#include <cmath>

extern "C" {
#include "napa_core.h"
}

namespace napa_far {

namespace {
constexpr int kMaxOut = 128;
constexpr int kBandOverlapPx = 64;
constexpr int kMinCropPx = 96;
constexpr double kGuardFactor = 5;  // next sweep waits 5x the last one's time (as far_search.cc)

double Ms(std::chrono::steady_clock::time_point a) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - a).count();
}
}  // namespace

double Tag::side() const {
  double s = 0;
  for (int k = 0; k < 4; ++k) {
    const int j = (k + 1) % 4;
    s += std::hypot(p[2 * k] - p[2 * j], p[2 * k + 1] - p[2 * j + 1]);
  }
  return s / 4;
}

std::array<double, 9> Tag::Homography() const {
  // AprilTag's correspondences for det->p: p0 (-1,1), p1 (1,1), p2 (1,-1), p3 (-1,-1). Solve the 8x8 DLT
  // system with h22 = 1 (Gaussian elimination, partial pivoting).
  static const double tx[4] = {-1, 1, 1, -1}, ty[4] = {1, 1, -1, -1};
  double A[8][9] = {};
  for (int k = 0; k < 4; ++k) {
    const double X = tx[k], Y = ty[k], u = p[2 * k], v = p[2 * k + 1];
    double *r = A[2 * k];
    r[0] = X, r[1] = Y, r[2] = 1, r[6] = -u * X, r[7] = -u * Y, r[8] = u;
    r = A[2 * k + 1];
    r[3] = X, r[4] = Y, r[5] = 1, r[6] = -v * X, r[7] = -v * Y, r[8] = v;
  }
  for (int c = 0; c < 8; ++c) {
    int piv = c;
    for (int r = c + 1; r < 8; ++r)
      if (std::fabs(A[r][c]) > std::fabs(A[piv][c])) piv = r;
    if (piv != c)
      for (int k = 0; k < 9; ++k) std::swap(A[c][k], A[piv][k]);
    if (std::fabs(A[c][c]) < 1e-12) return {1, 0, 0, 0, 1, 0, 0, 0, 1};
    for (int r = 0; r < 8; ++r) {
      if (r == c) continue;
      const double f = A[r][c] / A[c][c];
      for (int k = c; k < 9; ++k) A[r][k] -= f * A[c][k];
    }
  }
  std::array<double, 9> H;
  for (int k = 0; k < 8; ++k) H[k] = A[k][8] / A[k][k];
  H[8] = 1;
  return H;
}

Detector::Detector(const std::string &family) : family_(family) {
  det_ = napa_create_family(family.c_str());
}

Detector::~Detector() {
  napa_stream_destroy(stream_);
  napa_stream_destroy(sweep_stream_);
  if (sweep_det_) napa_destroy(sweep_det_);
  if (det_) napa_destroy(det_);
}

void Detector::SetConfig(const Config &c) {
  std::lock_guard<std::mutex> l(mu_);
  if (c.far != cfg_.far) tracks_.clear();
  cfg_ = c;
}

Config Detector::GetConfig() {
  std::lock_guard<std::mutex> l(mu_);
  return cfg_;
}

Counters Detector::GetCounters() {
  std::lock_guard<std::mutex> l(mu_);
  return cnt_;
}

int Detector::Run(const uint8_t *img, int w, int h, int stride, int min_tag, int ox, int oy, bool far,
                  std::vector<Tag> &out) {
  napa_params p{min_tag, cfg_.max_hamming, cfg_.min_contrast, cfg_.min_border_cells, cfg_.sharpening_x100};
  napa_detection d[kMaxOut];
  napa_set_early_slack(det_, cfg_.early_slack);
  const int n = napa_detect(det_, img + static_cast<size_t>(oy) * stride + ox, w, h, stride, &p, d, kMaxOut);
  return Merge(d, n, ox, oy, far, out);
}

int Detector::Merge(const void *dets, int n, int ox, int oy, bool far, std::vector<Tag> &out) {
  const napa_detection *d = static_cast<const napa_detection *>(dets);
  static const int perm[4] = {1, 0, 3, 2};
  int kept = 0;
  for (int i = 0; i < n; ++i) {
    if (d[i].decision_margin < cfg_.min_margin) continue;
    Tag t;
    t.id = d[i].id;
    t.hamming = d[i].hamming;
    t.margin = d[i].decision_margin;
    t.far = far;
    for (int k = 0; k < 4; ++k) {
      t.p[2 * k] = d[i].corners[2 * perm[k]] + ox;
      t.p[2 * k + 1] = d[i].corners[2 * perm[k] + 1] + oy;
    }
    // One per id: keep the higher margin.
    auto same = std::find_if(out.begin(), out.end(), [&](const Tag &o) { return o.id == t.id; });
    if (same == out.end()) {
      out.push_back(t), ++kept;
    } else if (!same->far && far) {
      continue;  // the base pass's answer wins
    } else if (t.margin > same->margin) {
      *same = t;
    }
  }
  return kept;
}

void Detector::Crops(const uint8_t *img, int w, int h, int stride, int64_t now_us, std::vector<Tag> &out) {
  // Tracking crops around recent small tags the base pass didn't return this frame.
  tracks_.erase(std::remove_if(tracks_.begin(), tracks_.end(),
                               [&](const Track &t) { return now_us - t.seen_us > cfg_.track_ms * 1000; }),
                tracks_.end());
  for (const auto &tr : tracks_) {
    if (std::any_of(out.begin(), out.end(), [&](const Tag &o) { return o.id == tr.id; })) continue;
    const int half = static_cast<int>(std::max<double>(kMinCropPx, cfg_.crop_scale * tr.side) / 2);
    const int x0 = std::clamp(static_cast<int>(tr.cx) - half, 0, w - 1);
    const int y0 = std::clamp(static_cast<int>(tr.cy) - half, 0, h - 1);
    const int x1 = std::clamp(static_cast<int>(tr.cx) + half, 0, w);
    const int y1 = std::clamp(static_cast<int>(tr.cy) + half, 0, h);
    if (x1 - x0 < 32 || y1 - y0 < 32) continue;
    auto t1 = std::chrono::steady_clock::now();
    cnt_.far_tags += Run(img, x1 - x0, y1 - y0, stride, cfg_.far_min_tag_px, x0, y0, true, out);
    cnt_.crop_ms += Ms(t1);
    ++cnt_.crops;
  }
}

void Detector::UpdateTracks(int64_t now_us, const std::vector<Tag> &out) {
  // Update tracks with this frame's small tags.
  for (const auto &t : out) {
    const double s = t.side();
    if (s >= cfg_.track_side_px) continue;
    auto it = std::find_if(tracks_.begin(), tracks_.end(), [&](const Track &r) { return r.id == t.id; });
    if (it == tracks_.end()) {
      tracks_.push_back({t.id, t.cx(), t.cy(), s, now_us});
    } else {
      *it = {t.id, t.cx(), t.cy(), s, now_us};
    }
  }
}

std::vector<Tag> Detector::Detect(const uint8_t *img, int w, int h, int stride, int64_t now_us) {
  std::lock_guard<std::mutex> l(mu_);
  std::vector<Tag> out;
  if (!det_ || !img || w <= 0 || h <= 0) return out;
  ++cnt_.frames;
  auto t0 = std::chrono::steady_clock::now();
  if (!cfg_.far) {
    Run(img, w, h, stride, cfg_.min_tag_px, 0, 0, false, out);
    cnt_.base_ms += Ms(t0);
    return out;
  }
  Run(img, w, h, stride, cfg_.base_min_tag_px, 0, 0, false, out);
  cnt_.base_ms += Ms(t0);
  Crops(img, w, h, stride, now_us, out);

  // One sweep band, when the schedule and the time guard allow.
  if (cfg_.sweep_bands > 0 && cfg_.sweeps_per_s > 0 && now_us >= next_sweep_us_) {
    const int bands = cfg_.sweep_bands;
    const int bh = (h + bands - 1) / bands;
    const int b = next_band_ % bands;
    next_band_ = (b + 1) % bands;
    const int y0 = std::max(0, b * bh - kBandOverlapPx / 2);
    const int y1 = std::min(h, (b + 1) * bh + kBandOverlapPx / 2);
    auto t1 = std::chrono::steady_clock::now();
    cnt_.far_tags += Run(img, w, y1 - y0, stride, cfg_.far_min_tag_px, 0, y0, true, out);
    const double ms = Ms(t1);
    cnt_.sweep_ms += ms;
    ++cnt_.sweeps;
    const double cost = cfg_.fixed_sweep_ms > 0 ? cfg_.fixed_sweep_ms : ms;
    const double gap_us = std::max(1e6 / cfg_.sweeps_per_s, kGuardFactor * cost * 1000);
    next_sweep_us_ = now_us + static_cast<int64_t>(gap_us);
  }
  UpdateTracks(now_us, out);
  return out;
}

bool Detector::Begin(const uint8_t *img, int w, int h, int stride, int64_t now_us) {
  std::lock_guard<std::mutex> l(mu_);
  s_ok_ = false;
  if (!det_ || !img || w <= 0 || h <= 0) return false;
  if (!stream_ && !(stream_ = napa_stream_create(det_))) return false;
  s_img_ = img, s_w_ = w, s_h_ = h, s_stride_ = stride, s_now_ = now_us;
  s_base_ms_ = s_sweep_ms_ = 0;
  auto t0 = std::chrono::steady_clock::now();
  napa_set_early_slack(det_, cfg_.early_slack);
  napa_params p{cfg_.far ? cfg_.base_min_tag_px : cfg_.min_tag_px, cfg_.max_hamming, cfg_.min_contrast,
                cfg_.min_border_cells, cfg_.sharpening_x100};
  if (napa_stream_begin(stream_, img, w, h, stride, &p) != 0) return false;
  s_base_ms_ += Ms(t0);
  s_sweep_ = false;
  if (cfg_.far && cfg_.sweep_bands > 0 && cfg_.sweeps_per_s > 0 && now_us >= next_sweep_us_) {
    const int bands = cfg_.sweep_bands;
    const int bh = (h + bands - 1) / bands;
    const int b = next_band_ % bands;
    next_band_ = (b + 1) % bands;
    s_y0_ = std::max(0, b * bh - kBandOverlapPx / 2);
    s_y1_ = std::min(h, (b + 1) * bh + kBandOverlapPx / 2);
    if (!sweep_det_) sweep_det_ = napa_create_family(family_.c_str());
    if (sweep_det_ && !sweep_stream_) sweep_stream_ = napa_stream_create(sweep_det_);
    if (!sweep_stream_) return false;
    auto t1 = std::chrono::steady_clock::now();
    napa_set_early_slack(sweep_det_, cfg_.early_slack);
    napa_params q{cfg_.far_min_tag_px, cfg_.max_hamming, cfg_.min_contrast, cfg_.min_border_cells,
                  cfg_.sharpening_x100};
    if (napa_stream_begin(sweep_stream_, img + static_cast<size_t>(s_y0_) * stride, w, s_y1_ - s_y0_, stride, &q) != 0)
      return false;
    s_sweep_ = true;
    s_sweep_ms_ += Ms(t1);
  }
  s_ok_ = true;
  return true;
}

void Detector::Feed(int rows) {
  std::lock_guard<std::mutex> l(mu_);
  if (!s_ok_) return;
  auto t0 = std::chrono::steady_clock::now();
  napa_stream_feed(stream_, rows);
  s_base_ms_ += Ms(t0);
  if (s_sweep_ && rows > s_y0_) {
    auto t1 = std::chrono::steady_clock::now();
    napa_stream_feed(sweep_stream_, std::min(rows, s_y1_) - s_y0_);
    s_sweep_ms_ += Ms(t1);
  }
}

std::vector<Tag> Detector::Finish() {
  std::lock_guard<std::mutex> l(mu_);
  std::vector<Tag> out;
  if (!s_ok_) return out;
  s_ok_ = false;
  ++cnt_.frames;
  napa_detection d[kMaxOut];
  auto t0 = std::chrono::steady_clock::now();
  int n = napa_stream_finish(stream_, d, kMaxOut);
  Merge(d, n, 0, 0, false, out);
  cnt_.base_ms += s_base_ms_ + Ms(t0);
  if (!cfg_.far) return out;
  Crops(s_img_, s_w_, s_h_, s_stride_, s_now_, out);
  if (s_sweep_) {
    auto t1 = std::chrono::steady_clock::now();
    n = napa_stream_finish(sweep_stream_, d, kMaxOut);
    cnt_.far_tags += Merge(d, n, 0, s_y0_, true, out);
    const double ms = s_sweep_ms_ + Ms(t1);
    cnt_.sweep_ms += ms;
    ++cnt_.sweeps;
    const double cost = cfg_.fixed_sweep_ms > 0 ? cfg_.fixed_sweep_ms : ms;
    const double gap_us = std::max(1e6 / cfg_.sweeps_per_s, kGuardFactor * cost * 1000);
    next_sweep_us_ = s_now_ + static_cast<int64_t>(gap_us);
  }
  UpdateTracks(s_now_, out);
  return out;
}

int Detector::StreamInfo(long *reruns, int *lag_rows, int max) {
  std::lock_guard<std::mutex> l(mu_);
  napa_stream_stats st{};
  napa_stream_get_stats(stream_, &st);
  if (reruns) *reruns = st.reruns;
  return stream_ ? napa_stream_lag(stream_, lag_rows, max) : 0;
}

}  // namespace napa_far
