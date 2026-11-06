// SpectrumJetson: libspectrum-napa-apriltag.so, the JNI bridge for org.photonvision.jni.NapaDetectorJNI in
// the Spectrum PhotonVision fork: NAPA (third_party/napa, by Zachary Wilson, GPL-3.0-only with a 7(b)
// credit term) on the CPU, one detector handle per camera (napa_far.h). No OpenCV or WPILib: Java passes
// the gray Mat's data address, size and step, and gets WPILib AprilTagDetection objects back, in
// OpenCV's pixel convention like the GPU detector's (so they must not go through
// AprilTagPixelConvention.toOpenCv).
//
// Java API (all static):
//   long create(String family)                      0 if the family is unknown
//   void destroy(long handle)
//   void setParams(long handle, int minTagPx, int maxHamming, boolean far, int baseMinTagPx,
//                  int farMinTagPx, double sweepsPerSecond)
//   void setEarlySlack(long handle, int slack)      early-decode slack bits 0-3 (default 2, NAPA's)
//   AprilTagDetection[] detect(long handle, long dataAddr, int width, int height, int step)
//   double[] stats(long handle)  frames, base ms, crops, crop ms, sweeps, sweep ms, far tags
// Streaming NAPA (patches/napa-03-streaming.patch, tests/napa-stream; off by default):
//   boolean streamAvailable()    libspectrum-stream.so could be opened (the streaming decoder)
//   int streamDecodeGray(long rawFramePtr, long dataAddr, int width, int height, int step)
//       0: the camera's frame was decoded while it arrived (into the gray Mat at dataAddr); 1: it
//       wasn't (decode it yourself); -1: not MJPEG / no stream library. For a machine without the CUDA
//       library (SystemCore); on the Jetson the GPU library's decodeMjpegGray does the same.
//   AprilTagDetection[] detectStreamed(long handle, long dataAddr, int width, int height, int step,
//                                      long wantAfterNanos)
//       As detect(), for a frame the streaming decoder just wrote into dataAddr on this thread: the
//       camera's watcher thread ran NAPA band by band as the frame was decoded (Begin/Feed/Finish on
//       its own napa_far::Detector, the handle's config), so only ~0.1 ms was left after the last
//       byte; this returns that result. Identical to detect() (checked live: every 64th streamed
//       frame is re-detected whole on a low-priority thread and compared field by field). A frame
//       that wasn't streamed is detected whole, as detect(). wantAfterNanos (CLOCK_MONOTONIC, 0 =
//       none): when the camera's frame-rate cap next takes a frame, so frames it skips aren't fed.
//       The streaming decoder must be running (SPECTRUM_JPEG_DECODER=stream on the Jetson).
#include <dlfcn.h>
#include <fcntl.h>
#include <jni.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <deque>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../stream_decode.h"
#include "napa_far.h"
#include "../../native/sc-vision/src/rewind_writer.h"
extern "C" {
#include "../../native/sc-vision/src/pose.h"  // poseSquare (sc/mjpeg-napa)
#include "../../native/sc-vision/src/mjdec.h"  // the native camera backend's decoder
}
#include "../../native/sc-vision/src/pv_pack.h"  // native publish (sc/mjpeg-napa)

namespace {
jclass detectionCls = nullptr;
jmethodID detectionCtor = nullptr;

// libspectrum-stream.so's C API, opened on first use (the same copy the GPU library links, if loaded).
struct StreamApi {
  decltype(&spectrum_stream_decode_gray) decode = nullptr;
  decltype(&spectrum_stream_take) take = nullptr;
  decltype(&spectrum_stream_detach) detach = nullptr;
  decltype(&spectrum_stream_set_copy) set_copy = nullptr;  // newer libspectrum-stream.so only
  decltype(&spectrum_stream_release) release = nullptr;    // newer still
};
const StreamApi *Stream() {
  static const StreamApi *api = [] () -> const StreamApi * {
    void *h = dlopen("libspectrum-stream.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
      std::cout << "NAPA: no streaming (libspectrum-stream.so: " << dlerror() << ")" << std::endl;
      return nullptr;
    }
    auto *a = new StreamApi;
    a->decode = reinterpret_cast<decltype(a->decode)>(dlsym(h, "spectrum_stream_decode_gray"));
    a->take = reinterpret_cast<decltype(a->take)>(dlsym(h, "spectrum_stream_take"));
    a->detach = reinterpret_cast<decltype(a->detach)>(dlsym(h, "spectrum_stream_detach"));
    a->set_copy = reinterpret_cast<decltype(a->set_copy)>(dlsym(h, "spectrum_stream_set_copy"));
    a->release = reinterpret_cast<decltype(a->release)>(dlsym(h, "spectrum_stream_release"));
    if (!a->decode || !a->take || !a->detach) {
      std::cout << "NAPA: libspectrum-stream.so is too old for streaming NAPA" << std::endl;
      return nullptr;
    }
    return a;
  }();
  return api;
}

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// sc/mjpeg-napa native publish: ntcore's C API from the copy PhotonVision's JVM already loaded (no second ntcore).
struct NtApi {
  int (*set_raw)(unsigned, int64_t, const uint8_t *, size_t) = nullptr;
  int (*set_double_array)(unsigned, int64_t, const double *, size_t) = nullptr;
  void (*flush)(unsigned) = nullptr;
};
const NtApi *Nt() {
  static const NtApi *api = []() -> const NtApi * {
    void *h = dlopen("libntcore.so", RTLD_NOW | RTLD_NOLOAD);
    auto *a = new NtApi;
    a->set_raw = reinterpret_cast<decltype(a->set_raw)>(h ? dlsym(h, "NT_SetRaw") : dlsym(RTLD_DEFAULT, "NT_SetRaw"));
    a->flush = reinterpret_cast<decltype(a->flush)>(h ? dlsym(h, "NT_Flush") : dlsym(RTLD_DEFAULT, "NT_Flush"));
    a->set_double_array = reinterpret_cast<decltype(a->set_double_array)>(
        h ? dlsym(h, "NT_SetDoubleArray") : dlsym(RTLD_DEFAULT, "NT_SetDoubleArray"));
    if (!a->set_raw || !a->flush) {
      std::cout << "NAPA: native publish unavailable (ntcore's C API not found in this process)" << std::endl;
      return nullptr;
    }
    return a;
  }();
  return api;
}

int64_t MonoNs() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return static_cast<int64_t>(t.tv_sec) * 1000000000LL + t.tv_nsec;
}

// What the watcher needs to publish a frame's result itself (set from Java, every frame).
struct PublishCfg {
  unsigned pub = 0, inst = 0;  // ntcore handles: PhotonVision's rawBytes publisher and its instance
  unsigned quality_pub = 0;    // the camera's tagQuality publisher on the same instance (0: none)
  cam_model cam{};
  bool have_cam = false;
  double tag_size = 0.1651;
  int64_t mid_shift_ns = 0;    // frame's first bytes -> mid-exposure
  int64_t cam_shift_ns = 0;    // camera-clock stamp (PTS) -> mid-exposure; 0: don't use the camera clock
  int64_t nt_offset_ns = 0;    // PhotonVision's time-sync offset
  int64_t since_pong = 0;
};

// A streamed frame's result: its tags and when its bytes were first seen.
struct SinkOut {
  std::vector<napa_far::Tag> tags;
  int64_t t_begin;
};

