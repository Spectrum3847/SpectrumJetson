// SpectrumJetson napa-stream: streaming NAPA (patches/napa-03-streaming.patch) against whole-frame NAPA on a
// Rewind session. Uses detector/napa/napa_far (what PhotonVision runs): Detect() for the whole frame,
// Begin()/Feed()/Finish() for the stream.
//
//   napa_stream_replay SESSION_DIR [--config min16|far] [--mode identity|timing] [--band ROWS]
//                      [--frame-ms MS] [--out STREAM.csv] [--out-whole WHOLE.csv] [--times T.csv]
//                      [--max-frames N] [--every N]
// --config min16: one pass at min_tag_px 16. far: base 32 every frame + crops and sweep bands at 16
//   (fixed sweep cost 0.5 ms so runs repeat), as tests/napa-eval's napafar.
// --mode identity: every camera's frames in order (one thread per camera), fed in --band row bands
//   (default 8) with no pacing; each frame's stream result is compared with Detect()'s, field by field and
//   bit for bit (corners as doubles). Prints the mismatch count and stream reruns.
// --mode timing: one thread; per frame, Detect() (timed), then the stream with the bands arriving evenly
//   over --frame-ms (default 8: the camera's readout), spinning until each band's arrival. --times gets one
//   row per frame: camera,frame,whole_ms,stream_cpu_ms,tail_ms,behind_ms,ntags,reruns,lag0..lag3 where
//   tail is from the last band's arrival to Finish() returning, behind how late the last Feed() started
//   after its band arrived, and lagN level N's rows still to threshold when the last band arrived.
// CSVs: as tests/napa-eval/napa_replay (margin >= 15, one per id, AprilTag order and convention), for
// tests/napa-profile/same.py.
#include <time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "napa/napa_far.h"
#include "rewind_reader.h"

extern "C" {
#include "napa_core.h"
}

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

static double CpuMs() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static napa_far::Config MakeConfig(const std::string &config) {
  napa_far::Config c;
  c.max_hamming = 1, c.min_contrast = 20, c.min_border_cells = 22;
  if (config == "far") {
    c.far = true, c.base_min_tag_px = 32, c.far_min_tag_px = 16, c.sweep_bands = 4, c.sweeps_per_s = 60;
    c.fixed_sweep_ms = 0.5;
  } else {
    c.min_tag_px = 16;
  }
  return c;
}

static bool Same(const std::vector<napa_far::Tag> &a, const std::vector<napa_far::Tag> &b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (a[i].id != b[i].id || a[i].hamming != b[i].hamming || a[i].far != b[i].far) return false;
    if (std::memcmp(&a[i].margin, &b[i].margin, sizeof(float))) return false;
    if (std::memcmp(a[i].p.data(), b[i].p.data(), sizeof(double) * 8)) return false;
  }
  return true;
}

static void WriteRows(std::ostream &out, const std::string &cam, const recording::Frame &f,
                      const std::vector<napa_far::Tag> &tags) {
  std::vector<int> seen;
  for (const auto &t : tags) {
    if (t.margin < 15) continue;
    if (std::find(seen.begin(), seen.end(), t.id) != seen.end()) continue;
    seen.push_back(t.id);
    double p[8];
    for (int k = 0; k < 8; ++k) p[k] = t.p[k] + 0.5;
    double side = 0;
    for (int k = 0; k < 4; ++k) side += std::hypot(p[2 * k] - p[2 * ((k + 1) % 4)], p[2 * k + 1] - p[2 * ((k + 1) % 4) + 1]);
    out << cam << ',' << f.index << ',' << f.jetson_us << ',' << t.id << ',' << t.margin << ',' << side / 4
        << (t.far ? ",far" : ",normal");
    for (double v : p) out << ',' << v;
    out << '\n';
  }
}

static double Pct(std::vector<double> v, double q) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, static_cast<size_t>(q * (v.size() - 1) + 0.5))];
}

