// SpectrumJetson systemcore-mjpeg-napa: offline bench for the SystemCore MJPEG -> luma -> streaming NAPA path,
// on Rewind sessions (real recordings or gen_synth.py's rendered ones). Built by build.sh (cross, WPILib's
// SystemCore toolchain) and run on the Pi by run.sh. Every decoder is checked against libjpeg-turbo's gray
// decode (the reference PhotonVision used before), and every detection result against whole-frame NAPA.
//
//   scmn_bench MODE SESSION_DIR [options]
// MODE:
//   decode  per frame, each decoder whole-frame (all bytes present): thread CPU ms, and luma identity vs the
//           reference (pixels that differ, max |diff|).
//   fused   per frame, the JPEG bytes arrive in --chunk byte pieces evenly over --frame-ms (as USB delivers
//           them); the decoder decodes what it can as they arrive and hands 8/16-row bands to streaming NAPA.
//           Reports the tail (last byte -> tags), CPU per frame, and tag identity vs whole-frame NAPA on the
//           reference gray. The "whole" baseline is reference decode + NAPA Detect() after the last byte.
//   fuzz    corrupt / truncated / garbage frames through every decoder (fused path, forked child with a
//           watchdog): crashes, hangs, and frames reported OK whose luma is wrong.
// options: --dec turbo,tj,stream[,builder]   decoders (default all built in)
//          --config min16|far  --frame-ms 8  --chunk 16384  --max-frames N  --every N
//          --cpu N (pin)  --fifo PRIO (SCHED_FIFO)  --times OUT.csv (per frame rows)  --seed S (fuzz)
#include <dlfcn.h>
#include <sched.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <csetjmp>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include <jpeglib.h>
#include <turbojpeg.h>

#include "napa/napa_far.h"
#include "rewind_reader.h"

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

static double CpuMs() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static double Ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }
static double Pct(std::vector<double> v, double q) {
  if (v.empty()) return NAN;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, static_cast<size_t>(q * (v.size() - 1) + 0.5))];
}
static double Mean(const std::vector<double> &v) {
  double s = 0;
  for (double x : v) s += x;
  return v.empty() ? NAN : s / v.size();
}
static std::string Stats(const std::vector<double> &v) {
  char b[160];
  std::snprintf(b, sizeof b, "%.3f / %.3f / %.3f (mean %.3f, max %.3f, n %zu)", Pct(v, .5), Pct(v, .95), Pct(v, .99),
                Mean(v), Pct(v, 1), v.size());
  return b;
}

// ---- decoders ------------------------------------------------------------------------------------------
// Feed(avail): bytes [0, avail) of the JPEG are present (more may come). Decode as far as possible into
// out, return the rows final so far (-1: error). After the last Feed (avail == size), rows must reach h.
struct Decoder {
  virtual ~Decoder() = default;
  virtual const char *Name() const = 0;
  virtual bool Begin(const uint8_t *jpeg, size_t cap, uint8_t *out, int w, int h) = 0;
  virtual int Feed(size_t avail) = 0;
  virtual void End() {}
};

struct JErr {
  jpeg_error_mgr mgr;
  std::jmp_buf jump;
};
static void ErrExit(j_common_ptr c) { std::longjmp(reinterpret_cast<JErr *>(c->err)->jump, 1); }
static void NoMessage(j_common_ptr, int) {}
static void SrcInit(j_decompress_ptr) {}
static boolean SrcFill(j_decompress_ptr) { return FALSE; }
static void SrcSkip(j_decompress_ptr d, long n) {
  auto *s = d->src;
  const size_t k = std::min(static_cast<size_t>(std::max(0L, n)), s->bytes_in_buffer);
  s->next_input_byte += k;
  s->bytes_in_buffer -= k;
}
static void SrcTerm(j_decompress_ptr) {}

