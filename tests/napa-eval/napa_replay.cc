// SpectrumJetson napa-eval: NAPA (github.com/zwatx/NAPA) or AprilTag 3 (CPU) on a Rewind session, writing
// the same CSV as detector-replay so tests/field-replay/{analyze.py,accuracy/judge.py} can score it.
//
//   napa_replay SESSION_DIR --backend napa|at3 [--out OUT.csv] [--times T.csv] [--log] [--min-tag N]
//               [--hamming N] [--contrast N] [--border N] [--decimate D] [--nthreads N] [--parallel P]
//               [--every N] [--max-frames N] [--tile-stats]
//               [--base-min N] [--far-min N] [--bands N] [--sweeps S] [--fixed-sweep-ms MS]
// --backend napafar: detector/napa/napa_far.cc with its far search on (base pass --base-min 32 every frame,
//   crops and sweep bands at --far-min 16), one detector per camera fed that camera's frames in order with
//   their recording times; the time guard uses --fixed-sweep-ms (0.5) so runs repeat. Rows found by crops
//   or sweeps have source "far".
//
// Frames: every frame of each camera folder, decoded to gray with libjpeg-turbo exactly as detector-replay
// (detector/rewind_reader.h); frame numbers match detector-replay's. Decode is not timed.
// --backend napa: napa_detect with min_tag_px --min-tag (default 32, NAPA's default), max_hamming
//   --hamming (default 1, as our GPU detector), min_contrast --contrast (20), min_border_cells --border (22),
//   sharpening 0.25. Corners: NAPA reports OpenCV order in pixel-centre coordinates; written in AprilTag's
//   order and convention (+0.5) as detector-replay writes them.
// --backend at3: AprilTag 3 (apriltag-src), tag36h11 with 1 corrected bit (as the GPU detector), quad_decimate
//   --decimate (default 2), nthreads --nthreads (1), refine_edges 1, decode_sharpening 0.25, blur 0
//   (PhotonVision's AprilTagPipeline settings apart from threads/decimate).
// Rows with decision margin < 15 are dropped (as detector-replay, PhotonVision's floor).
// --parallel P: P worker threads, each with its own detector, take frames from a shared queue (P cameras on
//   one CPU); --times gets one row per frame: camera,frame,ms,ntags.
// --tile-stats: per frame, the fraction of 4x4 tiles of the half-res (2x2 mean) frame whose 3x3-tile
//   neighbourhood has max - min >= 20 (the GPU detector's threshold test, mwbd 20), and of NAPA's base-level
//   tiles that are not flat (napa_stats.c build only); written to --times as extra columns.
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "napa/napa_far.h"
#include "rewind_reader.h"

extern "C" {
#include "apriltag.h"
#include "napa_core.h"
#include "tag36h11.h"
#ifdef NAPA_STATS
extern __thread long napa_stat_tot[8], napa_stat_act[8];
#endif
}

namespace fs = std::filesystem;

struct Det {
  int id;
  double margin;
  double p[8];
  bool far = false;
  double side() const {
    double s = 0;
    for (int k = 0; k < 4; ++k) s += std::hypot(p[2 * k] - p[2 * ((k + 1) % 4)], p[2 * k + 1] - p[2 * ((k + 1) % 4) + 1]);
    return s / 4;
  }
};

struct Opts {
  std::string backend = "napa";
  int min_tag = 32, hamming = 1, contrast = 20, border = 22, nthreads = 1;
  double decimate = 2;
  bool tile_stats = false;
  // --backend napafar: detector/napa/napa_far (what PhotonVision's NAPA backend runs), far search on.
  int base_min = 32, far_min = 16, bands = 4;
  double sweeps = 60, fixed_sweep_ms = 0.5;
};

