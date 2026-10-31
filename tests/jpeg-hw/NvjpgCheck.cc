// Checks libspectrumnvjpg.so (NVJPG hardware JPEG -> gray) against libjpeg-turbo, the way
// libspectrum-gpu-apriltag.so uses it: loaded with dlopen(RTLD_DEEPBIND) into a process that also has
// libjpeg-turbo (here it's even linked into the executable, the worst case for the name clash).
//
//   NvjpgCheck <lib> <file.mjpeg>...   (Rewind recordings: JPEG frames back to back)
//
// 1. Every frame decoded by both; the gray images must be identical (frames libjpeg-turbo warns
//    about, i.e. corrupt ones, are skipped).
// 2. Bad input: truncated, corrupted, garbage, not a JPEG, wrong size. None may crash or exit,
//    and the next good frame must decode on the hardware again and match. Then format changes
//    (half size, 4:2:0), where libnvjpeg reallocates its buffers.
// 3. 4 threads (4 cameras), one decoder each, all at once: every frame must still match.
// Every frame is also decoded to BGR (snj_decode_bgr) and must match libjpeg-turbo's JCS_EXT_BGR
// exactly; JPEGs that aren't 4:2:2 must be refused (SNJ_UNSUPPORTED) so PhotonVision falls back.
// Colour test recordings: tests/jpeg-hw/make-colour-recordings.py (our cameras are mono).
// 4. Memory: after the first recording has warmed the decoder up, the process may not grow more
//    than 64 MB over all the others (libnvjpeg outside MJPEG mode leaked ~250 KB a frame).
// Exit code 0 only if everything passed.
#include <dlfcn.h>
#include <sys/resource.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csetjmp>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include <jpeglib.h>

#include "../../detector/nvjpg_decoder.h"

using clk = std::chrono::steady_clock;

