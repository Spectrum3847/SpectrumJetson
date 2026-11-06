// uvc_timing: per-packet timing of a UVC MJPEG camera over usbfs, for camera characterization.
//
// Streams one camera for SECS seconds with short URBs (default 1 packet = 125 us each) and logs every non-empty
// isochronous packet: CLOCK_MONOTONIC reap time, payload bytes, UVC header flags, PTS and SCR (source clock + SOF).
// Optionally saves the first N whole frames (concatenated JPEGs) for structure analysis.
// Only standard UVC requests are sent (VS probe/commit, SET_INTERFACE); no vendor or extension-unit commands.
// uvc_usb.c/.h: copied from native/sc-vision on branch sc/mjpeg-napa (dcf9faf); uvc_reap returns on EINTR.
//
//   uvc_timing VID:PID WxH FPS SECS OUT.csv [--alt N] [--pkts N] [--urbs N] [--frames N OUT.mjpeg] [--force]
// Camera controls (exposure, gain) are set beforehand with v4l2-ctl; they stay on the camera.
#define _GNU_SOURCE
#include <signal.h>
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
  uvc_usb *u = uvc_open(&cfg);
  if (!u) return 1;
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
          saved++;
        }
        nframes++;
        flen = 0;
        frame_started = 1;
      }
      cur_fid = fid;
      if (frame_started && !(c->flags & 0x40) && c->len > 0 && flen + (size_t)c->len < sizeof frame) {
        memcpy(frame + flen, c->data, (size_t)c->len);
        flen += (size_t)c->len;
      }
      if (c->flags & 2) {  // EOF: the frame is complete
        if (frame_started && mj && saved < nsave && flen > 4) {
          fwrite(frame, 1, flen, mj);
          saved++;
        }
        nframes++;
        flen = 0;
        frame_started = 1;
        cur_fid = -1;  // the next packet (other FID) starts a frame without counting it twice
      }
    }
  }
  uvc_close(u);
  fclose(out);
  if (mj) fclose(mj);
  fprintf(stderr, "uvc_timing: %ld packets, ~%ld frames, %d saved, %.1f s\n", npk, nframes, saved,
          (mono_ns() - t0) / 1e9);
  return 0;
}
