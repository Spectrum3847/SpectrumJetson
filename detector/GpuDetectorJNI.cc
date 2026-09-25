// JNI bridge between the FRC-Team-4143 PhotonVision fork (org.photonvision.jni.GpuDetectorJNI)
// and Austin Schuh's current CUDA AprilTag detector, as built in frc971/bos
// third_party/971apriltag (from RealtimeRoboticsGroup/aos frc/orin).
//
// Keeps the exact Java API of FRC-Team-4143/GpuDetectorJNI so the fork jar is unchanged:
//   long createGpuDetector(int width, int height)
//   void destroyGpuDetector(long handle)
//   void setparams(long handle, fx, cx, fy, cy, k1, k2, p1, p2, k3)
//   void setparams8(long handle, fx, cx, fy, cy, k1, k2, p1, p2, k3, k4, k5, k6)   // ours
//   AprilTagDetection[] processimage(long handle, long cvMatPtr)   // 8-bit mono Mat
//
// Differences from the 4143 JNI (see SpectrumJetson patches/gpudetector-0*.patch for the
// same fixes applied to the old code):
//   - detector slots are reused after destroy; every handle is bounds-checked
//   - detectors are freed with apriltag_detector_destroy / tag36h11_destroy
//   - a per-slot mutex stops destroy/setparams racing processimage
//   - stale CUDA errors are cleared before each detect (NVIDIA/cccl#1791)
//   - Detect() failures (absl::Status) are logged and return no detections
//   - CUDA errors throw (patches/bos-01-nonfatal-cuda.patch) instead of aborting the JVM:
//     the frame is skipped and the detector rebuilt on the next frame; only after
//     the CUDA context stays broken (sticky error) for kMaxFailingTime do we exit so systemd restarts
//     PhotonVision (a broken CUDA context cannot be recovered in-process)
//   - no per-detection std::cout; a once-per-second stats line instead

#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <csetjmp>

#include <dlfcn.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cuda_runtime.h>
#include <jpeglib.h>
#include "nvjpg_decoder.h"
#include <wpi/util/PixelFormat.h>
#include <wpi/util/RawFrame.h>
#include "absl/status/status.h"
#include <opencv2/core/mat.hpp>

#include "apriltag/apriltag.h"
#include "apriltag/tag36h11.h"
#include "third_party/971apriltag/apriltag.h"

void SpectrumInjectStickyCudaFault();  // fault_kernel.cu (test only)

namespace {

class GlobalJClass {
 public:
  GlobalJClass() = default;
  GlobalJClass(JNIEnv *env, const char *name) : m_name(name) {
    jclass local = env->FindClass(name);
    if (!local) return;
    m_class = static_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
  }

  void Free(JNIEnv *env) {
    if (m_class) env->DeleteGlobalRef(m_class);
    m_class = nullptr;
  }

  explicit operator bool() const { return m_class != nullptr; }
  operator jclass() const { return m_class; }
  const char *name() const { return m_name; }