// libjpeg-turbo with a suspending source: exactly detector/stream_decode.cc's watcher loop (gray, ISLOW,
// 16 scanlines a call). With all bytes present at once it is the plain whole-frame gray decode ("turbo").
struct TurboStream : Decoder {
  std::string name;
  bool whole;  // decode only once every byte is in (the pre-streaming path)
  TurboStream(const char *n, bool wh) : name(n), whole(wh) {}
  const char *Name() const override { return name.c_str(); }
  jpeg_decompress_struct d{};
  JErr err{};
  jpeg_source_mgr src{};
  size_t fed = 0;
  const uint8_t *p = nullptr;
  uint8_t *out = nullptr;
  int w = 0, h = 0, hdr = 0;
  bool live = false;
  size_t cap_ = 0;
  bool Begin(const uint8_t *jpeg, size_t cap, uint8_t *o, int ww, int hh) override {
    End();
    cap_ = cap;
    p = jpeg, out = o, w = ww, h = hh, fed = 0, hdr = 0;
    d.err = jpeg_std_error(&err.mgr);
    err.mgr.error_exit = ErrExit;
    err.mgr.emit_message = NoMessage;
    jpeg_create_decompress(&d);
    src = jpeg_source_mgr{};
    src.init_source = SrcInit;
    src.fill_input_buffer = SrcFill;
    src.skip_input_data = SrcSkip;
    src.resync_to_restart = jpeg_resync_to_restart;
    src.term_source = SrcTerm;
    src.next_input_byte = p;
    src.bytes_in_buffer = 0;
    d.src = &src;
    live = true;
    return true;
  }
  int Feed(size_t avail) override {
    if (!live) return -1;
    if (whole && avail < cap_) return 0;
    if (setjmp(err.jump)) {
      End();
      return -1;
    }
    if (avail > fed) {
      const size_t used = fed - src.bytes_in_buffer;
      fed = avail;
      src.next_input_byte = p + used;
      src.bytes_in_buffer = fed - used;
    }
    if (hdr == 0 && jpeg_read_header(&d, TRUE) == JPEG_HEADER_OK) {
      d.out_color_space = JCS_GRAYSCALE;
      d.dct_method = JDCT_ISLOW;
      hdr = 1;
    }
    if (hdr == 1 && jpeg_start_decompress(&d)) {
      if (static_cast<int>(d.output_width) != w || static_cast<int>(d.output_height) != h || d.output_components != 1) {
        End();
        return -1;
      }
      hdr = 2;
    }
    while (hdr == 2 && d.output_scanline < d.output_height) {
      JSAMPROW rows[16];
      for (int r = 0; r < 16; r++)
        rows[r] = out + static_cast<size_t>(std::min<unsigned>(d.output_scanline + r, d.output_height - 1)) * w;
      if (!jpeg_read_scanlines(&d, rows, 16)) break;
    }
    return hdr == 2 ? static_cast<int>(d.output_scanline) : 0;
  }
  void End() override {
    if (live) jpeg_destroy_decompress(&d);
    live = false;
  }
  ~TurboStream() override { End(); }
};

// TurboJPEG API (tjDecompress2 to TJPF_GRAY, accurate DCT): whole frame only (returns h at the last byte).
struct TjWhole : Decoder {
  tjhandle tj = tjInitDecompress();
  const uint8_t *p = nullptr;
  size_t cap = 0;
  uint8_t *out = nullptr;
  int w = 0, h = 0;
  const char *Name() const override { return "tj"; }
  bool Begin(const uint8_t *jpeg, size_t c, uint8_t *o, int ww, int hh) override {
    p = jpeg, cap = c, out = o, w = ww, h = hh;
    return true;
  }
  int Feed(size_t avail) override {
    if (avail < cap) return 0;
    return tjDecompress2(tj, p, static_cast<unsigned long>(cap), out, w, w, h, TJPF_GRAY, TJFLAG_ACCURATEDCT) == 0 ? h
                                                                                                                   : -1;
  }
  ~TjWhole() override { tjDestroy(tj); }
};

