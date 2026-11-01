// SpectrumJetson: TensorRT YOLO engine with GPU preprocessing and batching (trt_yolo.cu).
//
// Used by libspectrumtrt.so (TensorRtYoloJNI.cu, PhotonVision's TensorRT object-detection backend)
// and by trt_yolo_bench (the bench tool). See docs/OBJECT-DETECTION.md.
//
// - Takes a YOLOv8 / YOLO11 detect model as ONNX (Ultralytics export, dynamic or static) or a
//   ready-built .engine. ONNX is built into an engine on first use (FP16 by default) and cached in
//   cache_dir, keyed by the model's bytes, the input size, the batch size, the precision, the
//   TensorRT version and the GPU: a JetPack update or a new model rebuilds it, nothing else does.
// - Any number of frames up to max_batch run as one batch (dynamic batch profile 1..max_batch).
// - Frames are letterboxed to the input size on the GPU (bilinear, grey 114 padding). A mono
//   (1-channel) frame is copied to all three input channels; colour frames are BGR. Input sizes
//   needn't be square (640x384 for a 16:10 camera).
// - The output is decoded on the GPU (best class per anchor, confidence threshold, compaction);
//   only the candidates come back to the CPU for NMS. Boxes come out in source-frame pixels.
// - Everything runs on one CUDA stream at the lowest priority, so the AprilTag detector's stream
//   (detector-19: high priority when SPECTRUM_TAG_STREAM_PRIORITY=high) goes first.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace spectrum_trt {

struct Image {
  const uint8_t *data = nullptr;  // host memory, or device memory if on_device
  int width = 0, height = 0;
  int stride = 0;    // bytes per row
  int channels = 1;  // 1 = grey (mono camera), 3 = BGR
  bool on_device = false;
};

struct Detection {
  float x, y, w, h;  // top-left corner and size, source-frame pixels
  float score;
  int cls;
};

struct Options {
  int width = 640, height = 640;  // network input; used when the ONNX's H/W are dynamic
  int max_batch = 4;              // 1 for a model exported with a fixed batch of 1
  bool fp16 = true;
  std::string cache_dir = ".";
};

struct Timing {  // filled only when passed (each stage then synchronises: bench use)
  double upload_ms = 0, preprocess_ms = 0, infer_ms = 0, decode_ms = 0, nms_ms = 0;
};

class YoloEngine {
 public:
  // Builds (or loads from the cache) and allocates. Null on failure, with *error set.
  static std::unique_ptr<YoloEngine> Create(const std::string &model_path, const Options &options,
                                            std::string *error);
  virtual ~YoloEngine() = default;

  virtual int width() const = 0;
  virtual int height() const = 0;
  virtual int max_batch() const = 0;
  virtual int num_classes() const = 0;  // -1 for an end-to-end (NMS in the model) head
  virtual const std::string &engine_path() const = 0;

  // Runs n (1..max_batch) frames as one batch. out->at(i) are frame i's detections, best first.
  virtual bool Detect(const Image *images, int n, float conf, float iou, int max_det,
                      std::vector<std::vector<Detection>> *out, Timing *timing = nullptr) = 0;
};

// The cache file a model would build to (for scripts: whether it's already built).
std::string CachedEnginePath(const std::string &model_path, const Options &options);

}  // namespace spectrum_trt
