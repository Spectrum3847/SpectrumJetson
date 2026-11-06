// SpectrumJetson: streaming MJPEG -> gray decode, overlapped with the USB transfer
// (SPECTRUM_JPEG_DECODER=stream; off by default; tests/latency-breakdown).
//
// The Thriftiest Cam sends a frame's JPEG over ~8 ms, as the sensor reads out, and uvcvideo copies
// each USB packet into the V4L2 buffer as it arrives. User space only gets the buffer at the end,
// so today's decoders (NVJPG 2.6 ms, libjpeg-turbo 2.9 ms) start after the last packet. Here a
// watcher thread per camera maps the camera's V4L2 buffers through its own file descriptor (an
// mmap needs no stream ownership; nothing is queued, dequeued or configured, so cscore's stream is
// untouched) and decodes each frame with libjpeg-turbo while it fills, leaving ~0.1 ms of work
// after the last byte.
//
// Seeing how far a buffer has filled: after a frame is complete and cscore has copied it (3 ms
// later; cscore copies ~0.1 ms after the last packet, p99 0.3), the watcher fills the buffer with
// 0xFF. The driver writes the next frame into it from offset 0 at the earliest ~2 frames later
// (3 other buffers are queued ahead). Valid JPEG data never has 0xFF 0xFF..., so the first run of
// 16 0xFF bytes is the fill point. A buffer the watcher hasn't wiped yet (at start) is wiped 12 ms
// after its content is first seen to change (the frame is complete and copied by then).
//
// PhotonVision still gets every frame from cscore. DecodeGray matches that frame's bytes (length,
// tail and middle samples) against what a watcher decoded; any mismatch (a frame the driver
// dropped and restarted in the same buffer, a stale read, a watcher that lost sync) falls back to
// the normal decoder. Every 64th matched frame is re-decoded whole on a low-priority thread and
// compared byte for byte; one difference turns streaming off until PhotonVision restarts.
// Watchers close when their camera stops (no new frame for 300 ms), so cscore can free its buffers.
//
// Band sinks (stream_decode.h; streaming NAPA): a watcher with a sink attached hands each decoded band
// to it as it is decoded and keeps the sink's frame result with the frame. Sinks are fed only while
// their consumer keeps taking results (1 s), and frames the consumer's frame-rate cap will skip aren't
// fed. Built as libspectrum-stream.so (CMakeLists.txt, scripts/jetson/07-build-napa-detector.sh).
#include "stream_decode.h"

extern "C" {
#include "../native/sc-vision/src/mjdec.h"  // SPECTRUM_STREAM_DECODER=mjdec: the luma-only decoder
}

#include <algorithm>
#include <atomic>
#include <dirent.h>
#include <fstream>
#include <sched.h>
#include <chrono>
#include <condition_variable>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <linux/videodev2.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <jpeglib.h>

namespace spectrum_stream {
namespace {

using Clock = std::chrono::steady_clock;
constexpr int kMaxBuffers = 8;
constexpr int kResults = 3;
constexpr size_t kSample = 32;
constexpr int kFfRun = 16;

double Ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }
long ThreadCpuNs() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1000000000L + t.tv_nsec;
}

struct JErr {
  jpeg_error_mgr mgr;
  std::jmp_buf jump;
};
void ErrExit(j_common_ptr c) { std::longjmp(reinterpret_cast<JErr *>(c->err)->jump, 1); }
void NoMessage(j_common_ptr, int) {}

struct Src {
  jpeg_source_mgr pub;
  size_t fed = 0;  // bytes made visible to libjpeg so far
};
void SrcInit(j_decompress_ptr) {}
boolean SrcFill(j_decompress_ptr) { return FALSE; }  // suspend until more bytes arrive
void SrcSkip(j_decompress_ptr d, long n) {
  auto *s = d->src;
  const size_t k = std::min(static_cast<size_t>(std::max(0L, n)), s->bytes_in_buffer);
  s->next_input_byte += k;
  s->bytes_in_buffer -= k;
}
void SrcTerm(j_decompress_ptr) {}

struct Result {
  size_t len = 0;
  uint8_t tail[kSample], mid[kSample];
  std::vector<uint8_t> gray;
  long seq = 0;
  // the band sink's result for this frame (owned here until taken)
  void *sink_ctx = nullptr, *sink_out = nullptr;
  void (*sink_free)(void *) = nullptr;
  void ClearSink() {
    if (sink_out && sink_free) sink_free(sink_out);
    sink_ctx = sink_out = nullptr;
    sink_free = nullptr;
  }
};

