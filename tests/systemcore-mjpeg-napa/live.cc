// SpectrumJetson systemcore-mjpeg-napa: scmn_live, a minimal native capture -> decode -> NAPA -> pose loop for one
// UVC MJPEG camera, as the bench's live reference (what the stock building blocks give without PhotonVision) and
// as a per-frame timing probe. Run it under the camera lock: flock /tmp/camera.lock scmn_live ...
//
//   scmn_live [--dev /dev/video0] [--secs 20] [--mode whole|stream|fused] [--cpu N] [--fifo PRIO]
//             [--poll-us 50] [--min-contrast 20] [--config min16|far] [--tag-m 0.1651]
//             [--calib fx,fy,cx,cy,k1,k2,p1,p2[,k3,k4,k5,k6]] [--exposure-ms 1.2] [--cam-delay-ms 2.5]
//             [--csv OUT.csv] [--width 1280 --height 800]
// modes: whole  = DQBUF, then libjpeg-turbo gray + whole-frame NAPA (the pre-streaming path)
//        stream = decode while the buffer fills (stream_decode.cc's method), whole-frame NAPA after the last row
//        fused  = decode while it fills and feed each band to streaming NAPA (Begin/Feed/Finish)
// While a buffer fills, its fill point is the first run of 16 0xFF bytes (buffers are wiped with 0xFF before
// QBUF; JPEG data never has that). The streamed result is only kept if DQBUF then returns that buffer with the
// same length and bytes; otherwise the frame is redone whole ("redo").
// Timestamps (CLOCK_MONOTONIC): v4l2 = the buffer's timestamp (uvcvideo: the frame's first packet, see README),
// eoi = the poll that first saw the EOI (<= poll-us after the last packet landed), dq = DQBUF returned,
// tags, pose. mid-exposure is estimated as v4l2 - cam_delay - exposure/2 (assumed values, printed).
// Pose: corners undistorted with the calibration, homography (napa_far::Tag::Homography) -> R,t, then
// Gauss-Newton on the reprojection error; translation of the tag centre in the camera frame (x right, y down,
// z forward), and the rotation as roll/pitch/yaw (deg) of the tag frame in the camera frame.
#include <fcntl.h>
#include <linux/videodev2.h>
#include <sched.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include <jpeglib.h>

#include "napa/napa_far.h"

static volatile sig_atomic_t g_stop = 0;
static double NowMs() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static double CpuMs() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static int xioctl(int fd, unsigned long r, void *a) {
  int e;
  do e = ioctl(fd, r, a);
  while (e < 0 && errno == EINTR);
  return e;
}

