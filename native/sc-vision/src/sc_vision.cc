// sc-vision: AprilTags from one UVC MJPEG camera on the SystemCore, native, lowest latency.
//
//   USB isochronous packets (user-space UVC, 0.5 ms URBs)  ->  luma-only streaming JPEG decode (mjdec, per
//   restart interval = 8 rows, as the bytes land)  ->  streaming NAPA (napa_stream_feed per band)  ->
//   IPPE-square pose  ->  publish (NetworkTables, nt_pub.cc) + per-frame CSV.
//
// One real-time thread does all of it, pinned to one core; nothing waits on another thread. A low-priority
// checker thread re-decodes every Nth frame with libjpeg-turbo and re-detects it with whole-frame napa_detect,
// and counts any difference (identity, live).
//
//   sc-vision [--secs S] [--csv FILE] [--cpu K] [--fifo PRIO] [--exposure N(0.1ms)] [--gain G] [--size WxH] [--fps F]
//             [--pkts 0=auto] [--urbs 32] [--alt -1] [--min-tag 22] [--hamming 1] [--min-contrast 20]
//             [--every N] [--check N] [--calib FILE] [--tag-size M] [--save DIR] [--no-napa] [--whole]
//             [--nt HOST] [--name CAM] [--no-tagfit] [--selftest]
// Full-tag refinement (docs/FULL-TAG-REFINEMENT.md): on by default with --calib; off with --no-tagfit or env
// SPECTRUM_TAGFIT=0, between NAPA and the pose, full-scale frames only. SPECTRUM_TAGFIT_* settings: tagfit.h.
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/resource.h>
#include <jpeglib.h>
#include <linux/videodev2.h>
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <dirent.h>
#include <sys/syscall.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cmath>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include "mjdec.h"
#include "napa_core.h"
#include "pose.h"
#include "tagfit.h"
#include "tagfit_napa.h"
#include "uvc_usb.h"
}
#include "nt_pub.h"

// napa-03 streaming API (napa_core.c with patches/napa-03-streaming.patch)
extern "C" {
typedef struct napa_stream napa_stream;
napa_stream *napa_stream_create(napa_detector *det);
void napa_stream_destroy(napa_stream *s);
int napa_stream_begin(napa_stream *s, const uint8_t *img, int w, int h, int stride, const napa_params *p);
int napa_stream_feed(napa_stream *s, int rows);
int napa_stream_finish(napa_stream *s, napa_detection *out, int max_out);
}

static std::atomic<bool> g_stop{false};
static void on_sig(int) { g_stop = true; }

