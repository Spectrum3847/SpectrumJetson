// graph_bench: times GpuDetector::Detect() on frames from one Rewind camera folder, as the JNI
// bridge runs it (the frame already on the GPU, copied into the detector's own fixed buffer, the
// first-stage graph recorded once), and writes every detection exactly, for A/B tests of the
// detector's CUDA launch path (detector-11, SPECTRUM_DETECTOR_GRAPHS).
//
//   graph_bench CAMERA_DIR [--frames N] [--loops N] [--mwbd N] [--edge N] [--threads N]
//               [--calib fx,fy,cx,cy,k1,k2,p1,p2,k3,k4,k5,k6] [--out DETECTIONS.txt]
//
// Decodes the first N frames (default 300) once, then runs them through Detect() --loops times
// (default 3; the first loop is warm-up and isn't timed). Per Detect(): the calling thread's CPU
// time (CLOCK_THREAD_CPUTIME_ID), the whole process's (the decode worker threads too) and wall
// time. Prints medians and p95. DETECTIONS.txt: one line per detection of the last loop: frame id hamming margin(%a) corners(%a), so two builds can be
// compared bit for bit with cmp. --calib: a lens calibration, as PhotonVision passes once the camera
// is calibrated (RefineEdges undistorts every edge sample); without one, none (fx=fy=1, k=0).
// --threads: the decode worker threads (default 6, as live).
#include <time.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include <cuda_runtime.h>

#include "absl/status/status.h"
#include "apriltag/apriltag.h"
#include "apriltag/tag36h11.h"
#include "rewind_reader.h"
#include "third_party/971apriltag/apriltag.h"

namespace {
double ThreadCpuUs() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}
double ProcessCpuUs() {
  timespec t;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}