// ---- streaming libjpeg-turbo decoder (suspending source), as detector/stream_decode.cc ----
struct JErr {
  jpeg_error_mgr mgr;
  std::jmp_buf jump;
};
static void ErrExit(j_common_ptr c) { std::longjmp(reinterpret_cast<JErr *>(c->err)->jump, 1); }
static void NoMessage(j_common_ptr, int) {}
static void SrcInit(j_decompress_ptr) {}
static boolean SrcFill(j_decompress_ptr) { return FALSE; }
static void SrcSkip(j_decompress_ptr d, long n) {
  auto *s = d->src;
  const size_t k = std::min(static_cast<size_t>(std::max(0L, n)), s->bytes_in_buffer);
  s->next_input_byte += k;
  s->bytes_in_buffer -= k;
}
static void SrcTerm(j_decompress_ptr) {}
struct Dec {
  jpeg_decompress_struct d{};
  JErr err{};
  jpeg_source_mgr src{};
  size_t fed = 0;
  const uint8_t *p = nullptr;
  uint8_t *out = nullptr;
  int w = 0, h = 0, hdr = 0;
  bool live = false;
  void Begin(const uint8_t *jp, uint8_t *o, int ww, int hh) {
    End();
    p = jp, out = o, w = ww, h = hh, fed = 0, hdr = 0;
    d.err = jpeg_std_error(&err.mgr);
    err.mgr.error_exit = ErrExit;
    err.mgr.emit_message = NoMessage;
    jpeg_create_decompress(&d);
    src = jpeg_source_mgr{};
    src.init_source = SrcInit, src.fill_input_buffer = SrcFill, src.skip_input_data = SrcSkip;
    src.resync_to_restart = jpeg_resync_to_restart, src.term_source = SrcTerm;
    src.next_input_byte = p, src.bytes_in_buffer = 0;
    d.src = &src;
    live = true;
  }
  int Feed(size_t avail) {  // rows final so far, -1 error
    if (!live) return -1;
    if (setjmp(err.jump)) {
      End();
      return -1;
    }
    if (avail > fed) {
      const size_t used = fed - src.bytes_in_buffer;
      fed = avail;
      src.next_input_byte = p + used;
      src.bytes_in_buffer = fed - used;
    }
    if (hdr == 0 && jpeg_read_header(&d, TRUE) == JPEG_HEADER_OK) {
      d.out_color_space = JCS_GRAYSCALE;
      d.dct_method = JDCT_ISLOW;
      hdr = 1;
    }
    if (hdr == 1 && jpeg_start_decompress(&d)) {
      if (static_cast<int>(d.output_width) != w || static_cast<int>(d.output_height) != h) {
        End();
        return -1;
      }
      hdr = 2;
    }
    while (hdr == 2 && d.output_scanline < d.output_height) {
      JSAMPROW rows[16];
      for (int r = 0; r < 16; r++)
        rows[r] = out + static_cast<size_t>(std::min<unsigned>(d.output_scanline + r, d.output_height - 1)) * w;
      if (!jpeg_read_scanlines(&d, rows, 16)) break;
    }
    return hdr == 2 ? static_cast<int>(d.output_scanline) : 0;
  }
  void End() {
    if (live) jpeg_destroy_decompress(&d);
    live = false;
  }
};