 private:
  const char *m_name = "";
  jclass m_class = nullptr;
};

struct ClassInit {
  const char *name;
  GlobalJClass *cls;
};

GlobalJClass detectionCls;

constexpr char kDetectionClass[] = "org/wpilib/vision/apriltag/AprilTagDetection";
const ClassInit classes[] = {{kDetectionClass, &detectionCls}};

// Contrast threshold for the GPU thresholding step. 4143 used 5, frc971/bos uses 4,
// and RealtimeRoboticsGroup/aos 76d8f216 moved to 20 for speed. Override at launch
// with SPECTRUM_971_MIN_WHITE_BLACK_DIFF.
int MinWhiteBlackDiff() {
  if (const char *v = std::getenv("SPECTRUM_971_MIN_WHITE_BLACK_DIFF")) return std::atoi(v);
  return 5;
}

// Largest mean-squared error of a candidate quad's edge-line fit. AprilTag's default is 10.
// Upstream PhotonVision PR #2138 lowers its CPU detector to 2.5, which stops tags cut off at the
// image edge from being detected, with little effect on range in their tests. Set with
// SPECTRUM_971_MAX_LINE_FIT_MSE (08-select-detector.sh --mse N); test range and edge behaviour
// before changing it.
float MaxLineFitMse() {
  if (const char *v = std::getenv("SPECTRUM_971_MAX_LINE_FIT_MSE")) {
    const float f = std::strtof(v, nullptr);
    if (f > 0) return f;
  }
  return 10.0f;
}

// Worker threads for each detector's CPU stage (edge refinement and tag decoding). Every camera
// has its own detector and pool, so 4 cameras x 6 threads compete for the Jetson's 6 cores. Set
// with SPECTRUM_971_THREADS; /tmp/spectrum-971-threads overrides it without a restart
// (re-read every 2 s; processimage swaps the pool between frames), for A/B tests.
int DetectorThreads() {
  static std::mutex mu;
  static std::chrono::steady_clock::time_point next{};
  static int threads = 6;
  std::lock_guard<std::mutex> lock(mu);
  const auto now = std::chrono::steady_clock::now();
  if (now >= next) {
    next = now + std::chrono::seconds(2);
    int n = 6;
    if (const char *e = std::getenv("SPECTRUM_971_THREADS")) n = std::atoi(e);
    if (FILE *f = std::fopen("/tmp/spectrum-971-threads", "r")) {
      if (std::fscanf(f, "%d", &n) != 1) n = 6;
      std::fclose(f);
    }
    threads = n >= 1 && n <= 12 ? n : 6;
  }
  return threads;
}

// How the CPU thread waits for the GPU (cudaSetDeviceFlags, at library load, before any CUDA
// context exists): "block" (sleep; the default), "auto" (CUDA's default; with one context on 6
// cores it spins), "spin" or "yield". With 2 cameras (2026-09-24) blocking added ~0.3 ms and saved
// no CPU. With 4 cameras it made no difference over 11 one-minute runs (docs/TECHNICAL.md), so it's
// the default because it doesn't hurt. Set with SPECTRUM_971_CUDA_SYNC;
// /tmp/spectrum-971-cuda-sync overrides it (for A/B tests: write it, restart PhotonVision).
unsigned CudaScheduleFlag(std::string *name) {
  std::string v = "block";
  if (const char *e = std::getenv("SPECTRUM_971_CUDA_SYNC")) v = e;
  if (FILE *f = std::fopen("/tmp/spectrum-971-cuda-sync", "r")) {
    char buf[16] = {0};
    if (std::fgets(buf, sizeof(buf), f)) v = std::string(buf).substr(0, std::strcspn(buf, " \r\n"));
    std::fclose(f);
  }
  *name = v;
  if (v == "spin") return cudaDeviceScheduleSpin;
  if (v == "yield") return cudaDeviceScheduleYield;
  if (v == "auto") return cudaDeviceScheduleAuto;
  *name = "block";
  return cudaDeviceScheduleBlockingSync;
}

// Test hooks, read from /tmp/spectrum-971-fault-every (re-read every 30 frames so a test can
// remove it before a restarted process runs):
//   N > 0     every Nth frame hits a real, non-sticky CUDA error (cudaSetDevice on a bad
//             ordinal right before Detect: the NVIDIA/cccl#1791 case) -> frame skipped
//   "sticky"  one null-pointer kernel write: a sticky error that breaks the CUDA context
//             -> the watchdog restarts PhotonVision
constexpr const char *kFaultFile = "/tmp/spectrum-971-fault-every";
constexpr int kFaultSticky = -1;
int FaultEvery() {
  static int n = 0;
  static int calls = 0;
  if (calls++ % 30 == 0) {
    n = 0;
    if (FILE *f = std::fopen(kFaultFile, "r")) {
      char buf[16] = {0};
      if (std::fgets(buf, sizeof(buf), f)) n = (std::strncmp(buf, "sticky", 6) == 0) ? kFaultSticky : std::atoi(buf);
      std::fclose(f);
    }
  }
  return n;
}

frc::apriltag::CameraMatrix DefaultCameraMatrix() {
  return frc::apriltag::CameraMatrix{1, 1, 1, 1};
}

frc::apriltag::DistCoeffs DefaultDistCoeffs() {
  frc::apriltag::DistCoeffs d{};
  d.num_params = 5;
  return d;
}

struct Stats {
  std::chrono::steady_clock::time_point start{};
  int frames = 0;
  int tags = 0;
  int errors = 0;
  double detect_ms = 0, jni_ms = 0, max_ms = 0, margin = 0, min_margin = 1e9;
};

struct DetectorSlot {
  frc::apriltag::GpuDetector *gpu = nullptr;
  apriltag_detector_t *td = nullptr;
  apriltag_family_t *family = nullptr;
  frc::apriltag::CameraMatrix camera_matrix = DefaultCameraMatrix();
  frc::apriltag::DistCoeffs dist_coeffs = DefaultDistCoeffs();
  bool in_use = false;
  bool needs_rebuild = false;
  int consecutive_failures = 0;
  std::chrono::steady_clock::time_point first_failure{};
  std::mutex mu;
  Stats stats;
};

// A broken CUDA context (sticky error) for this long, over at least kMinFailures frames,
// means only a process restart can recover. Time-based because each failed frame also
// rebuilds the detector, so frame count alone stretched this to ~5 s.
constexpr std::chrono::milliseconds kMaxFailingTime{1000};
constexpr int kMinFailures = 3;

constexpr int kMaxDetectors = 10;
DetectorSlot slots[kMaxDetectors];
std::mutex alloc_mu;

DetectorSlot *Slot(jlong handle) {
  if (handle < 0 || handle >= kMaxDetectors) return nullptr;
  if (!slots[handle].in_use) return nullptr;
  return &slots[handle];
}

apriltag_detector_t *MakeTagDetector(apriltag_family_t *family) {
  apriltag_detector_t *td = apriltag_detector_create();
  apriltag_detector_add_family_bits(td, family, 1);
  td->nthreads = DetectorThreads();
  td->wp = workerpool_create(td->nthreads);
  td->qtp.min_white_black_diff = MinWhiteBlackDiff();
  td->qtp.max_line_fit_mse = MaxLineFitMse();
  td->debug = false;
  // GpuDetector CHECKs these (the AprilTag defaults): quad_decimate 2, no deglitch.
  return td;
}

// Rebuilds the GPU detector for a new size or calibration. Caller holds s.mu.
bool Rebuild(DetectorSlot &s, size_t width, size_t height) {
  delete s.gpu;
  s.gpu = nullptr;
  try {
    s.gpu = new frc::apriltag::GpuDetector(width, height, s.td, s.camera_matrix,
                                           s.dist_coeffs, vision::ImageFormat::MONO8);
    s.needs_rebuild = false;
    return true;
  } catch (const std::exception &e) {
    std::cout << "971 detector build " << width << "x" << height << " failed: " << e.what()
              << std::endl;
    return false;
  }
}

// Called with s.mu held after a failed frame or rebuild. The frame is skipped and the detector
// rebuilt next frame. PhotonVision is restarted only if the CUDA *context* is broken: a sticky
// error (illegal address, launch failure) makes every later call fail, including
// cudaDeviceSynchronize, and only a new process recovers. A failure on one camera with a
// healthy context must never take the other cameras down or cause a restart loop.
void RecordFailure(DetectorSlot &s, jlong handle, const char *what) {
  s.needs_rebuild = true;
  auto now = std::chrono::steady_clock::now();
  const bool context_ok = cudaDeviceSynchronize() == cudaSuccess;
  cudaGetLastError();  // clear whatever was pending so the rebuild starts clean
  if (s.consecutive_failures == 0 || context_ok) s.first_failure = now;
  if (++s.consecutive_failures <= 5 || s.consecutive_failures % 30 == 0) {
    std::cout << "971 detector h" << handle << " failure " << s.consecutive_failures << ": "
              << what << (context_ok ? " (CUDA context OK; frame skipped)" : " (CUDA context BROKEN)")
              << std::endl;
  }
  if (!context_ok && s.consecutive_failures >= kMinFailures &&
      now - s.first_failure >= kMaxFailingTime) {
    std::cout << "971 detector h" << handle << ": CUDA context broken for "
              << std::chrono::duration<double>(now - s.first_failure).count()
              << " s; exiting so systemd restarts PhotonVision" << std::endl;
    // _exit, not abort(): SIGABRT runs the JVM crash handler and Apport, which took ~28 s
    // (and a 156 MB /var/crash report) before the process died. Exit code 1 still makes
    // systemd's Restart=on-failure restart it.
    std::_Exit(1);
  }
}

jobject MakeJObject(JNIEnv *env, const apriltag_detection_t *detect) {
  static jmethodID constructor =
      env->GetMethodID(detectionCls, "<init>", "(Ljava/lang/String;IIF[DDD[D)V");
  if (!constructor) return nullptr;

  jstring family = env->NewStringUTF(detect->family->name);
  if (!family) return nullptr;

  const size_t homography_size = static_cast<size_t>(detect->H->nrows * detect->H->ncols);
  jdoubleArray homography = env->NewDoubleArray(static_cast<jsize>(homography_size));
  if (!homography) {
    env->DeleteLocalRef(family);
    return nullptr;
  }
  env->SetDoubleArrayRegion(
      homography, 0, static_cast<jsize>(homography_size),
      reinterpret_cast<const jdouble *>(detect->H->data));

  jdoubleArray corners = env->NewDoubleArray(4 * 2);
  if (!corners) {
    env->DeleteLocalRef(homography);
    env->DeleteLocalRef(family);
    return nullptr;
  }
  env->SetDoubleArrayRegion(corners, 0, 4 * 2, reinterpret_cast<const jdouble *>(detect->p));

  jobject result = env->NewObject(detectionCls, constructor, family,
                                   static_cast<jint>(detect->id),
                                   static_cast<jint>(detect->hamming),
                                   static_cast<jfloat>(detect->decision_margin), homography,
                                   static_cast<jdouble>(detect->c[0]),
                                   static_cast<jdouble>(detect->c[1]), corners);
  env->DeleteLocalRef(corners);
  env->DeleteLocalRef(homography);
  env->DeleteLocalRef(family);
  return result;
}

jobjectArray MakeJObjectArray(JNIEnv *env, const zarray_t *detections) {
  int n = detections ? zarray_size(detections) : 0;
  jobjectArray jarr = env->NewObjectArray(n, detectionCls, nullptr);
  if (!jarr) return nullptr;
  for (int i = 0; i < n; ++i) {
    apriltag_detection_t *det;
    zarray_get(detections, i, &det);
    jobject elem = MakeJObject(env, det);
    if (!elem) {
      env->DeleteLocalRef(jarr);
      return nullptr;
    }
    env->SetObjectArrayElement(jarr, i, elem);
    env->DeleteLocalRef(elem);
  }
  return jarr;
}

void RecordStats(Stats &st, jlong handle, const cv::Mat &img, const zarray_t *detections,
                 bool error, std::chrono::steady_clock::time_point t0,
                 std::chrono::steady_clock::time_point t1,
                 std::chrono::steady_clock::time_point t2) {
  using ms = std::chrono::duration<double, std::milli>;
  if (st.frames == 0) st.start = t0;
  double d = ms(t1 - t0).count();
  st.frames++;
  st.errors += error;
  st.detect_ms += d;
  st.jni_ms += ms(t2 - t1).count();
  if (d > st.max_ms) st.max_ms = d;
  int n = detections ? zarray_size(detections) : 0;
  st.tags += n;
  for (int i = 0; i < n; ++i) {
    apriltag_detection_t *det;
    zarray_get(detections, i, &det);
    st.margin += det->decision_margin;
    if (det->decision_margin < st.min_margin) st.min_margin = det->decision_margin;
  }
  double window = std::chrono::duration<double>(t2 - st.start).count();
  if (window >= 1.0) {
    std::cout << "971 stats h" << handle << " " << img.cols << "x" << img.rows << ": "
              << st.frames / window << " calls/s, detect avg " << st.detect_ms / st.frames
              << " ms max " << st.max_ms << " ms, jni " << st.jni_ms / st.frames
              << " ms, tags/frame " << double(st.tags) / st.frames;
    if (st.tags) {
      std::cout << ", margin avg " << st.margin / st.tags << " min " << st.min_margin;
    }
    if (st.errors) std::cout << ", errors " << st.errors;
    std::cout << " [bos]" << std::endl;
    st = Stats{};
  }
}

// ---- MJPEG -> gray (decodeMjpegGray) and -> BGR (decodeMjpegBgr) ----------------------------------
// libjpeg-turbo by default. SPECTRUM_JPEG_DECODER=nvjpg uses the Jetson's NVJPG hardware engine
// instead (libspectrumnvjpg.so, nvjpg_decoder.h): 2.5 ms and 0.7 ms of CPU a frame, against
// 2.9 ms and 2.9 ms. /tmp/spectrum-jpeg-decoder ("nvjpg" or "turbo", re-read every 2 s)
// overrides it without a restart, for A/B tests.
//   - A frame the hardware can't decode is decoded by libjpeg-turbo instead.
//   - Every kCheckEvery hardware frames per camera, a low-priority thread decodes the same JPEG
//     with libjpeg-turbo. Any difference turns the hardware decoder off until PhotonVision
//     restarts: the obvious way of calling libnvjpeg returned stale frames with no error
//     (docs/VISION-RESEARCH.md), so the output is checked, not trusted.

struct JpegError {
  jpeg_error_mgr mgr;
  std::jmp_buf jump;
  int warnings;
};
void JpegErrorExit(j_common_ptr c) {  // libjpeg's default calls exit(): never in a JVM
  std::longjmp(reinterpret_cast<JpegError *>(c->err)->jump, 1);
}
void JpegCountWarnings(j_common_ptr c, int level) {
  if (level < 0) reinterpret_cast<JpegError *>(c->err)->warnings++;  // corrupt data
}

// libjpeg-turbo to gray (channels 1) or BGR (channels 3). 0 ok, -2 bad/unsupported JPEG,
// -3 not width x height. *warnings (if given) counts libjpeg's corrupt-data warnings, e.g. a
// truncated frame. BGR uses libjpeg's defaults, which is what cscore's cv::imdecode gives.
int TurboDecode(const uint8_t *jpeg, size_t size, uint8_t *out, int width, int height,
                size_t stride, int channels, int *warnings = nullptr) {
  jpeg_decompress_struct c;
  JpegError err;
  c.err = jpeg_std_error(&err.mgr);
  err.mgr.error_exit = JpegErrorExit;
  err.mgr.emit_message = JpegCountWarnings;
  err.warnings = 0;
  if (setjmp(err.jump)) {
    jpeg_destroy_decompress(&c);
    return -2;
  }
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, const_cast<unsigned char *>(jpeg), size);
  if (jpeg_read_header(&c, TRUE) != JPEG_HEADER_OK) {
    jpeg_destroy_decompress(&c);
    return -2;
  }
  c.out_color_space = channels == 1 ? JCS_GRAYSCALE : JCS_EXT_BGR;
  c.dct_method = JDCT_ISLOW;  // accurate: tag corners depend on clean edges (and the default)
  jpeg_start_decompress(&c);
  if (static_cast<int>(c.output_width) != width || static_cast<int>(c.output_height) != height ||
      c.output_components != channels) {
    jpeg_abort_decompress(&c);
    jpeg_destroy_decompress(&c);
    return -3;
  }
  while (c.output_scanline < c.output_height) {
    JSAMPROW row = out + static_cast<size_t>(c.output_scanline) * stride;
    jpeg_read_scanlines(&c, &row, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  if (warnings) *warnings = err.warnings;
  return 0;
}

int TurboDecodeGray(const uint8_t *jpeg, size_t size, uint8_t *gray, int width, int height,
                    size_t stride) {
  return TurboDecode(jpeg, size, gray, width, height, stride, 1);
}

struct Nvjpg {
  decltype(&snj_create) create;
  decltype(&snj_create_error) create_error;
  decltype(&snj_destroy) destroy;
  decltype(&snj_decode_gray) decode;
  decltype(&snj_decode_bgr) decode_bgr;  // null in a library older than the colour path
  decltype(&snj_error) error;
};

// libspectrumnvjpg.so from this library's own directory (so an uninstalled build tests its own
// copy), else from the search path. RTLD_DEEPBIND: its jpeg_* calls must bind to libnvjpeg, not
// to the libjpeg-turbo this library links.
const Nvjpg *LoadNvjpg() {
  static const Nvjpg *api = []() -> const Nvjpg * {
    std::string path = "libspectrumnvjpg.so";
    Dl_info self;
    if (dladdr(reinterpret_cast<void *>(&TurboDecodeGray), &self) && self.dli_fname) {
      std::string dir = self.dli_fname;
      dir.erase(dir.rfind('/') + 1);
      if (access((dir + path).c_str(), R_OK) == 0) path = dir + path;
    }
    void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
    if (!h) {
      std::cout << "971 jpeg: can't load " << path << " (" << dlerror()
                << "); using libjpeg-turbo" << std::endl;
      return nullptr;
    }
    static Nvjpg a;
    a.create = reinterpret_cast<decltype(a.create)>(dlsym(h, "snj_create"));
    a.create_error = reinterpret_cast<decltype(a.create_error)>(dlsym(h, "snj_create_error"));
    a.destroy = reinterpret_cast<decltype(a.destroy)>(dlsym(h, "snj_destroy"));
    a.decode = reinterpret_cast<decltype(a.decode)>(dlsym(h, "snj_decode_gray"));
    a.decode_bgr = reinterpret_cast<decltype(a.decode_bgr)>(dlsym(h, "snj_decode_bgr"));
    a.error = reinterpret_cast<decltype(a.error)>(dlsym(h, "snj_error"));
    if (!a.create || !a.create_error || !a.destroy || !a.decode || !a.error) {
      std::cout << "971 jpeg: " << path << " is missing functions; using libjpeg-turbo"
                << std::endl;
      return nullptr;
    }
    std::cout << "971 jpeg: loaded " << path << (a.decode_bgr ? " (gray and colour)" : " (gray only)")
              << std::endl;
    return &a;
  }();
  return api;
}

enum class JpegDecoder { kTurbo, kNvjpg };

// Set when a check finds the hardware's output differs, or on a CUDA failure: from then on
// libjpeg-turbo decodes everything until PhotonVision restarts.
std::atomic<bool> nvjpg_off{false};

JpegDecoder WantedJpegDecoder() {
  static std::mutex mu;
  static std::chrono::steady_clock::time_point next{};
  static JpegDecoder mode = JpegDecoder::kTurbo;
  static std::string logged;
  std::lock_guard<std::mutex> lock(mu);
  const auto now = std::chrono::steady_clock::now();
  if (now >= next) {
    next = now + std::chrono::seconds(2);
    std::string v = "turbo";
    if (const char *e = std::getenv("SPECTRUM_JPEG_DECODER")) v = e;
    if (FILE *f = std::fopen("/tmp/spectrum-jpeg-decoder", "r")) {
      char buf[16] = {0};
      if (std::fgets(buf, sizeof(buf), f)) v = std::string(buf).substr(0, std::strcspn(buf, " \r\n"));
      std::fclose(f);
    }
    mode = v == "nvjpg" ? JpegDecoder::kNvjpg : JpegDecoder::kTurbo;
    if (v != logged) {
      logged = v;
      std::cout << "971 jpeg decoder: "
                << (mode == JpegDecoder::kNvjpg ? "nvjpg (hardware)" : "libjpeg-turbo")
                << (nvjpg_off ? " requested, but the hardware decoder is off (see above)" : "")
                << std::endl;
    }
  }
  return nvjpg_off ? JpegDecoder::kTurbo : mode;
}

std::atomic<long> checks_ok{0}, checks_differ{0}, checks_skipped{0};

// Re-decodes copies of hardware-decoded frames with libjpeg-turbo on its own low-priority
// thread, and compares. One job at a time; a frame offered while it's busy isn't checked.
// (Plain buffers, not cv::Mat: this library uses only OpenCV's header-inline parts, because
// PhotonVision brings its own OpenCV build.)
class JpegChecker {
 public:
  // channels: 1 = gray, 3 = BGR.
  void Submit(const uint8_t *jpeg, size_t size, const uint8_t *image, int width, int height,
              size_t stride, int channels) {
    std::lock_guard<std::mutex> lock(mu_);
    if (busy_) return;
    busy_ = true;
    jpeg_.assign(jpeg, jpeg + size);
    width_ = width;
    height_ = height;
    channels_ = channels;
    const size_t row = static_cast<size_t>(width) * channels;
    image_.resize(row * height);
    for (int y = 0; y < height; ++y) std::memcpy(&image_[y * row], image + y * stride, row);
    if (!thread_.joinable()) thread_ = std::thread([this] { Run(); });
    cv_.notify_one();
  }

 private:
  void Run() {
    setpriority(PRIO_PROCESS, static_cast<id_t>(syscall(SYS_gettid)), 10);
    std::vector<uint8_t> ref;
    for (;;) {
      {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait(lock, [this] { return busy_; });
      }
      ref.resize(image_.size());
      int warnings = 0;
      const int rc = TurboDecode(jpeg_.data(), jpeg_.size(), ref.data(), width_, height_,
                                 static_cast<size_t>(width_) * channels_, channels_, &warnings);
      if (rc != 0 || warnings) {
        checks_skipped++;  // a corrupt frame: libjpeg-turbo and NVJPG may fill the gap differently
      } else {
        long differ = 0;
        int max_diff = 0;
        for (size_t i = 0; i < ref.size(); ++i) {
          const int d = std::abs(ref[i] - image_[i]);
          differ += d != 0;
          max_diff = std::max(max_diff, d);
        }
        if (differ == 0) {
          checks_ok++;
        } else {
          checks_differ++;
          nvjpg_off = true;
          std::cout << "971 jpeg: HARDWARE DECODE DIFFERS from libjpeg-turbo ("
                    << (channels_ == 1 ? "gray" : "colour") << ", " << differ << " of "
                    << ref.size() << " values, max difference " << max_diff
                    << "); libjpeg-turbo decodes everything until PhotonVision restarts"
                    << std::endl;
        }
      }
      std::lock_guard<std::mutex> lock(mu_);
      busy_ = false;
    }
  }

  std::mutex mu_;
  std::condition_variable cv_;
  bool busy_ = false;
  std::thread thread_;
  std::vector<uint8_t> jpeg_, image_;
  int width_ = 0, height_ = 0, channels_ = 1;
};

JpegChecker &Checker() {
  static JpegChecker *c = new JpegChecker;  // never destroyed: its thread runs until exit
  return *c;
}

// ~2 s at 120 fps. The first hardware frame on each camera is checked too.
constexpr long kCheckEvery = 240;

// One hardware decoder per camera thread (a decoder isn't thread-safe; PhotonVision decodes
// each camera's frames on that camera's own thread).
struct NvjpgThread {
  SnjDecoder *dec = nullptr;
  bool unavailable = false;       // no decoder
  bool path_unavailable[2] = {};  // [0] gray, [1] colour: this camera's JPEGs can't use it
  int unsupported_in_a_row[2] = {};
  long frames = 0;
  ~NvjpgThread() {
    if (dec) LoadNvjpg()->destroy(dec);
  }
};
thread_local NvjpgThread nvjpg_thread;

std::atomic<int> nvjpg_errors_logged{0};

// Test hook for the safety net: while /tmp/spectrum-jpeg-fault exists (checked every 30 frames),
// every hardware-decoded frame gets one pixel changed, so the next check must find it and turn
// the hardware decoder off.
bool JpegFaultActive() {
  static std::atomic<int> calls{0};
  static std::atomic<bool> active{false};
  if (calls++ % 30 == 0) active = access("/tmp/spectrum-jpeg-fault", F_OK) == 0;
  return active;
}

// Decodes into mat (CV_8UC1 gray, or CV_8UC3 BGR when bgr). SNJ_OK, or why libjpeg-turbo has to
// decode this frame instead.
int NvjpgDecode(const uint8_t *jpeg, size_t size, cv::Mat &mat, bool bgr) {
  NvjpgThread &t = nvjpg_thread;
  if (t.unavailable || t.path_unavailable[bgr]) return SNJ_UNSUPPORTED;
  const Nvjpg *api = LoadNvjpg();
  if (!api || (bgr && !api->decode_bgr)) {
    if (!api) t.unavailable = true;
    t.path_unavailable[bgr] = true;
    return SNJ_UNSUPPORTED;
  }
  if (!t.dec && !(t.dec = api->create())) {
    std::cout << "971 jpeg: no hardware decoder (" << api->create_error()
              << "); using libjpeg-turbo on this camera" << std::endl;
    t.unavailable = true;
    return SNJ_UNSUPPORTED;
  }
  const int rc = (bgr ? api->decode_bgr : api->decode)(t.dec, jpeg, size, mat.data, mat.cols,
                                                       mat.rows, mat.step);
  if (rc == SNJ_OK) {
    t.unsupported_in_a_row[bgr] = 0;
    if (JpegFaultActive()) mat.data[0] ^= 0x80;
    if (t.frames++ % kCheckEvery == 0) {
      Checker().Submit(jpeg, size, mat.data, mat.cols, mat.rows, mat.step, bgr ? 3 : 1);
    }
    return rc;
  }
  if (nvjpg_errors_logged++ < 20) {
    std::cout << "971 jpeg: hardware decode failed (" << rc << ": " << api->error(t.dec)
              << "); libjpeg-turbo decodes this frame" << std::endl;
  }
  if (rc == SNJ_UNSUPPORTED && ++t.unsupported_in_a_row[bgr] >= 30) {
    std::cout << "971 jpeg: this camera's JPEGs can't use the hardware " << (bgr ? "colour" : "gray")
              << " decoder (" << api->error(t.dec) << "); using libjpeg-turbo on this camera"
              << std::endl;
    t.path_unavailable[bgr] = true;
  }
  if (rc == SNJ_CUDA && !nvjpg_off.exchange(true)) {
    std::cout << "971 jpeg: CUDA failed in the hardware decoder; libjpeg-turbo decodes "
                 "everything until PhotonVision restarts"
              << std::endl;
  }
  return rc;
}

// A "971 jpeg" line every 10 s (not "971 stats", which health-check.sh parses per detector).
// Colour frames are also counted on their own, in a clause at the end of the line.
void CountJpeg(JpegDecoder used, int fallback, std::chrono::steady_clock::time_point t0,
               bool colour = false) {
  static std::mutex mu;
  static std::chrono::steady_clock::time_point start = t0;
  static long frames[2] = {0, 0}, colour_frames[2] = {0, 0}, fallbacks[5] = {0, 0, 0, 0, 0};
  static double ms[2] = {0, 0}, colour_ms[2] = {0, 0};
  const auto t1 = std::chrono::steady_clock::now();
  std::lock_guard<std::mutex> lock(mu);
  const int i = used == JpegDecoder::kNvjpg ? 1 : 0;
  const double this_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
  frames[i]++;
  ms[i] += this_ms;
  if (colour) {
    colour_frames[i]++;
    colour_ms[i] += this_ms;
  }
  if (fallback < 0 && fallback >= -4) fallbacks[-fallback]++;
  const double window = std::chrono::duration<double>(t1 - start).count();
  if (window < 10) return;
  std::cout << "971 jpeg " << static_cast<int>(window + 0.5) << " s: nvjpg "
            << frames[1] / window << " frames/s";
  if (frames[1]) std::cout << " (" << ms[1] / frames[1] << " ms)";
  std::cout << ", libjpeg-turbo " << frames[0] / window << " frames/s";
  if (frames[0]) std::cout << " (" << ms[0] / frames[0] << " ms)";
  if (long f = fallbacks[1] + fallbacks[3] + fallbacks[4]) {
    std::cout << "; " << f << " fell back (bad JPEG " << fallbacks[1] << ", unsupported "
              << fallbacks[3] << ", CUDA " << fallbacks[4] << ")";
  }
  std::cout << "; checks since start " << checks_ok << " ok, " << checks_differ << " differ";
  if (checks_skipped) std::cout << ", " << checks_skipped << " skipped (corrupt frame)";
  if (nvjpg_off) std::cout << "; hardware decoder OFF";
  if (colour_frames[0] + colour_frames[1]) {
    std::cout << "; colour: nvjpg " << colour_frames[1] / window << " frames/s";
    if (colour_frames[1]) std::cout << " (" << colour_ms[1] / colour_frames[1] << " ms)";
    std::cout << ", libjpeg-turbo " << colour_frames[0] / window << " frames/s";
    if (colour_frames[0]) std::cout << " (" << colour_ms[0] / colour_frames[0] << " ms)";
  }
  std::cout << std::endl;
  start = t1;
  frames[0] = frames[1] = colour_frames[0] = colour_frames[1] = 0;
  ms[0] = ms[1] = colour_ms[0] = colour_ms[1] = 0;
  for (auto &f : fallbacks) f = 0;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  for (auto &c : classes) {
    *c.cls = GlobalJClass(env, c.name);
    if (!*c.cls) {
      std::cout << "971 library could not find class " << c.name << std::endl;
      return JNI_ERR;
    }
  }
  std::string sync;
  const cudaError_t sync_err = cudaSetDeviceFlags(CudaScheduleFlag(&sync));
  // CUDA reads CUDA_DEVICE_MAX_CONNECTIONS (default 8) from the process environment, which
  // 08-select-detector.sh sets; only reported here.
  const char *connections = std::getenv("CUDA_DEVICE_MAX_CONNECTIONS");
  std::cout << "971 library loaded (frc971/bos detector, min_white_black_diff "
            << MinWhiteBlackDiff() << ", max_line_fit_mse " << MaxLineFitMse() << ", threads "
            << DetectorThreads() << ", CUDA wait " << sync
            << (sync_err == cudaSuccess ? "" : std::string(" FAILED: ") + cudaGetErrorString(sync_err))
            << ", GPU connections " << (connections ? connections : "8") << ")" << std::endl;
  return JNI_VERSION_1_6;
}

// SpectrumJetson: decode a camera's MJPEG frame straight to 8-bit gray, into a Mat Java already
// allocated (PhotonVision's OpenCV owns the memory; this only writes the pixels).
//   int decodeMjpegGray(long rawFramePtr, long cvMatPtr)
//     0 ok, -1 not an MJPEG frame, -2 bad/unsupported JPEG, -3 Mat isn't WxH 8-bit mono
// Why: cscore's own gray path decodes every JPEG to full-colour BGR and then converts it
// (Frame::ConvertImpl), ~8.9 ms a frame on the Orin Nano; this is ~2.6 ms (libjpeg-turbo,
// grayscale output: only the Y component is inverse-DCT'd, no colour conversion), or 0.7 ms of
// CPU on the NVJPG hardware engine (see "MJPEG -> gray" above).
JNIEXPORT jint JNICALL Java_org_photonvision_jni_GpuDetectorJNI_decodeMjpegGray(
    JNIEnv *, jclass, jlong raw_ptr, jlong mat_ptr) {
  auto *frame = reinterpret_cast<WPI_RawFrame *>(raw_ptr);
  auto *mat = reinterpret_cast<cv::Mat *>(mat_ptr);
  if (!frame || !mat) return -2;
  if (frame->pixelFormat != WPI_PIXFMT_MJPEG || !frame->data || frame->size < 4) return -1;
  if (mat->type() != CV_8UC1 || !mat->isContinuous()) return -3;
  const auto *data = reinterpret_cast<const uint8_t *>(frame->data);
  const size_t size = static_cast<size_t>(frame->size);

  const auto t0 = std::chrono::steady_clock::now();
  int fallback = SNJ_OK;
  if (WantedJpegDecoder() == JpegDecoder::kNvjpg) {
    fallback = NvjpgDecode(data, size, *mat, /*bgr=*/false);
    if (fallback == SNJ_OK) {
      CountJpeg(JpegDecoder::kNvjpg, SNJ_OK, t0);
      return 0;
    }
    if (fallback == SNJ_WRONG_SIZE) return -3;
  }
  const int rc = TurboDecodeGray(data, size, mat->data, mat->cols, mat->rows, mat->step);
  if (rc == 0) CountJpeg(JpegDecoder::kTurbo, fallback, t0);
  return rc;
}

// SpectrumJetson: the same for colour cameras (game pieces, driver mode, calibration): the
// camera's MJPEG frame to 8-bit BGR, into a WxH CV_8UC3 Mat Java allocated.
//   boolean hardwareJpegDecode()   true when PhotonVision should use decodeMjpegBgr instead of
//                                  cscore's own BGR decode (the hardware decoder is on and loaded)
//   int decodeMjpegBgr(long rawFramePtr, long cvMatPtr)
//     0 ok, -1 not an MJPEG frame, -2 bad/unsupported JPEG, -3 Mat isn't WxH 8-bit BGR
// NVJPG plus a CUDA colour conversion (nvjpg_bgr.cu) takes 3.3-4 ms and ~1.6 ms of CPU a
// 1280x800 frame, against ~5.7 ms of CPU for libjpeg-turbo, with identical pixels. A frame the
// hardware can't decode (e.g. 4:2:0 chroma) is decoded by libjpeg-turbo, like cscore would.
JNIEXPORT jboolean JNICALL Java_org_photonvision_jni_GpuDetectorJNI_hardwareJpegDecode(JNIEnv *,
                                                                                       jclass) {
  if (WantedJpegDecoder() != JpegDecoder::kNvjpg) return JNI_FALSE;
  const Nvjpg *api = LoadNvjpg();
  return api && api->decode_bgr ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL Java_org_photonvision_jni_GpuDetectorJNI_decodeMjpegBgr(
    JNIEnv *, jclass, jlong raw_ptr, jlong mat_ptr) {
  auto *frame = reinterpret_cast<WPI_RawFrame *>(raw_ptr);
  auto *mat = reinterpret_cast<cv::Mat *>(mat_ptr);
  if (!frame || !mat) return -2;
  if (frame->pixelFormat != WPI_PIXFMT_MJPEG || !frame->data || frame->size < 4) return -1;
  if (mat->type() != CV_8UC3 || !mat->isContinuous()) return -3;
  const auto *data = reinterpret_cast<const uint8_t *>(frame->data);
  const size_t size = static_cast<size_t>(frame->size);

  const auto t0 = std::chrono::steady_clock::now();
  int fallback = SNJ_OK;
  if (WantedJpegDecoder() == JpegDecoder::kNvjpg) {
    fallback = NvjpgDecode(data, size, *mat, /*bgr=*/true);
    if (fallback == SNJ_OK) {
      CountJpeg(JpegDecoder::kNvjpg, SNJ_OK, t0, /*colour=*/true);
      return 0;
    }
    if (fallback == SNJ_WRONG_SIZE) return -3;
  }
  const int rc = TurboDecode(data, size, mat->data, mat->cols, mat->rows, mat->step, 3);
  if (rc == 0) CountJpeg(JpegDecoder::kTurbo, fallback, t0, /*colour=*/true);
  return rc;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM *vm, void *) {
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return;
  for (auto &c : classes) c.cls->Free(env);
}

JNIEXPORT jlong JNICALL Java_org_photonvision_jni_GpuDetectorJNI_createGpuDetector(
    JNIEnv *, jclass, jint width, jint height) {
  std::lock_guard<std::mutex> alloc_lock(alloc_mu);
  int h = -1;
  for (int i = 0; i < kMaxDetectors; ++i) {
    if (!slots[i].in_use) {
      h = i;
      break;
    }
  }
  if (h < 0) {
    std::cout << "creategpudetector: all " << kMaxDetectors << " slots in use" << std::endl;
    return -1;
  }
  DetectorSlot &s = slots[h];
  std::lock_guard<std::mutex> lock(s.mu);
  s.camera_matrix = DefaultCameraMatrix();
  s.dist_coeffs = DefaultDistCoeffs();
  s.family = tag36h11_create();
  s.td = MakeTagDetector(s.family);
  s.consecutive_failures = 0;
  // If the GPU build fails, keep the slot: processimage retries the build each frame.
  if (!Rebuild(s, width, height)) s.needs_rebuild = true;
  s.stats = Stats{};
  s.in_use = true;
  std::cout << "creategpudetector " << width << "x" << height << " handle " << h << std::endl;
  return h;
}

JNIEXPORT void JNICALL Java_org_photonvision_jni_GpuDetectorJNI_destroyGpuDetector(
    JNIEnv *, jclass, jlong handle) {
  std::lock_guard<std::mutex> alloc_lock(alloc_mu);
  DetectorSlot *s = Slot(handle);
  if (!s) {
    std::cout << "destroygpudetector: bad handle " << handle << std::endl;
    return;
  }
  std::lock_guard<std::mutex> lock(s->mu);
  delete s->gpu;
  s->gpu = nullptr;
  if (s->td) apriltag_detector_destroy(s->td);
  s->td = nullptr;
  if (s->family) tag36h11_destroy(s->family);
  s->family = nullptr;
  s->in_use = false;
  std::cout << "destroygpudetector handle " << handle << std::endl;
}

namespace {

// Stores new intrinsics; the detector is rebuilt with them on the next frame.
// num_params 5 = k1 k2 p1 p2 k3 (k4..k6 zero); 8 = OpenCV rational model, which is what
// PhotonVision's (mrcal) calibration produces.
void SetParams(jlong handle, double fx, double cx, double fy, double cy, double k1, double k2,
               double p1, double p2, double k3, double k4, double k5, double k6,
               int num_params) {
  DetectorSlot *s = Slot(handle);
  if (!s) {
    std::cout << "setparams: bad handle " << handle << std::endl;
    return;
  }
  std::lock_guard<std::mutex> lock(s->mu);
  s->camera_matrix = frc::apriltag::CameraMatrix{fx, cx, fy, cy};
  s->dist_coeffs = DefaultDistCoeffs();
  s->dist_coeffs.k1 = k1;
  s->dist_coeffs.k2 = k2;
  s->dist_coeffs.p1 = p1;
  s->dist_coeffs.p2 = p2;
  s->dist_coeffs.k3 = k3;
  s->dist_coeffs.k4 = k4;
  s->dist_coeffs.k5 = k5;
  s->dist_coeffs.k6 = k6;
  s->dist_coeffs.num_params = num_params;
  std::cout << "setparams handle " << handle << " (" << num_params << " dist coeffs): fx " << fx
            << " cx " << cx << " fy " << fy << " cy " << cy << " k1 " << k1 << " k2 " << k2
            << " p1 " << p1 << " p2 " << p2 << " k3 " << k3;
  if (num_params == 8) std::cout << " k4 " << k4 << " k5 " << k5 << " k6 " << k6;
  std::cout << std::endl;
  // Takes effect on the next frame (processimage rebuilds at the frame's size).
  s->needs_rebuild = true;
}

}  // namespace

JNIEXPORT void JNICALL Java_org_photonvision_jni_GpuDetectorJNI_setparams(
    JNIEnv *, jclass, jlong handle, jdouble fx, jdouble cx, jdouble fy, jdouble cy, jdouble k1,
    jdouble k2, jdouble p1, jdouble p2, jdouble k3) {
  SetParams(handle, fx, cx, fy, cy, k1, k2, p1, p2, k3, 0, 0, 0, 5);
}

JNIEXPORT void JNICALL Java_org_photonvision_jni_GpuDetectorJNI_setparams8(
    JNIEnv *, jclass, jlong handle, jdouble fx, jdouble cx, jdouble fy, jdouble cy, jdouble k1,
    jdouble k2, jdouble p1, jdouble p2, jdouble k3, jdouble k4, jdouble k5, jdouble k6) {
  SetParams(handle, fx, cx, fy, cy, k1, k2, p1, p2, k3, k4, k5, k6, 8);
}

JNIEXPORT jobjectArray JNICALL Java_org_photonvision_jni_GpuDetectorJNI_processimage(
    JNIEnv *env, jclass, jlong handle, jlong p) {
  if (!p) return nullptr;
  cv::Mat &img = *reinterpret_cast<cv::Mat *>(p);
  if (!img.ptr()) return nullptr;
  if (img.type() != CV_8UC1 || !img.isContinuous()) {
    static bool logged = false;
    if (!logged) {
      logged = true;
      std::cout << "processimage: need a continuous 8-bit mono Mat, got type " << img.type()
                << std::endl;
    }
    return nullptr;
  }
  if (img.cols % 8 != 0 || img.rows % 8 != 0) {
    // threshold.cc CHECKs this; refuse instead of aborting the JVM.
    static bool logged = false;
    if (!logged) {
      logged = true;
      std::cout << "processimage: " << img.cols << "x" << img.rows
                << " is not a multiple of 8; skipping" << std::endl;
    }
    return nullptr;
  }

  DetectorSlot *s = Slot(handle);
  if (!s) {
    std::cout << "processimage: bad handle " << handle << std::endl;
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(s->mu);

  // Clear any CUDA error left by an earlier unchecked call; CUB (CCCL >= 2.5) otherwise
  // fails later calls with it, and this detector's CHECK_CUDA would abort the process.
  if (cudaError_t stale = cudaGetLastError(); stale != cudaSuccess) {
    static bool logged = false;
    if (!logged) {
      logged = true;
      std::cout << "processimage: cleared stale CUDA error: " << cudaGetErrorString(stale)
                << std::endl;
    }
  }

  if (!s->gpu || s->needs_rebuild || static_cast<size_t>(img.cols) != s->gpu->width() ||
      static_cast<size_t>(img.rows) != s->gpu->height()) {
    if (s->gpu && !s->needs_rebuild) {
      std::cout << "processimage: size changed to " << img.cols << "x" << img.rows
                << ", rebuilding detector" << std::endl;
    }
    if (!Rebuild(*s, img.cols, img.rows)) {
      RecordFailure(*s, handle, "detector rebuild failed");
      return MakeJObjectArray(env, nullptr);
    }
  }
  // The pool is only used inside Detect (tag_detector_->wp and ->nthreads), so it can be
  // swapped between frames.
  if (const int n = DetectorThreads(); n != s->td->nthreads) {
    workerpool_destroy(s->td->wp);
    s->td->nthreads = n;
    s->td->wp = workerpool_create(n);
    std::cout << "971 detector h" << handle << ": " << n << " threads" << std::endl;
  }

  auto t0 = std::chrono::steady_clock::now();
  const zarray_t *detections = nullptr;
  bool failed = false;
  if (int every = FaultEvery(); every > 0) {
    static long frame = 0;
    if (++frame % every == 0) cudaSetDevice(9999);  // leaves "invalid device ordinal"
  } else if (every == kFaultSticky) {
    static bool injected = false;
    if (!injected) {
      injected = true;
      std::cout << "971 TEST: injecting a sticky CUDA fault" << std::endl;
      SpectrumInjectStickyCudaFault();
    }
  }
  try {
    absl::Status status = s->gpu->Detect(img.ptr<uint8_t>(), nullptr);
    if (status.ok()) {
      detections = s->gpu->Detections();
      s->consecutive_failures = 0;
    } else {
      failed = true;
      RecordFailure(*s, handle, std::string(status.message()).c_str());
    }
  } catch (const std::exception &e) {
    failed = true;
    cudaGetLastError();  // clear a non-sticky error so the rebuild can succeed
    RecordFailure(*s, handle, e.what());
  }
  auto t1 = std::chrono::steady_clock::now();

  jobjectArray result = MakeJObjectArray(env, detections);
  auto t2 = std::chrono::steady_clock::now();
  RecordStats(s->stats, handle, img, detections, failed, t0, t1, t2);
  return result;
}

// ---- Status for NetworkTables (JetsonStatusJNI) -------------------------------------------------

// SpectrumJetson: the JPEG decoder's state, for the telemetry PhotonVision publishes under
// /photonvision/jetson (JetsonTelemetry, photonvision-16):
//   long[] nativeJpegStatus()
//     {active decoder (1 nvjpg, 0 libjpeg-turbo), hardware decoder switched off (1/0),
//      checks ok, checks that differed, checks skipped}; counts since PhotonVision started.
JNIEXPORT jlongArray JNICALL Java_org_photonvision_jni_JetsonStatusJNI_nativeJpegStatus(JNIEnv *env,
                                                                                        jclass) {
  const jlong v[5] = {WantedJpegDecoder() == JpegDecoder::kNvjpg ? 1 : 0,
                      nvjpg_off ? 1 : 0,
                      checks_ok.load(),
                      checks_differ.load(),
                      checks_skipped.load()};
  jlongArray arr = env->NewLongArray(5);
  if (arr) env->SetLongArrayRegion(arr, 0, 5, v);
  return arr;
}

}  // extern "C"
