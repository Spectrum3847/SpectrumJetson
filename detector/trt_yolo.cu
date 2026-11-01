// SpectrumJetson: TensorRT YOLO engine with GPU preprocessing and batching. See trt_yolo.h.
#include "trt_yolo.h"

#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>

#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <NvInfer.h>
#include <NvOnnxParser.h>

namespace spectrum_trt {
namespace {

class Logger : public nvinfer1::ILogger {
  void log(Severity severity, const char *msg) noexcept override {
    if (severity <= Severity::kWARNING) std::cout << "TensorRT: " << msg << std::endl;
  }
};
Logger gLogger;

// Holds libspectrum-gpu-apriltag.so's CUDA capture lock shared for a scope (GpuDetectorJNI.cc):
// that library records CUDA graphs, and while it does, cudaMalloc/cudaFree/engine loading here
// would break the capture. Does nothing when that library isn't loaded (the bench tool).
class CudaShared {
 public:
  CudaShared() : unlock_(Fns().unlock) {
    if (auto lock = Fns().lock) lock();
  }
  ~CudaShared() {
    if (unlock_) unlock_();
  }

 private:
  using Fn = void (*)();
  struct Pair {
    Fn lock = nullptr, unlock = nullptr;
  };
  static Pair Fns() {
    static std::atomic<bool> found{false};
    static Pair fns;
    if (!found.load(std::memory_order_acquire)) {
      static std::mutex mu;
      std::lock_guard<std::mutex> l(mu);
      if (!found.load(std::memory_order_relaxed)) {
        if (void *h = dlopen("libspectrum-gpu-apriltag.so", RTLD_NOLOAD | RTLD_LAZY)) {
          fns.lock = reinterpret_cast<Fn>(dlsym(h, "spectrum_cuda_lock_shared"));
          fns.unlock = reinterpret_cast<Fn>(dlsym(h, "spectrum_cuda_unlock_shared"));
          if (fns.lock && fns.unlock) found.store(true, std::memory_order_release);
          else fns = Pair{};
        }
      }
    }
    return found.load(std::memory_order_acquire) ? fns : Pair{};
  }
  Fn unlock_;
};

double NowMs() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::string DimsStr(const nvinfer1::Dims &d) {
  std::string s = "[";
  for (int i = 0; i < d.nbDims; ++i) s += (i ? "," : "") + std::to_string(d.d[i]);
  return s + "]";
}

std::vector<char> ReadFile(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  return std::vector<char>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

uint64_t Fnv1a(const char *p, size_t n, uint64_t h = 1469598103934665603ULL) {
  for (size_t i = 0; i < n; ++i) {
    h ^= static_cast<uint8_t>(p[i]);
    h *= 1099511628211ULL;
  }
  return h;
}

bool EndsWith(const std::string &s, const std::string &suffix) {
  return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string Stem(const std::string &path) {
  std::string base = path.substr(path.find_last_of('/') + 1);
  return base.substr(0, base.find_last_of('.'));
}

// The GPU, so an engine copied from another Jetson model (different SM count) rebuilds.
std::string GpuKey() {
  cudaDeviceProp p{};
  if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) return "gpu?";
  std::string name = p.name;
  for (auto &c : name) {
    if (!isalnum(static_cast<unsigned char>(c))) c = '_';
  }
  return name + "-sm" + std::to_string(p.major) + std::to_string(p.minor) + "x" +
         std::to_string(p.multiProcessorCount);
}

// Ultralytics' .engine files start with a 4-byte length and a JSON metadata block; skip it.
void StripUltralyticsHeader(std::vector<char> *buf) {
  if (buf->size() > 8) {
    uint32_t len;
    std::memcpy(&len, buf->data(), 4);
    if (len > 2 && len + 4 < buf->size() && (*buf)[4] == '{' && (*buf)[4 + len - 1] == '}') {
      buf->erase(buf->begin(), buf->begin() + 4 + len);
    }
  }
}

__device__ __forceinline__ float Sample(const uint8_t *src, int w, int h, int stride, int ch,
                                        int c, float sx, float sy) {
  sx = fminf(fmaxf(sx, 0.f), w - 1.f);
  sy = fminf(fmaxf(sy, 0.f), h - 1.f);
  const int x0 = static_cast<int>(sx), y0 = static_cast<int>(sy);
  const int x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
  const float fx = sx - x0, fy = sy - y0;
  const uint8_t *r0 = src + y0 * stride, *r1 = src + y1 * stride;
  const float a = r0[x0 * ch + c], b = r0[x1 * ch + c];
  const float d = r1[x0 * ch + c], e = r1[x1 * ch + c];
  return (a + (b - a) * fx) + ((d + (e - d) * fx) - (a + (b - a) * fx)) * fy;
}

// Letterbox + colour handling + normalisation into one batch slot of the NCHW input.
// ch 1: grey copied to R, G and B. ch 3: BGR in, RGB out.
template <typename T>
__global__ void Letterbox(const uint8_t *src, int sw, int sh, int stride, int ch, T *out, int W,
                          int H, float scale, float pad_x, float pad_y) {
  const int x = blockIdx.x * blockDim.x + threadIdx.x;
  const int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= W || y >= H) return;
  const float sx = (x + 0.5f - pad_x) / scale - 0.5f;
  const float sy = (y + 0.5f - pad_y) / scale - 0.5f;
  const size_t hw = static_cast<size_t>(W) * H, i = static_cast<size_t>(y) * W + x;
  float r, g, b;
  if (sx < -0.5f || sy < -0.5f || sx > sw - 0.5f || sy > sh - 0.5f) {
    r = g = b = 114.f / 255.f;
  } else if (ch == 1) {
    r = g = b = Sample(src, sw, sh, stride, 1, 0, sx, sy) / 255.f;
  } else {
    b = Sample(src, sw, sh, stride, 3, 0, sx, sy) / 255.f;
    g = Sample(src, sw, sh, stride, 3, 1, sx, sy) / 255.f;
    r = Sample(src, sw, sh, stride, 3, 2, sx, sy) / 255.f;
  }
  out[i] = static_cast<T>(r);
  out[hw + i] = static_cast<T>(g);
  out[2 * hw + i] = static_cast<T>(b);
}

struct Candidate {
  float cx, cy, w, h, score;
  int cls;
};

// Raw head [B, 4 + nc, N]: one thread per anchor; the best class, thresholded, compacted.
template <typename T>
__global__ void DecodeRaw(const T *out, int batch, int c, int n, int nc, float conf,
                          Candidate *cand, int max_cand, int *counts) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  const int b = blockIdx.y;
  if (i >= n || b >= batch) return;
  const T *o = out + static_cast<size_t>(b) * c * n;
  int best = 0;
  float score = static_cast<float>(o[4 * n + i]);
  for (int k = 1; k < nc; ++k) {
    const float s = static_cast<float>(o[(4 + k) * n + i]);
    if (s > score) {
      score = s;
      best = k;
    }
  }
  if (score < conf) return;
  const int slot = atomicAdd(&counts[b], 1);
  if (slot >= max_cand) return;
  cand[b * max_cand + slot] = {static_cast<float>(o[i]), static_cast<float>(o[n + i]),
                               static_cast<float>(o[2 * n + i]), static_cast<float>(o[3 * n + i]),
                               score, best};
}

// End-to-end head [B, K, 6] (x1 y1 x2 y2 score class): to float.
template <typename T>
__global__ void ToFloat(const T *in, float *out, size_t n) {
  const size_t i = blockIdx.x * static_cast<size_t>(blockDim.x) + threadIdx.x;
  if (i < n) out[i] = static_cast<float>(in[i]);
}

float Iou(const Detection &a, const Detection &b) {
  const float x1 = std::max(a.x, b.x), y1 = std::max(a.y, b.y);
  const float x2 = std::min(a.x + a.w, b.x + b.w), y2 = std::min(a.y + a.h, b.y + b.h);
  const float inter = std::max(0.f, x2 - x1) * std::max(0.f, y2 - y1);
  const float uni = a.w * a.h + b.w * b.h - inter;
  return uni > 0 ? inter / uni : 0.f;
}

constexpr int kMaxCandidates = 2048;

class Engine : public YoloEngine {
 public:
  ~Engine() override {
    CudaShared cuda;
    context_.reset();
    engine_.reset();
    runtime_.reset();
    for (auto &s : src_) {
      if (s.ptr) cudaFree(s.ptr);
    }
    if (d_in_) cudaFree(d_in_);
    if (d_out_) cudaFree(d_out_);
    if (d_cand_) cudaFree(d_cand_);
    if (d_counts_) cudaFree(d_counts_);
    if (d_e2e_) cudaFree(d_e2e_);
    if (h_cand_) cudaFreeHost(h_cand_);
    if (h_counts_) cudaFreeHost(h_counts_);
    if (stream_) cudaStreamDestroy(stream_);
  }