// One camera: its V4L2 buffers, mapped read-write through our own descriptor.
struct Watcher {
  std::string dev;
  int fd = -1, width = 0, height = 0;
  size_t length = 0;
  int n = 0;
  uint8_t *buf[kMaxBuffers] = {};
  std::thread thread;
  std::atomic<bool> stop{false}, dead{false};

  std::mutex mu;
  std::condition_variable cv;
  Result results[kResults];
  long seq = 0;
  int active = -1;  // buffer being decoded
  size_t frontier = 0;

  // stats (watcher thread writes, logged every 10 s)
  std::vector<double> tails;
  long frames = 0, aborted = 0;
  long cpu_ns = 0;

  // band sink (sink_mu is held across every call into it, so detach() can wait for it)
  std::mutex sink_mu;
  spectrum_band_sink sink{};
  Clock::time_point sink_taken{};          // last spectrum_stream_take for this sink
  std::atomic<int64_t> want_after_ns{0};   // the consumer's next frame due (CLOCK_MONOTONIC)
  double frame_ms = 8;                     // SOI -> EOI of the last frame (for the skip rule)
  std::vector<double> sink_tails;          // finish() ms
  long sink_fed = 0, sink_skipped = 0;
  // the cores of the thread that takes this watcher's frames (SPECTRUM_STREAM_CPUS=camera)
  std::mutex cpu_mu;
  std::string consumer_cpus;
};

std::mutex g_mu;
// Never destroyed: at JVM exit a static vector's destructor would destroy joinable threads
// (std::terminate). The process is ending; the kernel unmaps and closes everything.
std::vector<std::unique_ptr<Watcher>> &g_watchers = *new std::vector<std::unique_ptr<Watcher>>;
Clock::time_point g_next_scan{};
std::atomic<bool> g_off{false};
std::atomic<long> g_hit{0}, g_miss{0}, g_waited{0}, g_check_ok{0}, g_check_differ{0};

// The frames DecodeGray handed out (by output pointer; the pipeline may see a copy, so take() also
// matches by content): which watcher and which of its frames.
struct Served {
  const uint8_t *out = nullptr;
  std::string dev;
  long seq = 0;
};
thread_local Served t_served;

// Is `img` (stride bytes a row) the frame r decoded? Every 16th row compared whole.
bool SameImage(const Result &r, const uint8_t *img, int width, int height, size_t stride) {
  if (r.gray.size() != static_cast<size_t>(width) * height) return false;
  for (int y = 3; y < height; y += 16)
    if (std::memcmp(r.gray.data() + static_cast<size_t>(y) * width, img + y * stride, width) != 0) return false;
  return true;
}

// The fill point: start of the first run of kFfRun 0xFF bytes at or after from (or limit).
size_t FindFill(const uint8_t *p, size_t from, size_t limit) {
  size_t i = from;
  while (i < limit) {
    const void *q = std::memchr(p + i, 0xFF, limit - i);
    if (!q) return limit;
    i = static_cast<const uint8_t *>(q) - p;
    size_t j = i;
    while (j < limit && p[j] == 0xFF && j - i < kFfRun) j++;
    if (j - i >= kFfRun || j == limit) return i;
    i = j;
  }
  return limit;
}

// Watcher placement (SPECTRUM_STREAM_CPUS): "all" (default) leaves watchers to the scheduler;
// "auto" keeps them off the cores another thread of this process is pinned to alone
// (photonvision-102's tag camera threads); or an explicit list such as "0-1" or "1,4". Re-checked
// every 2 s (pinning is applied after start). With 2 cameras, auto and all measured the same
// (handoff p99 0.23-0.26 vs 0.13-0.22 ms, tests/latency-breakdown), and with 4 cameras auto would
// crowd 4 watchers onto 2 cores, so it's not the default.
std::vector<int> ParseCpus(const std::string &s) {
  std::vector<int> v;
  size_t i = 0;
  while (i < s.size()) {
    size_t j = s.find(',', i);
    if (j == std::string::npos) j = s.size();
    const std::string part = s.substr(i, j - i);
    const size_t dash = part.find('-');
    try {
      const int a = std::stoi(part.substr(0, dash));
      const int b = dash == std::string::npos ? a : std::stoi(part.substr(dash + 1));
      for (int c = a; c <= b && c < CPU_SETSIZE; c++) v.push_back(c);
    } catch (...) {
    }
    i = j + 1;
  }
  return v;
}

