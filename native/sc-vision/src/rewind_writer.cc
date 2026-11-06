// Rewind video writer (rewind_writer.h). The camera thread and the writer share no lock: a single-producer /
// single-consumer byte ring plus a ring of frame records, with acquire/release counters, so a slow writer (the
// SD card can stall for seconds) can only make the producer drop frames, never wait.
#include "rewind_writer.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
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
  uint64_t pos;  // its first byte, as a running byte count
  size_t len;
  int width, height;
  int64_t t_us, robot_us;
};
constexpr int64_t kFileUs = 5LL * 60 * 1000000;  // a new file every 5 min
constexpr int64_t kSyncUs = 2000000;             // force to disk every 2 s
constexpr size_t kChunk = 1 << 20;               // write in ~1 MB pieces
constexpr uint32_t kRecs = 4096;                 // frame records in flight (34 s of a 120 fps camera)
}  // namespace

struct RewindWriter {
  std::string prefix;
  std::vector<uint8_t> ring;  // default 32 MB per camera (rewind_open's ring_bytes)
  std::vector<Rec> recs = std::vector<Rec>(kRecs);
  // producer-owned counters (written by the camera thread only), read by the writer
  std::atomic<uint64_t> head{0};   // bytes ever pushed
  std::atomic<uint32_t> rhead{0};  // records ever pushed
  // writer-owned counters, read by the producer
  std::atomic<uint64_t> tail{0};   // bytes ever released (written or dropped by the writer)
  std::atomic<uint32_t> rtail{0};  // records ever consumed
  std::atomic<bool> stop{false}, failed{false};
  double record_fps;
  int64_t last_keep_us = 0;  // producer only
  std::atomic<long> queued{0}, written{0}, dropped_full{0}, dropped_fps{0}, lost{0};
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