// The builder's decoder, loaded from a shared library at run time (SCMN_BUILDER_LIB), through this small
// C ABI (an adapter .c next to the builder's code provides it; see prototypes/README.md):
//   void *scmn_dec_create(void);  void scmn_dec_destroy(void *);
//   int scmn_dec_begin(void *, const uint8_t *jpeg, size_t cap, uint8_t *out, int w, int h);  0 ok
//   int scmn_dec_feed(void *, size_t avail);   rows final so far, -1 error
struct Builder : Decoder {
  void *lib = nullptr, *ctx = nullptr;
  void *(*create)() = nullptr;
  void (*destroy)(void *) = nullptr;
  int (*begin)(void *, const uint8_t *, size_t, uint8_t *, int, int) = nullptr;
  int (*feed)(void *, size_t) = nullptr;
  std::string name = "builder";
  bool ok = false;
  explicit Builder(const char *path) {
    lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
      std::fprintf(stderr, "builder decoder: %s\n", dlerror());
      return;
    }
    create = reinterpret_cast<void *(*)()>(dlsym(lib, "scmn_dec_create"));
    destroy = reinterpret_cast<void (*)(void *)>(dlsym(lib, "scmn_dec_destroy"));
    begin = reinterpret_cast<int (*)(void *, const uint8_t *, size_t, uint8_t *, int, int)>(dlsym(lib, "scmn_dec_begin"));
    feed = reinterpret_cast<int (*)(void *, size_t)>(dlsym(lib, "scmn_dec_feed"));
    if (auto nm = reinterpret_cast<const char *(*)()>(dlsym(lib, "scmn_dec_name"))) name = nm();
    ok = create && destroy && begin && feed && (ctx = create());
    if (!ok) std::fprintf(stderr, "builder decoder: %s lacks the scmn_dec_* ABI\n", path);
  }
  const char *Name() const override { return name.c_str(); }
  bool Begin(const uint8_t *jpeg, size_t cap, uint8_t *out, int w, int h) override {
    return begin(ctx, jpeg, cap, out, w, h) == 0;
  }
  int Feed(size_t avail) override { return feed(ctx, avail); }
  ~Builder() override {
    if (ctx) destroy(ctx);
  }
};

static std::vector<std::unique_ptr<Decoder>> MakeDecoders(const std::string &list) {
  std::vector<std::unique_ptr<Decoder>> v;
  std::stringstream ss(list);
  std::string n;
  while (std::getline(ss, n, ',')) {
    if (n == "turbo") v.emplace_back(new TurboStream("turbo", true));
    else if (n == "stream") v.emplace_back(new TurboStream("stream", false));
    else if (n == "tj") v.emplace_back(new TjWhole());
    else if (n == "builder") {
      const char *lib = getenv("SCMN_BUILDER_LIB");
      if (!lib) {
        std::fprintf(stderr, "builder: set SCMN_BUILDER_LIB\n");
        continue;
      }
      auto *b = new Builder(lib);
      if (b->ok) v.emplace_back(b);
      else delete b;
    } else std::fprintf(stderr, "unknown decoder %s\n", n.c_str());
  }
  return v;
}

// ---- NAPA ----------------------------------------------------------------------------------------------
static int g_min_contrast = 20;  // --min-contrast (PhotonVision's NAPA default is 20)
static napa_far::Config MakeConfig(const std::string &config) {
  napa_far::Config c;
  c.max_hamming = 1, c.min_contrast = g_min_contrast, c.min_border_cells = 22;
  if (config == "far") {
    c.far = true, c.base_min_tag_px = 32, c.far_min_tag_px = 16, c.sweep_bands = 4, c.sweeps_per_s = 60;
    c.fixed_sweep_ms = 0.5;
  } else {
    c.min_tag_px = 16;
  }
  return c;
}
static bool SameTags(const std::vector<napa_far::Tag> &a, const std::vector<napa_far::Tag> &b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (a[i].id != b[i].id || a[i].hamming != b[i].hamming || a[i].far != b[i].far) return false;
    if (std::memcmp(&a[i].margin, &b[i].margin, sizeof(float))) return false;
    if (std::memcmp(a[i].p.data(), b[i].p.data(), sizeof(double) * 8)) return false;
  }
  return true;
}
static double MaxCornerDiff(const std::vector<napa_far::Tag> &a, const std::vector<napa_far::Tag> &b) {
  double m = 0;
  for (auto &x : a)
    for (auto &y : b)
      if (x.id == y.id)
        for (int k = 0; k < 8; k++) m = std::max(m, std::fabs(x.p[k] - y.p[k]));
  return m;
}

// ---- options / frames -----------------------------------------------------------------------------------
struct Opt {
  std::string mode, session, decs = "turbo,tj,stream", config = "min16", times;
  double frame_ms = 8;
  size_t chunk = 16384;
  long max_frames = -1;
  int every = 1, cpu = -1, fifo = 0, band = 8, fill = 0;
  unsigned seed = 1;
};

struct Item {
  std::string cam;
  recording::Frame f;
};
static std::vector<Item> LoadFrames(const Opt &o) {
  std::vector<Item> v;
  std::vector<std::string> cams;
  for (auto &e : fs::directory_iterator(o.session))
    if (e.is_directory()) cams.push_back(e.path().filename().string());
  std::sort(cams.begin(), cams.end());
  for (auto &c : cams) {
    auto fr = recording::ReadIndex(fs::path(o.session) / c);
    long n = 0;
    for (size_t i = 0; i < fr.size(); i += o.every) {
      if (o.max_frames >= 0 && n >= o.max_frames) break;
      v.push_back({c, fr[i]}), ++n;
    }
  }
  return v;
}