// "camera": the watcher (and its band sink's work) runs on the cores of the thread that takes its frames,
// i.e. its camera's VisionRunner core when photonvision-102 pins it.
void PlaceWatcher(Watcher *w, std::string &applied) {
  const char *env = std::getenv("SPECTRUM_STREAM_CPUS");
  const std::string mode = env && *env ? env : "all";
  if (mode == "all") return;
  cpu_set_t want;
  CPU_ZERO(&want);
  if (mode == "camera") {
    std::string c;
    {
      std::lock_guard<std::mutex> l(w->cpu_mu);
      c = w->consumer_cpus;
    }
    for (int k : ParseCpus(c)) CPU_SET(k, &want);
    if (CPU_COUNT(&want) == 0) return;
  } else if (mode == "auto") {
    cpu_set_t proc;
    if (sched_getaffinity(getpid(), sizeof(proc), &proc)) return;  // the main thread: the process's cores
    std::vector<int> avoid;
    if (DIR *dir = opendir("/proc/self/task")) {
      const long me = syscall(SYS_gettid);
      while (dirent *e = readdir(dir)) {
        if (e->d_name[0] == '.' || std::atol(e->d_name) == me) continue;
        const std::string base = std::string("/proc/self/task/") + e->d_name;
        std::ifstream comm(base + "/comm");
        std::string name;
        std::getline(comm, name);
        if (name == "SpectrumStream") continue;
        std::ifstream st(base + "/status");
        for (std::string line; std::getline(st, line);)
          if (line.rfind("Cpus_allowed_list:", 0) == 0) {
            auto c = ParseCpus(line.substr(line.find_first_not_of(" \t", 18)));
            if (c.size() == 1) avoid.push_back(c[0]);
            break;
          }
      }
      closedir(dir);
    }
    want = proc;
    for (int c : avoid) CPU_CLR(c, &want);
    if (CPU_COUNT(&want) == 0) want = proc;  // every core has a camera: share them all
  } else {
    for (int c : ParseCpus(mode)) CPU_SET(c, &want);
    if (CPU_COUNT(&want) == 0) return;
  }
  std::string list;
  for (int c = 0; c < CPU_SETSIZE; c++)
    if (CPU_ISSET(c, &want)) list += (list.empty() ? "" : ",") + std::to_string(c);
  if (list == applied) return;
  if (sched_setaffinity(0, sizeof(want), &want) == 0) {
    std::cout << "stream decode " << w->dev << ": watcher on cores " << list << std::endl;
    applied = list;
  }
}