namespace {

struct Api {
  decltype(&snj_create) create;
  decltype(&snj_create_error) create_error;
  decltype(&snj_destroy) destroy;
  decltype(&snj_decode_gray) decode;
  decltype(&snj_decode_bgr) decode_bgr;
  decltype(&snj_error) error;
} api;

struct TurboErr {
  jpeg_error_mgr mgr;
  jmp_buf jump;
  int warnings;
};
void TurboExit(j_common_ptr c) { longjmp(reinterpret_cast<TurboErr *>(c->err)->jump, 1); }
void TurboMsg(j_common_ptr c, int level) {
  if (level < 0) reinterpret_cast<TurboErr *>(c->err)->warnings++;
}
// Same settings as GpuDetectorJNI.cc (channels 1 gray, 3 BGR). 0 ok (warnings counted), -1 error,
// -2 wrong size.
int Turbo(const std::vector<uint8_t> &j, std::vector<uint8_t> &out, int w, int h, int *warnings,
          int channels = 1) {
  jpeg_decompress_struct c;
  TurboErr e;
  c.err = jpeg_std_error(&e.mgr);
  e.mgr.error_exit = TurboExit;
  e.mgr.emit_message = TurboMsg;
  e.warnings = 0;
  if (setjmp(e.jump)) {
    jpeg_destroy_decompress(&c);
    return -1;
  }
  jpeg_create_decompress(&c);
  jpeg_mem_src(&c, const_cast<unsigned char *>(j.data()), j.size());
  jpeg_read_header(&c, TRUE);
  c.out_color_space = channels == 1 ? JCS_GRAYSCALE : JCS_EXT_BGR;
  c.dct_method = JDCT_ISLOW;
  jpeg_start_decompress(&c);
  if (static_cast<int>(c.output_width) != w || static_cast<int>(c.output_height) != h) {
    jpeg_destroy_decompress(&c);
    return -2;
  }
  out.resize(static_cast<size_t>(w) * h * channels);
  while (c.output_scanline < c.output_height) {
    JSAMPROW row = out.data() + static_cast<size_t>(c.output_scanline) * w * channels;
    jpeg_read_scanlines(&c, &row, 1);
  }
  jpeg_finish_decompress(&c);
  jpeg_destroy_decompress(&c);
  *warnings = e.warnings;
  return 0;
}

// A gray image as a 3-component JPEG with Y sampling h x v (2x1 = 4:2:2, 2x2 = 4:2:0).
std::vector<uint8_t> Encode(const std::vector<uint8_t> &gray, int w, int h, int hs, int vs) {
  jpeg_compress_struct c;
  jpeg_error_mgr e;
  c.err = jpeg_std_error(&e);
  jpeg_create_compress(&c);
  unsigned char *buf = nullptr;
  unsigned long len = 0;
  jpeg_mem_dest(&c, &buf, &len);
  c.image_width = w;
  c.image_height = h;
  c.input_components = 3;
  c.in_color_space = JCS_RGB;
  jpeg_set_defaults(&c);
  jpeg_set_quality(&c, 90, TRUE);
  c.comp_info[0].h_samp_factor = hs;
  c.comp_info[0].v_samp_factor = vs;
  jpeg_start_compress(&c, TRUE);
  std::vector<uint8_t> row(static_cast<size_t>(w) * 3);
  while (c.next_scanline < c.image_height) {
    for (int x = 0; x < w; ++x) {
      row[3 * x] = row[3 * x + 1] = row[3 * x + 2] = gray[c.next_scanline * w + x];
    }
    JSAMPROW r = row.data();
    jpeg_write_scanlines(&c, &r, 1);
  }
  jpeg_finish_compress(&c);
  std::vector<uint8_t> out(buf, buf + len);
  jpeg_destroy_compress(&c);
  free(buf);
  return out;
}

std::vector<std::vector<uint8_t>> Frames(const char *path) {
  std::ifstream in(path, std::ios::binary);
  std::vector<uint8_t> d((std::istreambuf_iterator<char>(in)), {});
  std::vector<std::vector<uint8_t>> out;
  size_t s = 0;
  for (size_t i = 2; i + 1 < d.size(); ++i) {
    if (d[i] == 0xFF && d[i + 1] == 0xD8 && d[i - 2] == 0xFF && d[i - 1] == 0xD9) {
      out.emplace_back(d.begin() + s, d.begin() + i);
      s = i;
    }
  }
  if (s < d.size()) out.emplace_back(d.begin() + s, d.end());
  return out;
}

bool Size(const std::vector<uint8_t> &j, int *w, int *h) {  // from the SOF0 marker
  for (size_t i = 2; i + 9 < j.size(); ++i) {
    if (j[i] == 0xFF && (j[i + 1] == 0xC0 || j[i + 1] == 0xC1)) {
      *h = j[i + 5] << 8 | j[i + 6];
      *w = j[i + 7] << 8 | j[i + 8];
      return true;
    }
  }
  return false;
}

bool Is422(const std::vector<uint8_t> &j) {  // SOF0: 3 components, Y 2x1, Cb/Cr 1x1
  for (size_t i = 2; i + 18 < j.size(); ++i) {
    if (j[i] == 0xFF && (j[i + 1] == 0xC0 || j[i + 1] == 0xC1)) {
      return j[i + 9] == 3 && j[i + 11] == 0x21 && j[i + 14] == 0x11 && j[i + 17] == 0x11;
    }
  }
  return false;
}

long RssKb() {
  long pages = 0, rss = 0;
  if (FILE *f = std::fopen("/proc/self/statm", "r")) {
    if (std::fscanf(f, "%ld %ld", &pages, &rss) != 2) rss = 0;
    std::fclose(f);
  }
  return rss * (sysconf(_SC_PAGESIZE) / 1024);
}

double CpuSeconds() {
  rusage r;
  getrusage(RUSAGE_SELF, &r);
  return r.ru_utime.tv_sec + r.ru_stime.tv_sec + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6;
}

int failures = 0;
void Fail(const std::string &what) {
  failures++;
  std::printf("FAIL: %s\n", what.c_str());
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <libspectrumnvjpg.so> <file.mjpeg>...\n", argv[0]);
    return 2;
  }
  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
  if (!h) {
    std::printf("FAIL: dlopen %s: %s\n", argv[1], dlerror());
    return 1;
  }
  api.create = reinterpret_cast<decltype(api.create)>(dlsym(h, "snj_create"));
  api.create_error = reinterpret_cast<decltype(api.create_error)>(dlsym(h, "snj_create_error"));
  api.destroy = reinterpret_cast<decltype(api.destroy)>(dlsym(h, "snj_destroy"));
  api.decode = reinterpret_cast<decltype(api.decode)>(dlsym(h, "snj_decode_gray"));
  api.decode_bgr = reinterpret_cast<decltype(api.decode_bgr)>(dlsym(h, "snj_decode_bgr"));
  api.error = reinterpret_cast<decltype(api.error)>(dlsym(h, "snj_error"));
  if (!api.create || !api.create_error || !api.destroy || !api.decode || !api.decode_bgr ||
      !api.error) {
    std::printf("FAIL: %s is missing functions\n", argv[1]);
    return 1;
  }
  SnjDecoder *d = api.create();
  if (!d) {
    std::printf("FAIL: snj_create: %s\n", api.create_error());
    return 1;
  }

