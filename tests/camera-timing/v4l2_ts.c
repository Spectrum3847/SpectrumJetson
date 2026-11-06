// v4l2_ts: frame timestamps as uvcvideo gives them (the Jetson's / PhotonVision's path), for the camera-delay test.
//
// Streams a UVC camera through V4L2 (uvcvideo, MJPEG) and, if the camera's metadata node is given, its UVC
// metadata (V4L2_META_FMT_UVC: every packet header with a new SCR, with the host time uvcvideo saw it). Per frame:
//   OUT.csv : seq, buffer timestamp (ns; with uvcvideo hwtimestamps=1 the camera PTS converted by uvcvideo,
//             else the first-packet time), DQBUF time, bytes, timestamp-source flags, and from the metadata the
//             frame's PTS, the SCR (source clock) of its first header carrying that PTS, and that header's host time.
//   --frames N F.mjpeg : the first N frames + F.mjpeg.idx (frame,t_first_ns,pts,scr_stc,bytes) where t_first_ns
//             is the BUFFER TIMESTAMP, so led_analyze.py measures exposure end -> buffer timestamp directly.
//   --led ... : the same LED pulse sweep as uvc_timing, scheduled from each frame's DQBUF time.
// Only standard V4L2 ioctls; nothing is sent to the camera beyond what uvcvideo does for any capture.
//
//   v4l2_ts /dev/videoN [--meta /dev/videoM] WxH FPS SECS OUT.csv [--frames N F.mjpeg]
//           [--led LED START_MS STEP_MS NSTEPS EVERY WIDTH_US PULSES.csv [--led-invert]]
//   LED: a sysfs file taking 1/0, or /dev/gpiochipN:LINE (GPIO v2 line request; e.g. a Jetson header pin).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <linux/videodev2.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#ifndef V4L2_META_FMT_UVC
#define V4L2_META_FMT_UVC v4l2_fourcc('U', 'V', 'C', 'H')
#endif

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
static int xioctl(int fd, unsigned long req, void *arg) {
  int r;
  do r = ioctl(fd, req, arg);
  while (r < 0 && errno == EINTR && !stop_flag);
  return r;
}