double Pct(std::vector<double> v, double p) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, static_cast<size_t>(p * (v.size() - 1) + 0.5))];
}
}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::cerr << "graph_bench CAMERA_DIR [--frames N] [--loops N] [--mwbd N] [--edge N] [--threads N]"
                 " [--calib fx,fy,cx,cy,k1,k2,p1,p2,k3,k4,k5,k6] [--out FILE]\n";
    return 2;
  }
  int max_frames = 300, loops = 3, mwbd = 20, edge = 0, threads = 6;
  std::string out_path;
  std::vector<double> calib;
  for (int i = 2; i + 1 < argc; i += 2) {
    const std::string a = argv[i];
    if (a == "--frames") max_frames = std::atoi(argv[i + 1]);
    else if (a == "--loops") loops = std::max(2, std::atoi(argv[i + 1]));
    else if (a == "--mwbd") mwbd = std::atoi(argv[i + 1]);
    else if (a == "--edge") edge = std::atoi(argv[i + 1]);
    else if (a == "--threads") threads = std::max(1, std::atoi(argv[i + 1]));
    else if (a == "--calib") {
      calib.clear();
      for (char *p = argv[i + 1]; *p;) {
        char *end;
        calib.push_back(std::strtod(p, &end));
        if (end == p) break;
        p = *end == ',' ? end + 1 : end;
      }
      if (calib.size() != 4 && calib.size() != 12) {
        std::cerr << "--calib needs fx,fy,cx,cy[,k1,k2,p1,p2,k3,k4,k5,k6]\n";
        return 2;
      }
    }
    else if (a == "--out") out_path = argv[i + 1];
    else {
      std::cerr << "unknown option " << a << "\n";
      return 2;
    }
  }
  auto index = recording::ReadIndex(argv[1]);
  if (index.empty()) {
    std::cerr << "no frames in " << argv[1] << "\n";
    return 1;
  }
  const int w = index[0].width, h = index[0].height;
  std::vector<std::vector<uint8_t>> frames;
  std::vector<unsigned char> jpeg;
  for (const auto &f : index) {
    if (static_cast<int>(frames.size()) >= max_frames) break;
    std::vector<uint8_t> gray;
    if (recording::ReadJpeg(f, jpeg) && recording::DecodeGray(jpeg, gray, w, h)) frames.push_back(std::move(gray));
  }
  // As the JNI bridge: the thread sleeps while it waits for the GPU (SPECTRUM_CUDA_SYNC=spin to spin).
  const char *sync = std::getenv("SPECTRUM_CUDA_SYNC");
  cudaSetDeviceFlags(sync && std::string(sync) == "spin" ? cudaDeviceScheduleSpin
                                                         : cudaDeviceScheduleBlockingSync);
  const size_t n = static_cast<size_t>(w) * h;
  // All frames on the GPU; each one copied into the detector's fixed input buffer, as the JNI does.
  uint8_t *all = nullptr, *dev_in = nullptr;
  if (cudaMalloc(&all, n * frames.size()) != cudaSuccess || cudaMalloc(&dev_in, n) != cudaSuccess) return 1;
  for (size_t i = 0; i < frames.size(); ++i) cudaMemcpy(all + i * n, frames[i].data(), n, cudaMemcpyHostToDevice);

  apriltag_family_t *family = tag36h11_create();
  apriltag_detector_t *td = apriltag_detector_create();
  apriltag_detector_add_family_bits(td, family, 1);
  td->nthreads = threads;
  td->wp = workerpool_create(td->nthreads);
  td->qtp.min_white_black_diff = mwbd;
  td->qtp.max_line_fit_mse = 10;
  td->debug = false;
  frc::apriltag::CameraMatrix cm{1, 1, 1, 1};
  frc::apriltag::DistCoeffs dc{};
  dc.num_params = 5;
  if (!calib.empty()) {
    cm = {calib[0], calib[2], calib[1], calib[3]};  // fx, cx, fy, cy
    if (calib.size() == 12) {
      dc = {calib[4], calib[5], calib[6], calib[7], calib[8], calib[9], calib[10], calib[11], 8};
    }
  }
  frc::apriltag::GpuDetector gpu(w, h, td, cm, dc,
                                 vision::ImageFormat::MONO8);
  gpu.SetEdgeBorder(edge);  // detector-12: full-resolution pixels, 0 = off

  std::vector<double> cpu, wall, proc;
  FILE *out = out_path.empty() ? nullptr : std::fopen(out_path.c_str(), "w");
  size_t dets = 0, failures = 0;
  for (int loop = 0; loop < loops; ++loop) {
    for (size_t i = 0; i < frames.size(); ++i) {
      cudaMemcpy(dev_in, all + i * n, n, cudaMemcpyDeviceToDevice);
      if (gpu.FirstStageGraphWanted(dev_in)) {
        auto s = gpu.RecordFirstStageGraph(dev_in);
        if (!s.ok()) std::cerr << "first-stage graph: " << s.message() << "\n";
      }
      if (gpu.StageGraphsWanted()) {  // detector-11
        auto s = gpu.RecordStageGraphs();
        if (!s.ok()) std::cerr << "stage graphs: " << s.message() << "\n";
      }
      const double p0 = ProcessCpuUs();
      const double c0 = ThreadCpuUs();
      const auto t0 = std::chrono::steady_clock::now();
      const auto status = gpu.Detect(frames[i].data(), dev_in);
      const auto t1 = std::chrono::steady_clock::now();
      const double c1 = ThreadCpuUs();
      const double p1 = ProcessCpuUs();
      if (!status.ok()) {
        ++failures;
        continue;
      }
      if (loop == 0) continue;
      cpu.push_back(c1 - c0);
      proc.push_back(p1 - p0);
      wall.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
      if (loop != loops - 1) continue;
      const zarray_t *d = gpu.Detections();
      for (int k = 0; k < zarray_size(d); ++k) {
        apriltag_detection_t *det;
        zarray_get(const_cast<zarray_t *>(d), k, &det);
        ++dets;
        if (!out) continue;
        std::fprintf(out, "%zu %d %d %a", i, det->id, det->hamming, det->decision_margin);
        for (int c = 0; c < 4; ++c) std::fprintf(out, " %a %a", det->p[c][0], det->p[c][1]);
        std::fprintf(out, " %a %a\n", det->c[0], det->c[1]);
      }
    }
  }
  if (out) std::fclose(out);
  std::printf("frames %zu %dx%d detections(last loop) %zu failures %zu\n", frames.size(), w, h, dets, failures);
  std::printf("cpu_us p50 %.1f p95 %.1f mean %.1f | wall_us p50 %.1f p95 %.1f\n", Pct(cpu, .5), Pct(cpu, .95),
              [&] { double s = 0; for (double v : cpu) s += v; return cpu.empty() ? 0 : s / cpu.size(); }(),
              Pct(wall, .5), Pct(wall, .95));
  std::printf("process_cpu_us p50 %.1f p95 %.1f (all threads: the decode workers too)\n", Pct(proc, .5),
              Pct(proc, .95));
  return 0;
}
