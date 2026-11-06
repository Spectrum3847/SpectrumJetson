// sc-vision user-space UVC reader. See uvc_usb.h.
#define _GNU_SOURCE
#include "uvc_usb.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/usbdevice_fs.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MAX_URBS 128

struct uvc_usb {
  int fd;
  char sys[256];
  int vc_if, vs_if, alt, ep, psize, npk, nurbs;
  int detached[2];
  struct usbdevfs_urb *urb[MAX_URBS];
  uint8_t *buf[MAX_URBS];
  int mmapped;
  int verbose;
  struct usbdevfs_urb *held;  // reaped, its data still in use by the caller: resubmitted at the next reap
};

static int rd_hex(const char *dir, const char *name) {
  char p[512], b[32];
  snprintf(p, sizeof p, "%s/%s", dir, name);
  FILE *f = fopen(p, "r");
  if (!f) return -1;
  int v = -1;
  if (fgets(b, sizeof b, f)) v = (int)strtol(b, NULL, 16);
  fclose(f);
  return v;
}
static int rd_dec(const char *dir, const char *name) {
  char p[512], b[32];
  snprintf(p, sizeof p, "%s/%s", dir, name);
  FILE *f = fopen(p, "r");
  if (!f) return -1;
  int v = -1;
  if (fgets(b, sizeof b, f)) v = atoi(b);
  fclose(f);
  return v;
}

// The camera's sysfs device dir (e.g. /sys/bus/usb/devices/3-1).
static int find_dev(int vid, int pid, char *out, size_t n) {
  DIR *d = opendir("/sys/bus/usb/devices");
  if (!d) return -1;
  struct dirent *e;
  int found = -1;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.' || strchr(e->d_name, ':')) continue;
    char p[300];
    snprintf(p, sizeof p, "/sys/bus/usb/devices/%.200s", e->d_name);
    if (rd_hex(p, "idVendor") == vid && rd_hex(p, "idProduct") == pid) {
      snprintf(out, n, "%s", p);
      found = 0;
      break;
    }
  }
  closedir(d);
  return found;
}

int uvc_v4l2_set(int vid, int pid, uint32_t id, int value) {
  char sys[300];
  if (find_dev(vid ? vid : 0x1bcf, pid ? pid : 0x28c5, sys, sizeof sys)) return -1;
  char vdir[700];
  snprintf(vdir, sizeof vdir, "%s/%s:1.0/video4linux", sys, strrchr(sys, '/') + 1);
  DIR *d = opendir(vdir);
  if (!d) return -1;
  struct dirent *e;
  int rc = -1;
  while ((e = readdir(d))) {
    if (strncmp(e->d_name, "video", 5)) continue;
    char dev[64];
    snprintf(dev, sizeof dev, "/dev/%s", e->d_name);
    int fd = open(dev, O_RDWR);
    if (fd < 0) continue;
    struct v4l2_control c = {id, value};
    if (ioctl(fd, VIDIOC_S_CTRL, &c) == 0) rc = 0;
    close(fd);
    if (rc == 0) break;
  }
  closedir(d);
  return rc;
}

