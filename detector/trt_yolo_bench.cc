// SpectrumJetson: trt_yolo_bench, the bench tool for trt_yolo (TensorRT YOLO with batching).
//
// Builds (or loads from the cache) a model's engine and times batches of frames, or prints the
// detections on one raw image. No camera, no PhotonVision. tests/object-detection/bench.sh runs it.
//
//   trt_yolo_bench --model yolo11n.onnx [--cache DIR] [--size 640x640] [--max-batch 4]
//                  [--batches 1,2,4] [--iters 200] [--fp32] [--frame 1280x800x1]
//                  [--image file.raw --image-size WxHxC] [--conf 0.25] [--iou 0.45]
//   --build-only   build/cache the engine and exit (12-install-yolo-model.sh)
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <random>
#include <string>
#include <vector>

#include "trt_yolo.h"

using spectrum_trt::Image;

namespace {
double NowMs() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
bool ParseSize(const char *s, int *w, int *h, int *c = nullptr) {
  int n = c ? sscanf(s, "%dx%dx%d", w, h, c) : sscanf(s, "%dx%d", w, h);
  return n == (c ? 3 : 2);
}
}  // namespace

int main(int argc, char **argv) {
  spectrum_trt::Options opt;
  std::string model, image_path, batches_s = "1,2,4";
  int iters = 200, fw = 1280, fh = 800, fc = 1, iw = 0, ih = 0, ic = 0;
  float conf = 0.25f, iou = 0.45f;
  bool build_only = false;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> const char * {
      if (i + 1 >= argc) {
        std::cerr << a << " needs a value\n";
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--model") model = next();
    else if (a == "--cache") opt.cache_dir = next();
    else if (a == "--size") ParseSize(next(), &opt.width, &opt.height);
    else if (a == "--max-batch") opt.max_batch = atoi(next());
    else if (a == "--batches") batches_s = next();
    else if (a == "--iters") iters = atoi(next());
    else if (a == "--fp32") opt.fp16 = false;
    else if (a == "--frame") ParseSize(next(), &fw, &fh, &fc);
    else if (a == "--image") image_path = next();
    else if (a == "--image-size") ParseSize(next(), &iw, &ih, &ic);
    else if (a == "--conf") conf = static_cast<float>(atof(next()));
    else if (a == "--iou") iou = static_cast<float>(atof(next()));
    else if (a == "--build-only") build_only = true;
    else {
      std::cerr << "unknown argument " << a << "\n";
      return 2;
    }
  }
  if (model.empty()) {
    std::cerr << "--model is required\n";
    return 2;
  }
  std::string err;
  const double t0 = NowMs();
  auto engine = spectrum_trt::YoloEngine::Create(model, opt, &err);
  if (!engine) {
    std::cerr << "FAIL: " << err << "\n";
    return 1;
  }
  printf("engine %s ready in %.1f s: %dx%d, batch <= %d, classes %d\n",
         engine->engine_path().c_str(), (NowMs() - t0) / 1000, engine->width(), engine->height(),
         engine->max_batch(), engine->num_classes());
  if (build_only) return 0;

  if (!image_path.empty()) {
    std::ifstream f(image_path, std::ios::binary);
    std::vector<uint8_t> px((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (px.size() != static_cast<size_t>(iw) * ih * ic) {
      std::cerr << "FAIL: " << image_path << " is " << px.size() << " bytes, not " << iw << "x"
                << ih << "x" << ic << "\n";
      return 1;
    }
    Image im{px.data(), iw, ih, iw * ic, ic, false};
    std::vector<std::vector<spectrum_trt::Detection>> out;
    if (!engine->Detect(&im, 1, conf, iou, 100, &out)) return 1;
    for (const auto &d : out[0]) {
      printf("det cls %d score %.3f box %.1f %.1f %.1f %.1f\n", d.cls, d.score, d.x, d.y,
             d.x + d.w, d.y + d.h);
    }
    return 0;
  }

  // Synthetic frames: noise with some structure, so the head's work is realistic-ish.
  std::mt19937 rng(42);
  std::vector<std::vector<uint8_t>> frames(engine->max_batch());
  for (auto &fr : frames) {
    fr.resize(static_cast<size_t>(fw) * fh * fc);
    for (size_t i = 0; i < fr.size(); ++i) fr[i] = static_cast<uint8_t>((i / 7 + rng() % 64) & 0xff);
  }
  std::vector<int> batches;
  for (char *s = strtok(batches_s.data(), ","); s; s = strtok(nullptr, ",")) batches.push_back(atoi(s));
  for (int b : batches) {
    if (b < 1 || b > engine->max_batch()) continue;
    std::vector<Image> ims(b);
    for (int i = 0; i < b; ++i) ims[i] = {frames[i].data(), fw, fh, fw * fc, fc, false};
    std::vector<std::vector<spectrum_trt::Detection>> out;
    for (int i = 0; i < 20; ++i) engine->Detect(ims.data(), b, conf, iou, 100, &out);  // warm up
    std::vector<double> t;
    for (int i = 0; i < iters; ++i) {
      const double s = NowMs();
      if (!engine->Detect(ims.data(), b, conf, iou, 100, &out)) return 1;
      t.push_back(NowMs() - s);
    }
    std::sort(t.begin(), t.end());
    spectrum_trt::Timing tm;
    const int n_t = std::max(1, iters / 4);
    for (int i = 0; i < n_t; ++i) engine->Detect(ims.data(), b, conf, iou, 100, &out, &tm);
    printf("batch %d: call p50 %.2f p95 %.2f ms (%.2f ms/frame p50) | stages: upload %.2f pre %.2f "
           "infer %.2f decode %.2f nms %.2f ms\n",
           b, t[t.size() / 2], t[t.size() * 95 / 100], t[t.size() / 2] / b, tm.upload_ms / n_t,
           tm.preprocess_ms / n_t, tm.infer_ms / n_t, tm.decode_ms / n_t, tm.nms_ms / n_t);
  }
  return 0;
}
