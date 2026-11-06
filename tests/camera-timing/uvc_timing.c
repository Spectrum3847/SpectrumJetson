// uvc_timing: per-packet timing of a UVC MJPEG camera over usbfs, for camera characterization.
//
// Streams one camera for SECS seconds with short URBs (default 1 packet = 125 us each) and logs every non-empty
// isochronous packet: CLOCK_MONOTONIC reap time, payload bytes, UVC header flags, PTS and SCR (source clock + SOF).
// Optionally saves the first N whole frames (concatenated JPEGs, plus OUT.mjpeg.idx: each saved frame's
// first-data-packet time, PTS and SCR) for structure and flicker-phase analysis.
// Only standard UVC requests are sent (VS probe/commit, SET_INTERFACE); no vendor or extension-unit commands.
// uvc_usb.c/.h: copied from native/sc-vision on branch sc/mjpeg-napa (dcf9faf); uvc_reap returns on EINTR.
//
//   uvc_timing VID:PID WxH FPS SECS OUT.csv [--alt N] [--pkts N] [--urbs N] [--frames N OUT.mjpeg] [--force]
//              [--led BRIGHTNESS_FILE START_MS STEP_MS NSTEPS EVERY WIDTH_US PULSES.csv]
// Camera controls (exposure, gain) are set beforehand with v4l2-ctl; they stay on the camera.
//
// --led (camera-delay test): every EVERY-th frame, an LED (a sysfs LED brightness file, e.g.
// /sys/class/leds/ACT/brightness with its trigger set to none) is pulsed WIDTH_US long at
// (that frame's first data packet + START_MS + k * STEP_MS), k = 0..NSTEPS-1 cycling. A FIFO thread busy-waits for
// the time. PULSES.csv logs, per pulse: the saved-frame index that triggered it, the planned time and the
// measured times just before/after the on and off writes. Which later frame shows the LED gives the exposure
// window relative to the first packet (and, through the frames' PTS/SCR, relative to the camera's clock).
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "uvc_usb.h"

static volatile sig_atomic_t stop_flag;
static void on_sig(int s) {
  (void)s;
  stop_flag = 1;
}

static int64_t mono_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

// ---- LED pulses (--led)
static int led_fd = -1;
static double led_start_ms, led_step_ms;
static int led_nsteps, led_every, led_width_us;
static FILE *led_out;
static _Atomic int64_t led_target;  // planned on time (ns), 0 = none pending
static _Atomic int led_frame, led_k;
static atomic_int led_quit;

static void led_write(int on) {
  if (pwrite(led_fd, on ? "1" : "0", 1, 0) != 1) perror("led write");
}

static void *led_thread(void *arg) {
  (void)arg;
  cpu_set_t cs;
  CPU_ZERO(&cs);
  CPU_SET(2, &cs);
  pthread_setaffinity_np(pthread_self(), sizeof cs, &cs);
  struct sched_param sp = {.sched_priority = 60};
  pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
  while (!atomic_load(&led_quit)) {
    int64_t tgt = atomic_load(&led_target);
    if (!tgt) {
      struct timespec w = {0, 50000};
      nanosleep(&w, NULL);
      continue;
    }
    int64_t now = mono_ns();
    if (tgt - now > 200000) {  // sleep until 0.2 ms before, then spin
      struct timespec w = {0, (long)(tgt - now - 200000)};
      nanosleep(&w, NULL);
    }
    while (mono_ns() < tgt) {
    }
    int64_t on0 = mono_ns();
    led_write(1);
    int64_t on1 = mono_ns();
    while (mono_ns() < on0 + (int64_t)led_width_us * 1000) {
    }
    int64_t off0 = mono_ns();
    led_write(0);
    int64_t off1 = mono_ns();
    fprintf(led_out, "%d,%d,%lld,%lld,%lld,%lld,%lld\n", atomic_load(&led_frame), atomic_load(&led_k),
            (long long)tgt, (long long)on0, (long long)on1, (long long)off0, (long long)off1);
    atomic_store(&led_target, 0);
  }
  return NULL;
}

// Called at a frame's first data packet (time t, the frame's saved index).
static void led_on_frame(int64_t t, int frame) {
  static int n;
  if (led_fd < 0 || n++ % led_every || atomic_load(&led_target)) return;
  static int k;
  int64_t tgt = t + (int64_t)((led_start_ms + led_step_ms * (k % led_nsteps)) * 1e6);
  atomic_store(&led_frame, frame);
  atomic_store(&led_k, k % led_nsteps);
  atomic_store(&led_target, tgt);
  k++;
}