  // 1. Every frame, both decoders.
  std::vector<std::vector<std::vector<uint8_t>>> files;
  std::vector<double> hw_ms, bgr_ms;
  long frames = 0, same = 0, skipped = 0, bgr_same = 0, warm_rss = 0, warm_frames = 0;
  for (int f = 2; f < argc; ++f) files.push_back(Frames(argv[f]));  // all loaded before measuring
  double cpu0 = CpuSeconds();
  for (int f = 2; f < argc; ++f) {
    long fsame = 0, fdiff = 0, fskip = 0, ffall = 0, bsame = 0, bdiff = 0, brefused = 0, bbad = 0;
    for (auto &j : files[f - 2]) {
      int w, hh, warnings = 0;
      if (!Size(j, &w, &hh)) {
        fskip++;
        continue;
      }
      std::vector<uint8_t> ref, out(static_cast<size_t>(w) * hh);
      if (Turbo(j, ref, w, hh, &warnings) != 0 || warnings) {
        fskip++;
        continue;
      }
      auto a = clk::now();
      int rc = api.decode(d, j.data(), j.size(), out.data(), w, hh, w);
      hw_ms.push_back(std::chrono::duration<double, std::milli>(clk::now() - a).count());
      frames++;
      if (rc != SNJ_OK) {
        ffall++;
        if (ffall <= 3) std::printf("  hardware decode rc %d: %s\n", rc, api.error(d));
      } else if (out == ref) {
        fsame++;
      } else {
        fdiff++;
      }
      // Colour: identical to libjpeg-turbo for 4:2:2, refused otherwise.
      std::vector<uint8_t> bref, bout(static_cast<size_t>(w) * hh * 3);
      Turbo(j, bref, w, hh, &warnings, 3);
      a = clk::now();
      rc = api.decode_bgr(d, j.data(), j.size(), bout.data(), w, hh, static_cast<size_t>(w) * 3);
      if (Is422(j)) {
        bgr_ms.push_back(std::chrono::duration<double, std::milli>(clk::now() - a).count());
        if (rc != SNJ_OK) {
          if (++bbad <= 3) std::printf("  colour decode rc %d: %s\n", rc, api.error(d));
        } else if (bout == bref) {
          bsame++;
        } else {
          bdiff++;
        }
      } else if (rc == SNJ_UNSUPPORTED) {
        brefused++;
      } else {
        if (++bbad <= 3) std::printf("  colour decode of a non-4:2:2 JPEG: rc %d, not refused\n", rc);
      }
    }
    bgr_same += bsame;
    if (f == 2) {
      warm_rss = RssKb();
      warm_frames = frames;
    }
    std::printf("  colour: %ld identical, %ld DIFFER, %ld failed, %ld refused (not 4:2:2)\n", bsame,
                bdiff, bbad, brefused);
    if (bdiff) Fail(std::to_string(bdiff) + " colour frames differ in " + argv[f]);
    if (bbad) Fail(std::to_string(bbad) + " colour decodes failed in " + argv[f]);
    same += fsame;
    skipped += fskip;
    std::printf("%s: %zu frames, %ld identical, %ld DIFFER, %ld not decoded by the hardware, %ld "
                "skipped (corrupt)\n",
                argv[f], files[f - 2].size(), fsame, fdiff, ffall, fskip);
    if (fdiff) Fail(std::to_string(fdiff) + " frames differ in " + argv[f]);
    if (ffall) Fail(std::to_string(ffall) + " frames not decoded by the hardware in " + argv[f]);
  }
  // The CPU time includes libjpeg-turbo's reference decodes, so it's only a ceiling.
  double cpu = CpuSeconds() - cpu0;
  std::sort(hw_ms.begin(), hw_ms.end());
  if (!hw_ms.empty()) {
    std::printf("hardware decode + copy: median %.2f ms, p99 %.2f ms, max %.2f ms over %ld frames "
                "(process CPU incl. libjpeg-turbo %.2f ms/frame)\n",
                hw_ms[hw_ms.size() / 2], hw_ms[static_cast<size_t>(0.99 * (hw_ms.size() - 1))],
                hw_ms.back(), frames, cpu * 1000 / frames);
  }
  std::sort(bgr_ms.begin(), bgr_ms.end());
  if (!bgr_ms.empty()) {
    std::printf("hardware colour decode + GPU conversion + copy: median %.2f ms, p99 %.2f ms over "
                "%zu 4:2:2 frames\n",
                bgr_ms[bgr_ms.size() / 2], bgr_ms[static_cast<size_t>(0.99 * (bgr_ms.size() - 1))],
                bgr_ms.size());
  }
  if (frames == 0) Fail("no frames decoded");
  if (argc > 3) {
    const long grew = RssKb() - warm_rss;
    std::printf("memory: grew %ld MB over %ld frames after the first recording\n", grew / 1024,
                frames - warm_frames);
    if (grew > 64 * 1024) Fail("memory grew " + std::to_string(grew / 1024) + " MB: a leak");
  }