void WatchLoop(Watcher *w) {
  pthread_setname_np(pthread_self(), "SpectrumStream");
  enum State { kBoot, kBootChanging, kWiped, kFilling, kDone };
  State st[kMaxBuffers];
  Clock::time_point due[kMaxBuffers];
  uint8_t snap[kMaxBuffers][kSample];
  size_t wipe_len = 128 * 1024;
  for (int i = 0; i < w->n; i++) {
    st[i] = kBoot;
    std::memcpy(snap[i], w->buf[i] + 1024, kSample);
  }
  auto last_frame = Clock::now();
  auto next_log = Clock::now() + std::chrono::seconds(10);
  auto next_place = Clock::now();
  std::string placed;

  jpeg_decompress_struct d;
  JErr err;
  Src src;
  bool decoding = false;
  int hdr = 0;  // 0 header, 1 start, 2 rows
  Clock::time_point eoi_seen{};
  int ri = 0;  // result slot being filled
  std::vector<uint8_t> out;
  void *fed_ctx = nullptr;  // the sink fed this frame (nullptr: none)
  Clock::time_point t_soi{};
  // SPECTRUM_STREAM_DECODER=mjdec (sc/mjpeg-napa): native/sc-vision's luma-only decoder instead of libjpeg-turbo,
  // the same pixels (bit-identical to JCS_GRAYSCALE + ISLOW), about half the CPU on the Thriftiest Cam's frames.
  static const bool use_mj = [] {
    const char *e = std::getenv("SPECTRUM_STREAM_DECODER");
    return e && std::strcmp(e, "mjdec") == 0;
  }();
  std::unique_ptr<mjdec, void (*)(mjdec *)> mj(use_mj ? mjdec_create() : nullptr, mjdec_destroy);
  bool mj_on = false;  // this frame is decoded by mjdec
  int mj_rows = 0;

  // Start feeding the attached sink with this frame, if it's still taking results and wants it.
  auto sink_begin = [&]() {
    fed_ctx = nullptr;
    std::lock_guard<std::mutex> l(w->sink_mu);
    if (!w->sink.ctx || Clock::now() - w->sink_taken > std::chrono::seconds(1)) return;
    // The consumer's frame-rate cap: it next takes the newest frame complete at its due time, so a
    // frame completing more than a frame period (plus 1 ms) before that will be skipped.
    const int64_t due = w->want_after_ns.load();
    const int64_t done_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                (t_soi + std::chrono::microseconds(static_cast<long>(w->frame_ms * 1000)))
                                    .time_since_epoch())
                                .count();
    if (due > 0 && done_ns < due - static_cast<int64_t>((w->frame_ms + 1.5) * 1e6)) {
      w->sink_skipped++;
      return;
    }
    if (w->sink.begin(w->sink.ctx, out.data(), w->width, w->height, w->width)) fed_ctx = w->sink.ctx;
  };
  auto sink_feed = [&](int rows) {
    if (!fed_ctx) return;
    std::lock_guard<std::mutex> l(w->sink_mu);
    if (w->sink.ctx != fed_ctx) {
      fed_ctx = nullptr;  // detached or moved: its stream is abandoned (the next Begin resets it)
      return;
    }
    w->sink.feed(fed_ctx, rows);
  };
  // finish(); keep=false: an aborted frame, just reset the sink.
  auto sink_finish = [&](Result *r) {
    if (!fed_ctx) return;
    std::lock_guard<std::mutex> l(w->sink_mu);
    if (w->sink.ctx == fed_ctx) {
      const auto t0 = Clock::now();
      void *res = w->sink.finish(fed_ctx);
      if (r) {
        w->sink_tails.push_back(Ms(Clock::now() - t0));
        w->sink_fed++;
        std::lock_guard<std::mutex> lr(w->mu);
        r->ClearSink();
        r->sink_ctx = fed_ctx;
        r->sink_out = res;
        r->sink_free = w->sink.free_result;
      } else if (res) {
        w->sink.free_result(res);
      }
    }
    fed_ctx = nullptr;
  };

  auto abort_decode = [&]() {
    sink_finish(nullptr);
    if (decoding && !mj_on) jpeg_destroy_decompress(&d);
    decoding = false;
    mj_on = false;
    std::lock_guard<std::mutex> l(w->mu);
    w->active = -1;
  };

  while (!w->stop) {
    const long c0 = ThreadCpuNs();
    auto now = Clock::now();
    bool busy = false;
    for (int i = 0; i < w->n; i++) {
      uint8_t *p = w->buf[i];
      switch (st[i]) {
        case kBoot:
          if (std::memcmp(snap[i], p + 1024, kSample) != 0) {
            st[i] = kBootChanging;
            due[i] = now + std::chrono::milliseconds(12);
          }
          break;
        case kBootChanging:
        case kDone:
          if (now >= due[i]) {
            std::memset(p, 0xFF, std::min(wipe_len, w->length));
            st[i] = kWiped;
          }
          break;
        case kWiped:
          if (p[0] == 0xFF && p[1] == 0xD8 && w->active < 0) {
            last_frame = now;
            t_soi = now;
            // a new frame started in this buffer: decode it as it fills
            src = Src();
            out.resize(static_cast<size_t>(w->width) * w->height);
            if (mj) {
              mj_on = mjdec_begin(mj.get(), p, w->length, out.data(), w->width, w->height, w->width) == 0;
              mj_rows = 0;
            }
            if (!mj_on) {
            d.err = jpeg_std_error(&err.mgr);
            err.mgr.error_exit = ErrExit;
            err.mgr.emit_message = NoMessage;
            jpeg_create_decompress(&d);
            }
            src.pub.init_source = SrcInit;
            src.pub.fill_input_buffer = SrcFill;
            src.pub.skip_input_data = SrcSkip;
            src.pub.resync_to_restart = jpeg_resync_to_restart;
            src.pub.term_source = SrcTerm;
            src.pub.next_input_byte = p;
            src.pub.bytes_in_buffer = 0;
            d.src = &src.pub;
            decoding = true;
            hdr = 0;
            eoi_seen = {};
            {
              std::lock_guard<std::mutex> l(w->mu);
              w->active = i;
              w->frontier = 0;
              ri = static_cast<int>((w->seq + 1) % kResults);
            }
            sink_begin();
            st[i] = kFilling;
          }
          break;
        case kFilling: {
          if (!decoding || w->active != i) {
            st[i] = kBoot;
            std::memcpy(snap[i], p + 1024, kSample);
            break;
          }
          if (setjmp(err.jump)) {  // corrupt / not what we thought: resync this buffer
            abort_decode();
            w->aborted++;
            st[i] = kBoot;
            std::memcpy(snap[i], p + 1024, kSample);
            break;
          }
          const size_t fill = FindFill(p, src.fed, std::min(w->length, wipe_len));
          if (fill > src.fed) {
            const size_t used = src.fed - src.pub.bytes_in_buffer;
            src.fed = fill;
            src.pub.next_input_byte = p + used;
            src.pub.bytes_in_buffer = fill - used;
            std::lock_guard<std::mutex> l(w->mu);
            w->frontier = fill;
          }
          if (fill >= 2 && p[fill - 2] == 0xFF && p[fill - 1] == 0xD9 && eoi_seen == Clock::time_point{})
            eoi_seen = Clock::now();
          bool mj_done = false;
          if (mj_on) {
            const int r = mjdec_feed(mj.get(), fill);
            if (r < 0) {  // corrupt, or a JPEG mjdec doesn't do (then libjpeg-turbo from the next frame on)
              if (r == MJDEC_EUNSUP) {
                std::printf("stream decode %s: frames mjdec doesn't decode; libjpeg-turbo from now on\n",
                            w->dev.c_str());
                mj.reset();
              }
              abort_decode();
              w->aborted++;
              st[i] = kBoot;
              std::memcpy(snap[i], p + 1024, kSample);
              break;
            }
            if (r > mj_rows) {
              busy = true;
              mj_rows = r;
              sink_feed(r);
            }
            mj_done = r >= w->height;
          }
          if (!mj_on && hdr == 0 && jpeg_read_header(&d, TRUE) == JPEG_HEADER_OK) {
            d.out_color_space = JCS_GRAYSCALE;  // only Y is inverse-DCT'd; Cb/Cr just entropy-decoded
            d.dct_method = JDCT_ISLOW;          // as TurboDecodeGray: identical pixels
            hdr = 1;
          }
          if (!mj_on && hdr == 1 && jpeg_start_decompress(&d)) {
            if (static_cast<int>(d.output_width) != w->width ||
                static_cast<int>(d.output_height) != w->height || d.output_components != 1) {
              abort_decode();
              st[i] = kDone;
              due[i] = now + std::chrono::milliseconds(3);
              break;
            }
            hdr = 2;
          }
          while (!mj_on && hdr == 2 && d.output_scanline < d.output_height) {
            JSAMPROW rows[16];
            for (int r = 0; r < 16; r++)
              rows[r] = out.data() + static_cast<size_t>(std::min<unsigned>(d.output_scanline + r, d.output_height - 1)) * w->width;
            if (!jpeg_read_scanlines(&d, rows, 16)) break;
            busy = true;
            sink_feed(static_cast<int>(d.output_scanline));
          }
          if (mj_done || (!mj_on && hdr == 2 && d.output_scanline >= d.output_height)) {
            // all rows decoded: the frame ends at its EOI, at or just after the bytes consumed
            size_t len = 0;
            if (mj_on) {
              len = mjdec_end(mj.get());
            } else {
              const size_t used = src.fed - src.pub.bytes_in_buffer;
              for (size_t k = used >= 2 ? used - 2 : 0; k + 1 < src.fed && k < used + 64; k++)
                if (p[k] == 0xFF && p[k + 1] == 0xD9) {
                  len = k + 2;
                  break;
                }
            }
            if (!len) break;  // EOI not here yet
            if (!mj_on) jpeg_destroy_decompress(&d);
            mj_on = false;
            decoding = false;
            {
              std::lock_guard<std::mutex> l(w->mu);
              w->results[ri].ClearSink();  // the slot's previous frame's
            }
            sink_finish(&w->results[ri]);  // the frame's band-sink result goes with it
            const auto t_done = Clock::now();
            if (eoi_seen == Clock::time_point{}) eoi_seen = t_done;
            w->tails.push_back(Ms(t_done - eoi_seen));
            w->frame_ms = Ms(eoi_seen - t_soi);
            w->frames++;
            wipe_len = std::max(wipe_len, len + len / 2 + 16384);
            {
              std::lock_guard<std::mutex> l(w->mu);
              Result &r = w->results[ri];
              r.len = len;
              std::memcpy(r.tail, p + len - kSample, kSample);
              std::memcpy(r.mid, p + len / 2, kSample);
              r.gray.swap(out);
              r.seq = ++w->seq;
              w->active = -1;
            }
            w->cv.notify_all();
            st[i] = kDone;
            due[i] = t_done + std::chrono::milliseconds(3);
            last_frame = t_done;
          } else if (now - last_frame > std::chrono::milliseconds(25)) {
            abort_decode();  // stuck: never finished (dropped frame, restart)
            w->aborted++;
            st[i] = kBoot;
            std::memcpy(snap[i], p + 1024, kSample);
          }
          break;
        }
      }
    }
    w->cpu_ns += ThreadCpuNs() - c0;
    now = Clock::now();
    if (now - last_frame > std::chrono::milliseconds(300)) break;  // camera stopped
    if (now >= next_place && !decoding) {
      next_place = now + std::chrono::seconds(2);
      PlaceWatcher(w, placed);
    }
    if (now >= next_log) {
      next_log = now + std::chrono::seconds(10);
      std::vector<double> t;
      t.swap(w->tails);
      std::sort(t.begin(), t.end());
      auto pc = [&](double q) { return t.empty() ? -1.0 : t[std::min(t.size() - 1, static_cast<size_t>(t.size() * q))]; };
      std::printf(
          "stream decode %s: %ld frames, tail after last byte p50 %.3f p95 %.3f p99 %.3f ms, "
          "watcher CPU %.2f ms/frame (%.1f%% of a core), %ld resyncs; matched %ld missed %ld "
          "waited %ld; checks ok %ld differ %ld\n",
          w->dev.c_str(), w->frames, pc(.5), pc(.95), pc(.99),
          w->frames ? w->cpu_ns / 1e6 / w->frames : 0.0, w->cpu_ns / 1e8, w->aborted,
          g_hit.load(), g_miss.load(), g_waited.load(), g_check_ok.load(), g_check_differ.load());
      if (w->sink_fed || w->sink_skipped) {
        std::vector<double> s;
        s.swap(w->sink_tails);
        std::sort(s.begin(), s.end());
        auto ps = [&](double q) { return s.empty() ? -1.0 : s[std::min(s.size() - 1, static_cast<size_t>(s.size() * q))]; };
        std::printf("stream decode %s: band sink fed %ld frames (skipped %ld for the frame-rate cap), "
                    "finish p50 %.3f p95 %.3f p99 %.3f ms\n",
                    w->dev.c_str(), w->sink_fed, w->sink_skipped, ps(.5), ps(.95), ps(.99));
        w->sink_fed = w->sink_skipped = 0;
      }
      std::fflush(stdout);
      w->frames = 0;
      w->cpu_ns = 0;
      w->aborted = 0;
    }
    if (!busy) {
      timespec ts = {0, 100000};  // 0.1 ms: the tail is at most this plus the last rows
      nanosleep(&ts, nullptr);
    }
  }
  if (decoding && !mj_on) jpeg_destroy_decompress(&d);
  sink_finish(nullptr);
  w->dead = true;
  w->cv.notify_all();
}

