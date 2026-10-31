// SpectrumJetson: what libspectrum-gpu-apriltag.so used to take from WPILib's C++ libraries, without linking
// them. PhotonVision loads its own WPILib (2026 or 2027) into the same JVM, and a detector linked
// against a different build would bind to libraries it wasn't built for (MAINTENANCE-2027.md).
//   - WPI_RawFrame: cscore's C frame struct, which Java hands us by address. Same layout in WPILib
//     2026.2.1 and 2027 alpha-8; 2027 made the timestamp signed and nanoseconds (was microseconds).
//   - Now(): WPI_Now from the WPILib already in the process (dlsym), in its own units. Its timebase
//     starts at program start, so no clock of ours can stand in for it.
//   - JNI helpers in place of wpi::java's.
#pragma once

#include <dlfcn.h>
#include <jni.h>

#include <cstddef>
#include <cstdint>
#include <span>

extern "C" {
// wpi/RawFrame.h (2026), wpi/util/RawFrame.h + PixelFormat.h (2027)
typedef struct WPI_RawFrame {  // NOLINT
  uint8_t *data;
  void (*freeFunc)(void *cbdata, void *data, size_t capacity);
  void *freeCbData;
  size_t capacity;
  size_t size;
  int pixelFormat;
  int width;
  int height;
  int stride;
  int64_t timestamp;  // capture time in WPI_Now's timebase: us (2026) or ns (2027)
  int timestampSrc;
} WPI_RawFrame;
}
static_assert(sizeof(WPI_RawFrame) == 72 && offsetof(WPI_RawFrame, timestamp) == 56,
              "WPI_RawFrame layout changed");
constexpr int kWpiPixfmtMjpeg = 1;  // WPI_PIXFMT_MJPEG

namespace wpi_compat {

// WPI_Now in its own units, or 0 if no WPILib is loaded (a test program). The JVM loads WPILib's
// libraries RTLD_LOCAL, so a global lookup doesn't see them (2026-10-30: the frame ages were
// missing); look inside the already-loaded libwpiutil (RTLD_NOLOAD: never load a second copy).
inline int64_t Now() {
  using NowFn = int64_t (*)();
  static NowFn fn = [] {
    if (void *f = dlsym(RTLD_DEFAULT, "WPI_Now")) return reinterpret_cast<NowFn>(f);
    for (const char *lib : {"libwpiutil.so", "libwpiutiljni.so"}) {
      if (void *h = dlopen(lib, RTLD_LAZY | RTLD_NOLOAD)) {
        if (void *f = dlsym(h, "WPI_Now")) return reinterpret_cast<NowFn>(f);
      }
    }
    return static_cast<NowFn>(nullptr);
  }();
  return fn ? fn() : 0;
}

// WPI_Now ticks per millisecond: 1e6 for WPILib 2027 (nanoseconds), 1e3 for 2026. Set from the
// AprilTagDetection class JNI_OnLoad finds (its package moved in 2027, with the unit change).
inline double &TicksPerMs() {
  static double t = 1e6;
  return t;
}

template <typename T>
class JLocal {
 public:
  JLocal(JNIEnv *env, T obj) : env_(env), obj_(obj) {}
  JLocal(const JLocal &) = delete;
  JLocal &operator=(const JLocal &) = delete;
  ~JLocal() {
    if (obj_) env_->DeleteLocalRef(obj_);
  }
  T obj() const { return obj_; }

 private:
  JNIEnv *env_;
  T obj_;
};

inline jstring MakeJString(JNIEnv *env, const char *s) { return env->NewStringUTF(s); }

inline jdoubleArray MakeJDoubleArray(JNIEnv *env, std::span<const jdouble> v) {
  jdoubleArray a = env->NewDoubleArray(static_cast<jsize>(v.size()));
  if (a) env->SetDoubleArrayRegion(a, 0, static_cast<jsize>(v.size()), v.data());
  return a;
}

}  // namespace wpi_compat