// The camera watcher's side of streaming NAPA: its own detector, fed band by band on the watcher thread.
struct StreamSink {
  napa_far::Detector det;
  std::mutex cfg_mu;
  napa_far::Config cfg;
  bool cfg_new = true;
  PublishCfg pub;              // (cfg_mu)
  int64_t t_begin = 0;         // CLOCK_MONOTONIC when the frame's first bytes were seen
  int64_t t_cam = 0;           // the frame's predicted camera-clock stamp (0: unknown)
  int64_t t_cam_direct = 0;    // native camera backend: the frame's dequeued V4L2 stamp (camera clock), else 0
  std::atomic<long> cam_stamped{0};
  std::atomic<int64_t> taken_sight{0};  // t_begin of the frame detectStreamed last handed to Java
  // Camera clock (hwtimestamps=1). The first sight of a frame's bytes is noisy (sd ~0.07 ms: URB boundary and
  // wake); the camera's PTS-derived V4L2 stamps are steady (interval sd 0.007 ms) but final only at DQBUF, after
  // this publishes. Java hands back the stamps of the frames it detects (~30/s) as anchors; between them the
  // camera's period carries the stamp: t_cam = anchor + round((sight - anchor's sight) / period) x period.
  //
  // The stamp's offset to the frame's first data packet isn't fixed: uvcvideo's SCR clock recovery lands it -0.348
  // or -0.224 ms from the first data packet, a microframe apart, chosen at stream start (kernel trace, 5 sessions).
  // The first sight has no such bias (+0.087 ms, sd 0.07). So the camera clock gives each frame's timing and the
  // long-run mean of (first sight - camera stamp) puts it back on the first data packet:
  //   capture = t_cam + mean(sight - cam) - (mid_shift: seen lag + camera delay + exposure / 2).
  std::mutex cam_mu;
  int64_t anc_sight = 0, anc_cam = 0, last_sight = 0;
  double period = 0, sight_period = 0, sight_off = 0, sight_off_slow = 0;
  double deltas[9] = {};
  int ndeltas = 0, misses = 0;
  void Anchor(int64_t sight, int64_t cam) {
    std::lock_guard<std::mutex> l(cam_mu);
    const double off = static_cast<double>(sight - cam);
    if (off < -2e6 || off > 3e6) return;  // not this frame's stamp
    if (anc_sight && sight > anc_sight && sight_period > 0) {
      const double per = period > 0 ? period : sight_period;
      const long k = std::lround(static_cast<double>(sight - anc_sight) / per);
      if (k >= 1 && k <= 120) {
        const double pm = static_cast<double>(cam - anc_cam) / static_cast<double>(k);
        if (std::fabs(pm - sight_period) < 0.03 * sight_period &&
            (period == 0 || std::fabs(pm - period) < 0.01 * period))
          period = period == 0 ? pm : period + 0.2 * (pm - period);
        else
          period = 0;  // a mode change, or the count was off: start over
      }
    }
    sight_off = sight_off == 0 ? off : sight_off + 0.1 * (off - sight_off);
    // the bias: a slow mean (~3 s at Java's ~30 anchors/s; the sight's 0.07 ms noise averages to ~0.005 ms)
    sight_off_slow = sight_off_slow == 0 ? off : sight_off_slow + 0.01 * (off - sight_off_slow);
    if (sight > anc_sight) anc_sight = sight, anc_cam = cam;
  }
  int64_t Predict(int64_t sight) {
    std::lock_guard<std::mutex> l(cam_mu);
    if (last_sight) {  // the frame period from the sights: median of the last 9 intervals (robust to a late one)
      const double d = static_cast<double>(sight - last_sight);
      if (d > 1e6 && d < 100e6) {
        deltas[ndeltas++ % 9] = d;
        if (ndeltas >= 9) {
          double t[9];
          std::copy(deltas, deltas + 9, t);
          std::nth_element(t, t + 4, t + 9);
          sight_period = t[4];
        }
      }
    }
    last_sight = sight;
    if (period <= 0 || !anc_sight) return 0;
    const long k = std::lround(static_cast<double>(sight - anc_sight) / period);
    if (k < 0 || k > 60) return 0;  // anchors stale (Java not detecting): don't extrapolate far
    const int64_t pred = anc_cam + std::llround(static_cast<double>(k) * period);
    if (std::fabs(static_cast<double>(sight - pred) - sight_off) < 0.3 * period) {
      misses = 0;
      return pred;
    }
    if (++misses >= 5) period = 0, misses = 0;  // locked onto a wrong period or count: start over
    return 0;
  }
  int width = 0, height = 0;
  std::atomic<int64_t> seq{0};
  std::atomic<long> published{0};
  // Rewind: the results published natively, until Java drains them (want_log: Java drained within the last second)
  struct LogItem {
    int64_t t_ns;                 // NT time it was published
    std::vector<uint8_t> packet;  // the PhotonPipelineResult as sent
    std::vector<double> quality;  // its tagQuality ([] without tags)
  };
  std::mutex log_mu;
  std::deque<LogItem> log_q;
  std::atomic<bool> want_log{false};
  std::chrono::steady_clock::time_point log_last{};
  std::atomic<int64_t> lat_sum_ns{0}, lat_n{0};  // capture (mid-exposure) -> publish, since nativeLatencyMs
  spectrum_band_sink c{};
  // Frame policy (docs/FRAME-POLICY.md; setNativePolicy): process 1 frame in `every` (the others aren't decoded),
  // decode processed ones at 1/scale (NAPA on that image with min tag / scale, corners back to full-res pixels),
  // every full_every-th processed one at full scale. Defaults: every frame, full scale.
  std::atomic<int> pol_scale{1}, pol_full_every{0}, pol_every{1};
  long plan_n = 0, proc_n = 0;  // watcher thread
  int planned = 0, cur_scale = 1, applied_scale = 1, full_w = 0;
  std::atomic<long> n_scaled{0}, n_skipped{0};
  explicit StreamSink(const std::string &family) : det(family) {
    c.ctx = this;
    c.plan = [](void *x) -> int {
      auto *s = static_cast<StreamSink *>(x);
      const int every = std::max(1, s->pol_every.load());
      if (++s->plan_n % every != 0) {
        s->n_skipped++;
        return 0;
      }
      const int fe = s->pol_full_every.load(), sc = s->pol_scale.load();
      s->proc_n++;
      s->cur_scale = (fe > 0 && s->proc_n % fe == 0) || (sc != 2 && sc != 4) ? 1 : sc;
      s->planned = 1;
      return s->cur_scale;
    };
    c.begin = [](void *x, const uint8_t *img, int w, int h, int stride) -> int {
      auto *s = static_cast<StreamSink *>(x);
      s->t_begin = MonoNs();
      s->t_cam = s->Predict(s->t_begin);
      // this frame's scale: the plan's, if the watcher honoured it (it decodes full size while the image is copied)
      int sc = s->planned ? s->cur_scale : 1;
      s->planned = 0;
      if (sc > 1 && s->full_w && w * sc != s->full_w) sc = 1;
      if (sc == 1) s->full_w = w;
      s->cur_scale = sc;
      if (sc > 1) s->n_scaled++;
      s->width = w * sc, s->height = h * sc;
      {
        std::lock_guard<std::mutex> l(s->cfg_mu);
        if (s->cfg_new || sc != s->applied_scale) {
          napa_far::Config cf = s->cfg;
          if (sc > 1) {
            cf.min_tag_px = std::max(4, cf.min_tag_px / sc);
            cf.base_min_tag_px = std::max(4, cf.base_min_tag_px / sc);
            cf.far_min_tag_px = std::max(4, cf.far_min_tag_px / sc);
            cf.track_side_px /= sc;
          }
          s->det.SetConfig(cf);
          s->applied_scale = sc;
        }
        s->cfg_new = false;
      }
      return s->det.Begin(img, w, h, stride, NowUs()) ? 1 : 0;
    };
    c.feed = [](void *x, int rows) { static_cast<StreamSink *>(x)->det.Feed(rows); };
    c.finish = [](void *x) -> void * {
      auto *s = static_cast<StreamSink *>(x);
      auto *out = new SinkOut{s->det.Finish(), s->t_begin};
      if (s->cur_scale > 1)  // a reduced frame's corners back to full-res pixels (centres at integers)
        for (auto &t : out->tags)
          for (double &v : t.p) v = v * s->cur_scale + (s->cur_scale - 1) * 0.5;
      s->Publish(out->tags);
      return out;
    };
    c.free_result = [](void *r) { delete static_cast<SinkOut *>(r); };
  }
  // On the watcher thread, the moment the tags are known: pose + PhotonPipelineResult + NT, as PhotonVision's
  // Java pipeline would (pv_pack.h), so the Java pipeline is off the per-frame path.
  void Publish(const std::vector<napa_far::Tag> &tags) {
    PublishCfg p;
    {
      std::lock_guard<std::mutex> l(cfg_mu);
      p = pub;
    }
    const NtApi *nt = p.pub ? Nt() : nullptr;
    if (!nt) return;
    const int n = static_cast<int>(std::min<size_t>(tags.size(), 64));
    int ids[64];
    double corners[64 * 8];
    tag_pose best[64], alt[64];
    for (int i = 0; i < n; i++) {
      ids[i] = tags[i].id;
      std::memcpy(corners + 8 * i, tags[i].p.data(), sizeof(double) * 8);
      if (p.have_cam && pose_ippe_square(&p.cam, corners + 8 * i, p.tag_size, &best[i], &alt[i])) {
        std::memset(&best[i], 0, sizeof best[i]);
        alt[i] = best[i];
      }
    }
    std::vector<uint8_t> buf;
    buf.reserve(1024);
    const int64_t now = MonoNs();
    // capture (mid-exposure): from the camera's clock when known (steady to ~0.01 ms), else from the first sight
    // of the frame's bytes (0-0.15 ms after its first data packet, with the URB boundary and the wake)
    double bias = 0;
    {
      std::lock_guard<std::mutex> l(cam_mu);
      bias = sight_off_slow;
    }
    const bool direct = t_cam_direct > 0 && p.cam_shift_ns > 0;  // the native backend owns the queue
    const bool by_cam = direct || (t_cam > 0 && p.cam_shift_ns > 0 && bias != 0);
    const int64_t capture = direct ? t_cam_direct - p.cam_shift_ns
                            : by_cam ? t_cam + std::llround(bias) - p.mid_shift_ns
                                     : t_begin - p.mid_shift_ns;
    if (by_cam) cam_stamped++;
    const int64_t this_seq = ++seq;
    // photonvision-61's tagQuality for these tags, with this result's sequence ID, just before the result
    std::vector<double> q;
    if ((p.quality_pub && nt->set_double_array) || want_log.load()) {
      q.reserve(2 + 6 * n);
      q.push_back(static_cast<double>(this_seq));
      q.push_back(n);
      for (int i = 0; i < n; i++) {
        const double *c = corners + 8 * i;
        double edge = 1e30;
        for (int k = 0; k < 4; k++)
          edge = std::min({edge, c[2 * k], c[2 * k + 1], width - 1 - c[2 * k], height - 1 - c[2 * k + 1]});
        double tq[3] = {NAN, NAN, NAN};
        if (p.have_cam) pose_tag_quality(&p.cam, c, p.tag_size, &best[i], &alt[i], tq);
        q.insert(q.end(), {static_cast<double>(ids[i]), tags[i].margin, edge, tq[0], tq[1], tq[2]});
      }
      if (n > 0 && p.quality_pub && nt->set_double_array)
        nt->set_double_array(p.quality_pub, 0, q.data(), q.size());
    }
    pvpack::pack_result(buf, this_seq, capture + p.nt_offset_ns, now + p.nt_offset_ns, p.since_pong,
                        p.have_cam ? &p.cam : nullptr, width, height, n, ids, corners, p.have_cam ? best : nullptr,
                        p.have_cam ? alt : nullptr, nullptr);
    nt->set_raw(p.pub, 0, buf.data(), buf.size());
    nt->flush(p.inst);
    if (want_log.load()) {  // for Rewind's vision log (drainNativeResults), while Java asks for them
      std::lock_guard<std::mutex> l(log_mu);
      if (std::chrono::steady_clock::now() - log_last > std::chrono::seconds(1)) {
        want_log = false;  // Java stopped asking (Rewind not recording)
        log_q.clear();
      } else {
        if (log_q.size() >= 256) log_q.pop_front();
        log_q.push_back(LogItem{now + p.nt_offset_ns, buf, n > 0 ? q : std::vector<double>{}});
      }
    }
    lat_sum_ns += MonoNs() - capture;
    lat_n++;
    published++;
  }
};