struct Worker {
  Opts o;
  napa_detector *napa = nullptr;
  apriltag_detector_t *td = nullptr;
  apriltag_family_t *tf = nullptr;
  std::map<std::string, std::unique_ptr<napa_far::Detector>> far;  // napafar: one per camera, as live
  explicit Worker(const Opts &opts) : o(opts) {
    if (o.backend == "napafar") {
    } else if (o.backend == "napa") {
      napa = napa_create();
    } else {
      td = apriltag_detector_create();
      tf = tag36h11_create();
      apriltag_detector_add_family_bits(td, tf, 1);
      td->quad_decimate = static_cast<float>(o.decimate);
      td->quad_sigma = 0;
      td->nthreads = o.nthreads;
      td->refine_edges = true;
      td->decode_sharpening = 0.25;
    }
  }
  ~Worker() {
    if (napa) napa_destroy(napa);
    if (td) {
      apriltag_detector_destroy(td);
      tag36h11_destroy(tf);
    }
  }
  std::vector<Det> Detect(std::vector<uint8_t> &g, int w, int h, const std::string &cam = "", int64_t us = 0) {
    std::vector<Det> out;
    if (o.backend == "napafar") {
      auto &d = far[cam];
      if (!d) {
        d.reset(new napa_far::Detector("tag36h11"));
        napa_far::Config c;
        c.max_hamming = o.hamming, c.min_contrast = o.contrast, c.min_border_cells = o.border;
        c.far = true, c.base_min_tag_px = o.base_min, c.far_min_tag_px = o.far_min, c.sweep_bands = o.bands;
        c.sweeps_per_s = o.sweeps, c.fixed_sweep_ms = o.fixed_sweep_ms;
        d->SetConfig(c);
      }
      for (const auto &t : d->Detect(g.data(), w, h, w, us)) {
        Det e{t.id, t.margin, {}, t.far};
        for (int k = 0; k < 8; ++k) e.p[k] = t.p[k] + 0.5;  // to AprilTag's convention, as detector-replay
        out.push_back(e);
      }
    } else if (napa) {
      napa_params p{o.min_tag, o.hamming, o.contrast, o.border, 25};
      napa_detection d[128];
      const int n = napa_detect(napa, g.data(), w, h, w, &p, d, 128);
      for (int i = 0; i < n; ++i) {
        Det e{d[i].id, d[i].decision_margin, {}};
        // NAPA: OpenCV corner order, pixel centres at integers. To AprilTag's order and convention (pixel
        // centres at +0.5): the permutation was found empirically against the GPU detector on TXMAN1 Q17
        // (the only one of the 24 orderings with a median corner difference under 5 px: 0.11 px).
        static const int perm[4] = {1, 0, 3, 2};
        for (int k = 0; k < 4; ++k) {
          e.p[2 * k] = d[i].corners[2 * perm[k]] + 0.5;
          e.p[2 * k + 1] = d[i].corners[2 * perm[k] + 1] + 0.5;
        }
        out.push_back(e);
      }
    } else {
      image_u8_t im{w, h, w, g.data()};
      zarray_t *z = apriltag_detector_detect(td, &im);
      for (int i = 0; i < zarray_size(z); ++i) {
        apriltag_detection_t *d;
        zarray_get(z, i, &d);
        Det e{d->id, d->decision_margin, {}};
        for (int k = 0; k < 4; ++k) e.p[2 * k] = d->p[k][0], e.p[2 * k + 1] = d->p[k][1];
        out.push_back(e);
      }
      apriltag_detections_destroy(z);
    }
    return out;
  }
};