// Watch every MJPEG capture device of this size whose buffers exist (cscore is streaming it).
void Scan(int width, int height) {
  for (int k = 0; k < 16; k++) {
    const std::string dev = "/dev/video" + std::to_string(k);
    bool have = false;
    for (auto &w : g_watchers)
      if (w->dev == dev && !w->dead) have = true;
    if (have) continue;
    const int fd = open(dev.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) continue;
    v4l2_capability cap{};
    v4l2_format f{};
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) || !(cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) ||
        ioctl(fd, VIDIOC_G_FMT, &f) || f.fmt.pix.pixelformat != V4L2_PIX_FMT_MJPEG ||
        static_cast<int>(f.fmt.pix.width) != width || static_cast<int>(f.fmt.pix.height) != height) {
      close(fd);
      continue;
    }
    auto w = std::make_unique<Watcher>();
    w->dev = dev;
    w->fd = fd;
    w->width = width;
    w->height = height;
    w->length = f.fmt.pix.sizeimage;
    const long pg = sysconf(_SC_PAGESIZE);
    for (int i = 0; i < kMaxBuffers; i++) {
      // vb2's mmap cookie: buffer index << 3 pages (kernel 6.8); offset 0 needs no guess
      void *m = mmap(nullptr, w->length, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                     static_cast<off_t>(i) * 8 * pg);
      if (m == MAP_FAILED) break;
      w->buf[w->n++] = static_cast<uint8_t *>(m);
    }
    if (w->n < 2) {  // not streaming (no buffers), or a kernel with another cookie scheme
      for (int i = 0; i < w->n; i++) munmap(w->buf[i], w->length);
      close(fd);
      continue;
    }
    std::cout << "stream decode: watching " << dev << " (" << w->n << " buffers of "
              << w->length << " bytes)" << std::endl;
    Watcher *raw = w.get();
    w->thread = std::thread(WatchLoop, raw);
    g_watchers.push_back(std::move(w));
  }
  // reap watchers whose camera stopped: unmap, so cscore can free or reallocate its buffers
  for (auto it = g_watchers.begin(); it != g_watchers.end();) {
    if ((*it)->dead) {
      (*it)->thread.join();
      for (int i = 0; i < (*it)->n; i++) munmap((*it)->buf[i], (*it)->length);
      for (Result &r : (*it)->results) r.ClearSink();
      close((*it)->fd);
      std::cout << "stream decode: stopped watching " << (*it)->dev << std::endl;
      it = g_watchers.erase(it);
    } else {
      ++it;
    }
  }
}