// Whether any process has one of the camera's /dev/videoN nodes open (scans /proc/*/fd). who: "pid comm".
static int video_node_in_use(const char *sys, char *who, size_t whon) {
  char vdir[700], nodes[8][64];
  int nn = 0;
  snprintf(vdir, sizeof vdir, "%s/%s:1.0/video4linux", sys, strrchr(sys, '/') + 1);
  DIR *d = opendir(vdir);
  if (!d) return 0;
  struct dirent *e;
  while ((e = readdir(d)) && nn < 8)
    if (!strncmp(e->d_name, "video", 5)) snprintf(nodes[nn++], sizeof nodes[0], "/dev/%.50s", e->d_name);
  closedir(d);
  if (!nn) return 0;
  DIR *pd = opendir("/proc");
  if (!pd) return 0;
  int found = 0;
  while (!found && (e = readdir(pd))) {
    if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
    char fdd[300];
    snprintf(fdd, sizeof fdd, "/proc/%.20s/fd", e->d_name);
    DIR *fds = opendir(fdd);
    if (!fds) continue;
    struct dirent *f;
    while (!found && (f = readdir(fds))) {
      char l[600], tgt[128];
      snprintf(l, sizeof l, "%s/%.200s", fdd, f->d_name);
      ssize_t n = readlink(l, tgt, sizeof tgt - 1);
      if (n <= 0) continue;
      tgt[n] = 0;
      for (int k = 0; k < nn; k++)
        if (!strcmp(tgt, nodes[k])) found = 1;
    }
    closedir(fds);
    if (found) {
      char cp[300], comm[64] = "?";
      snprintf(cp, sizeof cp, "/proc/%.20s/comm", e->d_name);
      FILE *cf = fopen(cp, "r");
      if (cf) {
        if (fgets(comm, sizeof comm, cf)) comm[strcspn(comm, "\n")] = 0;
        fclose(cf);
      }
      snprintf(who, whon, "pid %.20s (%.30s)", e->d_name, comm);
    }
  }
  closedir(pd);
  return found;
}

static int ctrl(int fd, uint8_t rt, uint8_t req, uint16_t val, uint16_t idx, void *data, uint16_t len) {
  struct usbdevfs_ctrltransfer c = {rt, req, val, idx, len, 1000, data};
  return ioctl(fd, USBDEVFS_CONTROL, &c);
}

static int64_t mono_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