// Fraction of 4x4 tiles (of the 2x2-mean half-res frame) whose 3x3-tile neighbourhood range >= mwbd.
static double GpuActiveTiles(const std::vector<uint8_t> &g, int w, int h, int mwbd) {
  const int w2 = w / 2, h2 = h / 2, tw = w2 / 4, th = h2 / 4;
  std::vector<uint8_t> lo(tw * th, 255), hi(tw * th, 0);
  for (int y = 0; y < th * 4; ++y)
    for (int x = 0; x < tw * 4; ++x) {
      const uint8_t *s = g.data() + static_cast<size_t>(2 * y) * w + 2 * x;
      const uint8_t v = static_cast<uint8_t>((s[0] + s[1] + s[w] + s[w + 1] + 2) / 4);
      const int t = (y / 4) * tw + x / 4;
      if (v < lo[t]) lo[t] = v;
      if (v > hi[t]) hi[t] = v;
    }
  long act = 0;
  for (int ty = 0; ty < th; ++ty)
    for (int tx = 0; tx < tw; ++tx) {
      int l = 255, m = 0;
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const int yy = std::min(th - 1, std::max(0, ty + dy)), xx = std::min(tw - 1, std::max(0, tx + dx));
          l = std::min<int>(l, lo[yy * tw + xx]);
          m = std::max<int>(m, hi[yy * tw + xx]);
        }
      act += (m - l >= mwbd);
    }
  return static_cast<double>(act) / (tw * th);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    std::cerr << "usage: napa_replay SESSION_DIR --backend napa|at3 [--out OUT.csv] [--times T.csv] [--min-tag N]"
                 " [--hamming N] [--contrast N] [--border N] [--decimate D] [--nthreads N] [--parallel P]"
                 " [--every N] [--max-frames N] [--tile-stats]\n";
    return 2;
  }
  const fs::path session = fs::path(argv[1]).lexically_normal();
  Opts o;
  std::string out_path, times_path;
  int parallel = 1, every = 1;
  long max_frames = -1;
  for (int i = 2; i < argc; ++i) {
    const std::string a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (a == "--backend") o.backend = v, ++i;
    else if (a == "--out") out_path = v, ++i;
    else if (a == "--times") times_path = v, ++i;
    else if (a == "--min-tag") o.min_tag = std::atoi(v), ++i;
    else if (a == "--hamming") o.hamming = std::atoi(v), ++i;
    else if (a == "--contrast") o.contrast = std::atoi(v), ++i;
    else if (a == "--border") o.border = std::atoi(v), ++i;
    else if (a == "--decimate") o.decimate = std::atof(v), ++i;
    else if (a == "--nthreads") o.nthreads = std::atoi(v), ++i;
    else if (a == "--parallel") parallel = std::max(1, std::atoi(v)), ++i;
    else if (a == "--every") every = std::max(1, std::atoi(v)), ++i;
    else if (a == "--max-frames") max_frames = std::atol(v), ++i;
    else if (a == "--tile-stats") o.tile_stats = true;
    else if (a == "--base-min") o.base_min = std::atoi(v), ++i;
    else if (a == "--far-min") o.far_min = std::atoi(v), ++i;
    else if (a == "--bands") o.bands = std::atoi(v), ++i;
    else if (a == "--sweeps") o.sweeps = std::atof(v), ++i;
    else if (a == "--fixed-sweep-ms") o.fixed_sweep_ms = std::atof(v), ++i;
    else {
      std::cerr << "unknown option " << a << "\n";
      return 2;
    }
  }
  if (o.backend != "napa" && o.backend != "at3" && o.backend != "napafar") {
    std::cerr << "--backend napa, napafar or at3\n";
    return 2;
  }
  struct Item {
    std::string cam;
    recording::Frame f;
  };
  std::vector<Item> items;
  std::vector<std::string> cams;
  for (auto &e : fs::directory_iterator(session))
    if (e.is_directory()) cams.push_back(e.path().filename().string());
  std::sort(cams.begin(), cams.end());
  for (auto &c : cams) {
    auto fr = recording::ReadIndex(session / c);
    long n = 0;
    for (size_t i = 0; i < fr.size(); i += every) {
      if (max_frames >= 0 && n >= max_frames) break;
      items.push_back({c, fr[i]}), ++n;
    }
  }
  std::ofstream out, times;
  if (!out_path.empty()) {
    out.open(out_path);
    out << "camera,frame,jetson_us,id,margin,side_px,source,x0,y0,x1,y1,x2,y2,x3,y3\n";
  }
  if (!times_path.empty()) {
    times.open(times_path);
    times << "camera,frame,ms,ntags" << (o.tile_stats ? ",gpu_active,napa_active0,napa_active1" : "") << "\n";
  }
  std::map<std::string, int> cam_index;
  for (size_t i = 0; i < cams.size(); ++i) cam_index[cams[i]] = static_cast<int>(i);
  std::vector<std::unique_ptr<Worker>> workers;
  for (int i = 0; i < parallel; ++i) workers.emplace_back(new Worker(o));

  const size_t chunk = 64;
  double total_ms = 0;
  long sightings = 0, done = 0;
  const auto t_start = std::chrono::steady_clock::now();
  struct Res {
    std::vector<Det> d;
    double ms = 0, gpu = -1, n0 = -1, n1 = -1;
    bool ok = false;
  };
  for (size_t c0 = 0; c0 < items.size(); c0 += chunk) {
    const size_t n = std::min(chunk, items.size() - c0);
    std::vector<std::vector<uint8_t>> gray(n);
    std::vector<char> ok(n, 0);
    {
      std::atomic<size_t> next{0};
      std::vector<std::thread> th;
      for (int t = 0; t < 4; ++t)  // decode in parallel (untimed)
        th.emplace_back([&] {
          std::vector<unsigned char> jpeg;
          for (size_t k; (k = next++) < n;) {
            const auto &f = items[c0 + k].f;
            ok[k] = recording::ReadJpeg(f, jpeg) && recording::DecodeGray(jpeg, gray[k], f.width, f.height);
          }
        });
      for (auto &t : th) t.join();
    }
    std::vector<Res> res(n);
    std::atomic<size_t> next{0};
    std::vector<std::thread> th;
    const bool per_cam = o.backend == "napafar";  // far search keeps state: each camera's frames in order
    for (int t = 0; t < parallel; ++t)
      th.emplace_back([&, t] {
        size_t own = 0;
        for (size_t k; (k = per_cam ? own++ : next++) < n;) {
          if (per_cam && cam_index.at(items[c0 + k].cam) % parallel != t) continue;
          if (!ok[k]) continue;
          const auto &f = items[c0 + k].f;
#ifdef NAPA_STATS
          for (int l = 0; l < 8; ++l) napa_stat_tot[l] = napa_stat_act[l] = 0;
#endif
          const auto a = std::chrono::steady_clock::now();
          res[k].d = workers[t]->Detect(gray[k], f.width, f.height, items[c0 + k].cam, f.jetson_us);
          res[k].ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - a).count();
          res[k].ok = true;
#ifdef NAPA_STATS
          if (napa_stat_tot[0]) res[k].n0 = static_cast<double>(napa_stat_act[0]) / napa_stat_tot[0];
          if (napa_stat_tot[1]) res[k].n1 = static_cast<double>(napa_stat_act[1]) / napa_stat_tot[1];
#endif
          if (o.tile_stats) res[k].gpu = GpuActiveTiles(gray[k], f.width, f.height, 20);
        }
      });
    for (auto &t : th) t.join();
    for (size_t k = 0; k < n; ++k) {
      if (!res[k].ok) continue;
      const auto &it = items[c0 + k];
      total_ms += res[k].ms, ++done;
      std::vector<int> seen;
      int kept = 0;
      for (const auto &d : res[k].d) {
        if (d.margin < 15) continue;
        if (std::find(seen.begin(), seen.end(), d.id) != seen.end()) continue;  // one per id per frame
        seen.push_back(d.id), ++kept;
        if (out.is_open()) {
          out << it.cam << ',' << it.f.index << ',' << it.f.jetson_us << ',' << d.id << ',' << d.margin << ','
              << d.side() << (d.far ? ",far" : ",normal");
          for (double v : d.p) out << ',' << v;
          out << '\n';
        }
      }
      sightings += kept;
      if (times.is_open()) {
        times << it.cam << ',' << it.f.index << ',' << res[k].ms << ',' << kept;
        if (o.tile_stats) times << ',' << res[k].gpu << ',' << res[k].n0 << ',' << res[k].n1;
        times << '\n';
      }
    }
  }
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
  std::printf("%s: %zu cameras, %ld frames; backend %s\n", session.filename().c_str(), cams.size(), done,
              o.backend.c_str());
  std::printf("Total: %ld sightings\n", sightings);
  std::printf("Time: detect %.2f ms a frame, far search 0.00 ms a frame on average; replay took %.0f s\n",
              done ? total_ms / done : 0.0, wall);
  return 0;
}