// ---- native camera backend (docs/SYSTEMCORE-NATIVE-BACKEND.md) ----
// One camera owned natively: its V4L2 queue (our uvcvideo: small URBs, camera-clock stamps), each frame decoded as
// its bytes land (mjdec), streaming NAPA, pose, publish (the StreamSink above, unchanged), tag quality, health
// counters, Rewind video (a ring + writer thread) and the latest image for PhotonVision's UI/stream on request.
struct sj_wait_arg {
  uint32_t seq;
  uint32_t timeout_us;
};
#define SJ_WAIT_IOC _IOWR('u', 0x40, struct sj_wait_arg)

struct NativeCam {
  StreamSink *sink = nullptr;
  std::string dev;
  int fd = -1, w = 0, h = 0, nbuf = 0;
  uint8_t *buf[8] = {};
  size_t blen[8] = {};
  std::thread th;
  std::atomic<bool> stop{false};
  std::atomic<long> frames{0}, bad{0}, skipped{0}, rec_kept{0};
  std::atomic<int64_t> last_frame_ns{0};
  bool sj_wait = false;
  // the latest full-size image for Java (copied only while Java asks, at most once per request)
  std::mutex gmu;
  std::vector<uint8_t> gray;
  int64_t gray_capture_ns = 0;
  std::atomic<bool> want_gray{false};
  // Rewind
  std::mutex rmu;
  RewindWriter *rw = nullptr;

