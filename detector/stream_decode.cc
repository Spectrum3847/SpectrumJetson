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
#include "stream_decode.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csetjmp>
#include <cstdio>
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
};

std::mutex g_mu;
// Never destroyed: at JVM exit a static vector's destructor would destroy joinable threads
// (std::terminate). The process is ending; the kernel unmaps and closes everything.
std::vector<std::unique_ptr<Watcher>> &g_watchers = *new std::vector<std::unique_ptr<Watcher>>;
Clock::time_point g_next_scan{};
std::atomic<bool> g_off{false};
std::atomic<long> g_hit{0}, g_miss{0}, g_waited{0}, g_check_ok{0}, g_check_differ{0};

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

  jpeg_decompress_struct d;
  JErr err;
  Src src;
  bool decoding = false;
  int hdr = 0;  // 0 header, 1 start, 2 rows
  Clock::time_point eoi_seen{};
  int ri = 0;  // result slot being filled
  std::vector<uint8_t> out;

  auto abort_decode = [&]() {
    if (decoding) jpeg_destroy_decompress(&d);
    decoding = false;
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
            // a new frame started in this buffer: decode it as it fills
            d.err = jpeg_std_error(&err.mgr);
            err.mgr.error_exit = ErrExit;
            err.mgr.emit_message = NoMessage;
            jpeg_create_decompress(&d);
            src = Src();
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
            out.resize(static_cast<size_t>(w->width) * w->height);
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
          if (hdr == 0 && jpeg_read_header(&d, TRUE) == JPEG_HEADER_OK) {
            d.out_color_space = JCS_GRAYSCALE;  // only Y is inverse-DCT'd; Cb/Cr just entropy-decoded
            d.dct_method = JDCT_ISLOW;          // as TurboDecodeGray: identical pixels
            hdr = 1;
          }
          if (hdr == 1 && jpeg_start_decompress(&d)) {
            if (static_cast<int>(d.output_width) != w->width ||
                static_cast<int>(d.output_height) != w->height || d.output_components != 1) {
              abort_decode();
              st[i] = kDone;
              due[i] = now + std::chrono::milliseconds(3);
              break;
            }
            hdr = 2;
          }
          while (hdr == 2 && d.output_scanline < d.output_height) {
            JSAMPROW rows[16];
            for (int r = 0; r < 16; r++)
              rows[r] = out.data() + static_cast<size_t>(std::min<unsigned>(d.output_scanline + r, d.output_height - 1)) * w->width;
            if (!jpeg_read_scanlines(&d, rows, 16)) break;
            busy = true;
          }
          if (hdr == 2 && d.output_scanline >= d.output_height) {
            // all rows decoded: the frame ends at its EOI, at or just after the bytes consumed
            const size_t used = src.fed - src.pub.bytes_in_buffer;
            size_t len = 0;
            for (size_t k = used >= 2 ? used - 2 : 0; k + 1 < src.fed && k < used + 64; k++)
              if (p[k] == 0xFF && p[k + 1] == 0xD9) {
                len = k + 2;
                break;
              }
            if (!len) break;  // EOI not here yet
            const auto t_done = Clock::now();
            jpeg_destroy_decompress(&d);
            decoding = false;
            if (eoi_seen == Clock::time_point{}) eoi_seen = t_done;
            w->tails.push_back(Ms(t_done - eoi_seen));
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
  if (decoding) jpeg_destroy_decompress(&d);
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

int DecodeGray(const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height,
               size_t stride) {
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

}  // namespace spectrum_stream