int TurboWhole(const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height) {
  jpeg_decompress_struct c;
  JErr err;
  c.err = jpeg_std_error(&err.mgr);
  err.mgr.error_exit = ErrExit;
  err.mgr.emit_message = NoMessage;
  if (setjmp(err.jump)) {
    jpeg_destroy_decompress(&c);
    return -2;
  }
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, const_cast<unsigned char *>(jpeg), size);
  jpeg_read_header(&c, TRUE);
  c.out_color_space = JCS_GRAYSCALE;
  c.dct_method = JDCT_ISLOW;
  jpeg_start_decompress(&c);
  if (static_cast<int>(c.output_width) != width || static_cast<int>(c.output_height) != height) {
    jpeg_destroy_decompress(&c);
    return -3;
  }
  while (c.output_scanline < c.output_height) {
    JSAMPROW row = out + static_cast<size_t>(c.output_scanline) * width;
    jpeg_read_scanlines(&c, &row, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  return 0;
}

// Low-priority whole-frame re-decode of every 64th matched frame, compared byte for byte.
void Check(std::vector<uint8_t> jpeg, std::vector<uint8_t> gray, int width, int height) {
  static std::atomic<bool> running{false};
  if (running.exchange(true)) return;  // one at a time; skip if busy
  std::thread([jpeg = std::move(jpeg), gray = std::move(gray), width, height]() {
    setpriority(PRIO_PROCESS, static_cast<id_t>(syscall(SYS_gettid)), 19);
    std::vector<uint8_t> ref(gray.size());
    if (TurboWhole(jpeg.data(), jpeg.size(), ref.data(), width, height) == 0) {
      if (ref == gray) {
        g_check_ok++;
      } else {
        g_check_differ++;
        g_off = true;
        std::cout << "stream decode: a streamed frame differs from the whole-frame decode; "
                     "streaming is off until PhotonVision restarts"
                  << std::endl;
      }
    }
    running = false;
  }).detach();
}

bool Match(const Result &r, const uint8_t *jpeg, size_t size) {
  return r.len == size && r.seq &&
         std::memcmp(r.tail, jpeg + size - kSample, kSample) == 0 &&
         std::memcmp(r.mid, jpeg + size / 2, kSample) == 0;
}

}  // namespace
}  // namespace spectrum_stream