  bool open_next(int64_t now) {
    close_files();
    file_no++;
    char p[512];
    snprintf(p, sizeof p, "%s_%04d.mjpeg", prefix.c_str(), file_no);
    fd = ::open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    snprintf(p, sizeof p, "%s_%04d.csv", prefix.c_str(), file_no);
    csv = fopen(p, "w");
    if (fd < 0 || !csv) return false;
    fprintf(csv, "# frame,offset,size,width,height,jetson_us,robot_us\n");  // as RewindRecorder's
    file_off = 0;
    file_start_us = now;
    last_sync_us = now;
    return true;
  }
  void sync() {
    if (fd < 0) return;
    const int64_t w0 = mono_us();
    if (csv) fflush(csv);
    fdatasync(fd);
    if (csv) fdatasync(fileno(csv));
    const double ms = (mono_us() - w0) / 1e3;
    if (ms > max_fsync_ms.load()) max_fsync_ms = ms;
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
  // Writes all of buf; returns the bytes actually written (short only on an error other than EINTR).
  size_t write_all(const uint8_t *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
      const ssize_t k = ::write(fd, buf + done, n - done);
      if (k > 0) {
        done += (size_t)k;
      } else if (k < 0 && errno == EINTR) {
        continue;
      } else {
        break;  // ENOSPC, EIO, ...
      }
    }
    return done;
  }
  void run() {
    pthread_setname_np(pthread_self(), "RewindWriter");
    // Below everything that matters, but an ordinary CFS thread (not SCHED_IDLE): it holds no lock anyone waits on.
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
    std::vector<uint8_t> out;
    out.reserve(kChunk + 512 * 1024);
    std::vector<Rec> batch;
    for (;;) {
      const uint32_t rh = rhead.load(std::memory_order_acquire);
      uint32_t rt = rtail.load(std::memory_order_relaxed);
      if (rh == rt) {
        if (stop.load()) break;
        const int64_t now = mono_us();
        if (fd >= 0 && now - last_sync_us > kSyncUs) last_sync_us = now, sync();
        timespec ts{0, 20000000};  // 20 ms
        nanosleep(&ts, nullptr);
        continue;
      }
      batch.clear();
      out.clear();
      size_t take = 0;
      while (rt != rh && (batch.empty() || take + recs[rt % kRecs].len <= kChunk)) {
        const Rec &r = recs[rt % kRecs];
        const size_t off = (size_t)(r.pos % ring.size()), first = std::min(r.len, ring.size() - off);
        out.insert(out.end(), ring.begin() + off, ring.begin() + off + first);
        out.insert(out.end(), ring.begin(), ring.begin() + (r.len - first));
        batch.push_back(r);
        take += r.len;
        rt++;
      }
      // the copied frames' space and records go back to the producer
      tail.store(batch.back().pos + batch.back().len, std::memory_order_release);
      rtail.store(rt, std::memory_order_release);
      if (failed.load()) {
        lost += (long)batch.size();
        continue;
      }
      const int64_t now = mono_us();
      if ((fd < 0 || now - file_start_us > kFileUs) && !open_next(now)) {
        failed = true;
        lost += (long)batch.size();
        continue;
      }
      const size_t done = write_all(out.data(), out.size());
      // index only the frames written whole
      size_t o = 0;
      long whole = 0;
      for (const Rec &r : batch) {
        if (o + r.len > done) break;
        fprintf(csv, "%ld,%lld,%zu,%d,%d,%lld,%lld\n", frame_no, file_off + (long long)o, r.len, r.width, r.height,
                (long long)r.t_us, (long long)r.robot_us);
        frame_no++;
        o += r.len;
        whole++;
      }
      file_off += (long long)done;
      bytes += (long long)done;
      written += whole;
      if (done < out.size()) {  // the disk refused (full, error): stop recording, count what's lost
        failed = true;
        lost += (long)batch.size() - whole;
        fprintf(stderr, "Rewind writer %s: write failed (%s); recording stopped\n", prefix.c_str(), strerror(errno));
      }
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
  w->ring.resize(std::max<size_t>(ring_bytes ? ring_bytes : (size_t)32 << 20, 2 * kChunk));
  w->record_fps = record_fps;
  w->th = std::thread([w] { w->run(); });
  return w;
}

int rewind_push(RewindWriter *w, const uint8_t *jpeg, size_t len, int width, int height, int64_t t_us,
                int64_t robot_us) {
  if (!w || !len) return 0;
  if (w->record_fps > 0 && w->last_keep_us && t_us - w->last_keep_us < (int64_t)(1e6 / w->record_fps) - 2000) {
    w->dropped_fps++;
    return 0;
  }
  if (w->failed.load(std::memory_order_relaxed)) {
    w->lost++;
    return 0;
  }
  const uint64_t h = w->head.load(std::memory_order_relaxed);
  const uint32_t rh = w->rhead.load(std::memory_order_relaxed);
  if (h + len - w->tail.load(std::memory_order_acquire) > w->ring.size() ||
      rh - w->rtail.load(std::memory_order_acquire) >= kRecs) {
    w->dropped_full++;  // the writer is behind: drop, never wait
    return 0;
  }
  const size_t off = (size_t)(h % w->ring.size()), first = std::min(len, w->ring.size() - off);
  memcpy(w->ring.data() + off, jpeg, first);
  memcpy(w->ring.data(), jpeg + first, len - first);
  w->recs[rh % kRecs] = Rec{h, len, width, height, t_us, robot_us};
  w->head.store(h + len, std::memory_order_relaxed);
  w->rhead.store(rh + 1, std::memory_order_release);  // publishes the bytes and the record
  w->last_keep_us = t_us;
  w->queued++;
  return 1;
}

void rewind_get_stats(RewindWriter *w, rewind_stats *s) {
  s->queued = w->queued, s->written = w->written, s->dropped_full = w->dropped_full;
  s->dropped_fps = w->dropped_fps, s->bytes = w->bytes, s->max_fsync_ms = w->max_fsync_ms;
  s->writer_cpu_ms = w->cpu_ms, s->lost = w->lost;
}

void rewind_close(RewindWriter *w) {
  if (!w) return;
  w->stop = true;
  w->th.join();
  delete w;
}
