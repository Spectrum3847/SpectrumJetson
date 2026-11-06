// rewind_bench: the native Rewind writer's cost and throughput, offline (no camera): N "cameras" push the frames of
// a recorded MJPEG at a camera's rate into their own writers, as the native backend's vision threads would.
//   rewind_bench FILE.mjpeg OUTDIR [CAMS 2] [SECS 10] [FPS 120] [RECORD_FPS 0]
// Prints per camera: frames pushed / kept / dropped, the push's cost on the vision thread (us p50/p99/max),
// MB/s written, the writer thread's CPU, the worst fdatasync. Deletes nothing: OUTDIR gets the recordings.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <algorithm>
#include <string>
#include <thread>
#include <vector>

#include "rewind_writer.h"

static int64_t mono_ns() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: rewind_bench FILE.mjpeg OUTDIR [CAMS] [SECS] [FPS] [RECORD_FPS]\n");
    return 2;
  }
  const int cams = argc > 3 ? atoi(argv[3]) : 2;
  const double secs = argc > 4 ? atof(argv[4]) : 10, fps = argc > 5 ? atof(argv[5]) : 120;
  const double rec_fps = argc > 6 ? atof(argv[6]) : 0;
  FILE *f = fopen(argv[1], "rb");
  if (!f) return perror(argv[1]), 1;
  std::vector<uint8_t> all;
  for (int c; (c = fgetc(f)) != EOF;) all.push_back((uint8_t)c);
  fclose(f);
  std::vector<std::pair<size_t, size_t>> fr;  // offset, length
  for (size_t p = 0; p + 1 < all.size();) {
    if (all[p] == 0xFF && all[p + 1] == 0xD8) {
      size_t q = p + 2;
      while (q + 1 < all.size() && !(all[q] == 0xFF && all[q + 1] == 0xD9)) q++;
      fr.push_back({p, q + 2 - p});
      p = q + 2;
    } else {
      p++;
    }
  }
  if (fr.empty()) return fprintf(stderr, "no frames\n"), 1;
  double mean = 0;
  for (auto &x : fr) mean += x.second;
  printf("%zu frames, mean %.1f KB; %d cameras x %.0f fps for %.0f s, record fps %s\n", fr.size(),
         mean / fr.size() / 1024, cams, fps, secs, rec_fps > 0 ? std::to_string(rec_fps).c_str() : "all");
  std::vector<std::thread> th;
  for (int c = 0; c < cams; c++)
    th.emplace_back([&, c] {
      std::string prefix = std::string(argv[2]) + "/bench_cam" + std::to_string(c);
      RewindWriter *w = rewind_open(prefix.c_str(), 16u << 20, rec_fps);
      std::vector<double> push_us;
      const int64_t t0 = mono_ns(), period = (int64_t)(1e9 / fps);
      long n = 0;
      for (int64_t next = t0; next - t0 < (int64_t)(secs * 1e9); next += period, n++) {
        while (mono_ns() < next) {
          timespec ts{0, 200000};
          nanosleep(&ts, nullptr);
        }
        const auto &x = fr[(size_t)(n + c * 7) % fr.size()];
        const int64_t a = mono_ns();
        rewind_push(w, all.data() + x.first, x.second, 1280, 800, a / 1000, 0);
        push_us.push_back((mono_ns() - a) / 1e3);
      }
      const int64_t t1 = mono_ns();
      rewind_stats s{};
      rewind_get_stats(w, &s);
      rewind_close(w);  // drains: the rest is written and synced
      rewind_stats e{};
      (void)e;
      std::sort(push_us.begin(), push_us.end());
      auto P = [&](double q) { return push_us[std::min(push_us.size() - 1, (size_t)(q * push_us.size()))]; };
      printf("cam %d: pushed %ld, kept %ld, dropped %ld (ring full) %ld (record fps); push us p50 %.1f p99 %.1f "
             "max %.1f; %.1f MB/s written during the run; writer CPU %.0f ms (%.1f%% of a core); worst fdatasync "
             "%.1f ms\n",
             c, n, s.queued, s.dropped_full, s.dropped_fps, P(.5), P(.99), push_us.back(),
             s.bytes / 1e6 / ((t1 - t0) / 1e9), s.writer_cpu_ms, s.writer_cpu_ms / ((t1 - t0) / 1e6) * 100,
             s.max_fsync_ms);
    });
  for (auto &t : th) t.join();
  return 0;
}