  int width() const override { return w_; }
  int height() const override { return h_; }
  int max_batch() const override { return max_batch_; }
  int num_classes() const override { return e2e_ ? -1 : nc_; }
  const std::string &engine_path() const override { return engine_path_; }

  bool Init(const std::vector<char> &blob, const Options &opt, std::string *err);
  bool Detect(const Image *images, int n, float conf, float iou, int max_det,
              std::vector<std::vector<Detection>> *out, Timing *timing) override;

  std::string engine_path_;

 private:
  struct Src {
    uint8_t *ptr = nullptr;
    size_t bytes = 0;
  };
  std::unique_ptr<nvinfer1::IRuntime> runtime_;
  std::unique_ptr<nvinfer1::ICudaEngine> engine_;
  std::unique_ptr<nvinfer1::IExecutionContext> context_;
  cudaStream_t stream_ = nullptr;
  std::string in_name_, out_name_;
  bool in_half_ = false, out_half_ = false, e2e_ = false;
  int w_ = 0, h_ = 0, max_batch_ = 1, nc_ = 0;
  int out_c_ = 0, out_n_ = 0;  // raw: [B, c, n]; e2e: [B, n(K), 6]
  std::vector<Src> src_;
  void *d_in_ = nullptr, *d_out_ = nullptr;
  Candidate *d_cand_ = nullptr, *h_cand_ = nullptr;
  int *d_counts_ = nullptr, *h_counts_ = nullptr;
  float *d_e2e_ = nullptr;
  std::vector<float> h_e2e_;
  std::mutex mu_;
};

bool Engine::Init(const std::vector<char> &blob, const Options &opt, std::string *err) {
  runtime_.reset(nvinfer1::createInferRuntime(gLogger));
  if (!runtime_) return *err = "createInferRuntime failed", false;
  engine_.reset(runtime_->deserializeCudaEngine(blob.data(), blob.size()));
  if (!engine_) return *err = "not a TensorRT engine for this GPU/TensorRT version", false;
  context_.reset(engine_->createExecutionContext());
  if (!context_) return *err = "createExecutionContext failed", false;

  nvinfer1::Dims out_dims{};
  for (int i = 0; i < engine_->getNbIOTensors(); ++i) {
    const char *name = engine_->getIOTensorName(i);
    if (engine_->getTensorIOMode(name) == nvinfer1::TensorIOMode::kINPUT) {
      in_name_ = name;
      in_half_ = engine_->getTensorDataType(name) == nvinfer1::DataType::kHALF;
      auto d = engine_->getTensorShape(name);
      if (d.nbDims != 4 || d.d[1] != 3) return *err = "input isn't [B,3,H,W]: " + DimsStr(d), false;
      if (d.d[0] < 0) {  // dynamic batch: the profile's max
        max_batch_ = static_cast<int>(
            engine_->getProfileShape(name, 0, nvinfer1::OptProfileSelector::kMAX).d[0]);
        h_ = static_cast<int>(
            engine_->getProfileShape(name, 0, nvinfer1::OptProfileSelector::kMAX).d[2]);
        w_ = static_cast<int>(
            engine_->getProfileShape(name, 0, nvinfer1::OptProfileSelector::kMAX).d[3]);
      } else {
        max_batch_ = static_cast<int>(d.d[0]);
        h_ = static_cast<int>(d.d[2]);
        w_ = static_cast<int>(d.d[3]);
      }
    } else if (out_name_.empty()) {
      out_name_ = name;
      out_half_ = engine_->getTensorDataType(name) == nvinfer1::DataType::kHALF;
    }
  }
  if (in_name_.empty() || out_name_.empty()) return *err = "no input/output tensor", false;
  // Output dims at the max batch.
  context_->setInputShape(in_name_.c_str(), nvinfer1::Dims4{max_batch_, 3, h_, w_});
  out_dims = context_->getTensorShape(out_name_.c_str());
  if (out_dims.nbDims != 3) return *err = "output isn't 3-D: " + DimsStr(out_dims), false;
  if (out_dims.d[2] == 6) {
    e2e_ = true;
    out_n_ = static_cast<int>(out_dims.d[1]);
  } else if (out_dims.d[1] >= 5) {
    out_c_ = static_cast<int>(out_dims.d[1]);
    out_n_ = static_cast<int>(out_dims.d[2]);
    nc_ = out_c_ - 4;
  } else {
    return *err = "output " + DimsStr(out_dims) + " isn't a YOLO detect head", false;
  }
  // Lowest priority: the AprilTag detector's work goes first when both are queued.
  int least = 0, greatest = 0;
  cudaDeviceGetStreamPriorityRange(&least, &greatest);
  int prio = least;
  if (const char *e = getenv("SPECTRUM_TRT_STREAM_PRIORITY")) prio = atoi(e);
  if (cudaStreamCreateWithPriority(&stream_, cudaStreamNonBlocking, prio) != cudaSuccess) {
    return *err = "cudaStreamCreateWithPriority failed", false;
  }
  const size_t out_elems = static_cast<size_t>(max_batch_) * (e2e_ ? out_n_ * 6 : out_c_ * out_n_);
  const size_t in_elems = static_cast<size_t>(max_batch_) * 3 * w_ * h_;
  if (cudaMalloc(&d_in_, in_elems * (in_half_ ? 2 : 4)) != cudaSuccess ||
      cudaMalloc(&d_out_, out_elems * (out_half_ ? 2 : 4)) != cudaSuccess ||
      cudaMalloc(&d_cand_, sizeof(Candidate) * kMaxCandidates * max_batch_) != cudaSuccess ||
      cudaMalloc(&d_counts_, sizeof(int) * max_batch_) != cudaSuccess ||
      cudaMallocHost(&h_cand_, sizeof(Candidate) * kMaxCandidates * max_batch_) != cudaSuccess ||
      cudaMallocHost(&h_counts_, sizeof(int) * max_batch_) != cudaSuccess) {
    return *err = "CUDA allocation failed", false;
  }
  if (e2e_) {
    if (cudaMalloc(&d_e2e_, out_elems * 4) != cudaSuccess) return *err = "CUDA alloc", false;
    h_e2e_.resize(out_elems);
  }
  src_.resize(max_batch_);
  context_->setTensorAddress(in_name_.c_str(), d_in_);
  context_->setTensorAddress(out_name_.c_str(), d_out_);
  std::cout << "TensorRT: " << engine_path_ << ": input " << w_ << "x" << h_ << " batch 1.."
            << max_batch_ << (in_half_ ? " fp16" : " fp32") << ", output " << DimsStr(out_dims)
            << (e2e_ ? " (end to end)" : "") << ", stream priority " << prio << std::endl;
  return true;
}

bool Engine::Detect(const Image *images, int n, float conf, float iou, int max_det,
                    std::vector<std::vector<Detection>> *out, Timing *timing) {
  if (n < 1 || n > max_batch_) return false;
  std::lock_guard<std::mutex> lock(mu_);
  CudaShared cuda;
  auto sync = [&](double *acc, double &t0) {
    if (!timing) return;
    cudaStreamSynchronize(stream_);
    const double t = NowMs();
    *acc += t - t0;
    t0 = t;
  };
  double t0 = timing ? NowMs() : 0;
  struct Box {
    float scale, pad_x, pad_y;
    int w, h;
  };
  std::vector<Box> boxes(n);
  std::vector<const uint8_t *> dev(n);
  for (int b = 0; b < n; ++b) {
    const Image &im = images[b];
    if (!im.data || im.width <= 0 || im.height <= 0 || (im.channels != 1 && im.channels != 3)) {
      return false;
    }
    const int stride = im.stride > 0 ? im.stride : im.width * im.channels;
    if (im.on_device) {
      dev[b] = im.data;
    } else {
      const size_t row = static_cast<size_t>(im.width) * im.channels;
      const size_t bytes = row * im.height;
      if (src_[b].bytes < bytes) {
        if (src_[b].ptr) cudaFree(src_[b].ptr);
        src_[b].ptr = nullptr;
        if (cudaMalloc(&src_[b].ptr, bytes) != cudaSuccess) return src_[b].bytes = 0, false;
        src_[b].bytes = bytes;
      }
      cudaMemcpy2DAsync(src_[b].ptr, row, im.data, stride, row, im.height, cudaMemcpyHostToDevice,
                        stream_);
      dev[b] = src_[b].ptr;
    }
    const float s = std::min(static_cast<float>(w_) / im.width, static_cast<float>(h_) / im.height);
    boxes[b] = {s, (w_ - im.width * s) / 2.f, (h_ - im.height * s) / 2.f, im.width, im.height};
  }
  if (timing) sync(&timing->upload_ms, t0);
  const dim3 block(32, 8), grid((w_ + 31) / 32, (h_ + 7) / 8);
  const size_t slot = static_cast<size_t>(3) * w_ * h_;
  for (int b = 0; b < n; ++b) {
    const Image &im = images[b];
    const int stride = im.on_device ? (im.stride > 0 ? im.stride : im.width * im.channels)
                                    : im.width * im.channels;
    if (in_half_) {
      Letterbox<__half><<<grid, block, 0, stream_>>>(dev[b], im.width, im.height, stride,
                                                     im.channels, static_cast<__half *>(d_in_) + b * slot,
                                                     w_, h_, boxes[b].scale, boxes[b].pad_x,
                                                     boxes[b].pad_y);
    } else {
      Letterbox<float><<<grid, block, 0, stream_>>>(dev[b], im.width, im.height, stride,
                                                    im.channels, static_cast<float *>(d_in_) + b * slot,
                                                    w_, h_, boxes[b].scale, boxes[b].pad_x,
                                                    boxes[b].pad_y);
    }
  }
  if (timing) sync(&timing->preprocess_ms, t0);
  if (!context_->setInputShape(in_name_.c_str(), nvinfer1::Dims4{n, 3, h_, w_}) ||
      !context_->enqueueV3(stream_)) {
    std::cout << "TensorRT: enqueueV3 failed" << std::endl;
    return false;
  }
  if (timing) sync(&timing->infer_ms, t0);
  if (e2e_) {
    const size_t elems = static_cast<size_t>(n) * out_n_ * 6;
    if (out_half_) {
      ToFloat<__half><<<(elems + 255) / 256, 256, 0, stream_>>>(static_cast<__half *>(d_out_),
                                                                d_e2e_, elems);
    } else {
      ToFloat<float><<<(elems + 255) / 256, 256, 0, stream_>>>(static_cast<float *>(d_out_),
                                                               d_e2e_, elems);
    }
    cudaMemcpyAsync(h_e2e_.data(), d_e2e_, elems * 4, cudaMemcpyDeviceToHost, stream_);
  } else {
    cudaMemsetAsync(d_counts_, 0, sizeof(int) * n, stream_);
    const dim3 dgrid((out_n_ + 255) / 256, n);
    if (out_half_) {
      DecodeRaw<__half><<<dgrid, 256, 0, stream_>>>(static_cast<__half *>(d_out_), n, out_c_,
                                                    out_n_, nc_, conf, d_cand_, kMaxCandidates,
                                                    d_counts_);
    } else {
      DecodeRaw<float><<<dgrid, 256, 0, stream_>>>(static_cast<float *>(d_out_), n, out_c_,
                                                   out_n_, nc_, conf, d_cand_, kMaxCandidates,
                                                   d_counts_);
    }
    cudaMemcpyAsync(h_counts_, d_counts_, sizeof(int) * n, cudaMemcpyDeviceToHost, stream_);
    // All slots: one copy, no second sync for the counts (2048 x 24 B x batch, ~0.05 ms).
    cudaMemcpyAsync(h_cand_, d_cand_, sizeof(Candidate) * kMaxCandidates * n,
                    cudaMemcpyDeviceToHost, stream_);
  }
  const cudaError_t e = cudaStreamSynchronize(stream_);
  if (e != cudaSuccess) {
    std::cout << "TensorRT: " << cudaGetErrorString(e) << std::endl;
    cudaGetLastError();
    return false;
  }
  if (timing) {
    const double t = NowMs();
    timing->decode_ms += t - t0;
    t0 = t;
  }
  out->assign(n, {});
  for (int b = 0; b < n; ++b) {
    std::vector<Detection> dets;
    const Box &bx = boxes[b];
    auto unbox = [&](float x1, float y1, float x2, float y2, float score, int cls) {
      x1 = std::clamp((x1 - bx.pad_x) / bx.scale, 0.f, static_cast<float>(bx.w));
      x2 = std::clamp((x2 - bx.pad_x) / bx.scale, 0.f, static_cast<float>(bx.w));
      y1 = std::clamp((y1 - bx.pad_y) / bx.scale, 0.f, static_cast<float>(bx.h));
      y2 = std::clamp((y2 - bx.pad_y) / bx.scale, 0.f, static_cast<float>(bx.h));
      if (x2 > x1 && y2 > y1) dets.push_back({x1, y1, x2 - x1, y2 - y1, score, cls});
    };
    if (e2e_) {
      const float *o = h_e2e_.data() + static_cast<size_t>(b) * out_n_ * 6;
      for (int i = 0; i < out_n_; ++i) {
        const float *r = o + i * 6;
        if (r[4] >= conf) unbox(r[0], r[1], r[2], r[3], r[4], static_cast<int>(r[5]));
      }
      std::sort(dets.begin(), dets.end(),
                [](const Detection &a, const Detection &c) { return a.score > c.score; });
    } else {
      const int count = std::min(h_counts_[b], kMaxCandidates);
      const Candidate *c = h_cand_ + static_cast<size_t>(b) * kMaxCandidates;
      for (int i = 0; i < count; ++i) {
        unbox(c[i].cx - c[i].w / 2, c[i].cy - c[i].h / 2, c[i].cx + c[i].w / 2,
              c[i].cy + c[i].h / 2, c[i].score, c[i].cls);
      }
      std::sort(dets.begin(), dets.end(),
                [](const Detection &a, const Detection &c) { return a.score > c.score; });
      std::vector<Detection> kept;
      std::vector<char> removed(dets.size(), 0);
      for (size_t i = 0; i < dets.size() && static_cast<int>(kept.size()) < max_det; ++i) {
        if (removed[i]) continue;
        kept.push_back(dets[i]);
        for (size_t j = i + 1; j < dets.size(); ++j) {
          if (!removed[j] && dets[j].cls == dets[i].cls && Iou(dets[i], dets[j]) > iou) {
            removed[j] = 1;
          }
        }
      }
      dets.swap(kept);
    }
    if (static_cast<int>(dets.size()) > max_det) dets.resize(max_det);
    (*out)[b] = std::move(dets);
  }
  if (timing) timing->nms_ms += NowMs() - t0;
  return true;
}

// ONNX -> serialized engine. Dynamic dims get the requested size and batch 1..max_batch.
std::vector<char> BuildEngine(const std::string &onnx, const Options &opt, std::string *err) {
  std::unique_ptr<nvinfer1::IBuilder> builder(nvinfer1::createInferBuilder(gLogger));
  if (!builder) return *err = "createInferBuilder failed", std::vector<char>{};
  std::unique_ptr<nvinfer1::INetworkDefinition> network(builder->createNetworkV2(0));
  std::unique_ptr<nvonnxparser::IParser> parser(nvonnxparser::createParser(*network, gLogger));
  if (!parser->parseFromFile(onnx.c_str(),
                             static_cast<int>(nvinfer1::ILogger::Severity::kWARNING))) {
    return *err = "could not parse " + onnx, std::vector<char>{};
  }
  std::unique_ptr<nvinfer1::IBuilderConfig> config(builder->createBuilderConfig());
  config->setMemoryPoolLimit(nvinfer1::MemoryPoolType::kWORKSPACE, size_t(1) << 30);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  if (opt.fp16) config->setFlag(nvinfer1::BuilderFlag::kFP16);
#pragma GCC diagnostic pop
  auto *input = network->getInput(0);
  auto d = input->getDimensions();
  if (d.nbDims != 4) return *err = "input isn't 4-D: " + DimsStr(d), std::vector<char>{};
  const bool dyn = d.d[0] < 0 || d.d[2] < 0 || d.d[3] < 0;
  if (dyn) {
    auto *profile = builder->createOptimizationProfile();
    const int64_t h = d.d[2] < 0 ? opt.height : d.d[2], w = d.d[3] < 0 ? opt.width : d.d[3];
    const int64_t maxb = d.d[0] < 0 ? std::max(1, opt.max_batch) : d.d[0];
    const int64_t minb = d.d[0] < 0 ? 1 : d.d[0];
    profile->setDimensions(input->getName(), nvinfer1::OptProfileSelector::kMIN,
                           nvinfer1::Dims4{minb, 3, h, w});
    profile->setDimensions(input->getName(), nvinfer1::OptProfileSelector::kOPT,
                           nvinfer1::Dims4{maxb, 3, h, w});
    profile->setDimensions(input->getName(), nvinfer1::OptProfileSelector::kMAX,
                           nvinfer1::Dims4{maxb, 3, h, w});
    config->addOptimizationProfile(profile);
  }
  std::cout << "TensorRT: building " << onnx << " (" << (opt.fp16 ? "FP16" : "FP32")
            << "); this takes a few minutes, once" << std::endl;
  const double t0 = NowMs();
  std::unique_ptr<nvinfer1::IHostMemory> plan(builder->buildSerializedNetwork(*network, *config));
  if (!plan) return *err = "engine build failed", std::vector<char>{};
  std::cout << "TensorRT: built in " << (NowMs() - t0) / 1000 << " s" << std::endl;
  const char *p = static_cast<const char *>(plan->data());
  return std::vector<char>(p, p + plan->size());
}

}  // namespace

