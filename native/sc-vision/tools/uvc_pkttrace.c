// uvc_pkttrace: how a UVC camera spreads each frame over USB (user-space reader, src/uvc_usb.c). Per frame: first and
// last payload packet (host time from the URB reap, and the camera's own SCR clock), bytes, packets, full packets
// (payload = the alt's bytes per interval: the bus, not the camera, limits the rate), idle intervals inside the frame,
// and the EOF URB's reap delay above its floor (host latency jitter). Tests only (no decode).
//   uvc_pkttrace [--usb VID:PID] [--size WxH] [--fps F] [--frame-index N] [--yuyv] [--alt A] [--pkts P] [--urbs U]
//                [--secs S] [--force] [--cpu K] [--fifo PRIO] [--trace FILE] [--scr-hz 125000000]
// --trace writes every packet of frames 60-62 (time from frame 60's first packet).
#define _GNU_SOURCE
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uvc_usb.h"

static sigjmp_buf g_jb;
static void on_alarm(int s) {  // no frames (an unsupported mode): leave the blocking reap, close, report
  (void)s;
  siglongjmp(g_jb, 1);
}

typedef struct {
  int64_t t_first, t_last, t_prev;
  uint32_t stc_first, stc_last, pts;
  int has_stc_first, has_stc_last, has_pts;
  long bytes;
  int npk, nfull, gaps, maxgap;
} frame_t;

static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double pct(double *v, int n, double p) {
  if (n <= 0) return 0;
  qsort(v, (size_t)n, sizeof *v, cmp_d);
  return v[(int)(p * (n - 1) + 0.5)];
}

#define MAXF 8000
static frame_t fr[MAXF];
static double sp[MAXF], sps[MAXF], by[MAXF], np[MAXF], full[MAXF], gp[MAXF], mg[MAXF], per[MAXF], ptsd[MAXF];

int main(int argc, char **argv) {
  uvc_config c;
  memset(&c, 0, sizeof c);
  c.vid = 0x05c8;
  c.pid = 0x0a00;
  c.width = 1600;
  c.height = 1304;
  c.fps = 60;
  c.alt = -1;
  c.pkts_per_urb = 4;
  c.nurbs = 32;
  c.verbose = 1;
  double secs = 10, scr_hz = 125e6;
  int cpu = -1, prio = 0;
  const char *trace = NULL;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "0";
    unsigned vid, pid;
    if (!strcmp(a, "--usb")) {
      if (sscanf(v, "%x:%x", &vid, &pid) == 2) c.vid = (int)vid, c.pid = (int)pid;
      i++;
    } else if (!strcmp(a, "--size")) {
      if (sscanf(v, "%dx%d", &c.width, &c.height) != 2) return 2;
      i++;
    } else if (!strcmp(a, "--fps")) c.fps = atoi(v), i++;
    else if (!strcmp(a, "--frame-index")) c.frame_index = atoi(v), i++;
    else if (!strcmp(a, "--yuyv")) c.yuyv = 1;
    else if (!strcmp(a, "--force")) c.force = 1;
    else if (!strcmp(a, "--alt")) c.alt = atoi(v), i++;
    else if (!strcmp(a, "--pkts")) c.pkts_per_urb = atoi(v), i++;
    else if (!strcmp(a, "--urbs")) c.nurbs = atoi(v), i++;
    else if (!strcmp(a, "--secs")) secs = atof(v), i++;
    else if (!strcmp(a, "--cpu")) cpu = atoi(v), i++;
    else if (!strcmp(a, "--fifo")) prio = atoi(v), i++;
    else if (!strcmp(a, "--trace")) trace = v, i++;
    else if (!strcmp(a, "--scr-hz")) scr_hz = atof(v), i++;
    else {
      fprintf(stderr, "unknown option %s\n", a);
      return 2;
    }
  }
  if (cpu >= 0) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    sched_setaffinity(0, sizeof s, &s);
  }
  if (prio > 0) {
    struct sched_param sp0 = {.sched_priority = prio};
    if (sched_setscheduler(0, SCHED_FIFO, &sp0)) perror("fifo");
  }
  uvc_usb *u = uvc_open(&c);
  if (!u) return 1;
  signal(SIGALRM, on_alarm);
  alarm((unsigned)secs + 3);
  uvc_info in;
  uvc_get_info(u, &in);
  FILE *tf = trace ? fopen(trace, "w") : NULL;
  if (tf) fprintf(tf, "frame,t_us,len,flags,pkt_from_end,stc\n");
  const int64_t pk = uvc_packet_ns(u);
  uvc_chunk ch[256];
  int64_t t0 = 0, t;
  int nf = -1, fid = -1;
  long nurb = 0, nempty = 0;
  if (sigsetjmp(g_jb, 1)) {
    printf("watchdog: no end after %.0f s (%d frames)\n", secs + 3, nf + 1);
    goto done;
  }
  for (;;) {
    int n = uvc_reap(u, ch, 256, &t);
    if (n < 0) break;
    if (!t0) t0 = t;
    if ((t - t0) / 1e9 > secs) break;
    nurb++;
    if (!n) nempty++;
    for (int k = 0; k < n; k++) {
      uvc_chunk *q = &ch[k];
      int64_t tp = t - (int64_t)q->pkt_from_end * pk;
      int f = q->flags & 1;
      if (q->len > 0 && f != fid) {  // a new frame
        fid = f;
        if (nf + 1 >= MAXF) goto done;
        nf++;
        memset(&fr[nf], 0, sizeof fr[nf]);
        fr[nf].t_first = tp;
        if (q->flags & 8) fr[nf].stc_first = q->scr_stc, fr[nf].has_stc_first = 1;
        if (q->flags & 4) fr[nf].pts = q->pts, fr[nf].has_pts = 1;
      }
      if (nf < 0 || q->len <= 0) continue;
      frame_t *F = &fr[nf];
      if (F->t_prev) {
        int g = (int)((tp - F->t_prev + pk / 2) / pk) - 1;
        if (g > 0) {
          F->gaps += g;
          if (g > F->maxgap) F->maxgap = g;
        }
      }
      F->t_prev = tp;
      F->t_last = tp;
      F->bytes += q->len;
      F->npk++;
      if (q->len + 12 >= in.psize - 16) F->nfull++;  // the packet used (nearly) all of the alt's bytes
      if (q->flags & 8) F->stc_last = q->scr_stc, F->has_stc_last = 1;
      if (tf && nf >= 60 && nf <= 62)
        fprintf(tf, "%d,%.1f,%d,%d,%d,%u\n", nf, (double)(tp - fr[60].t_first) / 1e3, q->len, q->flags, q->pkt_from_end,
                q->scr_stc);
    }
  }