uvc_usb *uvc_open(const uvc_config *cfg) {
  int vid = cfg->vid ? cfg->vid : 0x1bcf, pid = cfg->pid ? cfg->pid : 0x28c5;
  uvc_usb *u = (uvc_usb *)calloc(1, sizeof *u);
  u->fd = -1;
  u->verbose = cfg->verbose;
  if (find_dev(vid, pid, u->sys, sizeof u->sys)) {
    fprintf(stderr, "uvc: no USB device %04x:%04x\n", vid, pid);
    free(u);
    return NULL;
  }
  int bus = rd_dec(u->sys, "busnum"), dev = rd_dec(u->sys, "devnum");
  char path[64];
  snprintf(path, sizeof path, "/dev/bus/usb/%03d/%03d", bus, dev);
  // descriptors: device descriptor (18 bytes) then the active configuration
  char dp[400];
  snprintf(dp, sizeof dp, "%s/descriptors", u->sys);
  FILE *f = fopen(dp, "rb");
  uint8_t desc[8192];
  size_t dn = f ? fread(desc, 1, sizeof desc, f) : 0;
  if (f) fclose(f);
  u->fd = open(path, O_RDWR | O_CLOEXEC);
  if (u->fd < 0 || dn < 18) {
    fprintf(stderr, "uvc: open %s: %s\n", path, strerror(errno));
    free(u);
    return NULL;
  }
  // Parse: VC header (UVC version), MJPEG format/frame indices, streaming interface alt settings.
  int uvc_ver = 0x100, fmt_idx = -1, frm_idx = -1, cur_if = -1, cur_alt = -1, cur_sub_if_class = 0;
  int alt_bytes[32] = {0}, alt_ep[32] = {0}, nalt = 0, in_mjpeg = 0;
  u->vc_if = -1;
  u->vs_if = -1;
  for (size_t i = 18; i + 2 <= dn && desc[i] >= 2; i += desc[i]) {
    const uint8_t *p = desc + i;
    int len = p[0], type = p[1];
    if (i + (size_t)len > dn) break;
    if (type == 4) {  // interface
      cur_if = p[2];
      cur_alt = p[3];
      cur_sub_if_class = p[5] == 0x0e ? p[6] : 0;
      if (cur_sub_if_class == 1 && u->vc_if < 0) u->vc_if = cur_if;
      if (cur_sub_if_class == 2 && u->vs_if < 0) u->vs_if = cur_if;
      if (cur_sub_if_class == 2 && cur_if == u->vs_if && cur_alt < 32 && cur_alt + 1 > nalt) nalt = cur_alt + 1;
    } else if (type == 5 && cur_sub_if_class == 2 && cur_if == u->vs_if && cur_alt < 32) {
      int mps = p[4] | (p[5] << 8);
      alt_bytes[cur_alt] = (mps & 0x7ff) * (1 + ((mps >> 11) & 3));
      alt_ep[cur_alt] = p[2];
    } else if (type == 0x24 && cur_sub_if_class == 1 && len >= 5 && p[2] == 0x01) {
      uvc_ver = p[3] | (p[4] << 8);
    } else if (type == 0x24 && cur_sub_if_class == 2 && len >= 4) {
      int sub = p[2];
      if (sub == 0x06) {  // VS_FORMAT_MJPEG
        in_mjpeg = 1;
        if (fmt_idx < 0) fmt_idx = p[3];
      } else if (sub == 0x04 || sub == 0x10) {
        in_mjpeg = 0;
      } else if (sub == 0x07 && in_mjpeg && len >= 26) {  // VS_FRAME_MJPEG
        int w = p[5] | (p[6] << 8), h = p[7] | (p[8] << 8);
        if (w == cfg->width && h == cfg->height && frm_idx < 0) frm_idx = p[3];
      }
    }
  }
  if (u->vc_if < 0 || u->vs_if < 0 || fmt_idx < 0 || frm_idx < 0 || nalt < 2) {
    fprintf(stderr, "uvc: no MJPEG %dx%d streaming setting (vc %d vs %d fmt %d frame %d alts %d)\n", cfg->width,
            cfg->height, u->vc_if, u->vs_if, fmt_idx, frm_idx, nalt);
    close(u->fd);
    free(u);
    return NULL;
  }
  // Refuse to take a camera another program is streaming (PhotonVision, Limelight's visionserver): detaching
  // uvcvideo would pull it out from under them.
  if (!cfg->force) {
    char who[64] = "";
    if (video_node_in_use(u->sys, who, sizeof who)) {
      fprintf(stderr, "uvc: the camera's video node is open by %s; stop it first (or --force)\n", who);
      close(u->fd);
      free(u);
      return NULL;
    }
  }
  // Detach uvcvideo from both interfaces (it binds them together), then claim them.
  int ifs[2] = {u->vc_if, u->vs_if};
  for (int k = 0; k < 2; k++) {
    struct usbdevfs_ioctl cmd = {ifs[k], USBDEVFS_DISCONNECT, NULL};
    u->detached[k] = ioctl(u->fd, USBDEVFS_IOCTL, &cmd) == 0;
    int ifn = ifs[k];
    if (ioctl(u->fd, USBDEVFS_CLAIMINTERFACE, &ifn)) {
      fprintf(stderr, "uvc: claim interface %d: %s\n", ifn, strerror(errno));
      uvc_close(u);
      return NULL;
    }
  }
  // Probe / commit.
  int plen = uvc_ver >= 0x150 ? 48 : uvc_ver >= 0x110 ? 34 : 26;
  uint8_t pr[48];
  memset(pr, 0, sizeof pr);
  pr[0] = 1;  // bmHint: dwFrameInterval
  pr[2] = (uint8_t)fmt_idx;
  pr[3] = (uint8_t)frm_idx;
  uint32_t interval = 10000000u / (uint32_t)(cfg->fps > 0 ? cfg->fps : 120);
  memcpy(pr + 4, &interval, 4);
  if (ctrl(u->fd, 0x21, 0x01, 0x0100, (uint16_t)u->vs_if, pr, (uint16_t)plen) < 0 ||
      ctrl(u->fd, 0xA1, 0x81, 0x0100, (uint16_t)u->vs_if, pr, (uint16_t)plen) < 0) {
    fprintf(stderr, "uvc: probe: %s\n", strerror(errno));
    uvc_close(u);
    return NULL;
  }
  uint32_t maxpay;
  memcpy(&maxpay, pr + 22, 4);
  if (ctrl(u->fd, 0x21, 0x01, 0x0200, (uint16_t)u->vs_if, pr, (uint16_t)plen) < 0) {
    fprintf(stderr, "uvc: commit: %s\n", strerror(errno));
    uvc_close(u);
    return NULL;
  }
  int alt = cfg->alt;
  if (alt < 0) {
    // The Thriftiest asks for 3060 B/microframe (the whole high-bandwidth isochronous budget of a USB 2 bus) but
    // sends ~1 KB/microframe; LimelightOS's uvcvideo caps compressed formats at 1600 (alt 8). Do the same, so a
    // second camera can share the bus. -2: the camera's own request.
    uint32_t want = (cfg->alt == -2 || maxpay < 1600) ? maxpay : 1600;
    for (int a = 1; a < nalt; a++)
      if (alt_bytes[a] >= (int)want) {
        alt = a;
        break;
      }
    if (alt < 0) alt = nalt - 1;
  }
  if (alt <= 0 || alt >= nalt || !alt_bytes[alt]) {
    fprintf(stderr, "uvc: bad alt setting %d\n", alt);
    uvc_close(u);
    return NULL;
  }
  u->alt = alt;
  u->psize = alt_bytes[alt];
  u->ep = alt_ep[alt];
  struct usbdevfs_setinterface si = {(unsigned)u->vs_if, (unsigned)alt};
  if (ioctl(u->fd, USBDEVFS_SETINTERFACE, &si)) {
    fprintf(stderr, "uvc: set alt %d: %s\n", alt, strerror(errno));
    uvc_close(u);
    return NULL;
  }
  u->npk = cfg->pkts_per_urb > 0 ? cfg->pkts_per_urb : 4;
  u->nurbs = cfg->nurbs > 0 ? (cfg->nurbs > MAX_URBS ? MAX_URBS : cfg->nurbs) : 32;
  size_t bl = (size_t)u->npk * u->psize;
  u->mmapped = 1;
  for (int i = 0; i < u->nurbs; i++) {
    u->urb[i] = (struct usbdevfs_urb *)calloc(1, sizeof(struct usbdevfs_urb) +
                                                     (size_t)u->npk * sizeof(struct usbdevfs_iso_packet_desc));
    void *b = u->mmapped ? mmap(NULL, bl, PROT_READ | PROT_WRITE, MAP_SHARED, u->fd, 0) : MAP_FAILED;
    if (b == MAP_FAILED) {
      u->mmapped = 0;
      b = aligned_alloc(64, (bl + 63) & ~(size_t)63);
    }
    u->buf[i] = (uint8_t *)b;
  }
  for (int i = 0; i < u->nurbs; i++) {
    struct usbdevfs_urb *r = u->urb[i];
    r->type = USBDEVFS_URB_TYPE_ISO;
    r->endpoint = (unsigned char)u->ep;
    r->flags = USBDEVFS_URB_ISO_ASAP;
    r->buffer = u->buf[i];
    r->buffer_length = (int)bl;
    r->number_of_packets = u->npk;
    r->usercontext = (void *)(intptr_t)i;
    for (int k = 0; k < u->npk; k++) r->iso_frame_desc[k].length = (unsigned)u->psize;
    if (ioctl(u->fd, USBDEVFS_SUBMITURB, r)) {
      fprintf(stderr, "uvc: submit: %s\n", strerror(errno));
      uvc_close(u);
      return NULL;
    }
  }
  if (u->verbose)
    fprintf(stderr,
            "uvc: %s, UVC %x, MJPEG format %d frame %d (%dx%d @ %d), max payload %u -> alt %d (%d B/uframe), "
            "%d URBs x %d packets, %s buffers\n",
            path, uvc_ver, fmt_idx, frm_idx, cfg->width, cfg->height, cfg->fps, maxpay, alt, u->psize, u->nurbs,
            u->npk, u->mmapped ? "mmap'd" : "heap");
  return u;
}