std::string CachedEnginePath(const std::string &model_path, const Options &opt) {
  const auto bytes = ReadFile(model_path);
  uint64_t h = Fnv1a(bytes.data(), bytes.size());
  std::ostringstream key;
  key << opt.width << "x" << opt.height << "b" << opt.max_batch << (opt.fp16 ? "fp16" : "fp32")
      << "trt" << getInferLibVersion() << GpuKey();
  const std::string k = key.str();
  h = Fnv1a(k.data(), k.size(), h);
  char hex[17];
  snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(h));
  return opt.cache_dir + "/" + Stem(model_path) + "-" + std::to_string(opt.width) + "x" +
         std::to_string(opt.height) + "-b" + std::to_string(opt.max_batch) +
         (opt.fp16 ? "-fp16-" : "-fp32-") + hex + ".engine";
}

std::unique_ptr<YoloEngine> YoloEngine::Create(const std::string &model_path, const Options &opt,
                                               std::string *error) {
  std::string err;
  std::vector<char> blob;
  std::string engine_path = model_path;
  if (EndsWith(model_path, ".onnx")) {
    engine_path = CachedEnginePath(model_path, opt);
    blob = ReadFile(engine_path);
    if (blob.empty()) {
      {
        CudaShared cuda;  // the build allocates and frees on the GPU throughout
        blob = BuildEngine(model_path, opt, &err);
      }
      if (blob.empty()) return *error = err, nullptr;
      mkdir(opt.cache_dir.c_str(), 0755);
      const std::string tmp = engine_path + ".tmp" + std::to_string(getpid());
      {
        std::ofstream f(tmp, std::ios::binary);
        f.write(blob.data(), static_cast<std::streamsize>(blob.size()));
        if (!f) err = "could not write " + tmp;
      }
      if (err.empty() && rename(tmp.c_str(), engine_path.c_str()) != 0) err = "rename failed";
      if (!err.empty()) std::cout << "TensorRT: engine not cached: " << err << std::endl;
      err.clear();
    } else {
      std::cout << "TensorRT: cached engine " << engine_path << std::endl;
    }
  } else {
    blob = ReadFile(model_path);
    StripUltralyticsHeader(&blob);
  }
  if (blob.empty()) return *error = "cannot read " + model_path, nullptr;
  CudaShared cuda;
  auto e = std::make_unique<Engine>();
  e->engine_path_ = engine_path;
  if (!e->Init(blob, opt, &err)) {
    // A cached engine from an older build that won't load: delete it so the next start rebuilds.
    if (engine_path != model_path) unlink(engine_path.c_str());
    return *error = engine_path + ": " + err, nullptr;
  }
  return e;
}

}  // namespace spectrum_trt
