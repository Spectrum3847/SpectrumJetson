// Rewind video writer (rewind_writer.h).
#include "rewind_writer.h"

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
int64_t mono_us() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}
double thread_cpu_ms() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
struct Rec {  // a frame in the ring
  size_t off, len;
  int width, height;
  int64_t t_us, robot_us;
};
constexpr int64_t kFileUs = 5LL * 60 * 1000000;  // a new file every 5 min
constexpr int64_t kSyncUs = 2000000;             // force to disk every 2 s
constexpr size_t kChunk = 1 << 20;               // write in ~1 MB pieces
}  // namespace

struct RewindWriter {
  std::string prefix;
  std::vector<uint8_t> ring;
  size_t head = 0, tail = 0, used = 0;  // bytes; head: next write position, tail: oldest unwritten
  std::vector<Rec> recs;                // queued frames, oldest first
  std::mutex mu;
  std::condition_variable cv;
  bool stop = false;
  double record_fps;
  int64_t last_keep_us = 0;
  std::atomic<long> queued{0}, written{0}, dropped_full{0}, dropped_fps{0};
  std::atomic<long long> bytes{0};
  std::atomic<double> max_fsync_ms{0}, cpu_ms{0};
  std::thread th;
  // writer state
  int fd = -1;
  FILE *csv = nullptr;
  int file_no = -1;
  long frame_no = 0;
  long long file_off = 0;
  int64_t file_start_us = 0, last_sync_us = 0;

  void open_next(int64_t now) {
    close_files();
    file_no++;
    char p[512];
    snprintf(p, sizeof p, "%s_%04d.mjpeg", prefix.c_str(), file_no);
    fd = ::open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    snprintf(p, sizeof p, "%s_%04d.csv", prefix.c_str(), file_no);
    csv = fopen(p, "w");
    if (csv) fprintf(csv, "frame,offset,size,width,height,jetson_us,robot_us\n");
    file_off = 0;
    file_start_us = now;
    last_sync_us = now;
  }
  void sync() {
    if (fd < 0) return;
    const double t0 = thread_cpu_ms();
    const int64_t w0 = mono_us();
    if (csv) fflush(csv);
    fdatasync(fd);
    if (csv) fdatasync(fileno(csv));
    const double ms = (mono_us() - w0) / 1e3;
    if (ms > max_fsync_ms.load()) max_fsync_ms = ms;
    (void)t0;
  }
  void close_files() {
    if (fd >= 0) {
      sync();
      ::close(fd);
      fd = -1;
    }
    if (csv) {
      fclose(csv);
      csv = nullptr;
    }
  }
  void run() {
    pthread_setname_np(pthread_self(), "RewindWriter");
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);  // below everything that matters
    sched_param sp{};
    sched_setscheduler(0, SCHED_IDLE, &sp);
    std::vector<uint8_t> out;
    out.reserve(kChunk + 512 * 1024);
    std::vector<Rec> batch;
    for (;;) {
      size_t take_bytes = 0;
      {
        std::unique_lock<std::mutex> l(mu);
        cv.wait_for(l, std::chrono::milliseconds(200), [&] { return stop || used >= kChunk / 2; });
        if (recs.empty() && stop) break;
        batch.clear();
        for (const Rec &r : recs) {  // up to ~1 MB, oldest first
          if (!batch.empty() && take_bytes + r.len > kChunk) break;
          batch.push_back(r);
          take_bytes += r.len;
        }
        recs.erase(recs.begin(), recs.begin() + batch.size());
      }
      // Copy out without the lock (the producer only writes past `used`, which still covers these bytes), so a
      // push never waits on this copy; then give the space back.
      out.clear();
      for (const Rec &r : batch) {
        const size_t first = std::min(r.len, ring.size() - r.off);
        out.insert(out.end(), ring.begin() + r.off, ring.begin() + r.off + first);
        out.insert(out.end(), ring.begin(), ring.begin() + (r.len - first));
      }
      if (take_bytes) {
        std::lock_guard<std::mutex> l(mu);
        tail = (tail + take_bytes) % ring.size();
        used -= take_bytes;
      }
      const int64_t now = mono_us();
      if (batch.empty()) {
        if (fd >= 0 && now - last_sync_us > kSyncUs) last_sync_us = now, sync();
        continue;
      }
      if (fd < 0 || now - file_start_us > kFileUs) open_next(now);
      size_t done = 0;
      while (done < out.size()) {
        const ssize_t n = ::write(fd, out.data() + done, out.size() - done);
        if (n <= 0) break;
        done += (size_t)n;
      }
      size_t o = 0;
      for (const Rec &r : batch) {
        if (csv)
          fprintf(csv, "%ld,%lld,%zu,%d,%d,%lld,%lld\n", frame_no, file_off + (long long)o, r.len, r.width, r.height,
                  (long long)r.t_us, (long long)r.robot_us);
        frame_no++;
        o += r.len;
      }
      file_off += (long long)out.size();
      bytes += (long long)out.size();
      written += (long)batch.size();
      if (now - last_sync_us > kSyncUs) last_sync_us = now, sync();
      cpu_ms = thread_cpu_ms();
    }
    close_files();
    cpu_ms = thread_cpu_ms();
  }
};

RewindWriter *rewind_open(const char *prefix, size_t ring_bytes, double record_fps) {
  auto *w = new RewindWriter;
  w->prefix = prefix;
  w->ring.resize(std::max<size_t>(ring_bytes, 2 * kChunk));
  w->record_fps = record_fps;
  w->th = std::thread([w] { w->run(); });
  return w;
}

int rewind_push(RewindWriter *w, const uint8_t *jpeg, size_t len, int width, int height, int64_t t_us,
                int64_t robot_us) {
  if (!w || !len) return 0;
  // One producer per writer (the camera's thread). The locks are only held for bookkeeping (the writer never
  // holds it across a copy or a write), and the frame is copied into the reserved space without it.
  size_t off;
  {
    std::lock_guard<std::mutex> l(w->mu);
    if (w->record_fps > 0 && w->last_keep_us && t_us - w->last_keep_us < (int64_t)(1e6 / w->record_fps) - 2000) {
      w->dropped_fps++;
      return 0;
    }
    if (w->used + len > w->ring.size()) {  // the writer is behind: drop, never wait
      w->dropped_full++;
      return 0;
    }
    off = w->head;
    w->head = (off + len) % w->ring.size();
    w->used += len;  // reserved: the writer's copies stay behind it
    w->last_keep_us = t_us;
  }
  const size_t first = std::min(len, w->ring.size() - off);
  memcpy(w->ring.data() + off, jpeg, first);
  memcpy(w->ring.data(), jpeg + first, len - first);
  {
    std::lock_guard<std::mutex> l(w->mu);
    w->recs.push_back(Rec{off, len, width, height, t_us, robot_us});
    w->queued++;
    if (w->used >= kChunk / 2) w->cv.notify_one();
  }
  return 1;
}

void rewind_get_stats(RewindWriter *w, rewind_stats *s) {
  s->queued = w->queued, s->written = w->written, s->dropped_full = w->dropped_full;
  s->dropped_fps = w->dropped_fps, s->bytes = w->bytes, s->max_fsync_ms = w->max_fsync_ms;
  s->writer_cpu_ms = w->cpu_ms;
}

void rewind_close(RewindWriter *w) {
  if (!w) return;
  {
    std::lock_guard<std::mutex> l(w->mu);
    w->stop = true;
  }
  w->cv.notify_one();
  w->th.join();
  delete w;
}