// ---- pose ----
struct Calib {
  double fx = 736.985, fy = 737.214, cx = 597.901, cy = 371.578;  // fieldcal TOPRIGHT (OV9281 1280x800)
  double k[8] = {0.1313, 0.0912, 5.2e-05, -0.000437, -0.0969, 0.0520, 0.0949, 0.0682};  // k1 k2 p1 p2 k3 k4 k5 k6
};
static void Distort(const Calib &c, double x, double y, double &u, double &v) {
  const double r2 = x * x + y * y, r4 = r2 * r2, r6 = r4 * r2;
  const double rad = (1 + c.k[0] * r2 + c.k[1] * r4 + c.k[4] * r6) / (1 + c.k[5] * r2 + c.k[6] * r4 + c.k[7] * r6);
  const double xd = x * rad + 2 * c.k[2] * x * y + c.k[3] * (r2 + 2 * x * x);
  const double yd = y * rad + c.k[2] * (r2 + 2 * y * y) + 2 * c.k[3] * x * y;
  u = c.fx * xd + c.cx, v = c.fy * yd + c.cy;
}
static void Undistort(const Calib &c, double u, double v, double &x, double &y) {
  const double xd = (u - c.cx) / c.fx, yd = (v - c.cy) / c.fy;
  x = xd, y = yd;
  for (int it = 0; it < 20; it++) {  // fixed point, as cv::undistortPoints
    const double r2 = x * x + y * y, r4 = r2 * r2, r6 = r4 * r2;
    const double icdist = (1 + c.k[5] * r2 + c.k[6] * r4 + c.k[7] * r6) / (1 + c.k[0] * r2 + c.k[1] * r4 + c.k[4] * r6);
    const double dx = 2 * c.k[2] * x * y + c.k[3] * (r2 + 2 * x * x), dy = c.k[2] * (r2 + 2 * y * y) + 2 * c.k[3] * x * y;
    x = (xd - dx) * icdist, y = (yd - dy) * icdist;
  }
}
static void Rodrigues(const double r[3], double R[9]) {
  const double th = std::sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
  if (th < 1e-12) {
    const double I[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    std::memcpy(R, I, sizeof I);
    return;
  }
  const double x = r[0] / th, y = r[1] / th, z = r[2] / th, c = std::cos(th), s = std::sin(th), C = 1 - c;
  const double M[9] = {c + x * x * C, x * y * C - z * s, x * z * C + y * s, y * x * C + z * s, c + y * y * C,
                       y * z * C - x * s, z * x * C - y * s, z * y * C + x * s, c + z * z * C};
  std::memcpy(R, M, sizeof M);
}
static void RotToVec(const double R[9], double r[3]) {
  const double c = std::max(-1.0, std::min(1.0, (R[0] + R[4] + R[8] - 1) / 2)), th = std::acos(c);
  if (th < 1e-9) {
    r[0] = r[1] = r[2] = 0;
    return;
  }
  const double s = 2 * std::sin(th);
  r[0] = (R[7] - R[5]) / s * th, r[1] = (R[2] - R[6]) / s * th, r[2] = (R[3] - R[1]) / s * th;
}
struct Pose {
  double t[3], rpy[3], err_px;
  bool ok = false;
};
// Tag corners in the tag frame (m): AprilTag's p0..p3 = (-1,1),(1,1),(1,-1),(-1,-1) times size/2, z = 0.
static Pose SolvePose(const napa_far::Tag &tag, const Calib &c, double size) {
  Pose P;
  napa_far::Tag n = tag;
  for (int k = 0; k < 4; k++) Undistort(c, tag.p[2 * k], tag.p[2 * k + 1], n.p[2 * k], n.p[2 * k + 1]);
  const auto H = n.Homography();
  double h1[3] = {H[0], H[3], H[6]}, h2[3] = {H[1], H[4], H[7]}, h3[3] = {H[2], H[5], H[8]};
  const double l1 = std::sqrt(h1[0] * h1[0] + h1[1] * h1[1] + h1[2] * h1[2]);
  const double l2 = std::sqrt(h2[0] * h2[0] + h2[1] * h2[1] + h2[2] * h2[2]);
  double lam = (l1 + l2) / 2;
  if (h3[2] < 0) lam = -lam;
  double r1[3], r2[3], r3[3], t[3];
  for (int i = 0; i < 3; i++) r1[i] = h1[i] / l1 * (lam > 0 ? 1 : -1), r2[i] = h2[i] / l2 * (lam > 0 ? 1 : -1),
                              t[i] = h3[i] / lam * size / 2;
  // Gram-Schmidt
  double d = r1[0] * r2[0] + r1[1] * r2[1] + r1[2] * r2[2];
  for (int i = 0; i < 3; i++) r2[i] -= d * r1[i];
  const double n2 = std::sqrt(r2[0] * r2[0] + r2[1] * r2[1] + r2[2] * r2[2]);
  for (double &v : r2) v /= n2;
  r3[0] = r1[1] * r2[2] - r1[2] * r2[1], r3[1] = r1[2] * r2[0] - r1[0] * r2[2], r3[2] = r1[0] * r2[1] - r1[1] * r2[0];
  double R[9] = {r1[0], r2[0], r3[0], r1[1], r2[1], r3[1], r1[2], r2[2], r3[2]};
  double x[6];
  RotToVec(R, x);
  x[3] = t[0], x[4] = t[1], x[5] = t[2];
  static const double tx[4] = {-1, 1, 1, -1}, ty[4] = {1, 1, -1, -1};
  auto resid = [&](const double *q, double *e) {
    double Rq[9];
    Rodrigues(q, Rq);
    for (int k = 0; k < 4; k++) {
      const double X = tx[k] * size / 2, Y = ty[k] * size / 2;
      const double px = Rq[0] * X + Rq[1] * Y + q[3], py = Rq[3] * X + Rq[4] * Y + q[4], pz = Rq[6] * X + Rq[7] * Y + q[5];
      double u, v;
      Distort(c, px / pz, py / pz, u, v);
      e[2 * k] = u - tag.p[2 * k], e[2 * k + 1] = v - tag.p[2 * k + 1];
    }
  };
  for (int it = 0; it < 10; it++) {  // Gauss-Newton, numeric Jacobian
    double e[8], J[8][6];
    resid(x, e);
    for (int j = 0; j < 6; j++) {
      double q[6];
      std::memcpy(q, x, sizeof q);
      const double hstep = j < 3 ? 1e-6 : 1e-7;
      q[j] += hstep;
      double e2[8];
      resid(q, e2);
      for (int i = 0; i < 8; i++) J[i][j] = (e2[i] - e[i]) / hstep;
    }
    double A[6][7] = {};
    for (int a = 0; a < 6; a++) {
      for (int b = 0; b < 6; b++)
        for (int i = 0; i < 8; i++) A[a][b] += J[i][a] * J[i][b];
      for (int i = 0; i < 8; i++) A[a][6] -= J[i][a] * e[i];
      A[a][a] *= 1.0001;
    }
    for (int col = 0; col < 6; col++) {
      int piv = col;
      for (int r = col + 1; r < 6; r++)
        if (std::fabs(A[r][col]) > std::fabs(A[piv][col])) piv = r;
      for (int k = 0; k < 7; k++) std::swap(A[col][k], A[piv][k]);
      if (std::fabs(A[col][col]) < 1e-18) return P;
      for (int r = 0; r < 6; r++)
        if (r != col) {
          const double f = A[r][col] / A[col][col];
          for (int k = col; k < 7; k++) A[r][k] -= f * A[col][k];
        }
    }
    double step = 0;
    for (int j = 0; j < 6; j++) x[j] += A[j][6] / A[j][j], step += std::fabs(A[j][6] / A[j][j]);
    if (step < 1e-10) break;
  }
  double e[8];
  resid(x, e);
  double s = 0;
  for (double v : e) s += v * v;
  Rodrigues(x, R);
  P.t[0] = x[3], P.t[1] = x[4], P.t[2] = x[5];
  P.rpy[0] = std::atan2(R[7], R[8]) * 180 / M_PI;  // ZYX
  P.rpy[1] = std::asin(std::max(-1.0, std::min(1.0, -R[6]))) * 180 / M_PI;
  P.rpy[2] = std::atan2(R[3], R[0]) * 180 / M_PI;
  P.err_px = std::sqrt(s / 4);
  P.ok = P.t[2] > 0;
  return P;
}

static double Pct(std::vector<double> v, double q) {
  if (v.empty()) return NAN;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, static_cast<size_t>(q * (v.size() - 1) + 0.5))];
}
static void Line(const char *name, const std::vector<double> &v) {
  std::printf("  %-34s p50 %7.3f  p95 %7.3f  p99 %7.3f  max %7.3f  (n %zu)\n", name, Pct(v, .5), Pct(v, .95), Pct(v, .99),
              Pct(v, 1), v.size());
}
static size_t FindFill(const uint8_t *p, size_t from, size_t len) {
  size_t i = from > 16 ? from - 16 : 0;
  while (i + 16 <= len) {
    if (p[i] == 0xFF) {
      size_t j = 1;
      while (j < 16 && p[i + j] == 0xFF) j++;
      if (j == 16) return i;
      i += j;
    } else {
      i++;
    }
  }
  return len;
}