using namespace spectrum_stream;

#define SPECTRUM_STREAM_API extern "C" __attribute__((visibility("default")))

SPECTRUM_STREAM_API int spectrum_stream_decode_gray(const uint8_t *jpeg, size_t size, uint8_t *out,
                                                    int width, int height, size_t stride) {
  t_served = Served();
  if (g_off || size < 1024) return 1;
  std::vector<Watcher *> ws;
  {
    std::lock_guard<std::mutex> l(g_mu);
    const auto now = Clock::now();
    if (now >= g_next_scan) {
      g_next_scan = now + std::chrono::seconds(2);
      Scan(width, height);
    }
    for (auto &w : g_watchers)
      if (!w->dead && w->width == width && w->height == height) ws.push_back(w.get());
  }
  for (Watcher *w : ws) {
    std::unique_lock<std::mutex> l(w->mu);
    auto find = [&]() -> const Result * {
      for (const Result &r : w->results)
        if (Match(r, jpeg, size)) return &r;
      return nullptr;
    };
    const Result *r = find();
    if (!r && w->active >= 0) {
      // still finishing the last rows? Only if the bytes it has match this frame's.
      const uint8_t *p = w->buf[w->active];
      const size_t f = std::min(w->frontier, size);
      if (f > 4096 && std::memcmp(p + f - 1024, jpeg + f - 1024, 512) == 0) {
        g_waited++;
        w->cv.wait_for(l, std::chrono::milliseconds(3), [&]() { return (r = find()) || w->dead; });
      }
    }
    if (!r) continue;
    t_served.out = out;
    t_served.dev = w->dev;
    t_served.seq = r->seq;
    {
      static thread_local Clock::time_point next_cpus{};
      const auto now = Clock::now();
      if (now >= next_cpus) {  // the consumer's cores, for SPECTRUM_STREAM_CPUS=camera
        next_cpus = now + std::chrono::seconds(2);
        cpu_set_t set;
        if (sched_getaffinity(0, sizeof(set), &set) == 0) {
          std::string list;
          for (int c = 0; c < CPU_SETSIZE; c++)
            if (CPU_ISSET(c, &set)) list += (list.empty() ? "" : ",") + std::to_string(c);
          std::lock_guard<std::mutex> lc(w->cpu_mu);
          w->consumer_cpus = list;
        }
      }
    }
    for (int y = 0; y < height; y++)
      std::memcpy(out + static_cast<size_t>(y) * stride, r->gray.data() + static_cast<size_t>(y) * width, width);
    const long hit = ++g_hit;
    if (hit % 64 == 0)
      Check(std::vector<uint8_t>(jpeg, jpeg + size), r->gray, width, height);
    return 0;
  }
  g_miss++;
  return 1;
}

