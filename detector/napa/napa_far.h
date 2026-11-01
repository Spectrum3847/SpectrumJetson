// SpectrumJetson: NAPA (third_party/napa, Zachary Wilson, GPL-3.0-only) as a CPU AprilTag backend, with
// an optional far search. One Detector per camera; thread-safe (one call at a time per Detector, any
// number of Detectors in parallel). Shared by libspectrum-napa-apriltag.so (NapaDetectorJNI.cc) and
// tests/napa-eval/napa_replay.cc, so the replay scores exactly what PhotonVision runs.
//
// Far search off (default): one NAPA pass over the full frame at min_tag_px (16 recommended on our
// frames: tests/napa-eval/README.md).
// Far search on: the full frame at base_min_tag_px (32, ~5x cheaper than 16) every frame, and the small
// tags it misses found at far_min_tag_px (16 or 12) only where they are likely:
//  - tracking crops: around every tag smaller than track_side_px seen in the last track_ms, a crop of
//    crop_scale x its side (at least 96 px) is searched at far_min_tag_px on the next frames;
//  - capped sweeps: one horizontal band of the frame (sweep_bands of them, overlapping by 64 px) at
//    far_min_tag_px, at most sweeps_per_s bands a second, and never sooner than 5x the last band's
//    time after it (the time guard, as detector/far_search.cc; fixed_sweep_ms > 0 uses a fixed cost
//    so a replay is repeatable).
// This is a small port of far_search.cc's crop tracking / sweep scheduling / time guard; far_search.cc
// itself is tied to the 971 detector (upscaling, its detector structs, cross-camera starvation), and
// with NAPA the base pass is cheap enough to search every camera every frame.
//
// Corners are returned in AprilTag's order (p0 = tag (-1,1), p1 = (1,1), p2 = (1,-1), p3 = (-1,-1)) and
// OpenCV's pixel convention (pixel centres at integers), as PhotonVision's pose code expects and the GPU
// detector's JNI returns. NAPA reports OpenCV's corner order: the permutation {1,0,3,2} was found against
// the GPU detector on TXMAN1 (tests/napa-eval/README.md).
#pragma once

#include <array>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

struct napa_detector;

namespace napa_far {

struct Tag {
  int id = 0;
  int hamming = 0;
  float margin = 0;
  std::array<double, 8> p{};  // x0 y0 x1 y1 ... (AprilTag order, OpenCV convention)
  bool far = false;           // found by a crop or a sweep, not the base pass
  double side() const;        // mean side, px
  double cx() const { return (p[0] + p[2] + p[4] + p[6]) / 4; }
  double cy() const { return (p[1] + p[3] + p[5] + p[7]) / 4; }
  // Homography tag coordinates -> image (row-major), from the 4 corners, as AprilTag's det->H.
  std::array<double, 9> Homography() const;
};

struct Config {
  int min_tag_px = 16;  // far search off: the full-frame pass
  int max_hamming = 1;
  int min_contrast = 20;
  int min_border_cells = 22;
  int sharpening_x100 = 25;
  bool far = false;
  int base_min_tag_px = 32;
  int far_min_tag_px = 16;
  double track_side_px = 48;
  double track_ms = 500;
  double crop_scale = 6;
  int sweep_bands = 4;
  double sweeps_per_s = 60;
  double fixed_sweep_ms = 0;
  float min_margin = 0;  // drop detections below this decision margin (0: keep all)
};

struct Counters {
  long frames = 0, sweeps = 0, crops = 0, far_tags = 0;
  double base_ms = 0, sweep_ms = 0, crop_ms = 0;
};

class Detector {
 public:
  // family: NAPA's name ("tag36h11", "tag16h5", ...). ok() is false if unknown.
  explicit Detector(const std::string &family = "tag36h11");
  ~Detector();
  Detector(const Detector &) = delete;
  Detector &operator=(const Detector &) = delete;
  bool ok() const { return det_ != nullptr; }
  const std::string &family() const { return family_; }

  void SetConfig(const Config &c);
  Config GetConfig();
  Counters GetCounters();

  // 8-bit gray image, `stride` bytes a row. now_us: the frame's time (steady clock live, recording time
  // in replay); only the sweep schedule uses it. At most one tag per id (the highest margin).
  std::vector<Tag> Detect(const uint8_t *img, int width, int height, int stride, int64_t now_us);

 private:
  struct Track {
    int id;
    double cx, cy, side;
    int64_t seen_us;
  };
  int Run(const uint8_t *img, int w, int h, int stride, int min_tag, int ox, int oy, bool far,
          std::vector<Tag> &out);

  std::mutex mu_;
  napa_detector *det_ = nullptr;
  std::string family_;
  Config cfg_;
  Counters cnt_;
  std::vector<Track> tracks_;
  int next_band_ = 0;
  int64_t next_sweep_us_ = 0;
};

}  // namespace napa_far