int main(int argc, char **argv) {
  if (argc < 6) {
    fprintf(stderr,
            "usage: %s VID:PID WxH FPS SECS OUT.csv [--alt N] [--pkts N] [--urbs N] [--frames N OUT.mjpeg] "
            "[--force]\n",
            argv[0]);
    return 2;
  }
  uvc_config cfg;
  memset(&cfg, 0, sizeof cfg);
  if (sscanf(argv[1], "%x:%x", (unsigned *)&cfg.vid, (unsigned *)&cfg.pid) != 2 ||
      sscanf(argv[2], "%dx%d", &cfg.width, &cfg.height) != 2) {
    fprintf(stderr, "bad VID:PID or WxH\n");
    return 2;
  }
  cfg.fps = atoi(argv[3]);
  double secs = atof(argv[4]);
  if (secs <= 0 || secs > 60) {
    fprintf(stderr, "SECS must be in (0, 60]\n");
    return 2;
  }
  const char *csv = argv[5];
  cfg.alt = -2;
  cfg.pkts_per_urb = 1;
  cfg.nurbs = 64;
  cfg.verbose = 1;
  int nsave = 0;
  const char *mjpeg = NULL;
  for (int i = 6; i < argc; i++) {
    if (!strcmp(argv[i], "--alt") && i + 1 < argc) cfg.alt = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--pkts") && i + 1 < argc) cfg.pkts_per_urb = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--urbs") && i + 1 < argc) cfg.nurbs = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--frames") && i + 2 < argc) {
      nsave = atoi(argv[++i]);
      mjpeg = argv[++i];
    } else if (!strcmp(argv[i], "--force")) cfg.force = 1;
    else if (!strcmp(argv[i], "--led") && i + 7 < argc) {
      led_fd = open(argv[++i], O_WRONLY);
      if (led_fd < 0) {
        perror("led");
        return 1;
      }
      led_start_ms = atof(argv[++i]);
      led_step_ms = atof(argv[++i]);
      led_nsteps = atoi(argv[++i]);
      led_every = atoi(argv[++i]);
      led_width_us = atoi(argv[++i]);
      led_out = fopen(argv[++i], "w");
      if (!led_out || led_nsteps < 1 || led_every < 1) {
        fprintf(stderr, "bad --led arguments\n");
        return 2;
      }
      fprintf(led_out, "frame,k,target_ns,on_before_ns,on_after_ns,off_before_ns,off_after_ns\n");
    }
    else {
      fprintf(stderr, "unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  struct sigaction sa;  // no SA_RESTART: a signal interrupts the blocking reap
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_sig;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGALRM, &sa, NULL);
  alarm((unsigned)secs + 5);  // watchdog: a camera that sends nothing can't hang the run
  FILE *out = fopen(csv, "w");
  if (!out) {
    perror(csv);
    return 1;
  }
  FILE *mj = mjpeg ? fopen(mjpeg, "wb") : NULL;
  FILE *idx = NULL;  // OUT.mjpeg.idx: frame,t_first_ns,pts,scr_stc_first,bytes for each saved frame
  if (mj) {
    char ip[1024];
    snprintf(ip, sizeof ip, "%s.idx", mjpeg);
    idx = fopen(ip, "w");
    if (idx) fprintf(idx, "frame,t_first_ns,pts,scr_stc,bytes\n");
  }
  int64_t f_t = 0;
  uint32_t f_pts = 0, f_stc = 0;
  uvc_usb *u = uvc_open(&cfg);
  if (!u) return 1;
  pthread_t lt;
  if (led_fd >= 0) {
    led_write(0);
    pthread_create(&lt, NULL, led_thread, NULL);
    cpu_set_t cs;
    CPU_ZERO(&cs);
    CPU_SET(3, &cs);
    sched_setaffinity(0, sizeof cs, &cs);
    struct sched_param sp = {.sched_priority = 50};
    sched_setscheduler(0, SCHED_FIFO, &sp);
  }
  fprintf(out, "t_ns,pkt_from_end,len,flags,pts,scr_stc,scr_sof\n");
  static uvc_chunk ch[64];
  static uint8_t frame[4 << 20];
  size_t flen = 0;
  int cur_fid = -1, saved = 0, frame_started = 0;
  int64_t t0 = mono_ns(), tend = t0 + (int64_t)(secs * 1e9);
  long npk = 0, nframes = 0;
  while (!stop_flag) {
    int64_t t;
    int n = uvc_reap(u, ch, 64, &t);
    if (n < 0) {
      fprintf(stderr, "reap failed\n");
      break;
    }
    if (t > tend) break;
    for (int k = 0; k < n; k++) {
      const uvc_chunk *c = &ch[k];
      fprintf(out, "%lld,%d,%d,%u,%u,%u,%u\n", (long long)t, c->pkt_from_end, c->len, c->flags, c->pts,
              c->scr_stc, c->scr_sof);
      npk++;
      int fid = c->flags & 1;
      if (cur_fid >= 0 && fid != cur_fid) {  // new frame by FID toggle
        if (frame_started && mj && saved < nsave && flen > 4) {
          fwrite(frame, 1, flen, mj);
          if (idx) fprintf(idx, "%d,%lld,%u,%u,%zu\n", saved, (long long)f_t, f_pts, f_stc, flen);
          saved++;
        }
        nframes++;
        flen = 0;
        frame_started = 1;
      }
      cur_fid = fid;
      if (frame_started && !(c->flags & 0x40) && c->len > 0 && flen + (size_t)c->len < sizeof frame) {
        if (flen == 0) {  // the frame's first data packet: its time, PTS and SCR go in the index
          f_t = t - (int64_t)c->pkt_from_end * 125000;
          f_pts = c->pts;
          f_stc = c->scr_stc;
          led_on_frame(f_t, saved);
        }
        memcpy(frame + flen, c->data, (size_t)c->len);
        flen += (size_t)c->len;
      }
      if (c->flags & 2) {  // EOF: the frame is complete
        if (frame_started && mj && saved < nsave && flen > 4) {
          fwrite(frame, 1, flen, mj);
          if (idx) fprintf(idx, "%d,%lld,%u,%u,%zu\n", saved, (long long)f_t, f_pts, f_stc, flen);
          saved++;
        }
        nframes++;
        flen = 0;
        frame_started = 1;
        cur_fid = -1;  // the next packet (other FID) starts a frame without counting it twice
      }
    }
  }
  if (led_fd >= 0) {
    atomic_store(&led_quit, 1);
    pthread_join(lt, NULL);
    led_write(0);
    fclose(led_out);
  }
  uvc_close(u);
  fclose(out);
  if (mj) fclose(mj);
  if (idx) fclose(idx);
  fprintf(stderr, "uvc_timing: %ld packets, ~%ld frames, %d saved, %.1f s\n", npk, nframes, saved,
          (mono_ns() - t0) / 1e9);
  return 0;
}