int uvc_packet_ns(const uvc_usb *u) {
  (void)u;
  return 125000;
}

int uvc_reap(uvc_usb *u, uvc_chunk *out, int max, int64_t *t_ns) {
  struct usbdevfs_urb *r = NULL;
  if (u->held) {  // the caller is done with the previous URB's data
    for (int k = 0; k < u->held->number_of_packets; k++) u->held->iso_frame_desc[k].actual_length = 0;
    if (ioctl(u->fd, USBDEVFS_SUBMITURB, u->held)) return -1;
    u->held = NULL;
  }
  for (;;) {
    if (ioctl(u->fd, USBDEVFS_REAPURB, &r) == 0) break;
    if (errno == EINTR) return -1;  // uvc_timing: a signal (SIGALRM watchdog, Ctrl-C) ends the run
    return -1;
  }
  *t_ns = mono_ns();
  int n = 0;
  size_t off = 0;
  for (int k = 0; k < r->number_of_packets; k++) {
    const struct usbdevfs_iso_packet_desc *pd = &r->iso_frame_desc[k];
    const uint8_t *p = (const uint8_t *)r->buffer + off;
    off += pd->length;
    int len = (int)pd->actual_length;
    if (pd->status || len < 2) continue;
    int hl = p[0];
    if (hl < 2 || hl > len) continue;
    if (n >= max) break;
    uvc_chunk *c = &out[n++];
    c->flags = p[1];
    c->data = p + hl;
    c->len = len - hl;
    c->pkt_from_end = r->number_of_packets - 1 - k;
    c->pts = 0;
    c->scr_stc = 0;
    c->scr_sof = 0;
    int o = 2;
    if ((p[1] & 4) && hl >= o + 4) {
      memcpy(&c->pts, p + o, 4);
      o += 4;
    }
    if ((p[1] & 8) && hl >= o + 6) {
      memcpy(&c->scr_stc, p + o, 4);
      memcpy(&c->scr_sof, p + o + 4, 2);
    }
  }
  u->held = r;
  return n;
}