static void Place(const Opt &o) {
  if (o.cpu >= 0) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(o.cpu, &s);
    if (sched_setaffinity(0, sizeof s, &s)) perror("sched_setaffinity");
  }
  if (o.fifo > 0) {
    sched_param p{};
    p.sched_priority = o.fifo;
    if (sched_setscheduler(0, SCHED_FIFO, &p)) perror("SCHED_FIFO (needs root)");
  }
}

// ---- decode mode ----------------------------------------------------------------------------------------
static int RunDecode(const Opt &o) {
  auto items = LoadFrames(o);
  auto decs = MakeDecoders(o.decs);
  std::map<std::string, std::vector<double>> cpu;
  std::map<std::string, long> bad_frames, bad_px, fail;
  std::map<std::string, int> maxdiff;
  std::vector<unsigned char> jpeg;
  std::vector<uint8_t> ref, out;
  std::vector<double> sizes;
  std::ofstream times;
  if (!o.times.empty()) {
    times.open(o.times);
    times << "camera,frame,bytes,decoder,cpu_ms,diff_px,max_diff\n";
  }
  std::vector<double> lumas;
  for (auto &it : items) {
    if (!recording::ReadJpeg(it.f, jpeg) || !recording::DecodeGray(jpeg, ref, it.f.width, it.f.height)) continue;
    sizes.push_back(jpeg.size() / 1024.0);
    const int w = it.f.width, h = it.f.height;
    {
      double s = 0;
      for (uint8_t v : ref) s += v;
      lumas.push_back(s / ref.size());
    }
    for (auto &d : decs) {
      out.assign(static_cast<size_t>(w) * h, 0x5A);
      const double c0 = CpuMs();
      int rows = d->Begin(jpeg.data(), jpeg.size(), out.data(), w, h) ? d->Feed(jpeg.size()) : -1;
      const double ms = CpuMs() - c0;
      d->End();
      cpu[d->Name()].push_back(ms);
      long npx = 0;
      int md = 0;
      if (rows != h) {
        fail[d->Name()]++;
      } else {
        for (size_t k = 0; k < out.size(); k++)
          if (out[k] != ref[k]) npx++, md = std::max(md, std::abs(out[k] - ref[k]));
      }
      if (npx) bad_frames[d->Name()]++, bad_px[d->Name()] += npx;
      maxdiff[d->Name()] = std::max(maxdiff[d->Name()], md);
      if (times.is_open())
        times << it.cam << ',' << it.f.index << ',' << jpeg.size() << ',' << d->Name() << ',' << ms << ',' << npx << ','
              << md << '\n';
    }
  }
  std::printf("decode: %s, %zu frames, JPEG KiB p50 %.0f max %.0f, mean luma p5/p50/p95 %.1f %.1f %.1f, cpu %d fifo %d\n",
              o.session.c_str(), sizes.size(), Pct(sizes, .5), Pct(sizes, 1), Pct(lumas, .05), Pct(lumas, .5),
              Pct(lumas, .95), o.cpu, o.fifo);
  int rc = 0;
  for (auto &d : decs) {
    const std::string n = d->Name();
    std::printf("  %-10s CPU ms p50/p95/p99 %s | luma vs libjpeg-turbo gray: %ld frames differ (%ld px, max |d| %d), "
                "%ld failed\n",
                n.c_str(), Stats(cpu[n]).c_str(), bad_frames[n], bad_px[n], maxdiff[n], fail[n]);
    if (bad_frames[n] || fail[n]) rc = 1;
  }
  std::printf("%s\n", rc ? "DECODE DIFFERENT" : "DECODE IDENTICAL");
  return rc;
}