  static int64_t mono() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return static_cast<int64_t>(t.tv_sec) * 1000000000LL + t.tv_nsec;
  }
  int xioctl(unsigned long req, void *arg) {
    int r;
    do r = ioctl(fd, req, arg);
    while (r < 0 && errno == EINTR);
    return r;
  }
  const char *step = "";
  bool open_dev(const std::string &path, int width, int height, int fps) {
    dev = path, w = width, h = height;
    step = "open";
    fd = ::open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return false;
    step = "S_FMT";
    v4l2_format f{};
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.width = width, f.fmt.pix.height = height, f.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(VIDIOC_S_FMT, &f) || (int)f.fmt.pix.width != width || (int)f.fmt.pix.height != height) return false;
    v4l2_streamparm sp{};
    sp.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    sp.parm.capture.timeperframe.numerator = 1, sp.parm.capture.timeperframe.denominator = fps > 0 ? fps : 120;
    xioctl(VIDIOC_S_PARM, &sp);
    step = "REQBUFS";
    v4l2_requestbuffers rb{};
    rb.count = 4, rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, rb.memory = V4L2_MEMORY_MMAP;
    if (xioctl(VIDIOC_REQBUFS, &rb) || rb.count < 2) return false;
    nbuf = std::min<int>(rb.count, 8);
    for (int i = 0; i < nbuf; i++) {
      v4l2_buffer b{};
      b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, b.memory = V4L2_MEMORY_MMAP, b.index = i;
      if (xioctl(VIDIOC_QUERYBUF, &b)) return false;
      void *m = mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
      if (m == MAP_FAILED) return false;
      buf[i] = static_cast<uint8_t *>(m), blen[i] = b.length;
      wipe(i);
      if (xioctl(VIDIOC_QBUF, &b)) return false;
    }
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    step = "STREAMON";
    if (xioctl(VIDIOC_STREAMON, &type)) return false;
    sj_wait_arg a{0, 0};
    sj_wait = xioctl(SJ_WAIT_IOC, &a) == 0;  // our uvcvideo: sleep until the driver copied more bytes
    return true;
  }
  void wipe(int i) { std::memset(buf[i], 0xFF, std::min<size_t>(blen[i], 256 * 1024)); }
  void wait_bytes() {
    if (sj_wait) {
      sj_wait_arg a{0, 2000};
      xioctl(SJ_WAIT_IOC, &a);
    } else {
      timespec ts{0, 100000};
      nanosleep(&ts, nullptr);
    }
  }
  // How many bytes of the frame have landed: the driver writes the wiped (0xFF) buffer front to back, and JPEG
  // data never holds 16 0xFF bytes in a row; trailing 0xFF bytes are held back (they may be wipe).
  static size_t landed(const uint8_t *p, size_t from, size_t cap) {
    size_t q = from & ~static_cast<size_t>(15);
    static const uint8_t ff[16] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    while (q + 16 <= cap && std::memcmp(p + q, ff, 16) != 0) q += 16;
    while (q > from && p[q - 1] == 0xFF) q--;
    return q;
  }
  // Dequeue the buffer the driver finished (blocking up to timeout_ms). Its index, or -1.
  int dqbuf(v4l2_buffer &b, int timeout_ms) {
    const int64_t end = mono() + static_cast<int64_t>(timeout_ms) * 1000000;
    for (;;) {
      b = v4l2_buffer{};
      b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, b.memory = V4L2_MEMORY_MMAP;
      if (xioctl(VIDIOC_DQBUF, &b) == 0) return static_cast<int>(b.index);
      if (errno != EAGAIN || mono() > end) return -1;
      timespec ts{0, 50000};
      nanosleep(&ts, nullptr);
    }
  }
  void requeue(int i) {
    wipe(i);
    v4l2_buffer b{};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, b.memory = V4L2_MEMORY_MMAP, b.index = i;
    xioctl(VIDIOC_QBUF, &b);
  }
  void loop() {
    pthread_setname_np(pthread_self(), "SpectrumCamera");
    std::unique_ptr<mjdec, void (*)(mjdec *)> mj(mjdec_create(), mjdec_destroy);
    std::vector<uint8_t> img(static_cast<size_t>(w) * h);
    int next = 0;  // the driver fills the queued buffers in queue order
    while (!stop) {
      uint8_t *p = buf[next];
      // the frame's first bytes
      const int64_t wait0 = mono();
      while (!stop && !(p[0] == 0xFF && p[1] == 0xD8)) {
        v4l2_buffer b;
        if (mono() - wait0 > 300000000LL) {  // nothing for 300 ms: resynchronise on whatever completes
          const int i = dqbuf(b, 0);
          if (i >= 0) requeue(i), next = (i + 1) % nbuf;
          if (mono() - wait0 > 2000000000LL) break;
        }
        wait_bytes();
      }
      if (stop || !(p[0] == 0xFF && p[1] == 0xD8)) continue;
      const int64_t t_sight = mono();
      int scale = sink->c.plan ? sink->c.plan(sink) : 1;
      bool fed = false;
      int rows = 0, hs = h;
      if (scale != 0) {
        hs = h / scale;
        mjdec_set_scale(mj.get(), scale);
        if (mjdec_begin(mj.get(), p, blen[next], img.data(), w, h, w / scale) == 0)
          fed = sink->c.begin(sink, img.data(), w / scale, hs, w / scale) != 0;
        sink->t_begin = t_sight;
        size_t got = 0;
        bool ok = true;
        while (!stop && rows < hs) {
          const size_t a = landed(p, got, blen[next]);
          if (a > got) {
            got = a;
            const int r = mjdec_feed(mj.get(), got);
            if (r < 0) {
              ok = false;
              break;
            }
            if (r > rows) {
              rows = r;
              if (fed) sink->c.feed(sink, rows);
            }
            continue;
          }
          if (mono() - t_sight > 50000000LL) {  // stuck mid-frame
            ok = false;
            break;
          }
          wait_bytes();
        }
        if (!ok) bad++;
      } else {
        skipped++;
      }
      // the finished buffer, with its camera-clock stamp
      v4l2_buffer b;
      const int i = dqbuf(b, 30);
      if (i < 0) {
        if (fed) sink->c.free_result(sink->c.finish(sink));
        continue;
      }
      const int64_t stamp = static_cast<int64_t>(b.timestamp.tv_sec) * 1000000000LL + b.timestamp.tv_usec * 1000LL;
      if (fed) {
        sink->t_cam_direct = (b.flags & V4L2_BUF_FLAG_ERROR) ? 0 : stamp;
        sink->c.free_result(sink->c.finish(sink));  // publishes (pose, result, quality, health counters)
        sink->t_cam_direct = 0;
      }
      if (i == next && !(b.flags & V4L2_BUF_FLAG_ERROR) && rows >= hs) {
        frames++;
        last_frame_ns = mono();
        if (scale == 1 && want_gray.load()) {  // Java's UI / stream: the latest image, when it asks
          std::lock_guard<std::mutex> l(gmu);
          gray.assign(img.begin(), img.end());
          gray_capture_ns = stamp;
          want_gray = false;
        }
      }
      {
        std::lock_guard<std::mutex> l(rmu);
        if (rw && b.bytesused > 0 && !(b.flags & V4L2_BUF_FLAG_ERROR))
          rec_kept += rewind_push(rw, buf[i], b.bytesused, w, h, stamp / 1000, 0);
      }
      requeue(i);
      next = (i + 1) % nbuf;
    }
  }
  ~NativeCam() {
    stop = true;
    if (th.joinable()) th.join();
    if (fd >= 0) {
      int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      xioctl(VIDIOC_STREAMOFF, &type);
      for (int i = 0; i < nbuf; i++)
        if (buf[i]) munmap(buf[i], blen[i]);
      ::close(fd);
    }
    std::lock_guard<std::mutex> l(rmu);
    if (rw) rewind_close(rw);
  }
};

// One camera's handle: the whole-frame detector, and the streaming side once detectStreamed is used.
struct Napa {
  napa_far::Detector det;
  std::unique_ptr<StreamSink> sink;
  std::unique_ptr<napa_far::Detector> check;  // the identity check's whole-frame detector
  std::atomic<bool> checking{false};
  std::thread check_thread;
  long streamed = 0, fallback = 0, not_streamed = 0, check_due = 0;
  std::atomic<long> check_ok{0}, check_differ{0}, check_skipped{0};
  std::chrono::steady_clock::time_point next_log{};
  std::unique_ptr<NativeCam> cam;  // the native camera backend, when this handle owns the camera
  explicit Napa(const std::string &family) : det(family) {}
  ~Napa() {
    cam.reset();  // stops its thread before the sink goes
    if (sink && Stream()) Stream()->detach(sink->c.ctx);
    if (check_thread.joinable()) check_thread.join();
  }
};