void uvc_close(uvc_usb *u) {
  if (!u) return;
  if (u->fd >= 0) {
    for (int i = 0; i < u->nurbs; i++)
      if (u->urb[i]) ioctl(u->fd, USBDEVFS_DISCARDURB, u->urb[i]);
    struct usbdevfs_urb *r;
    while (ioctl(u->fd, USBDEVFS_REAPURBNDELAY, &r) == 0) {
    }
    if (u->vs_if >= 0) {
      struct usbdevfs_setinterface si = {(unsigned)u->vs_if, 0};
      ioctl(u->fd, USBDEVFS_SETINTERFACE, &si);
    }
    // Release both interfaces before giving them back: uvcvideo's probe on the control interface claims the
    // streaming one too, and fails while we still hold it (then no /dev/video node comes back).
    int ifs[2] = {u->vc_if, u->vs_if};
    for (int k = 0; k < 2; k++) {
      if (ifs[k] < 0) continue;
      int ifn = ifs[k];
      ioctl(u->fd, USBDEVFS_RELEASEINTERFACE, &ifn);
    }
    for (int k = 0; k < 2; k++) {
      if (ifs[k] < 0) continue;
      struct usbdevfs_ioctl cmd = {ifs[k], USBDEVFS_CONNECT, NULL};
      ioctl(u->fd, USBDEVFS_IOCTL, &cmd);  // the kernel re-probes: uvcvideo takes the interfaces again
    }
    for (int i = 0; i < u->nurbs; i++) {
      if (u->buf[i]) {
        if (u->mmapped) munmap(u->buf[i], (size_t)u->npk * u->psize);
        else free(u->buf[i]);
      }
      free(u->urb[i]);
    }
    close(u->fd);
  }
  free(u);
}