// ---- fused mode -----------------------------------------------------------------------------------------
// Bytes arrive in chunks evenly over frame_ms; spin to each arrival, then let the decoder run and feed NAPA
// the new rows. The decoder sees new bytes only between Feed() calls, as the live watcher does.
struct FusedResult {
  double tail = 0, cpu = 0, behind = 0;
  std::vector<napa_far::Tag> tags;
  bool ok = false;
};
static FusedResult Fused(Decoder &d, napa_far::Detector &det, const std::vector<unsigned char> &jpeg,
                         std::vector<uint8_t> &out, int w, int h, int64_t now_us, const Opt &o, bool pace) {
  FusedResult r;
  const size_t n = jpeg.size();
  const int nc = static_cast<int>((n + o.chunk - 1) / o.chunk);
  const auto t0 = Clock::now();
  Clock::time_point arrival = t0;
  double c = CpuMs();
  bool ok = d.Begin(jpeg.data(), n, out.data(), w, h);
  bool napa_on = ok && det.Begin(out.data(), w, h, w, now_us);
  r.cpu += CpuMs() - c;
  int fed_rows = 0;
  for (int k = 0; k < nc && ok; k++) {
    if (pace) {
      arrival = t0 + std::chrono::nanoseconds(static_cast<long>((k + 1) * o.frame_ms * 1e6 / nc));
      while (Clock::now() < arrival) {
      }
      if (k == nc - 1) r.behind = Ms(Clock::now() - arrival);
    }
    c = CpuMs();
    const int rows = d.Feed(std::min(n, (k + 1) * o.chunk));
    if (rows < 0) ok = false;
    else if (rows > fed_rows && napa_on) det.Feed(fed_rows = rows);
    r.cpu += CpuMs() - c;
  }
  if (!pace) arrival = Clock::now();
  c = CpuMs();
  if (napa_on) {
    if (ok && fed_rows < h) det.Feed(h);  // a decoder that didn't report its last rows: let Finish see them
    r.tags = det.Finish();
  }
  r.cpu += CpuMs() - c;
  r.tail = Ms(Clock::now() - arrival);
  d.End();
  r.ok = ok && fed_rows == h;
  return r;
}

