// SpectrumJetson: self-test for napa_far (detector/napa): renders tag36h11 tags with NAPA's own codes and
// checks ids, corner order/convention, homography and the far search's crops/sweeps. Exits non-zero on
// failure. Built and run by scripts/jetson/07-build-napa-detector.sh (x86_64 or aarch64).
#include <cmath>
#include <cstdio>
#include <vector>

#include "napa_far.h"
extern "C" {
#include "napa_core.h"
}

static int fails = 0;
#define CHECK(c, ...)                         \
  do {                                        \
    if (!(c)) {                               \
      std::printf("FAIL %s: ", #c);           \
      std::printf(__VA_ARGS__);               \
      std::printf("\n");                      \
      ++fails;                                \
    }                                         \
  } while (0)

// Draws tag `id` axis-aligned with its black square's outer corners at (x, y) .. (x + s, y + s) in OpenCV
// coordinates (pixel centres at integers), oriented as the official artwork (NAPA's grid turned 180 deg).
static void Draw(std::vector<uint8_t> &img, int W, int id, double x, double y, double s) {
  uint64_t code = 0;
  napa_tag36h11_code(id, &code);
  const double cell = s / 8;
  for (int py = static_cast<int>(y - 2 * cell); py < y + s + 2 * cell; ++py)
    for (int px = static_cast<int>(x - 2 * cell); px < x + s + 2 * cell; ++px) {
      // Supersample 4x4.
      int acc = 0;
      for (int sy = 0; sy < 4; ++sy)
        for (int sx = 0; sx < 4; ++sx) {
          const double u = (px - 0.5 + (sx + 0.5) / 4 - x) / cell, v = (py - 0.5 + (sy + 0.5) / 4 - y) / cell;
          int white = 1;
          if (u >= 0 && u < 8 && v >= 0 && v < 8) {
            const int cx = static_cast<int>(u), cy = static_cast<int>(v);
            if (cx == 0 || cy == 0 || cx == 7 || cy == 7) {
              white = 0;
            } else {
              // NAPA's grid: row-major 6x6, MSB first, OpenCV orientation = artwork turned 180 deg.
              const int gx = 6 - cx, gy = 6 - cy;  // turn 180
              const int bit = 35 - (gy * 6 + gx);
              white = (code >> bit) & 1;
            }
          }
          acc += white ? 230 : 25;
        }
      if (px >= 0 && py >= 0 && px < W) img[static_cast<size_t>(py) * W + px] = static_cast<uint8_t>(acc / 16);
    }
}

int main() {
  const int W = 1280, H = 800;
  std::vector<uint8_t> img(W * H, 128);
  Draw(img, W, 7, 200, 150, 120);   // big
  Draw(img, W, 23, 900, 600, 22);   // small: missed at min 64, found at min 16
  napa_far::Detector d("tag36h11");
  CHECK(d.ok(), "create");
  napa_far::Config c;
  c.min_tag_px = 16;
  d.SetConfig(c);
  auto tags = d.Detect(img.data(), W, H, W, 0);
  const napa_far::Tag *big = nullptr;
  for (auto &t : tags)
    if (t.id == 7) big = &t;
  CHECK(tags.size() == 2, "min16 found %zu tags", tags.size());
  CHECK(big, "tag 7 found");
  if (big) {
    // The drawn tag is upright as printed, so AprilTag's p0 (-1,1) is bottom-left, p1 bottom-right, p2
    // top-right, p3 top-left (image y down).
    const double ex[8] = {200, 270, 320, 270, 320, 150, 200, 150};
    double emax = 0;
    for (int k = 0; k < 8; ++k) emax = std::max(emax, std::fabs(big->p[k] - ex[k]));
    std::printf("tag 7 corners:");
    for (double v : big->p) std::printf(" %.2f", v);
    std::printf("  (max error %.3f px)\n", emax);
    CHECK(emax < 0.6, "corner error %.3f", emax);
    const auto Hm = big->Homography();
    const double cx = Hm[2] / Hm[8], cy = Hm[5] / Hm[8];
    CHECK(std::fabs(cx - 260) < 0.6 && std::fabs(cy - 210) < 0.6, "centre %.2f %.2f", cx, cy);
    const double w = Hm[6] * -1 + Hm[7] * 1 + Hm[8];
    const double u = (Hm[0] * -1 + Hm[1] * 1 + Hm[2]) / w, v = (Hm[3] * -1 + Hm[4] * 1 + Hm[5]) / w;
    CHECK(std::fabs(u - big->p[0]) < 1e-6 && std::fabs(v - big->p[1]) < 1e-6, "H(-1,1) = p0");
  }
  // Rendered tags are clean: NAPA finds the 22 px one even at min 32, so the far test uses a base pass of
  // min 64, which misses it.
  c.min_tag_px = 64;
  d.SetConfig(c);
  tags = d.Detect(img.data(), W, H, W, 0);
  CHECK(tags.size() == 1, "min64 found %zu tags (expected only the big one)", tags.size());
  c.far = true;
  c.base_min_tag_px = 64;
  c.sweep_bands = 4;
  c.sweeps_per_s = 1000;
  d.SetConfig(c);
  int found_far = 0;
  for (int f = 0; f < 8; ++f) {
    tags = d.Detect(img.data(), W, H, W, f * 8000);
    for (auto &t : tags) found_far += t.id == 23 && t.far;
  }
  const auto k = d.GetCounters();
  std::printf("far: %d of 8 frames had tag 23; %ld sweeps, %ld crops\n", found_far, k.sweeps, k.crops);
  CHECK(found_far >= 4, "far search found tag 23 in %d frames", found_far);
  CHECK(k.crops > 0, "crops ran");
  std::printf(fails ? "napa_test: %d FAILED\n" : "napa_test: all passed\n", fails);
  return fails ? 1 : 0;
}
