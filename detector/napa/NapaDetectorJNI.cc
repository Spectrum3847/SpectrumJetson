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
#include <jni.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
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
extern "C" {
#include "../../native/sc-vision/src/pose.h"  // poseSquare (sc/mjpeg-napa)
}

namespace {
jclass detectionCls = nullptr;
jmethodID detectionCtor = nullptr;

// libspectrum-stream.so's C API, opened on first use (the same copy the GPU library links, if loaded).
struct StreamApi {
  decltype(&spectrum_stream_decode_gray) decode = nullptr;
  decltype(&spectrum_stream_take) take = nullptr;
  decltype(&spectrum_stream_detach) detach = nullptr;
  decltype(&spectrum_stream_set_copy) set_copy = nullptr;  // newer libspectrum-stream.so only
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

// The camera watcher's side of streaming NAPA: its own detector, fed band by band on the watcher thread.
struct StreamSink {
  napa_far::Detector det;
  std::mutex cfg_mu;
  napa_far::Config cfg;
  bool cfg_new = true;
  spectrum_band_sink c{};
  explicit StreamSink(const std::string &family) : det(family) {
    c.ctx = this;
    c.begin = [](void *x, const uint8_t *img, int w, int h, int stride) -> int {
      auto *s = static_cast<StreamSink *>(x);
      {
        std::lock_guard<std::mutex> l(s->cfg_mu);
        if (s->cfg_new) s->det.SetConfig(s->cfg);
        s->cfg_new = false;
      }
      return s->det.Begin(img, w, h, stride, NowUs()) ? 1 : 0;
    };
    c.feed = [](void *x, int rows) { static_cast<StreamSink *>(x)->det.Feed(rows); };
    c.finish = [](void *x) -> void * { return new std::vector<napa_far::Tag>(static_cast<StreamSink *>(x)->det.Finish()); };
    c.free_result = [](void *r) { delete static_cast<std::vector<napa_far::Tag> *>(r); };
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
  explicit Napa(const std::string &family) : det(family) {}
  ~Napa() {
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
    // the homography frame (x right, y up, z out of the tag) -> AprilTag's (y down, z into the tag): R diag(1,-1,-1)
    for (int r = 0; r < 3; r++) {
      o[3 + r * 3 + 0] = ps[s]->R[r * 3 + 0];
      o[3 + r * 3 + 1] = -ps[s]->R[r * 3 + 1];
      o[3 + r * 3 + 2] = -ps[s]->R[r * 3 + 2];
    }
    o[12] = ps[s]->err;
  }
  jdoubleArray arr = env->NewDoubleArray(26);
  if (arr) env->SetDoubleArrayRegion(arr, 0, 26, out);
  return arr;
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
      tags.swap(*static_cast<std::vector<napa_far::Tag> *>(res));
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