int main(int argc, char **argv) {
  std::string dev = "/dev/video0", mode = "fused", csv, config = "min16";
  double secs = 20, tag_m = 0.1651, exposure_ms = 1.2, cam_delay_ms = 2.5;
  int cpu = -1, fifo = 0, poll_us = 50, min_contrast = 20, W = 1280, H = 800;
  Calib cal;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (a == "--dev") dev = v, ++i;
    else if (a == "--secs") secs = std::atof(v), ++i;
    else if (a == "--mode") mode = v, ++i;
    else if (a == "--cpu") cpu = std::atoi(v), ++i;
    else if (a == "--fifo") fifo = std::atoi(v), ++i;
    else if (a == "--poll-us") poll_us = std::atoi(v), ++i;
    else if (a == "--min-contrast") min_contrast = std::atoi(v), ++i;
    else if (a == "--config") config = v, ++i;
    else if (a == "--tag-m") tag_m = std::atof(v), ++i;
    else if (a == "--exposure-ms") exposure_ms = std::atof(v), ++i;
    else if (a == "--cam-delay-ms") cam_delay_ms = std::atof(v), ++i;
    else if (a == "--csv") csv = v, ++i;
    else if (a == "--width") W = std::atoi(v), ++i;
    else if (a == "--height") H = std::atoi(v), ++i;
    else if (a == "--calib") {
      double q[12] = {};
      int n = std::sscanf(v, "%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf", q, q + 1, q + 2, q + 3, q + 4, q + 5, q + 6,
                          q + 7, q + 8, q + 9, q + 10, q + 11);
      if (n < 4) return std::fprintf(stderr, "--calib fx,fy,cx,cy[,k1..k6 as k1,k2,p1,p2,k3,k4,k5,k6]\n"), 2;
      cal.fx = q[0], cal.fy = q[1], cal.cx = q[2], cal.cy = q[3];
      for (int k = 0; k < 8; k++) cal.k[k] = q[4 + k];
      ++i;
    } else return std::fprintf(stderr, "unknown option %s\n", a.c_str()), 2;
  }
  if (mode != "whole" && mode != "stream" && mode != "fused") return std::fprintf(stderr, "--mode whole|stream|fused\n"), 2;
  signal(SIGINT, [](int) { g_stop = 1; });
  signal(SIGTERM, [](int) { g_stop = 1; });
  if (cpu >= 0) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    sched_setaffinity(0, sizeof s, &s);
  }
  if (fifo > 0) {
    sched_param sp{};
    sp.sched_priority = fifo;
    if (sched_setscheduler(0, SCHED_FIFO, &sp)) perror("SCHED_FIFO");
  }

  const int fd = open(dev.c_str(), O_RDWR | O_NONBLOCK);
  if (fd < 0) return perror(dev.c_str()), 1;
  v4l2_format fmt{};
  fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  fmt.fmt.pix.width = W, fmt.fmt.pix.height = H, fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
  fmt.fmt.pix.field = V4L2_FIELD_NONE;
  if (xioctl(fd, VIDIOC_S_FMT, &fmt)) return perror("S_FMT"), 1;
  v4l2_requestbuffers rb{};
  rb.count = 4, rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, rb.memory = V4L2_MEMORY_MMAP;
  if (xioctl(fd, VIDIOC_REQBUFS, &rb)) return perror("REQBUFS"), 1;
  const int nb = rb.count;
  std::vector<uint8_t *> bufs(nb);
  std::vector<size_t> lens(nb);
  size_t wipe = 1 << 16;
  std::deque<int> queued;
  for (int i = 0; i < nb; i++) {
    v4l2_buffer b{};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, b.memory = V4L2_MEMORY_MMAP, b.index = i;
    if (xioctl(fd, VIDIOC_QUERYBUF, &b)) return perror("QUERYBUF"), 1;
    lens[i] = b.length;
    void *m = mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
    if (m == MAP_FAILED) return perror("mmap"), 1;
    bufs[i] = static_cast<uint8_t *>(m);
    std::memset(bufs[i], 0xFF, b.length);
    if (xioctl(fd, VIDIOC_QBUF, &b)) return perror("QBUF"), 1;
    queued.push_back(i);
  }
  int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  if (xioctl(fd, VIDIOC_STREAMON, &type)) return perror("STREAMON"), 1;

  napa_far::Detector det("tag36h11");
  napa_far::Config cfg;
  cfg.max_hamming = 1, cfg.min_contrast = min_contrast, cfg.min_border_cells = 22;
  if (config == "far") cfg.far = true, cfg.base_min_tag_px = 32, cfg.far_min_tag_px = 16;
  else cfg.min_tag_px = 16;
  det.SetConfig(cfg);
  Dec dec;
  std::vector<uint8_t> gray(static_cast<size_t>(W) * H);
  FILE *out = csv.empty() ? nullptr : std::fopen(csv.c_str(), "w");
  if (out)
    std::fprintf(out, "seq,v4l2_ms,first_seen_ms,eoi_ms,dq_ms,tags_ms,pose_ms,bytes,cpu_ms,streamed,ntags,id,margin,"
                      "tx,ty,tz,roll,pitch,yaw,reproj_px,c0x,c0y,c1x,c1y,c2x,c2y,c3x,c3y\n");

  // per-frame state of the buffer at the head of the queue
  int cur = -1;           // buffer being streamed
  bool napa_on = false;   // fused: Begin() done
  size_t fill = 0;
  int rows = 0;
  double t_first = 0, t_eoi = 0, t_tags = 0, t_pose = 0, cpu_frame = 0;
  std::vector<napa_far::Tag> tags;
  bool have_result = false, failed = false;
  size_t eoi_len = 0;
  Pose pose;

  std::vector<double> lat_v4l2_pose, lat_mid_pose, tail_eoi_pose, dq_pose, v4l2_eoi, cpu_ms, tz, txv, tyv, rollv, pitchv, yawv;
  long frames = 0, drops = 0, redo = 0, with_tag = 0, last_seq = -1, finished_at_dq = 0;
  std::vector<double> chunks;  // KiB that became visible per poll that saw new bytes (~ URB size)
  size_t last_fill_seen = 0;
  const double t_start = NowMs();
  const double cpu_start = CpuMs();

  auto reset = [&]() {
    if (napa_on) det.Finish();
    dec.End();
    last_fill_seen = 0;
    cur = -1, napa_on = false, fill = 0, rows = 0, have_result = false, failed = false, eoi_len = 0;
    t_first = t_eoi = t_tags = t_pose = 0, cpu_frame = 0;
  };
  auto finish_frame = [&](const uint8_t *p, size_t len) {  // after all rows: tags + pose
    double c0 = CpuMs();
    if (mode == "fused") {
      if (napa_on) {
        if (rows < H) det.Feed(H);
        tags = det.Finish();
        napa_on = false;
      }
    } else {
      tags = det.Detect(gray.data(), W, H, W, static_cast<int64_t>(NowMs() * 1000));
    }
    t_tags = NowMs();
    pose = Pose();
    if (!tags.empty()) pose = SolvePose(tags[0], cal, tag_m);
    t_pose = NowMs();
    cpu_frame += CpuMs() - c0;
    have_result = true;
    eoi_len = len;
    (void)p;
  };

  while (!g_stop && NowMs() - t_start < secs * 1000) {
    bool busy = false;
    // 1. stream the head buffer as it fills
    if (mode != "whole" && !queued.empty() && !have_result && !failed) {
      const int i = queued.front();
      uint8_t *p = bufs[i];
      if (cur != i && p[0] == 0xFF && p[1] == 0xD8) {
        reset();
        cur = i;
        t_first = NowMs();
        dec.Begin(p, gray.data(), W, H);
        if (mode == "fused") napa_on = det.Begin(gray.data(), W, H, W, static_cast<int64_t>(t_first * 1000));
      }
      if (cur == i) {
        const double c0 = CpuMs();
        const size_t f = FindFill(p, fill, std::min(lens[i], wipe));
        if (f > fill) {
          fill = f;
          // the last bytes are here: the tail starts now, before decoding them (URBs land in big chunks)
          if (fill >= 2 && p[fill - 2] == 0xFF && p[fill - 1] == 0xD9 && t_eoi == 0) t_eoi = NowMs();
          chunks.push_back(static_cast<double>(fill - last_fill_seen) / 1024.0);
          last_fill_seen = fill;
          const int r = dec.Feed(fill);
          if (r < 0) failed = true;
          else if (r > rows) {
            rows = r;
            if (napa_on) det.Feed(rows);
          }
          busy = true;
          if (rows == H && t_eoi > 0) {
            cpu_frame += CpuMs() - c0;
            dec.End();
            finish_frame(p, fill);
          } else {
            cpu_frame += CpuMs() - c0;
          }
        } else {
          cpu_frame += CpuMs() - c0;
        }
      }
    }
    // 2. DQBUF
    v4l2_buffer b{};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE, b.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_DQBUF, &b) == 0) {
      const double t_dq = NowMs();
      busy = true;
      const int i = b.index;
      if (!queued.empty() && queued.front() == i) queued.pop_front();
      else queued.erase(std::remove(queued.begin(), queued.end(), i), queued.end());
      const double v4l2 = b.timestamp.tv_sec * 1e3 + b.timestamp.tv_usec / 1e3;
      if (last_seq >= 0 && static_cast<long>(b.sequence) > last_seq + 1) drops += b.sequence - last_seq - 1;
      last_seq = b.sequence;
      if (mode != "whole" && cur == i && !have_result && !failed) {
        // the frame completed before the poll saw its last bytes: finish the stream with what DQBUF says is there
        const double c0 = CpuMs();
        fill = b.bytesused;
        const int r = dec.Feed(fill);
        if (r < 0) failed = true;
        else if (r > rows) {
          rows = r;
          if (napa_on) det.Feed(rows);
        }
        cpu_frame += CpuMs() - c0;
        if (!failed && rows == H) {
          t_eoi = t_dq;
          dec.End();
          finish_frame(bufs[i], fill);
          finished_at_dq++;
        }
      }
      const bool streamed = mode != "whole" && cur == i && have_result && eoi_len == b.bytesused && !failed;
      if (!streamed) {
        if (mode != "whole" && redo++ < 8)
          std::fprintf(stderr, "redo seq %u: buffer %d head-streamed %d have_result %d failed %d eoi_len %zu bytesused %u "
                       "fill %zu rows %d flags 0x%x\n", b.sequence, i, cur, have_result, failed, eoi_len, b.bytesused,
                       fill, rows, b.flags);
        reset();
        cur = i;
        const double c0 = CpuMs();
        dec.Begin(bufs[i], gray.data(), W, H);
        rows = dec.Feed(b.bytesused);
        dec.End();
        cpu_frame += CpuMs() - c0;
        if (rows == H) {
          if (mode == "fused") napa_on = false;
          if (mode == "fused") {
            tags = det.Detect(gray.data(), W, H, W, static_cast<int64_t>(t_dq * 1000));
            t_tags = NowMs();
            pose = Pose();
            if (!tags.empty()) pose = SolvePose(tags[0], cal, tag_m);
            t_pose = NowMs();
            cpu_frame += 0;
          } else {
            finish_frame(bufs[i], b.bytesused);
          }
        }
        t_eoi = t_dq;
      }
      if (rows == H) {
        frames++;
        with_tag += !tags.empty();
        lat_v4l2_pose.push_back(t_pose - v4l2);
        lat_mid_pose.push_back(t_pose - v4l2 + cam_delay_ms + exposure_ms / 2);
        tail_eoi_pose.push_back(t_pose - t_eoi);
        dq_pose.push_back(t_pose - t_dq);
        v4l2_eoi.push_back(t_eoi - v4l2);
        cpu_ms.push_back(cpu_frame);
        if (pose.ok) {
          txv.push_back(pose.t[0]), tyv.push_back(pose.t[1]), tz.push_back(pose.t[2]);
          rollv.push_back(pose.rpy[0]), pitchv.push_back(pose.rpy[1]), yawv.push_back(pose.rpy[2]);
        }
        if (out) {
          std::fprintf(out, "%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%u,%.4f,%d,%zu", b.sequence, v4l2, t_first, t_eoi, t_dq,
                       t_tags, t_pose, b.bytesused, cpu_frame, streamed ? 1 : 0, tags.size());
          if (!tags.empty() && pose.ok) {
            std::fprintf(out, ",%d,%.2f,%.5f,%.5f,%.5f,%.3f,%.3f,%.3f,%.3f", tags[0].id, tags[0].margin, pose.t[0],
                         pose.t[1], pose.t[2], pose.rpy[0], pose.rpy[1], pose.rpy[2], pose.err_px);
            for (double v : tags[0].p) std::fprintf(out, ",%.4f", v);
          }
          std::fprintf(out, "\n");
        }
      }
      wipe = std::max(wipe, static_cast<size_t>(b.bytesused) * 3 / 2 + 16384);
      std::memset(bufs[i], 0xFF, std::min(wipe, lens[i]));
      reset();
      if (xioctl(fd, VIDIOC_QBUF, &b) == 0) queued.push_back(i);
    } else if (errno != EAGAIN) {
      perror("DQBUF");
      break;
    }
    if (!busy && poll_us > 0) {
      timespec ts = {0, poll_us * 1000L};
      nanosleep(&ts, nullptr);
    }
  }
  const double wall = NowMs() - t_start, cpu_all = CpuMs() - cpu_start;
  xioctl(fd, VIDIOC_STREAMOFF, &type);
  close(fd);
  if (out) std::fclose(out);
  auto sd = [](const std::vector<double> &v) -> double {
    if (v.size() < 2) return NAN;
    double m = 0, s = 0;
    for (double x : v) m += x;
    m /= v.size();
    for (double x : v) s += (x - m) * (x - m);
    return std::sqrt(s / (v.size() - 1));
  };
  auto mean = [](const std::vector<double> &v) -> double {
    double m = 0;
    for (double x : v) m += x;
    return v.empty() ? NAN : m / v.size();
  };
  std::printf("scmn_live %s: mode %s, %.1f s, %ld frames (%.1f fps), drops %ld, redone whole %ld, cpu %d fifo %d poll %d us, "
              "min_contrast %d\n",
              dev.c_str(), mode.c_str(), wall / 1000, frames, frames * 1000 / wall, drops, redo, cpu, fifo, poll_us,
              min_contrast);
  std::printf("  streamed frames finished at DQBUF (last bytes not yet seen by the poll): %ld\n", finished_at_dq);
  std::printf("  frames with a tag %ld (%.1f%%); loop thread CPU %.1f%% of a core, %.3f ms/frame\n", with_tag,
              frames ? 100.0 * with_tag / frames : 0.0, 100 * cpu_all / wall, frames ? cpu_all / frames : 0.0);
  Line("v4l2 ts (1st packet) -> pose ms", lat_v4l2_pose);
  Line("mid-exposure -> pose ms (est.)", lat_mid_pose);
  Line("v4l2 ts -> EOI seen ms", v4l2_eoi);
  Line("EOI seen -> pose ms (tail)", tail_eoi_pose);
  Line("DQBUF -> pose ms", dq_pose);
  Line("per-frame work CPU ms", cpu_ms);
  Line("KiB newly visible per poll (~URB)", chunks);
  std::printf("  (mid-exposure = v4l2 ts - %.2f ms camera delay - %.2f ms half exposure; both assumed)\n", cam_delay_ms,
              exposure_ms / 2);
  if (!tz.empty())
    std::printf("  pose (tag 0 of each frame, camera frame, m / deg): t = (%.4f, %.4f, %.4f) sd (%.5f, %.5f, %.5f); "
                "rpy = (%.2f, %.2f, %.2f) sd (%.3f, %.3f, %.3f); range %.3f m\n",
                mean(txv), mean(tyv), mean(tz), sd(txv), sd(tyv), sd(tz), mean(rollv), mean(pitchv), mean(yawv), sd(rollv),
                sd(pitchv), sd(yawv),
                std::sqrt(mean(txv) * mean(txv) + mean(tyv) * mean(tyv) + mean(tz) * mean(tz)));
  return 0;
}