  // 2. Bad input, each followed by a good frame.
  std::vector<uint8_t> good;
  int gw = 0, gh = 0;
  for (auto &file : files) {
    for (auto &j : file) {
      int warnings;
      std::vector<uint8_t> ref;
      if (Size(j, &gw, &gh) && Turbo(j, ref, gw, gh, &warnings) == 0 && !warnings) {
        good = j;
        break;
      }
    }
    if (!good.empty()) break;
  }
  if (!good.empty()) {
    std::vector<uint8_t> ref, out(static_cast<size_t>(gw) * gh);
    int warnings;
    Turbo(good, ref, gw, gh, &warnings);
    auto bad = [&](const char *name, std::vector<uint8_t> j, int w, int hh, bool must_fail) {
      std::vector<uint8_t> o(static_cast<size_t>(std::max(w, 1)) * std::max(hh, 1));
      int rc = api.decode(d, j.data(), j.size(), o.data(), w, hh, w);
      std::fill(out.begin(), out.end(), 0);
      int after = api.decode(d, good.data(), good.size(), out.data(), gw, gh, gw);
      bool ok = (!must_fail || rc != SNJ_OK) && after == SNJ_OK && out == ref;
      std::printf("  %-22s rc %2d (%s); next good frame rc %d, %s\n", name, rc,
                  rc ? api.error(d) : "decoded", after, out == ref ? "matches" : "DIFFERS");
      if (!ok) Fail(std::string("bad input: ") + name);
    };
    std::printf("bad input (a good frame after each):\n");
    {
      auto j = good;
      j.resize(j.size() / 2);
      bad("truncated half", j, gw, gh, false);
    }
    {
      auto j = good;
      for (size_t i = 2000; i + 10 < j.size(); i += 997) j[i] ^= 0x5a;
      bad("corrupted scan data", j, gw, gh, false);
    }
    {
      std::vector<uint8_t> j(50000, 0x42);
      j[0] = 0xFF;
      j[1] = 0xD8;
      bad("garbage after SOI", j, gw, gh, true);
    }
    bad("not a JPEG", std::vector<uint8_t>(64, 0), gw, gh, true);
    bad("wrong size", good, gw / 2, gh / 2, true);
    bad("empty", std::vector<uint8_t>(), gw, gh, true);

    // Format changes (a camera switched to another mode): libnvjpeg reallocates its buffers.
    std::vector<uint8_t> small(static_cast<size_t>(gw / 2) * (gh / 2));
    for (int y = 0; y < gh / 2; ++y)
      for (int x = 0; x < gw / 2; ++x) small[y * (gw / 2) + x] = ref[(2 * y) * gw + 2 * x];
    struct Case {
      const char *name;
      std::vector<uint8_t> jpeg;
      int w, h;
    };
    std::vector<Case> seq = {{"camera frame", good, gw, gh},
                             {"half size 4:2:2", Encode(small, gw / 2, gh / 2, 2, 1), gw / 2, gh / 2},
                             {"camera frame", good, gw, gh},
                             {"half size 4:2:0", Encode(small, gw / 2, gh / 2, 2, 2), gw / 2, gh / 2},
                             {"full size 4:2:0", Encode(ref, gw, gh, 2, 2), gw, gh},
                             {"camera frame", good, gw, gh}};
    std::printf("format changes:\n");
    for (auto &k : seq) {
      std::vector<uint8_t> kref, o(static_cast<size_t>(k.w) * k.h);
      int warnings;
      Turbo(k.jpeg, kref, k.w, k.h, &warnings);
      bool ok = true;
      for (int rep = 0; rep < 6; ++rep) {  // more than libnvjpeg's 4 buffers
        int rc = api.decode(d, k.jpeg.data(), k.jpeg.size(), o.data(), k.w, k.h, k.w);
        ok = ok && rc == SNJ_OK && o == kref;
      }
      std::printf("  %-18s %dx%d: %s\n", k.name, k.w, k.h, ok ? "decoded, matches" : "FAILED");
      if (!ok) Fail(std::string("format change: ") + k.name);
    }
  }
  api.destroy(d);