static int64_t mono_ns() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}
static int64_t cpu_ns() {
  timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

// ------------------------------------------------------------------------------------------- checker thread
struct jerr {
  jpeg_error_mgr m;
  jmp_buf j;
};
static void jerr_exit(j_common_ptr c) { longjmp(((jerr *)c->err)->j, 1); }
static void jerr_msg(j_common_ptr, int) {}
static int turbo_gray(const uint8_t *jpg, size_t n, uint8_t *out, int w, int h) {
  jpeg_decompress_struct c;
  jerr e;
  c.err = jpeg_std_error(&e.m);
  e.m.error_exit = jerr_exit;
  e.m.emit_message = jerr_msg;
  if (setjmp(e.j)) {
    jpeg_destroy_decompress(&c);
    return -1;
  }
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, jpg, n);
  jpeg_read_header(&c, TRUE);
  c.out_color_space = JCS_GRAYSCALE;
  c.dct_method = JDCT_ISLOW;
  jpeg_start_decompress(&c);
  if ((int)c.output_width != w || (int)c.output_height != h) {
    jpeg_destroy_decompress(&c);
    return -1;
  }
  while (c.output_scanline < c.output_height) {
    JSAMPROW r = out + (size_t)c.output_scanline * w;
    jpeg_read_scanlines(&c, &r, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  return 0;
}

struct Checker {
  std::mutex mu;
  std::condition_variable cv;
  bool busy = false, have = false;
  std::vector<uint8_t> jpg, y;
  std::vector<napa_detection> det;
  int w = 0, h = 0;
  napa_params params{};
  std::atomic<long> ok_dec{0}, bad_dec{0}, ok_det{0}, bad_det{0};
  std::thread th;
  bool napa_on = true;
  void start() {
    th = std::thread([this] { run(); });
  }
  // Called by the vision thread: copies (only if the checker is idle).
  void offer(const uint8_t *j, size_t n, const uint8_t *img, int W, int H, const napa_detection *d, int nd,
             const napa_params &p) {
    std::unique_lock<std::mutex> l(mu, std::try_to_lock);
    if (!l.owns_lock() || busy) return;
    jpg.assign(j, j + n);
    y.assign(img, img + (size_t)W * H);
    det.assign(d, d + nd);
    w = W, h = H, params = p;
    busy = have = true;
    cv.notify_one();
  }
  void run() {
    setpriority(PRIO_PROCESS, 0, 19);
    std::vector<uint8_t> ref;
    napa_detector *nd = napa_create();
    std::vector<napa_detection> out(64);
    while (!g_stop) {
      std::unique_lock<std::mutex> l(mu);
      cv.wait_for(l, std::chrono::milliseconds(200), [this] { return have; });
      if (!have) continue;
      have = false;
      l.unlock();
      ref.resize((size_t)w * h);
      if (turbo_gray(jpg.data(), jpg.size(), ref.data(), w, h) == 0 && !memcmp(ref.data(), y.data(), ref.size()))
        ok_dec++;
      else
        bad_dec++;
      if (napa_on) {
        int n = napa_detect(nd, y.data(), w, h, w, &params, out.data(), (int)out.size());
        bool same = n == (int)det.size();
        for (int i = 0; same && i < n; i++)
          same = out[i].id == det[i].id && out[i].hamming == det[i].hamming &&
                 out[i].decision_margin == det[i].decision_margin &&
                 !memcmp(out[i].corners, det[i].corners, sizeof out[i].corners);
        (same ? ok_det : bad_det)++;
      }
      l.lock();
      busy = false;
    }
    napa_destroy(nd);
  }
};

// ------------------------------------------------------------------------------------------- self test
static int selftest() {
  cam_model cam{};
  cam.fx = 734.5, cam.fy = 734.7, cam.cx = 594.3, cam.cy = 417.8;
  double kk[8] = {0.1137, 0.0329, 0.0008, 0.0004, 0.0010, 0.0250, 0.0957, 0.0794};
  memcpy(cam.k, kk, sizeof kk);
  int bad = 0;
  srand(7);
  double worst = 0;
  for (int it = 0; it < 2000; it++) {
    // random pose: tag 0.5-4 m ahead, rotated up to 60 deg
    double ax = (rand() / (double)RAND_MAX - 0.5) * 2.0, ay = (rand() / (double)RAND_MAX - 0.5) * 2.0,
           az = (rand() / (double)RAND_MAX - 0.5) * 6.0;
    double ca = cos(ax), sa = sin(ax), cb = cos(ay), sb = sin(ay), cc = cos(az), sc = sin(az);
    double Rx[9] = {1, 0, 0, 0, ca, -sa, 0, sa, ca}, Ry[9] = {cb, 0, sb, 0, 1, 0, -sb, 0, cb},
           Rz[9] = {cc, -sc, 0, sc, cc, 0, 0, 0, 1};
    double T[9], R[9];
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++) {
        T[i * 3 + j] = 0;
        for (int k = 0; k < 3; k++) T[i * 3 + j] += Ry[i * 3 + k] * Rz[k * 3 + j];
      }
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++) {
        R[i * 3 + j] = 0;
        for (int k = 0; k < 3; k++) R[i * 3 + j] += Rx[i * 3 + k] * T[k * 3 + j];
      }
    // keep the tag facing the camera: tag normal (R col 2) must point back (negative z)
    if (R[8] > 0)
      for (int i = 0; i < 3; i++) R[i * 3 + 0] = -R[i * 3 + 0], R[i * 3 + 2] = -R[i * 3 + 2];
    double t[3] = {(rand() / (double)RAND_MAX - 0.5) * 1.5, (rand() / (double)RAND_MAX - 0.5) * 1.0,
                   0.5 + 3.5 * rand() / (double)RAND_MAX};
    const double s = 0.1651, h = s / 2, obj[4][2] = {{-h, h}, {h, h}, {h, -h}, {-h, -h}};
    double px[8];
    bool vis = true;
    for (int i = 0; i < 4; i++) {
      double P[3];
      for (int r = 0; r < 3; r++) P[r] = R[r * 3] * obj[i][0] + R[r * 3 + 1] * obj[i][1] + t[r];
      double x = P[0] / P[2], y = P[1] / P[2], r2 = x * x + y * y;
      const double *k = cam.k;
      double rad = (1 + ((k[4] * r2 + k[1]) * r2 + k[0]) * r2) / (1 + ((k[7] * r2 + k[6]) * r2 + k[5]) * r2);
      double xd = x * rad + 2 * k[2] * x * y + k[3] * (r2 + 2 * x * x);
      double yd = y * rad + k[2] * (r2 + 2 * y * y) + 2 * k[3] * x * y;
      px[2 * i] = cam.fx * xd + cam.cx, px[2 * i + 1] = cam.fy * yd + cam.cy;
      if (px[2 * i] < 0 || px[2 * i] > 1280 || px[2 * i + 1] < 0 || px[2 * i + 1] > 800) vis = false;
    }
    if (!vis) continue;
    tag_pose b, a;
    if (pose_ippe_square(&cam, px, s, &b, &a)) {
      bad++;
      continue;
    }
    double et = sqrt((b.t[0] - t[0]) * (b.t[0] - t[0]) + (b.t[1] - t[1]) * (b.t[1] - t[1]) +
                     (b.t[2] - t[2]) * (b.t[2] - t[2]));
    double er = 0;
    for (int i = 0; i < 9; i++) er = std::max(er, fabs(b.R[i] - R[i]));
    worst = std::max(worst, et);
    if (et > 2e-3 || er > 2e-3) bad++;  // the iterative undistort converges to ~1e-4 at the image corners
  }
  // timing
  double c[8] = {500, 300, 600, 310, 610, 400, 505, 395};
  tag_pose b, a;
  int64_t t0 = cpu_ns();
  for (int i = 0; i < 100000; i++) {
    c[0] += 1e-9;
    pose_ippe_square(&cam, c, 0.1651, &b, &a);
  }
  int64_t t1 = cpu_ns();
  printf("pose self-test: %d bad of the visible random poses (worst translation error %.3g m); IPPE %.2f us/tag\n",
         bad, worst, (t1 - t0) / 100000.0 / 1000.0);
  return bad ? 1 : 0;
}