Napa *Handle(jlong h) { return reinterpret_cast<Napa *>(h); }

bool Same(const std::vector<napa_far::Tag> &a, const std::vector<napa_far::Tag> &b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++)
    if (a[i].id != b[i].id || a[i].hamming != b[i].hamming || a[i].margin != b[i].margin ||
        a[i].far != b[i].far || std::memcmp(a[i].p.data(), b[i].p.data(), sizeof(double) * 8) != 0)
      return false;
  return true;
}

// Every 64th streamed frame: re-detect the same gray image whole, on a low-priority thread (one at a
// time; skipped while one runs), and compare. Far search keeps per-detector state (tracks, the sweep
// schedule), so frames are only comparable with it off; with it on the check is counted as skipped.
void IdentityCheck(Napa *n, const uint8_t *img, int w, int h, int step, const std::vector<napa_far::Tag> &got,
                   int64_t now_us) {
  const auto cfg = n->det.GetConfig();
  if (cfg.far) {
    n->check_skipped++;
    return;
  }
  if (n->checking.exchange(true)) return;
  if (n->check_thread.joinable()) n->check_thread.join();
  std::vector<uint8_t> copy(static_cast<size_t>(w) * h);
  for (int y = 0; y < h; y++) std::memcpy(copy.data() + static_cast<size_t>(y) * w, img + static_cast<size_t>(y) * step, w);
  if (!n->check) n->check = std::make_unique<napa_far::Detector>(n->det.family());
  n->check->SetConfig(cfg);
  n->check_thread = std::thread([n, copy = std::move(copy), got, w, h, now_us]() {
    setpriority(PRIO_PROCESS, static_cast<id_t>(syscall(SYS_gettid)), 19);
    const auto ref = n->check->Detect(copy.data(), w, h, w, now_us);
    if (Same(ref, got)) {
      n->check_ok++;
    } else {
      n->check_differ++;
      std::cout << "NAPA streaming: a streamed result differs from whole-frame NAPA (" << got.size() << " vs "
                << ref.size() << " tags)" << std::endl;
    }
    n->checking = false;
  });
}

jobjectArray ToJava(JNIEnv *env, const std::string &family, const std::vector<napa_far::Tag> &tags);
}  // namespace

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  // WPILib 2027 moved AprilTagDetection; 2026 is edu.wpi.first.apriltag.
  for (const char *name :
       {"org/wpilib/vision/apriltag/AprilTagDetection", "edu/wpi/first/apriltag/AprilTagDetection"}) {
    jclass local = env->FindClass(name);
    if (!local) {
      env->ExceptionClear();
      continue;
    }
    detectionCls = static_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
    break;
  }
  if (!detectionCls) {
    std::cout << "NAPA detector could not find AprilTagDetection (WPILib 2027 or 2026)" << std::endl;
    return JNI_ERR;
  }
  detectionCtor = env->GetMethodID(detectionCls, "<init>", "(Ljava/lang/String;IIF[DDD[D)V");
  if (!detectionCtor) return JNI_ERR;
  std::cout << "NAPA AprilTag detector loaded (NAPA v0.5.1 by Zachary Wilson, GPL-3.0-only)" << std::endl;
  return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM *vm, void *) {
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return;
  if (detectionCls) env->DeleteGlobalRef(detectionCls);
  detectionCls = nullptr;
}

JNIEXPORT jlong JNICALL Java_org_photonvision_jni_NapaDetectorJNI_create(JNIEnv *env, jclass, jstring family) {
  std::string fam = "tag36h11";
  if (family) {
    const char *c = env->GetStringUTFChars(family, nullptr);
    if (c) fam = c;
    env->ReleaseStringUTFChars(family, c);
  }
  auto d = std::make_unique<Napa>(fam);
  if (!d->det.ok()) return 0;
  return reinterpret_cast<jlong>(d.release());
}

JNIEXPORT void JNICALL Java_org_photonvision_jni_NapaDetectorJNI_destroy(JNIEnv *, jclass, jlong h) {
  delete Handle(h);
}

JNIEXPORT void JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setParams(JNIEnv *, jclass, jlong h,
                                                                           jint minTagPx, jint maxHamming,
                                                                           jboolean far, jint baseMinTagPx,
                                                                           jint farMinTagPx,
                                                                           jdouble sweepsPerSecond) {
  auto *n = Handle(h);
  if (!n) return;
  auto *d = &n->det;
  auto c = d->GetConfig();
  c.min_tag_px = std::clamp<int>(minTagPx, 8, 30000);
  c.max_hamming = std::clamp<int>(maxHamming, 0, 3);
  c.far = far == JNI_TRUE;
  c.base_min_tag_px = std::clamp<int>(baseMinTagPx, 8, 30000);
  c.far_min_tag_px = std::clamp<int>(farMinTagPx, 8, 30000);
  c.sweeps_per_s = sweepsPerSecond;
  d->SetConfig(c);
  if (n->sink) {  // the streaming side (fast path / native camera) takes it at its next frame
    std::lock_guard<std::mutex> l(n->sink->cfg_mu);
    n->sink->cfg = c;
    n->sink->cfg_new = true;
  }
}

JNIEXPORT void JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setEarlySlack(JNIEnv *, jclass, jlong h,
                                                                               jint slack) {
  auto *n = Handle(h);
  if (!n) return;
  auto *d = &n->det;
  auto c = d->GetConfig();
  c.early_slack = std::clamp<int>(slack, 0, 3);
  d->SetConfig(c);
}

JNIEXPORT jobjectArray JNICALL Java_org_photonvision_jni_NapaDetectorJNI_detect(JNIEnv *env, jclass, jlong h,
                                                                                jlong data, jint width,
                                                                                jint height, jint step) {
  auto *n = Handle(h);
  if (!n || !data || width <= 0 || height <= 0 || step < width) return nullptr;
  const auto tags = n->det.Detect(reinterpret_cast<const uint8_t *>(data), width, height, step, NowUs());
  return ToJava(env, n->det.family(), tags);
}

JNIEXPORT jboolean JNICALL Java_org_photonvision_jni_NapaDetectorJNI_streamAvailable(JNIEnv *, jclass) {
  return Stream() ? JNI_TRUE : JNI_FALSE;
}

// cscore's C frame struct (WPILib 2026 and 2027 alpha-8 layout; detector/wpi_compat.h).
struct RawFrame {
  uint8_t *data;
  void (*freeFunc)(void *, void *, size_t);
  void *freeCbData;
  size_t capacity;
  size_t size;
  int pixelFormat;
  int width;
  int height;
  int stride;
  int64_t timestamp;
  int timestampSrc;
};
static_assert(sizeof(RawFrame) == 72, "WPI_RawFrame layout changed");

