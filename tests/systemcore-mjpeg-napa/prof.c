// SpectrumJetson systemcore-mjpeg-napa: scmn_prof, a tiny sampling profiler (LimelightOS has no perf).
//   sudo scmn_prof PID SECS [HZ] > samples.txt      (every thread of PID; default 4000 Hz per thread)
// perf_event_open(cpu-clock) per thread with PERF_SAMPLE_IP | PERF_SAMPLE_TID; prints the process's
// executable mappings, then "ip count" lines. Symbolize on the laptop with profsym.py (nm from the cross
// toolchain on copies of the mapped files). Kernel samples (exclude_kernel = 0) are counted as "[kernel]".
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define MAXT 64
#define PAGES 64  // ring buffer data pages per thread

typedef struct {
  uint64_t ip;
  long n;
} ent;
static ent *tab;
static size_t tab_cap = 1 << 16, kernel_n, lost_n, total_n;

static void add(uint64_t ip) {
  if (ip >= 0xffff000000000000ULL) {
    kernel_n++;
    return;
  }
  size_t h = (ip * 0x9E3779B97F4A7C15ULL) >> 48 & (tab_cap - 1);
  while (tab[h].ip && tab[h].ip != ip) h = (h + 1) & (tab_cap - 1);
  tab[h].ip = ip;
  tab[h].n++;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: scmn_prof PID SECS [HZ]\n");
    return 2;
  }
  int pid = atoi(argv[1]);
  double secs = atof(argv[2]);
  int hz = argc > 3 ? atoi(argv[3]) : 4000;
  tab = calloc(tab_cap, sizeof(ent));
  char path[64];
  snprintf(path, sizeof path, "/proc/%d/task", pid);
  DIR *d = opendir(path);
  if (!d) return perror(path), 1;
  int fds[MAXT], nt = 0;
  void *rings[MAXT];
  size_t pg = (size_t)sysconf(_SC_PAGESIZE);
  struct dirent *e;
  while ((e = readdir(d)) && nt < MAXT) {
    if (e->d_name[0] == '.') continue;
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = PERF_TYPE_SOFTWARE;
    a.config = PERF_COUNT_SW_CPU_CLOCK;
    a.sample_freq = hz;
    a.freq = 1;
    a.sample_type = PERF_SAMPLE_IP;
    a.wakeup_events = 1;
    int fd = (int)syscall(SYS_perf_event_open, &a, atoi(e->d_name), -1, -1, 0);
    if (fd < 0) {
      fprintf(stderr, "perf_event_open tid %s: %s\n", e->d_name, strerror(errno));
      continue;
    }
    void *r = mmap(NULL, (PAGES + 1) * pg, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (r == MAP_FAILED) {
      perror("mmap");
      close(fd);
      continue;
    }
    fds[nt] = fd, rings[nt] = r, nt++;
  }
  closedir(d);
  struct timespec t0, t;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    for (int i = 0; i < nt; i++) {
      struct perf_event_mmap_page *m = rings[i];
      uint64_t head = __atomic_load_n(&m->data_head, __ATOMIC_ACQUIRE), tail = m->data_tail;
      char *base = (char *)rings[i] + pg;
      size_t sz = PAGES * pg;
      while (tail < head) {
        struct perf_event_header h;
        size_t off = tail % sz;
        char tmp[64];
        for (size_t k = 0; k < sizeof h; k++) ((char *)&h)[k] = base[(off + k) % sz];
        if (h.size == 0) break;
        for (size_t k = 0; k < h.size && k < sizeof tmp; k++) tmp[k] = base[(off + k) % sz];
        if (h.type == PERF_RECORD_SAMPLE) {
          uint64_t ip;
          memcpy(&ip, tmp + sizeof h, 8);
          add(ip);
          total_n++;
        } else if (h.type == PERF_RECORD_LOST) {
          uint64_t lost;
          memcpy(&lost, tmp + sizeof h + 8, 8);
          lost_n += lost;
        }
        tail += h.size;
      }
      __atomic_store_n(&m->data_tail, tail, __ATOMIC_RELEASE);
    }
    clock_gettime(CLOCK_MONOTONIC, &t);
    if ((t.tv_sec - t0.tv_sec) + (t.tv_nsec - t0.tv_nsec) / 1e9 > secs) break;
    usleep(10000);
  }
  snprintf(path, sizeof path, "/proc/%d/maps", pid);
  FILE *f = fopen(path, "r");
  char line[512];
  while (f && fgets(line, sizeof line, f))
    if (strstr(line, " r-xp ")) printf("map %s", line);
  if (f) fclose(f);
  printf("samples %zu kernel %zu lost %zu threads %d hz %d secs %.1f\n", total_n, kernel_n, lost_n, nt, hz, secs);
  for (size_t i = 0; i < tab_cap; i++)
    if (tab[i].ip) printf("ip %llx %ld\n", (unsigned long long)tab[i].ip, tab[i].n);
  return 0;
}