static int RunFused(const Opt &o) {
  auto items = LoadFrames(o);
  auto decs = MakeDecoders(o.decs);
  std::map<std::string, std::unique_ptr<napa_far::Detector>> whole_det;
  std::map<std::pair<std::string, std::string>, std::unique_ptr<napa_far::Detector>> sdet;
  std::map<std::string, std::vector<double>> tail, cpu, behind;
  std::map<std::string, long> mism, fail, sightings_diff;
  std::map<std::string, double> maxcorner;
  std::vector<double> whole_tail, whole_cpu_dec, whole_cpu_napa;
  std::vector<unsigned char> jpeg;
  std::vector<uint8_t> ref, out;
  long sightings = 0, frames = 0, with_tag = 0, ndet = 0;
  std::vector<double> margins;
  std::ofstream times;
  if (!o.times.empty()) {
    times.open(o.times);
    times << "camera,frame,bytes,decoder,tail_ms,cpu_ms,behind_ms,ntags,same\n";
  }
  for (auto &it : items) {
    if (!recording::ReadJpeg(it.f, jpeg)) continue;
    const int w = it.f.width, h = it.f.height;
    auto &wd = whole_det[it.cam];
    if (!wd) wd.reset(new napa_far::Detector("tag36h11")), wd->SetConfig(MakeConfig(o.config));
    // whole-frame baseline: decode + Detect after the last byte (tail == their wall time, no pacing needed)
    const auto t0 = Clock::now();
    double c0 = CpuMs();
    if (!recording::DecodeGray(jpeg, ref, w, h)) continue;
    const double cdec = CpuMs() - c0;
    c0 = CpuMs();
    auto want = wd->Detect(ref.data(), w, h, w, it.f.jetson_us);
    whole_cpu_napa.push_back(CpuMs() - c0);
    whole_cpu_dec.push_back(cdec);
    whole_tail.push_back(Ms(Clock::now() - t0));
    ++frames;
    for (auto &t : want) sightings += t.margin >= 15, margins.push_back(t.margin), ++ndet;
    with_tag += !want.empty();
    for (auto &d : decs) {
      auto &sd = sdet[{it.cam, d->Name()}];
      if (!sd) sd.reset(new napa_far::Detector("tag36h11")), sd->SetConfig(MakeConfig(o.config));
      out.assign(static_cast<size_t>(w) * h, 0);
      auto r = Fused(*d, *sd, jpeg, out, w, h, it.f.jetson_us, o, true);
      const std::string n = d->Name();
      if (!r.ok) {
        fail[n]++;
        continue;
      }
      tail[n].push_back(r.tail), cpu[n].push_back(r.cpu), behind[n].push_back(r.behind);
      const bool same = SameTags(want, r.tags);
      if (!same) {
        if (mism[n] < 10) {
          std::fprintf(stderr, "MISMATCH %s %s frame %d: whole %zu tags, %s %zu, max corner diff %.4g px\n",
                       it.cam.c_str(), n.c_str(), it.f.index, want.size(), n.c_str(), r.tags.size(),
                       MaxCornerDiff(want, r.tags));
          for (size_t k = 0; k < std::max(want.size(), r.tags.size()); k++) {
            auto pr = [](const char *w, const std::vector<napa_far::Tag> &v, size_t k) {
              if (k < v.size())
                std::fprintf(stderr, "   %s[%zu] id %d ham %d far %d margin %.9g p0 %.17g,%.17g\n", w, k, v[k].id,
                             v[k].hamming, v[k].far, v[k].margin, v[k].p[0], v[k].p[1]);
            };
            pr("whole", want, k), pr("strm ", r.tags, k);
          }
        }
        mism[n]++;
        maxcorner[n] = std::max(maxcorner[n], MaxCornerDiff(want, r.tags));
        long a = 0, b = 0;
        for (auto &t : want) a += t.margin >= 15;
        for (auto &t : r.tags) b += t.margin >= 15;
        sightings_diff[n] += b - a;
      }
      if (times.is_open())
        times << it.cam << ',' << it.f.index << ',' << jpeg.size() << ',' << n << ',' << r.tail << ',' << r.cpu << ','
              << r.behind << ',' << r.tags.size() << ',' << same << '\n';
    }
  }
  std::printf("fused: %s, %ld frames, config %s, bytes over %.1f ms in %zu-byte chunks, cpu %d fifo %d; "
              "whole-frame sightings (margin >= 15) %ld\n",
              o.session.c_str(), frames, o.config.c_str(), o.frame_ms, o.chunk, o.cpu, o.fifo, sightings);
  std::printf("  detections (any margin) %ld, frames with a tag %ld of %ld (%.1f%%), margin p5/p50/p95 %.1f %.1f %.1f\n",
              ndet, with_tag, frames, frames ? 100.0 * with_tag / frames : 0.0, Pct(margins, .05), Pct(margins, .5),
              Pct(margins, .95));
  std::printf("  %-10s tail (last byte -> tags) ms p50/p95/p99 %s\n", "whole", Stats(whole_tail).c_str());
  std::printf("  %-10s   CPU decode %s\n", "", Stats(whole_cpu_dec).c_str());
  std::printf("  %-10s   CPU NAPA   %s\n", "", Stats(whole_cpu_napa).c_str());
  int rc = 0;
  for (auto &d : decs) {
    const std::string n = d->Name();
    std::printf("  %-10s tail ms p50/p95/p99 %s\n", n.c_str(), Stats(tail[n]).c_str());
    std::printf("  %-10s   CPU decode+NAPA %s; behind p99 %.3f\n", "", Stats(cpu[n]).c_str(), Pct(behind[n], .99));
    std::printf("  %-10s   tags vs whole-frame NAPA: %ld frames differ (max corner diff %.3g px, sightings %+ld), "
                "%ld failed\n",
                "", mism[n], maxcorner[n], sightings_diff[n], fail[n]);
    if (mism[n] || fail[n]) rc = 1;
  }
  std::printf("%s\n", rc ? "FUSED DIFFERENT" : "FUSED IDENTICAL");
  return rc;
}