// ---- LED pulses (as in uvc_timing.c)
static int led_fd = -1, led_inv;
static double led_start_ms, led_step_ms;
static int led_nsteps, led_every, led_width_us;
static FILE *led_out;
static _Atomic int64_t led_target;
static _Atomic int led_frame, led_k;
static atomic_int led_quit;
static int led_gpio;  // 1: led_fd is a GPIO v2 line request (/dev/gpiochipN:LINE), else a sysfs value file
static void led_write(int on) {
  int v = on ^ led_inv;
  if (led_gpio) {
    struct gpio_v2_line_values lv = {.bits = (uint64_t)v, .mask = 1};
    if (ioctl(led_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv)) perror("led gpio");
  } else if (pwrite(led_fd, v ? "1" : "0", 1, 0) != 1) perror("led write");
}
// LED target: a sysfs file taking "1"/"0" (/sys/class/leds/X/brightness, /sys/class/gpio/gpioN/value) or a GPIO
// character-device line, "/dev/gpiochipN:LINE" (e.g. a Jetson 40-pin header pin; `gpioinfo` lists the lines).
static int led_open(const char *spec) {
  const char *colon = strrchr(spec, ':');
  if (strncmp(spec, "/dev/gpiochip", 13) || !colon) return open(spec, O_WRONLY);
  char chip[256];
  snprintf(chip, sizeof chip, "%.*s", (int)(colon - spec), spec);
  int cfd = open(chip, O_RDWR);
  if (cfd < 0) return -1;
  struct gpio_v2_line_request rq;
  memset(&rq, 0, sizeof rq);
  rq.offsets[0] = (unsigned)atoi(colon + 1);
  rq.num_lines = 1;
  rq.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
  snprintf(rq.consumer, sizeof rq.consumer, "v4l2_ts-led");
  int r = ioctl(cfd, GPIO_V2_GET_LINE_IOCTL, &rq);
  close(cfd);
  if (r) return -1;
  led_gpio = 1;
  return rq.fd;
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
    if (tgt - now > 200000) {
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
static void led_on_frame(int64_t t, int frame) {
  static int n, k;
  if (led_fd < 0 || n++ % led_every || atomic_load(&led_target)) return;
  atomic_store(&led_frame, frame);
  atomic_store(&led_k, k % led_nsteps);
  atomic_store(&led_target, t + (int64_t)((led_start_ms + led_step_ms * (k % led_nsteps)) * 1e6));
  k++;
}

typedef struct {
  void *p;
  size_t len;
} mbuf;

static int start(int fd, enum v4l2_buf_type type, mbuf *b, int n) {
  struct v4l2_requestbuffers rb = {.count = (unsigned)n, .type = type, .memory = V4L2_MEMORY_MMAP};
  if (xioctl(fd, VIDIOC_REQBUFS, &rb)) return -1;
  for (unsigned i = 0; i < rb.count; i++) {
    struct v4l2_buffer q = {.index = i, .type = type, .memory = V4L2_MEMORY_MMAP};
    if (xioctl(fd, VIDIOC_QUERYBUF, &q)) return -1;
    b[i].len = q.length;
    b[i].p = mmap(NULL, q.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, q.m.offset);
    if (b[i].p == MAP_FAILED || xioctl(fd, VIDIOC_QBUF, &q)) return -1;
  }
  return xioctl(fd, VIDIOC_STREAMON, &type) ? -1 : (int)rb.count;
}

int main(int argc, char **argv) {
  if (argc < 6) {
    fprintf(stderr,
            "usage: %s /dev/videoN [--meta /dev/videoM] WxH FPS SECS OUT.csv [--frames N F.mjpeg] [--led FILE "
            "START_MS STEP_MS NSTEPS EVERY WIDTH_US PULSES.csv [--led-invert]]\n",
            argv[0]);
    return 2;
  }
  int ai = 1;
  const char *vdev = argv[ai++], *mdev = NULL;
  if (!strcmp(argv[ai], "--meta")) {
    mdev = argv[ai + 1];
    ai += 2;
  }
  int W, H;
  if (ai + 3 >= argc || sscanf(argv[ai++], "%dx%d", &W, &H) != 2) {
    fprintf(stderr, "bad WxH\n");
    return 2;
  }
  int fps = atoi(argv[ai++]);
  double secs = atof(argv[ai++]);
  const char *csv = argv[ai++];
  if (secs <= 0 || secs > 60) {
    fprintf(stderr, "SECS must be in (0, 60]\n");
    return 2;
  }
  int nsave = 0;
  const char *mjpeg = NULL;
  for (; ai < argc; ai++) {
    if (!strcmp(argv[ai], "--frames") && ai + 2 < argc) {
      nsave = atoi(argv[++ai]);
      mjpeg = argv[++ai];
    } else if (!strcmp(argv[ai], "--led") && ai + 7 < argc) {
      led_fd = led_open(argv[++ai]);
      if (led_fd < 0) {
        perror("led");
        return 1;
      }
      led_start_ms = atof(argv[++ai]);
      led_step_ms = atof(argv[++ai]);
      led_nsteps = atoi(argv[++ai]);
      led_every = atoi(argv[++ai]);
      led_width_us = atoi(argv[++ai]);
      led_out = fopen(argv[++ai], "w");
      if (!led_out || led_nsteps < 1 || led_every < 1) return 2;
      fprintf(led_out, "frame,k,target_ns,on_before_ns,on_after_ns,off_before_ns,off_after_ns\n");
    } else if (!strcmp(argv[ai], "--led-invert")) led_inv = 1;
    else {
      fprintf(stderr, "unknown argument %s\n", argv[ai]);
      return 2;
    }
  }
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_sig;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGALRM, &sa, NULL);
  alarm((unsigned)secs + 5);

  int vfd = open(vdev, O_RDWR | O_NONBLOCK);
  if (vfd < 0) {
    perror(vdev);
    return 1;
  }
  struct v4l2_format f = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE};
  f.fmt.pix.width = (unsigned)W;
  f.fmt.pix.height = (unsigned)H;
  f.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
  if (xioctl(vfd, VIDIOC_S_FMT, &f)) {
    perror("S_FMT");
    return 1;
  }
  struct v4l2_streamparm sp = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE};
  sp.parm.capture.timeperframe.numerator = 1;
  sp.parm.capture.timeperframe.denominator = (unsigned)fps;
  xioctl(vfd, VIDIOC_S_PARM, &sp);
  int mfd = -1;
  if (mdev) {
    mfd = open(mdev, O_RDWR | O_NONBLOCK);
    struct v4l2_format mf = {.type = V4L2_BUF_TYPE_META_CAPTURE};
    mf.fmt.meta.dataformat = V4L2_META_FMT_UVC;
    if (mfd < 0 || xioctl(mfd, VIDIOC_S_FMT, &mf)) {
      perror("meta node");
      return 1;
    }
  }
  static mbuf vb[8], mb[8];
  if (mfd >= 0 && start(mfd, V4L2_BUF_TYPE_META_CAPTURE, mb, 8) < 0) {
    perror("meta stream");
    return 1;
  }
  if (start(vfd, V4L2_BUF_TYPE_VIDEO_CAPTURE, vb, 6) < 0) {
    perror("video stream");
    return 1;
  }
  FILE *out = fopen(csv, "w");
  FILE *mj = mjpeg ? fopen(mjpeg, "wb") : NULL, *idx = NULL;
  if (mj) {
    char ip[1024];
    snprintf(ip, sizeof ip, "%s.idx", mjpeg);
    idx = fopen(ip, "w");
    fprintf(idx, "frame,t_first_ns,pts,scr_stc,bytes\n");
  }
  if (!out) return 1;
  FILE *scrf = NULL;  // OUT.csv.scr: every metadata header with an SCR: pts (0 = none), scr_stc, scr_sof, host ns, sof
  if (mfd >= 0) {
    char pp[1024];
    snprintf(pp, sizeof pp, "%s.scr", csv);
    scrf = fopen(pp, "w");
    if (scrf) fprintf(scrf, "pts,scr_stc,scr_sof,host_ns,host_sof\n");
  }
  fprintf(out, "seq,ts_ns,dq_ns,bytes,ts_flags,meta_seq,pts,scr_stc,scr_sof,meta_ns,meta_sof,meta_entries\n");
  pthread_t lt;
  if (led_fd >= 0) {
    led_write(0);
    pthread_create(&lt, NULL, led_thread, NULL);
  }
  // Latest PTS seen in the metadata stream, and the first header that carried it.
  uint32_t cur_pts = 0, cur_stc = 0;
  uint16_t cur_scr_sof = 0, cur_meta_sof = 0;
  int64_t cur_meta_ns = 0;
  int have_pts = 0, entries = 0;
  unsigned meta_seq = 0;
  int saved = 0;
  int64_t tend = mono_ns() + (int64_t)(secs * 1e9);
  while (!stop_flag && mono_ns() < tend) {
    fd_set rs;
    FD_ZERO(&rs);
    FD_SET(vfd, &rs);
    int mx = vfd;
    if (mfd >= 0) {
      FD_SET(mfd, &rs);
      if (mfd > mx) mx = mfd;
    }
    struct timeval tv = {1, 0};
    if (select(mx + 1, &rs, NULL, NULL, &tv) <= 0) continue;
    if (mfd >= 0 && FD_ISSET(mfd, &rs)) {
      struct v4l2_buffer b = {.type = V4L2_BUF_TYPE_META_CAPTURE, .memory = V4L2_MEMORY_MMAP};
      if (xioctl(mfd, VIDIOC_DQBUF, &b) == 0) {
        // struct uvc_meta_buf { u64 ns; u16 sof; u8 length; u8 flags; u8 buf[]; } packed, back to back.
        const uint8_t *p = mb[b.index].p, *e = p + b.bytesused;
        static int dumped;
        if (getenv("V4L2_TS_DUMP") && dumped++ < 3) {
          for (unsigned i = 0; i < b.bytesused && i < 96; i++)
            fprintf(stderr, "%02x%s", p[i], i % 24 == 23 ? "\n" : " ");
          fprintf(stderr, " (%u bytes)\n", b.bytesused);
        }
        while (p + 12 <= e) {
          int64_t ns;
          uint16_t msof;
          memcpy(&ns, p, 8);
          memcpy(&msof, p + 8, 2);
          // struct uvc_meta_buf: ns, sof, length (of the UVC header), flags (bmHeaderInfo), then the header's
          // remaining length - 2 bytes: PTS (4) if flags & 4, SCR (4 + 2) if flags & 8.
          int hl = p[10], fl = p[11];
          const uint8_t *h = p + 12;
          if (hl < 2 || p + 12 + (hl - 2) > e) break;
          int o = 0;
          uint32_t pts = 0, stc = 0;
          uint16_t ssof = 0;
          int hp = fl & 4, hs = fl & 8;
          if (hp && hl - 2 >= o + 4) {
            memcpy(&pts, h + o, 4);
            o += 4;
          }
          if (hs && hl - 2 >= o + 6) {
            memcpy(&stc, h + o, 4);
            memcpy(&ssof, h + o + 4, 2);
          }
          entries++;
          if (scrf && hs) fprintf(scrf, "%u,%u,%u,%lld,%u\n", hp ? pts : 0, stc, ssof, (long long)ns, msof);
          if (hp && (!have_pts || pts != cur_pts)) {
            cur_pts = pts;
            cur_stc = stc;
            cur_scr_sof = ssof;
            cur_meta_ns = ns;
            cur_meta_sof = msof;
            have_pts = 1;
          }
          p += 12 + (hl - 2);
        }
        meta_seq = b.sequence;
        xioctl(mfd, VIDIOC_QBUF, &b);
      }
    }
    if (FD_ISSET(vfd, &rs)) {
      struct v4l2_buffer b = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP};
      if (xioctl(vfd, VIDIOC_DQBUF, &b) == 0) {
        int64_t dq = mono_ns();
        int64_t ts = (int64_t)b.timestamp.tv_sec * 1000000000LL + (int64_t)b.timestamp.tv_usec * 1000;
        led_on_frame(dq, saved);
        fprintf(out, "%u,%lld,%lld,%u,%u,%u,%u,%u,%u,%lld,%u,%d\n", b.sequence, (long long)ts, (long long)dq,
                b.bytesused, b.flags & (V4L2_BUF_FLAG_TIMESTAMP_MASK | V4L2_BUF_FLAG_TSTAMP_SRC_MASK), meta_seq,
                cur_pts, cur_stc, cur_scr_sof, (long long)cur_meta_ns, cur_meta_sof, entries);
        entries = 0;
        if (mj && saved < nsave && b.bytesused > 4) {
          fwrite(vb[b.index].p, 1, b.bytesused, mj);
          fprintf(idx, "%d,%lld,%u,%u,%u\n", saved, (long long)ts, cur_pts, cur_stc, b.bytesused);
          saved++;
        }
        xioctl(vfd, VIDIOC_QBUF, &b);
      }
    }
  }
  if (led_fd >= 0) {
    atomic_store(&led_quit, 1);
    pthread_join(lt, NULL);
    led_write(0);
    fclose(led_out);
  }
  enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  xioctl(vfd, VIDIOC_STREAMOFF, &t);
  if (mfd >= 0) {
    t = V4L2_BUF_TYPE_META_CAPTURE;
    xioctl(mfd, VIDIOC_STREAMOFF, &t);
  }
  fclose(out);
  if (scrf) fclose(scrf);
  if (mj) {
    fclose(mj);
    fclose(idx);
  }
  fprintf(stderr, "v4l2_ts: %d frames saved\n", saved);
  return 0;
}