SPECTRUM_STREAM_API int spectrum_stream_take(const uint8_t *out, int width, int height, size_t stride,
                                             const spectrum_band_sink *sink, int64_t want_after_ns,
                                             void **result) {
  if (result) *result = nullptr;
  if (!out || !sink || !sink->ctx || width <= 0 || height <= 0) return -1;
  std::lock_guard<std::mutex> g(g_mu);
  Watcher *w = nullptr;
  long seq = 0;
  if (t_served.out == out) {
    for (auto &x : g_watchers)
      if (x->dev == t_served.dev && !x->dead) w = x.get();
    seq = t_served.seq;
  }
  if (!w) {  // a copy of the decoded frame: find it by content
    for (auto &x : g_watchers) {
      if (x->dead || x->width != width || x->height != height) continue;
      std::lock_guard<std::mutex> l(x->mu);
      for (const Result &r : x->results)
        if (r.seq && SameImage(r, out, width, height, stride)) {
          w = x.get();
          seq = r.seq;
        }
      if (w) break;
    }
  }
  if (!w) return -1;
  // attach here (and only here)
  for (auto &x : g_watchers) {
    if (x.get() == w) continue;
    std::lock_guard<std::mutex> l(x->sink_mu);
    if (x->sink.ctx == sink->ctx) x->sink = spectrum_band_sink{};
  }
  {
    std::lock_guard<std::mutex> l(w->sink_mu);
    if (w->sink.ctx != sink->ctx) {
      w->sink = *sink;
      std::cout << "stream decode " << w->dev << ": band sink attached" << std::endl;
    }
    w->sink_taken = Clock::now();
    w->want_after_ns = want_after_ns;
  }
  std::lock_guard<std::mutex> l(w->mu);
  for (Result &r : w->results)
    if (r.seq == seq) {
      if (r.sink_ctx != sink->ctx || !r.sink_out) return 0;
      *result = r.sink_out;
      r.sink_out = nullptr;
      r.sink_ctx = nullptr;
      return 1;
    }
  return 0;
}

SPECTRUM_STREAM_API void spectrum_stream_detach(void *ctx) {
  if (!ctx) return;
  std::lock_guard<std::mutex> g(g_mu);
  for (auto &w : g_watchers) {
    {
      std::lock_guard<std::mutex> l(w->sink_mu);
      if (w->sink.ctx == ctx) w->sink = spectrum_band_sink{};
    }
    std::lock_guard<std::mutex> l(w->mu);
    for (Result &r : w->results)
      if (r.sink_ctx == ctx) r.ClearSink();
  }
}