  // 3. 4 cameras at once.
  std::atomic<long> tframes{0}, tbad{0};
  auto worker = [&](int t) {
    SnjDecoder *td = api.create();
    if (!td) {
      tbad++;
      return;
    }
    auto &file = files[t % files.size()];
    auto end = clk::now() + std::chrono::seconds(5);
    for (size_t k = t * 13; clk::now() < end; ++k) {
      auto &j = file[k % file.size()];
      int w, hh, warnings;
      std::vector<uint8_t> ref;
      if (!Size(j, &w, &hh) || Turbo(j, ref, w, hh, &warnings) != 0 || warnings) continue;
      std::vector<uint8_t> out(static_cast<size_t>(w) * hh);
      if (api.decode(td, j.data(), j.size(), out.data(), w, hh, w) != SNJ_OK || out != ref) tbad++;
      tframes++;
      if (Is422(j) && k % 2) {  // every other frame in colour too, on the same decoder
        std::vector<uint8_t> bref, bout(static_cast<size_t>(w) * hh * 3);
        Turbo(j, bref, w, hh, &warnings, 3);
        if (api.decode_bgr(td, j.data(), j.size(), bout.data(), w, hh, static_cast<size_t>(w) * 3) !=
                SNJ_OK ||
            bout != bref) {
          tbad++;
        }
        tframes++;
      }
    }
    api.destroy(td);
  };
  std::vector<std::thread> threads;
  for (int t = 0; t < 4; ++t) threads.emplace_back(worker, t);
  for (auto &t : threads) t.join();
  std::printf("4 threads for 5 s: %ld frames, %ld wrong or failed\n", tframes.load(), tbad.load());
  if (tbad) Fail("4-thread run");

  std::printf("%s (%ld gray and %ld colour frames identical, %ld corrupt skipped)\n",
              failures ? "FAILED" : "PASSED", same, bgr_same, skipped);
  return failures ? 1 : 0;
}