// ------------------------------------------------------------------------------------------- main
int main(int argc, char **argv) {
  double secs = 0, tag_size = 0.1651, mid_offset_ms = -1, camera_delay_ms = -1, fps_max = 0;
  const char *lock_path = nullptr, *cam_serial = nullptr, *cam_port = nullptr;
  const char *csv = nullptr, *calib = nullptr, *save = nullptr, *nt_host = nullptr, *cam_name = "thrifty";
  int cpu = -1, fifo = 0, exposure = -1, gain = -1, gamma = -1, backlight = -1, sharpness = -1, brightness = -1000, every = 1, check = 64, whole = 0, no_napa = 0;
  uvc_config uc{};
  uc.width = 1280, uc.height = 800, uc.fps = 120, uc.alt = -1, uc.pkts_per_urb = 0, uc.nurbs = 32, uc.verbose = 1;
  napa_params np{22, 1, 20, 22, 25};
  // Frame policy (docs/FRAME-POLICY.md): frame skipping only, process 1 frame in `every`; the robot can override it
  // over NT (/photonvision/<name>/input/processEvery). Processed frames are full scale (fscale stays 1).
  int tagfit_on = tagfit_env_enabled();
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto nx = [&]() { return i + 1 < argc ? argv[++i] : (char *)"0"; };
    if (a == "--secs") secs = atof(nx());
    else if (a == "--csv") csv = nx();
    else if (a == "--cpu") cpu = atoi(nx());
    else if (a == "--fifo") fifo = atoi(nx());
    else if (a == "--exposure") exposure = atoi(nx());
    else if (a == "--gain") gain = atoi(nx());
    else if (a == "--size") {  // MJPEG mode WxH (default 1280x800; the ThriftyCam: 1600x1304)
      int w = 0, h = 0;
      if (sscanf(nx(), "%dx%d", &w, &h) == 2 && w > 0 && h > 0) uc.width = w, uc.height = h;
    } else if (a == "--fps") uc.fps = atoi(nx());  // the mode's frame rate (default 120; the ThriftyCam: 60)
    else if (a == "--pkts") uc.pkts_per_urb = atoi(nx());
    else if (a == "--urbs") uc.nurbs = atoi(nx());
    else if (a == "--alt") uc.alt = atoi(nx());
    else if (a == "--min-tag") np.min_tag_px = atoi(nx());
    else if (a == "--hamming") np.max_hamming = atoi(nx());
    else if (a == "--min-contrast") np.min_contrast = atoi(nx());
    else if (a == "--every") every = std::max(1, atoi(nx()));
    else if (a == "--fps-max") fps_max = atof(nx());  // process at most this many frames/s, decided at a frame's start
    else if (a == "--check") check = atoi(nx());
    else if (a == "--calib") calib = nx();
    else if (a == "--tag-size") tag_size = atof(nx());
    else if (a == "--save") save = nx();
    else if (a == "--whole") whole = 1;
    else if (a == "--no-napa") no_napa = 1;
    else if (a == "--nt") nt_host = nx();
    else if (a == "--name") cam_name = nx();
    else if (a == "--mid-offset-ms") mid_offset_ms = atof(nx());  // first packet -> mid-exposure (overrides)
    else if (a == "--camera-delay-ms") camera_delay_ms = atof(nx());  // exposure end -> first packet (per camera;
                                                                    // LED test: 0.41 +- 0.04 ms on the Thriftiest; camera PTS -> first packet 0.35 ms on both cameras)
    else if (a == "--no-refine") pose_refine = 0;
    else if (a == "--usb") {  // camera model VID:PID (hex), default 1bcf:28c5 (Thriftiest); Swyft: 0bda:3035
      unsigned v = 0, p = 0;
      if (sscanf(nx(), "%x:%x", &v, &p) == 2) uc.vid = (int)v, uc.pid = (int)p;
    } else if (a == "--serial") cam_serial = nx();  // which camera: USB serial (e.g. SJ-05)
    else if (a == "--port") cam_port = nx();      // or USB port (sysfs name, e.g. 3-1)
    else if (a == "--force") uc.force = 1;     // take the camera even if its /dev/video node is open
    else if (a == "--lock") lock_path = nx();  // hold this flock (e.g. /tmp/camera.lock) while running
    else if (a == "--gamma") gamma = atoi(nx());
    else if (a == "--backlight") backlight = atoi(nx());
    else if (a == "--sharpness") sharpness = atoi(nx());
    else if (a == "--brightness") brightness = atoi(nx());
    else if (a == "--sharpen") np.sharpening_x100 = atoi(nx());  // NAPA's cell sharpening x100 (default 25)
    else if (a == "--tagfit") tagfit_on = 1;     // full-tag refinement (the default)
    else if (a == "--no-tagfit") tagfit_on = 0;  // (also env SPECTRUM_TAGFIT=0)
    else if (a == "--selftest") return selftest();
    else {
      fprintf(stderr, "unknown option %s\n", a.c_str());
      return 2;
    }
  }
  cam_model cam{};
  bool have_cam = false;
  if (calib) {
    if (cam_model_load(calib, &cam)) {
      fprintf(stderr, "can't read calibration %s\n", calib);
      return 1;
    }
    have_cam = true;
  }
  signal(SIGINT, on_sig);
  signal(SIGTERM, on_sig);
  uvc_select(cam_serial, cam_port);
  // Controls first, through uvcvideo (they stay in the camera after we detach it).
  if (exposure > 0) {
    uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_EXPOSURE_AUTO, V4L2_EXPOSURE_MANUAL);
    if (uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_EXPOSURE_ABSOLUTE, exposure)) fprintf(stderr, "exposure: not set\n");
  }
  if (gain >= 0 && uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_GAIN, gain)) fprintf(stderr, "gain: not set\n");
  if (gamma > 0 && uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_GAMMA, gamma)) fprintf(stderr, "gamma: not set\n");
  if (backlight >= 0 && uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_BACKLIGHT_COMPENSATION, backlight))
    fprintf(stderr, "backlight compensation: not set\n");
  if (sharpness >= 0 && uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_SHARPNESS, sharpness))
    fprintf(stderr, "sharpness: not set\n");
  if (brightness > -1000 && uvc_v4l2_set(uc.vid, uc.pid, V4L2_CID_BRIGHTNESS, brightness))
    fprintf(stderr, "brightness: not set\n");
  mlockall(MCL_CURRENT | MCL_FUTURE);
  // Helper threads first (ntcore's network threads, the checker), while this thread still has every core and normal
  // scheduling: they inherit that. Only the vision thread is then pinned and made SCHED_FIFO. (Before, NT's threads
  // inherited the pin + FIFO and starved behind a never-yielding vision thread on an overloaded core: a client got
  // 6 results/s, up to 850 ms late; tester finding.) They are also kept off the vision core explicitly.
  NtPub *pub = nt_host ? nt_pub_create(nt_host, cam_name) : nullptr;
  Checker chk;
  chk.napa_on = !no_napa;
  if (check > 0) chk.start();  // nice 19
  if (cpu >= 0) {
    cpu_set_t others;
    CPU_ZERO(&others);
    for (int c = 0; c < CPU_SETSIZE && c < 64; c++)
      if (c != cpu) CPU_SET(c, &others);
    // every other thread of the process (ntcore's, the checker) off the vision core
    if (DIR *td = opendir("/proc/self/task")) {
      const pid_t self = (pid_t)syscall(SYS_gettid);
      while (struct dirent *e = readdir(td)) {
        pid_t tid = (pid_t)atoi(e->d_name);
        if (tid > 0 && tid != self) sched_setaffinity(tid, sizeof others, &others);
      }
      closedir(td);
    }
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
  // first data packet -> mid-exposure: half the exposure (exposure_time_absolute is 0.1 ms steps) + the camera's
  // delay from exposure end to its first data packet (0.4 ms: LED test 0.41 +- 0.05 ms on the Thriftiest). The
  // Thriftiest (usbrecov 5.13) mis-maps settings 1-4: 1 ~0.5 ms, 2 ~1.1 ms, 3 and 4 ~0.3 ms (FINDINGS 2A).
  // The ThriftyCam (05c8:0a00): no LED test yet. Its PTS is ~0.7 ms before the first data packet; assuming the PTS
  // marks the end of exposure (the Thriftiest's is 0.18 ms after it), exposure end -> first packet is 0.7 ms.
  if (camera_delay_ms < 0) camera_delay_ms = uc.vid == 0x05c8 && uc.pid == 0x0a00 ? 0.7 : 0.4;
  double exposure_ms = exposure > 0 ? exposure * 0.1 : 0;
  const bool thriftiest = uc.vid == 0x1bcf || (uc.vid == 0 && !(cam_serial && strncmp(cam_serial, "SJ-SW", 5) == 0));
  if (thriftiest && exposure >= 1 && exposure <= 4) exposure_ms = exposure == 1 ? 0.5 : exposure == 2 ? 1.1 : 0.3;
  if (mid_offset_ms < 0) mid_offset_ms = exposure_ms / 2 + camera_delay_ms;
  if (pub) nt_pub_config(pub, have_cam ? &cam : nullptr, tag_size, (int64_t)(mid_offset_ms * 1e6));
  if (lock_path) {  // the bench's camera lock: wait up to 30 s, then give up
    int lfd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0666);
    int got = -1;
    for (int k = 0; lfd >= 0 && k < 300 && (got = flock(lfd, LOCK_EX | LOCK_NB)) != 0 && !g_stop; k++) usleep(100000);
    if (got != 0) {
      fprintf(stderr, "camera lock %s is held by another program\n", lock_path);
      g_stop = true;
      if (chk.th.joinable()) chk.th.join();
      if (pub) nt_pub_destroy(pub);
      return 1;
    }
  }
  uvc_usb *u = uvc_open(&uc);
  if (!u) {
    g_stop = true;  // the checker thread must be joined before exit
    if (chk.th.joinable()) chk.th.join();
    if (pub) nt_pub_destroy(pub);
    return 1;
  }
  const int W = uc.width, H = uc.height;
  const int64_t overload_ns = (int64_t)(0.84e9 / (uc.fps > 0 ? uc.fps : 120));
  const size_t FB = 4 << 20;
  std::vector<uint8_t> fb(FB + 64), Y((size_t)W * H + 64);
  memset(Y.data(), 0, Y.size());
  mjdec *dec = mjdec_create();
  napa_detector *nd = napa_create();
  napa_stream *ns = napa_stream_create(nd);
  std::vector<napa_detection> dets(64), dets_raw(64);
  tagfit_live *tf = tagfit_on && have_cam ? tagfit_live_create(&cam, W, H) : nullptr;
  fprintf(stderr, "sc-vision: tagfit %s\n", tf ? "on" : tagfit_on ? "off (needs --calib)" : "off");
  FILE *out = csv ? fopen(csv, "w") : nullptr;
  if (out)
    fprintf(out,
            "seq,t_first,t_eof_reap,t_dec,t_det,t_pose,t_pub,bytes,dec_cpu_us,napa_cpu_us,pose_us,frame_cpu_us,"
            "ntags,id,margin,hamming,c0x,c0y,c1x,c1y,c2x,c2y,c3x,c3y,tx,ty,tz,err,alt_err,uvc_flags,pts,scr_stc,scr_sof,t_tag_row\n");
  uvc_chunk ch[256];
  int64_t t_start = mono_ns();
  // frame state
  size_t flen = 0;
  int fid = -1, done_fid = -1, in_frame = 0, process = 0, rows_dec = 0, rows_fed = 0, bad = 0;
  long seq = 0, nframes = 0, ndone = 0, nbad = 0, ndet = 0, nskip = 0;
  int64_t last_frame_cpu_ns = 0;
  int fscale = 1, Hs = H;  // this frame's decode scale and its image height
  long nproc = 0;          // frames processed (for full_every)
  long n_by_scale[5] = {0, 0, 0, 0, 0};
  int64_t t_first = 0, t_fid = 0, c_frame0 = 0, c_dec = 0, c_napa = 0, last_proc_start = 0;
  std::vector<double> lat;  // eof reap -> results, ms
  FILE *save_f = nullptr;
  unsigned f_flags = 0, f_pts = 0, f_stc = 0, f_sof = 0;
  // Decode the bytes in so far and feed NAPA the rows that became final.
  int64_t band_t[512];  // reap time of the URB that completed each 8-row band (rolling-shutter row times)
  int64_t cur_tr = 0;
  auto feed = [&]() {
    if (bad || rows_dec >= Hs) return;
    int64_t c0 = cpu_ns();
    int r = mjdec_feed(dec, flen);
    int64_t c1 = cpu_ns();
    c_dec += c1 - c0;
    if (r < 0) {
      bad = 1;
      return;
    }
    for (int b = rows_dec / 8; b < r / 8 && b < 512; b++) band_t[b] = cur_tr;
    rows_dec = r;
    if (!no_napa && !whole && rows_dec > rows_fed) {
      napa_stream_feed(ns, rows_dec);
      rows_fed = rows_dec;
      c_napa += cpu_ns() - c1;
    }
  };
  // The frame's last packet is in (reaped at tr): tags, pose, publish, log.
  auto finish = [&](int64_t tr) {
    nframes++;
    if (bad || rows_dec < Hs) {
      nbad++;
      return;
    }
    int64_t t_dec = mono_ns();
    int nt = 0;
    int64_t c2 = cpu_ns();
    if (!no_napa) {
      napa_params nps = np;
      if (fscale > 1) nps.min_tag_px = std::max(4, np.min_tag_px / fscale);
      nt = whole ? napa_detect(nd, Y.data(), W / fscale, Hs, W / fscale, &nps, dets.data(), (int)dets.size())
                 : napa_stream_finish(ns, dets.data(), (int)dets.size());
      if (nt < 0) nt = 0;
      // a reduced frame's corners back to full-res pixels (pixel centres at integers): x = s x' + (s - 1) / 2
      if (fscale > 1)
        for (int i = 0; i < nt; i++)
          for (int k = 0; k < 8; k++) dets[i].corners[k] = dets[i].corners[k] * fscale + (fscale - 1) * 0.5;
    }
    int64_t t_det = mono_ns();
    c_napa += cpu_ns() - c2;
    tag_pose poses[64], alts[64];
    int64_t p0 = cpu_ns();
    // full-tag refinement: only frames that get published (this one), at full scale; NAPA's corner order
    const bool fitted = tf && fscale == 1 && nt > 0;
    if (fitted) {
      std::copy(dets.begin(), dets.begin() + nt, dets_raw.begin());  // the identity check compares NAPA's own
      uint8_t cells[18 * 18];
      for (int i = 0; i < nt; i++) {
        const int tw = tagfit_napa_cells(dets[i].id, cells);
        if (tw) tagfit_live_refine(tf, Y.data(), W, Hs, W, dets[i].id, cells, tw, dets[i].corners, ndone);
      }
    }
    if (have_cam)
      for (int i = 0; i < nt; i++) {
        double c[8];  // AprilTag's corner order: the tag frame PhotonVision's pose uses
        napa_to_apriltag_order(dets[i].corners, c);
        pose_ippe_square(&cam, c, tag_size, &poses[i], &alts[i]);
      }
    // Diagnostics only (CSV t_tag_row): when the band holding each tag's centre row arrived, i.e. when the tag's
    // pixels became available. NOT a capture time: the OV9281 is a global-shutter sensor, so every tag in a frame
    // was exposed at the same moment (the frame's mid-exposure timestamp); only readout/transfer is row by row.
    int64_t tag_t[64];
    for (int i = 0; i < nt; i++) {
      double yc = (dets[i].corners[1] + dets[i].corners[3] + dets[i].corners[5] + dets[i].corners[7]) / 4;
      int b = std::min(std::max((int)(yc / fscale / 8), 0), std::min(Hs / 8, 512) - 1);
      tag_t[i] = band_t[b];
    }
    int64_t t_pose = mono_ns();
    int64_t pose_ns = cpu_ns() - p0;
    if (nt) ndet++;
    int64_t t_pub = t_pose;
    if (pub) {
      nt_pub_result(pub, t_first, dets.data(), have_cam ? poses : nullptr, have_cam ? alts : nullptr, nt);
      t_pub = mono_ns();
    }
    int64_t frame_cpu = cpu_ns() - c_frame0;
    last_frame_cpu_ns = frame_cpu;
    ndone++;
    if (pub) nt_pub_health(pub, t_pub, ndone, nbad, frame_cpu / 1e6, 1);
    lat.push_back((t_det - tr) / 1e6);
    if (out) {
      const napa_detection *d = nt ? &dets[0] : nullptr;
      fprintf(out, "%ld,%lld,%lld,%lld,%lld,%lld,%lld,%zu,%.1f,%.1f,%.1f,%.1f,%d", seq, (long long)t_first,
              (long long)tr, (long long)t_dec, (long long)t_det, (long long)t_pose, (long long)t_pub, flen,
              c_dec / 1e3, c_napa / 1e3, pose_ns / 1e3, frame_cpu / 1e3, nt);
      if (d) {
        fprintf(out, ",%d,%.3f,%d", d->id, d->decision_margin, d->hamming);
        for (int k = 0; k < 8; k++) fprintf(out, ",%.4f", d->corners[k]);
        if (have_cam)
          fprintf(out, ",%.5f,%.5f,%.5f,%.4f,%.4f", poses[0].t[0], poses[0].t[1], poses[0].t[2], poses[0].err,
                  alts[0].err);
        else
          fprintf(out, ",,,,,");
      } else {
        fprintf(out, ",,,,,,,,,,,,,,,,");
      }
      // the frame's first UVC payload header: PTS / SCR (camera clock), for timestamp work
      fprintf(out, ",%u,%u,%u,%u,%lld\n", f_flags, f_pts, f_stc, f_sof, nt ? (long long)tag_t[0] : 0LL);
    }
    if (save && ndone <= 600) {
      if (!save_f) save_f = fopen(save, "wb");
      if (save_f) fwrite(fb.data(), 1, flen, save_f);
    }
    if (check > 0 && ndone % check == 0 && fscale == 1) chk.offer(fb.data(), flen, Y.data(), W, H, fitted ? dets_raw.data() : dets.data(), nt, np);
  };
  while (!g_stop) {
    int64_t tr;
    int n = uvc_reap(u, ch, 256, &tr);
    if (n < 0) {
      fprintf(stderr, "uvc reap failed: %s\n", strerror(errno));
      break;
    }
    if (secs > 0 && tr - t_start > (int64_t)(secs * 1e9)) break;
    for (int i = 0; i < n; i++) {
      const uvc_chunk &c = ch[i];
      const int f = c.flags & 1;
      if (!in_frame && f == done_fid) continue;  // header-only packets of the frame just finished
      if (!in_frame || f != fid) {               // a new frame starts (FID toggled)
        if (in_frame) {                          // the previous one never saw EOF
          nframes++;
          nbad++;
        }
        in_frame = 1, fid = f, flen = 0, bad = 0, rows_dec = rows_fed = 0;
        // The frame's time reference is its first DATA packet (the LED test's: exposure end = first data packet -
        // 0.41 ms). The camera starts a frame with ~0.75 ms of header-only packets carrying the new frame ID
        // (kernel trace, tests/systemcore-latency/tsref-compare.sh); t_fid is the first of those (scheduling).
        t_fid = tr - (int64_t)c.pkt_from_end * 125000;
        t_first = 0;
        f_flags = c.flags, f_pts = c.pts, f_stc = c.scr_stc, f_sof = c.scr_sof;
        seq++;
        int pol_every = every;
        if (pub) nt_pub_policy(pub, &pol_every);  // the robot's, when it publishes one
        process = (seq % pol_every) == 0;
        // --fps-max: skip a frame (no decode, no NAPA) if it starts less than a period (less 2 ms of jitter
        // room) after the last processed one. Decided at its first packet, so a processed frame is not delayed.
        if (process && fps_max > 0 && last_proc_start &&
            t_fid - last_proc_start < (int64_t)(1e9 / fps_max) - 2000000)
          process = 0;
        // Overload (e.g. min tag 16 on a busy frame costing more than a frame period): newest-frame semantics.
        // Skip this frame if we are working behind the USB stream (this URB was reaped > 2 ms after it completed) or
        // the last processed frame took most of a period (7 ms at 120 fps, 14 ms at 60), instead of falling further
        // and further behind.
        if (process && (mono_ns() - tr > 2000000 || last_frame_cpu_ns > overload_ns)) {
          process = 0;
          nskip++;
          last_frame_cpu_ns = 0;  // try the next one
        }
        if (process) last_proc_start = t_fid;
        if (process) {
          c_frame0 = cpu_ns();
          c_dec = c_napa = 0;
          nproc++;
          n_by_scale[fscale]++;
          mjdec_set_scale(dec, fscale);
          mjdec_begin(dec, fb.data(), FB, Y.data(), W, H, W / fscale);
          napa_params nps = np;
          if (fscale > 1) nps.min_tag_px = std::max(4, np.min_tag_px / fscale);
          if (!no_napa && !whole) napa_stream_begin(ns, Y.data(), W / fscale, Hs, W / fscale, &nps);
        }
      }
      if (c.flags & 0x40) bad = 1;
      if (c.len > 0 && t_first == 0) t_first = tr - (int64_t)c.pkt_from_end * 125000;
      if (process && c.len > 0) {
        if (flen + c.len > FB) bad = 1;
        else memcpy(fb.data() + flen, c.data, c.len), flen += c.len;
      }
      if (c.flags & 2) {  // EOF: finish this frame now; the URB's later packets belong to the next one
        if (process) {
          cur_tr = tr;
          feed();
          finish(tr);
        }
        in_frame = 0;
        done_fid = f;
      }
    }
    if (in_frame && process) {
      cur_tr = tr;
      feed();
    }
    if (pub) nt_pub_health(pub, tr, ndone, nbad, 0, 0);  // keeps the once-a-second health going with no frames
  }
  if (save_f) fclose(save_f);
  uvc_close(u);
  g_stop = true;
  if (chk.th.joinable()) chk.th.join();
  if (out) fclose(out);
  std::sort(lat.begin(), lat.end());
  auto P = [&](double q) { return lat.empty() ? 0.0 : lat[std::min(lat.size() - 1, (size_t)(lat.size() * q))]; };
  uint64_t dco, blocks;
  mjdec_stats(dec, &dco, &blocks);
  fprintf(stderr,
          "sc-vision: %ld frames seen, %ld processed, %ld skipped (overload), %ld bad, %ld with tags; last URB reap -> "
          "tags p50 %.3f p95 %.3f p99 %.3f ms; identity checks: decode %ld ok %ld differ, NAPA %ld ok %ld differ; "
          "DC-only %.1f%%\n",
          nframes, ndone, nskip, nbad, ndet, P(.5), P(.95), P(.99), chk.ok_dec.load(), chk.bad_dec.load(),
          chk.ok_det.load(), chk.bad_det.load(), blocks ? 100.0 * dco / blocks : 0.0);
  fprintf(stderr, "sc-vision: processed at full scale %ld, 1/2 %ld, 1/4 %ld\n", n_by_scale[1], n_by_scale[2],
          n_by_scale[4]);
  if (tf) {
    long tt, tr2, tw2;
    double tus;
    tagfit_live_stats(tf, &tt, &tr2, &tw2, &tus);
    fprintf(stderr, "sc-vision: tagfit %ld tags, %ld refined (%ld warm), %.1f us/tag CPU\n", tt, tr2, tw2,
            tt ? tus / tt : 0.0);
    tagfit_live_destroy(tf);
  }
  if (pub) nt_pub_destroy(pub);
  mjdec_destroy(dec);
  napa_stream_destroy(ns);
  napa_destroy(nd);
  return 0;
}