done:
  alarm(0);
  uvc_close(u);
  if (tf) fclose(tf);
  int a = 30, b = nf - 1, m = b - a;  // skip the first 30 frames and the last one
  if (m < 10) {
    printf("too few frames (%d)\n", nf + 1);
    return 1;
  }
  int ns = 0, npd = 0;
  for (int i = a; i < b; i++) {
    frame_t *F = &fr[i];
    sp[i - a] = (double)(F->t_last - F->t_first) / 1e6;
    by[i - a] = (double)F->bytes / 1024.0;
    np[i - a] = F->npk;
    full[i - a] = F->npk ? (double)F->nfull / F->npk : 0;
    gp[i - a] = F->gaps;
    mg[i - a] = F->maxgap;
    per[i - a] = (double)(fr[i + 1].t_first - F->t_first) / 1e6;
    if (F->has_stc_first && F->has_stc_last) sps[ns++] = (uint32_t)(F->stc_last - F->stc_first) / scr_hz * 1e3;
    if (F->has_pts && F->has_stc_first) ptsd[npd++] = (int32_t)(F->stc_first - F->pts) / scr_hz * 1e3;
  }
  double dur = (double)(fr[b].t_first - fr[a].t_first) / 1e9;
  double kb50 = pct(by, m, .5), np50 = pct(np, m, .5);
  printf("mode %dx%d %s fmt %d frame %d interval %u (%.2f fps; asked %d) maxpay %u alt %d (%d B) %d Mb/s, %d pkts x %d urbs\n",
         c.width, c.height, c.yuyv ? "YUYV" : "MJPG", in.format_index, in.frame_index, in.interval,
         in.interval ? 1e7 / in.interval : 0, c.fps, in.maxpay, in.alt, in.psize, in.speed, c.pkts_per_urb, c.nurbs);
  printf("frames %d in %.2f s = %.2f fps (period p50 %.3f ms), empty URBs %.1f%%\n", m, dur, m / dur, pct(per, m, .5),
         100.0 * (double)nempty / (double)(nurb ? nurb : 1));
  printf("spread host p5/p50/p95 %.2f/%.2f/%.2f ms; camera SCR p50 %.2f ms (n %d); first SCR - PTS p50 %.3f ms\n",
         pct(sp, m, .05), pct(sp, m, .5), pct(sp, m, .95), pct(sps, ns, .5), ns, pct(ptsd, npd, .5));
  printf("KB/frame p5/p50/p95 %.1f/%.1f/%.1f; packets p50 %.0f (%.0f B avg); full-packet share p50 %.2f; "
         "idle intervals in a frame p50 %.0f, longest gap p50/p95 %.0f/%.0f\n",
         pct(by, m, .05), kb50, pct(by, m, .95), np50, np50 > 0 ? kb50 * 1024 / np50 : 0, pct(full, m, .5),
         pct(gp, m, .5), pct(mg, m, .5), pct(mg, m, .95));
  return 0;
}