// ---- probe mode -----------------------------------------------------------------------------------------
// Does streaming NAPA read rows it hasn't been given? tests/napa-stream's identity check feeds bands of an
// image that is already complete, so a read past Feed(rows) can't show there. Here rows are copied into a
// buffer pre-filled with --fill (0 or 255) only as they are fed (--band rows at a time); any difference
// from Detect() on the complete image means Feed()/Finish() looked at rows beyond those fed so far.
static int RunProbe(const Opt &o, int band, int fill) {
  auto items = LoadFrames(o);
  std::map<std::string, std::unique_ptr<napa_far::Detector>> wd, sd;
  std::vector<unsigned char> jpeg;
  std::vector<uint8_t> ref, buf;
  long frames = 0, mism = 0;
  for (auto &it : items) {
    if (!recording::ReadJpeg(it.f, jpeg) || !recording::DecodeGray(jpeg, ref, it.f.width, it.f.height)) continue;
    const int w = it.f.width, h = it.f.height;
    auto &a = wd[it.cam], &b = sd[it.cam];
    if (!a) a.reset(new napa_far::Detector("tag36h11")), a->SetConfig(MakeConfig(o.config));
    if (!b) b.reset(new napa_far::Detector("tag36h11")), b->SetConfig(MakeConfig(o.config));
    auto want = a->Detect(ref.data(), w, h, w, it.f.jetson_us);
    buf.assign(ref.size(), static_cast<uint8_t>(fill));
    b->Begin(buf.data(), w, h, w, it.f.jetson_us);
    for (int r = 0; r < h;) {
      const int r1 = std::min(h, r + band);
      std::memcpy(buf.data() + static_cast<size_t>(r) * w, ref.data() + static_cast<size_t>(r) * w,
                  static_cast<size_t>(r1 - r) * w);
      b->Feed(r = r1);
    }
    auto got = b->Finish();
    ++frames;
    if (!SameTags(want, got)) {
      if (mism < 10) {
        std::fprintf(stderr, "PROBE MISMATCH %s frame %d: whole %zu tags, stream %zu, max corner diff %.4g px\n",
                     it.cam.c_str(), it.f.index, want.size(), got.size(), MaxCornerDiff(want, got));
        for (size_t k = 0; k < std::max(want.size(), got.size()); k++) {
          if (k < want.size())
            std::fprintf(stderr, "   whole[%zu] id %d ham %d margin %.9g\n", k, want[k].id, want[k].hamming, want[k].margin);
          if (k < got.size())
            std::fprintf(stderr, "   strm [%zu] id %d ham %d margin %.9g\n", k, got[k].id, got[k].hamming, got[k].margin);
        }
      }
      ++mism;
    }
  }
  std::printf("probe: %s, %ld frames, config %s, band %d, unfed rows = %d: %ld frames differ -> %s\n", o.session.c_str(),
              frames, o.config.c_str(), band, fill, mism, mism ? "PROBE DIFFERENT (reads rows not yet fed)" : "PROBE IDENTICAL");
  return mism ? 1 : 0;
}