int main(int argc, char **argv) {
  if (argc < 2) {
    std::cerr << "usage: napa_stream_replay SESSION_DIR [--config min16|far] [--mode identity|timing] [--band ROWS]"
                 " [--frame-ms MS] [--out S.csv] [--out-whole W.csv] [--times T.csv] [--max-frames N] [--every N]\n";
    return 2;
  }
  const fs::path session = fs::path(argv[1]).lexically_normal();
  std::string config = "min16", mode = "identity", out_path, whole_path, times_path;
  int band = 8, every = 1;
  double frame_ms = 8;
  long max_frames = -1;
  for (int i = 2; i < argc; ++i) {
    const std::string a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (a == "--config") config = v, ++i;
    else if (a == "--mode") mode = v, ++i;
    else if (a == "--band") band = std::max(1, std::atoi(v)), ++i;
    else if (a == "--frame-ms") frame_ms = std::atof(v), ++i;
    else if (a == "--out") out_path = v, ++i;
    else if (a == "--out-whole") whole_path = v, ++i;
    else if (a == "--times") times_path = v, ++i;
    else if (a == "--max-frames") max_frames = std::atol(v), ++i;
    else if (a == "--every") every = std::max(1, std::atoi(v)), ++i;
    else {
      std::cerr << "unknown option " << a << "\n";
      return 2;
    }
  }
  if ((config != "min16" && config != "far") || (mode != "identity" && mode != "timing")) {
    std::cerr << "--config min16|far, --mode identity|timing\n";
    return 2;
  }
  std::vector<std::string> cams;
  for (auto &e : fs::directory_iterator(session))
    if (e.is_directory()) cams.push_back(e.path().filename().string());
  std::sort(cams.begin(), cams.end());
  std::map<std::string, std::vector<recording::Frame>> frames;
  for (auto &c : cams) {
    auto fr = recording::ReadIndex(session / c);
    long n = 0;
    for (size_t i = 0; i < fr.size(); i += every) {
      if (max_frames >= 0 && n >= max_frames) break;
      frames[c].push_back(fr[i]), ++n;
    }
  }
  std::ofstream out, whole, times;
  const char *hdr = "camera,frame,jetson_us,id,margin,side_px,source,x0,y0,x1,y1,x2,y2,x3,y3\n";
  if (!out_path.empty()) out.open(out_path), out << hdr;
  if (!whole_path.empty()) whole.open(whole_path), whole << hdr;
  if (!times_path.empty()) {
    times.open(times_path);
    times << "camera,frame,whole_ms,stream_cpu_ms,tail_ms,behind_ms,ntags,reruns,lag0,lag1,lag2,lag3\n";
  }
  std::mutex io;
  std::atomic<long> nframes{0}, mismatches{0}, sightings{0}, reruns{0};
  std::vector<double> tails, cpu_stream, cpu_whole, behinds;

  auto run_camera = [&](const std::string &cam) {
    napa_far::Detector wd("tag36h11"), sd("tag36h11");
    wd.SetConfig(MakeConfig(config));
    sd.SetConfig(MakeConfig(config));
    std::vector<unsigned char> jpeg;
    std::vector<uint8_t> g;
    long last_reruns = 0;
    for (const auto &f : frames[cam]) {
      if (!recording::ReadJpeg(f, jpeg) || !recording::DecodeGray(jpeg, g, f.width, f.height)) continue;
      const int w = f.width, h = f.height;
      double c0 = CpuMs();
      auto a = wd.Detect(g.data(), w, h, w, f.jetson_us);
      const double whole_ms = CpuMs() - c0;
      double tail = 0, behind = 0, scpu = 0;
      std::vector<napa_far::Tag> b;
      if (mode == "identity") {
        sd.Begin(g.data(), w, h, w, f.jetson_us);
        for (int r = band; r < h + band; r += band) sd.Feed(std::min(r, h));
        b = sd.Finish();
      } else {
        const int nb = (h + band - 1) / band;
        const auto t0 = Clock::now();
        const double c1 = CpuMs();
        sd.Begin(g.data(), w, h, w, f.jetson_us);
        scpu += CpuMs() - c1;
        Clock::time_point arrival;
        for (int k = 0; k < nb; ++k) {
          arrival = t0 + std::chrono::nanoseconds(static_cast<long>((k + 1) * frame_ms * 1e6 / nb));
          while (Clock::now() < arrival) {
          }
          if (k == nb - 1) behind = std::chrono::duration<double, std::milli>(Clock::now() - arrival).count();
          const double s0 = CpuMs();
          sd.Feed(std::min((k + 1) * band, h));
          scpu += CpuMs() - s0;
        }
        const double s0 = CpuMs();
        b = sd.Finish();
        scpu += CpuMs() - s0;
        tail = std::chrono::duration<double, std::milli>(Clock::now() - arrival).count();
      }
      const bool same = Same(a, b);
      std::lock_guard<std::mutex> l(io);
      ++nframes;
      if (!same) {
        if (mismatches < 20)
          std::fprintf(stderr, "MISMATCH %s frame %d: whole %zu tags, stream %zu\n", cam.c_str(), f.index, a.size(),
                       b.size());
        ++mismatches;
      }
      if (out.is_open()) WriteRows(out, cam, f, b);
      if (whole.is_open()) WriteRows(whole, cam, f, a);
      for (const auto &t : a) sightings += t.margin >= 15;
      if (mode == "timing") {
        tails.push_back(tail), cpu_stream.push_back(scpu), cpu_whole.push_back(whole_ms), behinds.push_back(behind);
      }
      long rr = 0;
      int lag[4] = {-1, -1, -1, -1};
      sd.StreamInfo(&rr, lag, 4);
      reruns += rr - last_reruns;
      if (times.is_open()) {
        times << cam << ',' << f.index << ',' << whole_ms << ',' << scpu << ',' << tail << ',' << behind << ','
              << a.size() << ',' << rr - last_reruns;
        for (int v : lag) times << ',' << v;
        times << '\n';
      }
      last_reruns = rr;
    }
  };
  const auto t_start = Clock::now();
  if (mode == "identity") {
    std::vector<std::thread> th;
    for (auto &c : cams) th.emplace_back(run_camera, c);
    for (auto &t : th) t.join();
  } else {
    for (auto &c : cams) run_camera(c);
  }
  const double wall = std::chrono::duration<double>(Clock::now() - t_start).count();
  std::printf("%s: %zu cameras, %ld frames, config %s, mode %s, band %d\n", session.filename().c_str(), cams.size(),
              nframes.load(), config.c_str(), mode.c_str(), band);
  std::printf("Whole-frame sightings (margin >= 15): %ld; stream mismatches: %ld frames; base-stream reruns %ld\n",
              sightings.load(), mismatches.load(), reruns.load());
  if (mode == "timing") {
    auto mean = [](const std::vector<double> &v) {
      double s = 0;
      for (double x : v) s += x;
      return v.empty() ? 0 : s / v.size();
    };
    std::printf("whole ms p50/p95/p99/mean %.3f %.3f %.3f %.3f\n", Pct(cpu_whole, .5), Pct(cpu_whole, .95),
                Pct(cpu_whole, .99), mean(cpu_whole));
    std::printf("tail ms p50/p95/p99/mean %.3f %.3f %.3f %.3f\n", Pct(tails, .5), Pct(tails, .95), Pct(tails, .99),
                mean(tails));
    std::printf("stream cpu ms p50/p95/p99/mean %.3f %.3f %.3f %.3f\n", Pct(cpu_stream, .5), Pct(cpu_stream, .95),
                Pct(cpu_stream, .99), mean(cpu_stream));
    std::printf("behind ms p50/p99 %.3f %.3f\n", Pct(behinds, .5), Pct(behinds, .99));
  }
  std::printf("%s\n", mismatches ? "DIFFERENT" : "IDENTICAL");
  std::printf("Time: replay took %.0f s\n", wall);
  return mismatches ? 1 : 0;
}