// sc/mjpeg-napa: the single-tag pose natively (native/sc-vision/src/pose.c: IPPE for a square + Gauss-Newton on
// the pixel reprojection error, ~10 us), instead of WPILib's orthogonal iteration plus OpenCV's IPPE for the
// alternate in Java (~0.28 ms a frame). corners: AprilTag order, raw pixels. K: 3x3 row-major; dist: up to 8
// OpenCV coefficients. Returns {best t[3], R[9], err, alt t[3], R[9], err} in the AprilTag frame (x right, y down,
// z into the tag), errors in pixels; null for a degenerate quad.
JNIEXPORT jdoubleArray JNICALL Java_org_photonvision_jni_NapaDetectorJNI_poseSquare(JNIEnv *env, jclass,
                                                                                   jdoubleArray jc, jdoubleArray jk,
                                                                                   jdoubleArray jd, jdouble size) {
  double c[8], k[9], d[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  if (env->GetArrayLength(jc) < 8 || env->GetArrayLength(jk) < 9) return nullptr;
  env->GetDoubleArrayRegion(jc, 0, 8, c);
  env->GetDoubleArrayRegion(jk, 0, 9, k);
  const jsize nd = std::min<jsize>(8, env->GetArrayLength(jd));
  if (nd > 0) env->GetDoubleArrayRegion(jd, 0, nd, d);
  cam_model cam{};
  cam.fx = k[0], cam.cx = k[2], cam.fy = k[4], cam.cy = k[5];
  for (int i = 0; i < 8; i++) cam.k[i] = d[i];
  tag_pose best, alt;
  if (pose_ippe_square(&cam, c, size, &best, &alt)) return nullptr;
  double out[26];
  const tag_pose *ps[2] = {&best, &alt};
  for (int s = 0; s < 2; s++) {
    double *o = out + 13 * s;
    for (int i = 0; i < 3; i++) o[i] = ps[s]->t[i];
    // Already AprilTag's tag frame: the corners come in AprilTag's order and pose.c pairs corner i with the same
    // object point AprilTag's estimate_tag_pose does ((-s/2, s/2), (s/2, s/2), (s/2, -s/2), (-s/2, -s/2): x right,
    // y down, z into the tag). (photonvision-108 to -115 flipped it by diag(1,-1,-1): published rotations were
    // 180 degrees off against WPILib's orthogonal iteration, and TagQuality's reprojection read about a tag side.)
    for (int i = 0; i < 9; i++) o[3 + i] = ps[s]->R[i];
    o[12] = ps[s]->err;
  }
  jdoubleArray arr = env->NewDoubleArray(26);
  if (arr) env->SetDoubleArrayRegion(arr, 0, 26, out);
  return arr;
}

// sc/mjpeg-napa native publish: the watcher publishes each streamed frame's PhotonPipelineResult on PhotonVision's
// rawBytes publisher (pub, an ntcore handle; 0 = off) the moment its tags are known. k/dist: calibration (null:
// no pose); midShiftNs: first bytes -> mid-exposure; ntOffsetNs: PhotonVision's time-sync offset. Call every
// frame (cheap). Returns frames published so far, or -1 when ntcore's C API isn't reachable / not streaming yet.
JNIEXPORT jlong JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setNativePublish(
    JNIEnv *env, jclass, jlong h, jint pub, jint inst, jdoubleArray jk, jdoubleArray jd, jdouble size, jlong midShiftNs,
    jlong ntOffsetNs, jlong sincePongNs) {
  auto *n = Handle(h);
  if (!n || !n->sink) return -1;
  if (pub && !Nt()) return -1;
  PublishCfg p;
  p.pub = static_cast<unsigned>(pub);
  p.inst = static_cast<unsigned>(inst);
  if (jk && env->GetArrayLength(jk) >= 9) {
    double k[9], d[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    env->GetDoubleArrayRegion(jk, 0, 9, k);
    const jsize nd = jd ? std::min<jsize>(8, env->GetArrayLength(jd)) : 0;
    if (nd > 0) env->GetDoubleArrayRegion(jd, 0, nd, d);
    p.cam.fx = k[0], p.cam.cx = k[2], p.cam.fy = k[4], p.cam.cy = k[5];
    for (int i = 0; i < 8; i++) p.cam.k[i] = d[i];
    p.have_cam = true;
  }
  p.tag_size = size;
  p.mid_shift_ns = midShiftNs;
  {
    std::lock_guard<std::mutex> l(n->sink->cfg_mu);
    p.cam_shift_ns = n->sink->pub.cam_shift_ns;  // set by setNativeCamShift
    p.quality_pub = n->sink->pub.quality_pub;    // set by setNativeQualityPub
  }
  p.nt_offset_ns = ntOffsetNs;
  p.since_pong = sincePongNs;
  {
    std::lock_guard<std::mutex> l(n->sink->cfg_mu);
    n->sink->pub = p;
  }
  return n->sink->published.load();
}

// sc/mjpeg-napa: camera-clock stamp (uvcvideo hwtimestamps=1: the PTS, which marks the end of exposure) ->
// mid-exposure, ns (exposure/2 + the PTS's delay after exposure end); 0: stamp from the first sight of the bytes.
// Returns how many published results were stamped from the camera clock so far.
// lastFrameCamNs: the camera-clock stamp of the frame detectStreamed last returned (0: none), an anchor.
JNIEXPORT jlong JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setNativeCamShift(JNIEnv *, jclass, jlong h,
                                                                                    jlong camShiftNs,
                                                                                    jlong lastFrameCamNs) {
  auto *n = Handle(h);
  if (!n || !n->sink) return -1;
  {
    std::lock_guard<std::mutex> l(n->sink->cfg_mu);
    n->sink->pub.cam_shift_ns = camShiftNs;
  }
  const int64_t sight = n->sink->taken_sight.exchange(0);
  if (lastFrameCamNs > 0 && sight > 0) n->sink->Anchor(sight, lastFrameCamNs);
  return n->sink->cam_stamped.load();
}

// sc/mjpeg-napa: the camera's tagQuality publisher (an ntcore DoubleArray publisher handle on the same instance
// as the native rawBytes publisher; 0: none). The native publish sends each result's tag quality with its own
// sequence ID just before the result, as PhotonVision's Java path does.
JNIEXPORT void JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setNativeQualityPub(JNIEnv *, jclass, jlong h,
                                                                                    jint pub) {
  auto *n = Handle(h);
  if (!n || !n->sink) return;
  std::lock_guard<std::mutex> l(n->sink->cfg_mu);
  n->sink->pub.quality_pub = static_cast<unsigned>(pub);
}

// sc/mjpeg-napa: the results this camera's native publish sent since the last call, for Rewind's vision log. Each
// element: [8 bytes publish time (NT ns, little-endian)][4 bytes quality count q][q doubles][the result packet].
// Calling it turns the collection on; it stops 1 s after the last call. Null when there's nothing.
JNIEXPORT jobjectArray JNICALL Java_org_photonvision_jni_NapaDetectorJNI_drainNativeResults(JNIEnv *env, jclass,
                                                                                            jlong h) {
  auto *n = Handle(h);
  if (!n || !n->sink) return nullptr;
  auto *s = n->sink.get();
  std::deque<StreamSink::LogItem> items;
  {
    std::lock_guard<std::mutex> l(s->log_mu);
    s->log_last = std::chrono::steady_clock::now();
    s->want_log = true;
    items.swap(s->log_q);
  }
  if (items.empty()) return nullptr;
  jclass cls = env->FindClass("[B");
  jobjectArray arr = env->NewObjectArray(static_cast<jsize>(items.size()), cls, nullptr);
  jsize k = 0;
  for (const auto &it : items) {
    const uint32_t nq = static_cast<uint32_t>(it.quality.size());
    std::vector<uint8_t> b(12 + 8 * nq + it.packet.size());
    std::memcpy(b.data(), &it.t_ns, 8);
    std::memcpy(b.data() + 8, &nq, 4);
    if (nq) std::memcpy(b.data() + 12, it.quality.data(), 8 * nq);
    std::memcpy(b.data() + 12 + 8 * nq, it.packet.data(), it.packet.size());
    jbyteArray ba = env->NewByteArray(static_cast<jsize>(b.size()));
    env->SetByteArrayRegion(ba, 0, static_cast<jsize>(b.size()), reinterpret_cast<const jbyte *>(b.data()));
    env->SetObjectArrayElement(arr, k++, ba);
    env->DeleteLocalRef(ba);
  }
  return arr;
}

// ---- native camera backend JNI (docs/SYSTEMCORE-NATIVE-BACKEND.md) ----
// Opens the camera (a /dev/video path, e.g. /dev/v4l/by-id/...-index0) natively: MJPEG width x height at fps, its own
// capture thread, decode + streaming NAPA + pose + publish on it. Returns a NAPA handle (all the setNative* calls,
// setParams, nativeLatencyMs and drainNativeResults work on it; destroy() closes the camera), or 0.
JNIEXPORT jlong JNICALL Java_org_photonvision_jni_NapaDetectorJNI_cameraOpen(JNIEnv *env, jclass, jstring jdev,
                                                                            jint width, jint height, jint fps,
                                                                            jstring family) {
  const char *d = env->GetStringUTFChars(jdev, nullptr);
  const char *f = env->GetStringUTFChars(family, nullptr);
  std::string dev(d), fam(f);
  env->ReleaseStringUTFChars(jdev, d);
  env->ReleaseStringUTFChars(family, f);
  auto *n = new Napa(fam);
  n->sink = std::make_unique<StreamSink>(fam);
  {
    std::lock_guard<std::mutex> l(n->sink->cfg_mu);
    n->sink->cfg = n->det.GetConfig();
    n->sink->cfg_new = true;
  }
  n->sink->log_last = std::chrono::steady_clock::now();
  // the streaming decoder's watcher of this camera (from frames cscore delivered before) keeps cscore's buffers
  // mapped, and vb2 then refuses our REQBUFS (EBUSY): stop it first
  if (const StreamApi *sa = Stream())
    if (sa->release) sa->release(dev.c_str());
  auto cam = std::make_unique<NativeCam>();
  cam->sink = n->sink.get();
  if (!cam->open_dev(dev, width, height, fps)) {
    std::cout << "native camera: cannot open " << dev << " (" << cam->step << ": " << std::strerror(errno) << ")"
              << std::endl;
    delete n;
    return 0;
  }
  auto *c = cam.get();
  c->th = std::thread([c] { c->loop(); });
  n->cam = std::move(cam);
  std::cout << "native camera: " << dev << " " << width << "x" << height << " MJPEG, "
            << (c->sj_wait ? "driver wake per URB" : "polling") << std::endl;
  return reinterpret_cast<jlong>(n);
}

// Sets a V4L2 control on the native camera, read first: 1 written, 0 already that value, -1 error.
JNIEXPORT jint JNICALL Java_org_photonvision_jni_NapaDetectorJNI_cameraSetControl(JNIEnv *, jclass, jlong h, jint id,
                                                                                 jint value) {
  auto *n = Handle(h);
  if (!n || !n->cam) return -1;
  v4l2_control c{};
  c.id = static_cast<uint32_t>(id);
  if (n->cam->xioctl(VIDIOC_G_CTRL, &c) == 0 && c.value == value) return 0;  // the Swyft writes controls to flash
  c.value = value;
  return n->cam->xioctl(VIDIOC_S_CTRL, &c) == 0 ? 1 : -1;
}

// A V4L2 control's value, or Integer.MIN_VALUE.
JNIEXPORT jint JNICALL Java_org_photonvision_jni_NapaDetectorJNI_cameraGetControl(JNIEnv *, jclass, jlong h, jint id) {
  auto *n = Handle(h);
  if (!n || !n->cam) return INT32_MIN;
  v4l2_control c{};
  c.id = static_cast<uint32_t>(id);
  return n->cam->xioctl(VIDIOC_G_CTRL, &c) == 0 ? c.value : INT32_MIN;
}

// The latest full-size gray image into dataAddr (width x height, stride width), for the UI / stream / Java pipeline
// at its own low rate. Returns its camera stamp (ns), or 0 when none is ready yet (the next frame provides one).
JNIEXPORT jlong JNICALL Java_org_photonvision_jni_NapaDetectorJNI_cameraLatestGray(JNIEnv *, jclass, jlong h,
                                                                                  jlong data, jint width,
                                                                                  jint height) {
  auto *n = Handle(h);
  if (!n || !n->cam || !data) return 0;
  auto *c = n->cam.get();
  std::lock_guard<std::mutex> l(c->gmu);
  if (c->gray.size() != static_cast<size_t>(width) * height || c->gray_capture_ns == 0) {
    c->want_gray = true;
    return 0;
  }
  std::memcpy(reinterpret_cast<uint8_t *>(data), c->gray.data(), c->gray.size());
  const int64_t t = c->gray_capture_ns;
  c->gray_capture_ns = 0;  // used: the next request waits for a newer frame
  c->want_gray = true;
  return t;
}

// {frames, bad frames, frames skipped by the policy, ms since the last frame (-1: none), Rewind frames kept}.
JNIEXPORT jlongArray JNICALL Java_org_photonvision_jni_NapaDetectorJNI_cameraStats(JNIEnv *env, jclass, jlong h) {
  auto *n = Handle(h);
  if (!n || !n->cam) return nullptr;
  auto *c = n->cam.get();
  const int64_t last = c->last_frame_ns.load();
  jlong v[5] = {c->frames.load(), c->bad.load(), c->skipped.load(),
                last ? (NativeCam::mono() - last) / 1000000 : -1, c->rec_kept.load()};
  jlongArray a = env->NewLongArray(5);
  if (a) env->SetLongArrayRegion(a, 0, 5, v);
  return a;
}

// Rewind video from the native thread: prefix (path without _NNNN; null stops), ring MB (default 32), record fps
// (0: every frame; independent of the frame policy). Returns true when recording.
JNIEXPORT jboolean JNICALL Java_org_photonvision_jni_NapaDetectorJNI_cameraRecord(JNIEnv *env, jclass, jlong h,
                                                                                 jstring prefix, jint ringMb,
                                                                                 jdouble recordFps) {
  auto *n = Handle(h);
  if (!n || !n->cam) return JNI_FALSE;
  auto *c = n->cam.get();
  RewindWriter *old = nullptr;
  RewindWriter *nw = nullptr;
  if (prefix) {
    const char *p = env->GetStringUTFChars(prefix, nullptr);
    nw = rewind_open(p, static_cast<size_t>(ringMb > 0 ? ringMb : 32) << 20, recordFps);
    env->ReleaseStringUTFChars(prefix, p);
  }
  {
    std::lock_guard<std::mutex> l(c->rmu);
    old = c->rw;
    c->rw = nw;
  }
  if (old) rewind_close(old);  // drains and syncs, off the camera thread
  return nw ? JNI_TRUE : JNI_FALSE;
}

// sc/mjpeg-napa frame policy for this camera's streamed frames (docs/FRAME-POLICY.md): decode scale 1, 2 or 4
// (others: 1), every fullEvery-th processed frame at full scale (0: never forced), process 1 frame in processEvery
// (>= 1; the others aren't decoded). Scale and skipping only apply while nobody watches the stream (image copy
// off). Returns frames decoded reduced so far.
JNIEXPORT jlong JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setNativePolicy(JNIEnv *, jclass, jlong h,
                                                                                  jint scale, jint fullEvery,
                                                                                  jint processEvery) {
  auto *n = Handle(h);
  if (!n || !n->sink) return -1;
  n->sink->pol_scale = scale == 2 || scale == 4 ? scale : 1;
  n->sink->pol_full_every = std::max(0, static_cast<int>(fullEvery));
  n->sink->pol_every = std::max(1, static_cast<int>(processEvery));
  return n->sink->n_scaled.load();
}

// Mean capture (mid-exposure) -> publish of this camera's natively published results since the last call, ms;
// -1 if none.
JNIEXPORT jdouble JNICALL Java_org_photonvision_jni_NapaDetectorJNI_nativeLatencyMs(JNIEnv *, jclass, jlong h) {
  auto *n = Handle(h);
  if (!n || !n->sink) return -1;
  const int64_t c = n->sink->lat_n.exchange(0);
  const int64_t sum = n->sink->lat_sum_ns.exchange(0);
  return c > 0 ? sum / 1e6 / c : -1;
}

// Whether streamDecodeGray copies the decoded image (false: only when nobody watches the stream; the tags come from
// the band sink). True if the library supports it.
JNIEXPORT jboolean JNICALL Java_org_photonvision_jni_NapaDetectorJNI_setStreamCopy(JNIEnv *, jclass, jboolean on) {
  const StreamApi *api = Stream();
  if (!api || !api->set_copy) return JNI_FALSE;
  api->set_copy(on ? 1 : 0);
  return JNI_TRUE;
}

JNIEXPORT jint JNICALL Java_org_photonvision_jni_NapaDetectorJNI_streamDecodeGray(JNIEnv *, jclass, jlong raw,
                                                                                  jlong data, jint width,
                                                                                  jint height, jint step) {
  const auto *f = reinterpret_cast<const RawFrame *>(raw);
  if (!Stream() || !f || !data || f->pixelFormat != 1 /* MJPEG */ || !f->data || f->size < 4 || step < width)
    return -1;
  return Stream()->decode(f->data, f->size, reinterpret_cast<uint8_t *>(data), width, height,
                          static_cast<size_t>(step));
}

JNIEXPORT jobjectArray JNICALL Java_org_photonvision_jni_NapaDetectorJNI_detectStreamed(
    JNIEnv *env, jclass, jlong h, jlong data, jint width, jint height, jint step, jlong wantAfterNanos) {
  auto *n = Handle(h);
  if (!n || !data || width <= 0 || height <= 0 || step < width) return nullptr;
  const auto *img = reinterpret_cast<const uint8_t *>(data);
  const int64_t now_us = NowUs();
  std::vector<napa_far::Tag> tags;
  int rc = -1;
  if (const StreamApi *api = Stream()) {
    if (!n->sink) n->sink = std::make_unique<StreamSink>(n->det.family());
    {
      std::lock_guard<std::mutex> l(n->sink->cfg_mu);
      n->sink->cfg = n->det.GetConfig();
      n->sink->cfg_new = true;  // cheap: applied at the next frame's Begin
    }
    void *res = nullptr;
    rc = api->take(img, width, height, static_cast<size_t>(step), &n->sink->c, wantAfterNanos, &res);
    if (rc == 1) {
      tags.swap(static_cast<SinkOut *>(res)->tags);
      n->sink->taken_sight = static_cast<SinkOut *>(res)->t_begin;
      n->sink->c.free_result(res);
      n->streamed++;
      // (a frame handed over without its pixels (no stream viewer) can't be re-detected here)
      if (++n->check_due % 64 == 0 && !(width >= 8 && std::memcmp(img, "SJREFv1", 8) == 0))
        IdentityCheck(n, img, width, height, step, tags, now_us);
    }
  }
  if (rc != 1) {
    (rc == 0 ? n->fallback : n->not_streamed)++;
    tags = n->det.Detect(img, width, height, step, now_us);
  }
  const auto now = std::chrono::steady_clock::now();
  if (now >= n->next_log) {
    if (n->next_log != std::chrono::steady_clock::time_point{})
      std::printf("NAPA streaming: %ld streamed, %ld whole-frame (%ld not fed, %ld not stream-decoded); "
                  "identity checks ok %ld differ %ld skipped (far search) %ld\n",
                  n->streamed, n->fallback + n->not_streamed, n->fallback, n->not_streamed, n->check_ok.load(),
                  n->check_differ.load(), n->check_skipped.load());
    if (n->sink && n->sink->pub.cam_shift_ns > 0) {
      std::lock_guard<std::mutex> l(n->sink->cam_mu);
      std::printf("NAPA native publish: %ld results stamped from the camera clock so far, period %.4f ms, "
                  "first sight - camera stamp %.3f ms (slow mean %.3f)\n",
                  n->sink->cam_stamped.load(), n->sink->period / 1e6, n->sink->sight_off / 1e6,
                  n->sink->sight_off_slow / 1e6);
    }
    std::fflush(stdout);
    n->next_log = now + std::chrono::seconds(10);
    n->streamed = n->fallback = n->not_streamed = 0;
  }
  return ToJava(env, n->det.family(), tags);
}

}  // extern "C"

namespace {
jobjectArray ToJava(JNIEnv *env, const std::string &family, const std::vector<napa_far::Tag> &tags) {
  jobjectArray arr = env->NewObjectArray(static_cast<jsize>(tags.size()), detectionCls, nullptr);
  if (!arr) return nullptr;
  jstring fam = env->NewStringUTF(family.c_str());
  for (size_t i = 0; i < tags.size(); ++i) {
    const auto &t = tags[i];
    const auto H = t.Homography();
    jdoubleArray harr = env->NewDoubleArray(9);
    jdoubleArray carr = env->NewDoubleArray(8);
    if (!harr || !carr) return nullptr;
    env->SetDoubleArrayRegion(harr, 0, 9, H.data());
    env->SetDoubleArrayRegion(carr, 0, 8, t.p.data());
    // Centre: the homography's image of the tag centre, as AprilTag's det->c.
    const double cx = H[2] / H[8], cy = H[5] / H[8];
    jobject o = env->NewObject(detectionCls, detectionCtor, fam, static_cast<jint>(t.id),
                               static_cast<jint>(t.hamming), static_cast<jfloat>(t.margin), harr, cx, cy, carr);
    env->SetObjectArrayElement(arr, static_cast<jsize>(i), o);
    env->DeleteLocalRef(o);
    env->DeleteLocalRef(harr);
    env->DeleteLocalRef(carr);
  }
  env->DeleteLocalRef(fam);
  return arr;
}
}  // namespace

extern "C" {

JNIEXPORT jdoubleArray JNICALL Java_org_photonvision_jni_NapaDetectorJNI_stats(JNIEnv *env, jclass, jlong h) {
  auto *n = Handle(h);
  if (!n) return nullptr;
  const auto c = n->det.GetCounters();
  const double v[7] = {static_cast<double>(c.frames), c.base_ms,    static_cast<double>(c.crops), c.crop_ms,
                       static_cast<double>(c.sweeps), c.sweep_ms, static_cast<double>(c.far_tags)};
  jdoubleArray arr = env->NewDoubleArray(7);
  if (arr) env->SetDoubleArrayRegion(arr, 0, 7, v);
  return arr;
}

}  // extern "C"