// ---- fuzz mode ------------------------------------------------------------------------------------------
// Each case runs in a forked child with an alarm: crash = signal, hang = alarm. A decoder that says it
// decoded every row of a corrupted frame is fine (libjpeg conceals); what counts is no crash, no hang, no
// out-of-bounds write (guard bytes after the output), and the same handling of a clean frame afterwards.
static int RunFuzz(const Opt &o) {
  auto items = LoadFrames(o);
  auto decs = MakeDecoders(o.decs);
  std::mt19937 rng(o.seed);
  const char *kinds[] = {"truncate", "flipbytes", "zero-run", "drop-rst", "garbage", "huge-dims", "no-eoi", "dup-soi"};
  std::map<std::string, std::map<std::string, std::array<long, 4>>> res;  // ok, error, crash, hang
  std::vector<unsigned char> jpeg;
  std::vector<uint8_t> ref;
  long cases = 0;
  for (size_t fi = 0; fi < items.size(); fi += std::max<size_t>(1, items.size() / 40)) {
    auto &it = items[fi];
    if (!recording::ReadJpeg(it.f, jpeg) || !recording::DecodeGray(jpeg, ref, it.f.width, it.f.height)) continue;
    const int w = it.f.width, h = it.f.height;
    for (int kind = 0; kind < 8; kind++) {
      std::vector<unsigned char> m = jpeg;
      const size_t n = m.size();
      switch (kind) {
        case 0: m.resize(std::uniform_int_distribution<size_t>(2, n - 1)(rng)); break;
        case 1:
          for (int k = 0; k < 20; k++) m[std::uniform_int_distribution<size_t>(600, n - 3)(rng)] ^= 1u << (rng() % 8);
          break;
        case 2: {
          size_t a = std::uniform_int_distribution<size_t>(600, n - 4000)(rng);
          std::fill(m.begin() + a, m.begin() + a + 3000, 0);
          break;
        }
        case 3:
          for (size_t k = 600; k + 1 < m.size(); k++)
            if (m[k] == 0xFF && m[k + 1] >= 0xD0 && m[k + 1] <= 0xD7 && rng() % 4 == 0) m.erase(m.begin() + k, m.begin() + k + 2);
          break;
        case 4:
          for (size_t k = 2; k < n; k++) m[k] = static_cast<unsigned char>(rng());
          break;
        case 5:
          for (size_t k = 0; k + 8 < n; k++)
            if (m[k] == 0xFF && m[k + 1] == 0xC0) {
              m[k + 5] = 0x7F, m[k + 6] = 0xFF, m[k + 7] = 0x7F, m[k + 8] = 0xFF;  // 32767 x 32767
              break;
            }
          break;
        case 6: m.resize(n - 2); break;
        case 7: m.insert(m.begin() + n / 2, {0xFF, 0xD8, 0xFF, 0xD8}); break;
      }
      for (auto &d : decs) {
        ++cases;
        fflush(nullptr);
        pid_t pid = fork();
        if (pid == 0) {
          alarm(5);
          std::vector<uint8_t> out(static_cast<size_t>(w) * h + 4096, 0xA5);
          napa_far::Detector det("tag36h11");
          det.SetConfig(MakeConfig(o.config));
          Opt q = o;
          std::vector<uint8_t> img(static_cast<size_t>(w) * h);
          // corrupted frame, then the clean one: it must still decode identically
          auto r1 = Fused(*d, det, m, out, w, h, 0, q, false);
          for (size_t k = static_cast<size_t>(w) * h; k < out.size(); k++)
            if (out[k] != 0xA5) _exit(30);  // wrote past the image
          auto r2 = Fused(*d, det, jpeg, out, w, h, 0, q, false);
          if (!r2.ok || std::memcmp(out.data(), ref.data(), static_cast<size_t>(w) * h)) _exit(31);
          _exit(r1.ok ? 0 : 1);
        }
        int st = 0;
        waitpid(pid, &st, 0);
        auto &cnt = res[d->Name()][kinds[kind]];
        if (WIFEXITED(st) && WEXITSTATUS(st) <= 1) cnt[WEXITSTATUS(st)]++;
        else if (WIFSIGNALED(st) && WTERMSIG(st) == SIGALRM) {
          cnt[3]++;
          std::fprintf(stderr, "HANG %s %s frame %d\n", d->Name(), kinds[kind], it.f.index);
        } else {
          cnt[2]++;
          std::fprintf(stderr, "CRASH/BAD %s %s frame %d: %s %d\n", d->Name(), kinds[kind], it.f.index,
                       WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
        }
      }
    }
  }
  int rc = 0;
  std::printf("fuzz: %s, %ld cases (decoder x mutation x frame); counts ok / error / CRASH-or-BAD / HANG\n",
              o.session.c_str(), cases);
  for (auto &d : decs)
    for (int k = 0; k < 8; k++) {
      auto c = res[d->Name()][kinds[k]];
      std::printf("  %-10s %-10s %4ld %4ld %4ld %4ld\n", d->Name(), kinds[k], c[0], c[1], c[2], c[3]);
      if (c[2] || c[3]) rc = 1;
    }
  std::printf("%s\n", rc ? "FUZZ FAILURES" : "FUZZ CLEAN");
  return rc;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: scmn_bench decode|fused|fuzz SESSION [--dec LIST] [--config min16|far] [--frame-ms MS]"
                         " [--chunk BYTES] [--max-frames N] [--every N] [--cpu N] [--fifo PRIO] [--times CSV] [--seed S]\n");
    return 2;
  }
  Opt o;
  o.mode = argv[1], o.session = argv[2];
  if (getenv("SCMN_BUILDER_LIB")) o.decs += ",builder";
  for (int i = 3; i < argc; i++) {
    const std::string a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (a == "--dec") o.decs = v, ++i;
    else if (a == "--config") o.config = v, ++i;
    else if (a == "--frame-ms") o.frame_ms = std::atof(v), ++i;
    else if (a == "--chunk") o.chunk = std::max(1L, std::atol(v)), ++i;
    else if (a == "--max-frames") o.max_frames = std::atol(v), ++i;
    else if (a == "--every") o.every = std::max(1, std::atoi(v)), ++i;
    else if (a == "--cpu") o.cpu = std::atoi(v), ++i;
    else if (a == "--fifo") o.fifo = std::atoi(v), ++i;
    else if (a == "--times") o.times = v, ++i;
    else if (a == "--band") o.band = std::max(1, std::atoi(v)), ++i;
    else if (a == "--fill") o.fill = std::atoi(v), ++i;
    else if (a == "--min-contrast") g_min_contrast = std::atoi(v), ++i;
    else if (a == "--seed") o.seed = static_cast<unsigned>(std::atol(v)), ++i;
    else {
      std::fprintf(stderr, "unknown option %s\n", a.c_str());
      return 2;
    }
  }
  Place(o);
  if (o.mode == "decode") return RunDecode(o);
  if (o.mode == "fused") return RunFused(o);
  if (o.mode == "fuzz") return RunFuzz(o);
  if (o.mode == "probe") return RunProbe(o, o.band, o.fill);
  std::fprintf(stderr, "mode: decode|fused|fuzz\n");
  return 2;
}
