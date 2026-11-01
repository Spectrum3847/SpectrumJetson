#!/usr/bin/env python3
"""Adds per-frame quad counters to a COPY of bos's third_party/971apriltag (never the installed build).

  instrument.py DIR      DIR = the copy's third_party/971apriltag

QuadDecodeTask counts the quads reaching corner refinement / decode, times RefineEdges and decode per quad,
and splits both by whether the quad decoded to a tag (hamming <= the family's bits; any margin). With
SPECTRUM_QS_EARLY=1 it also decodes each quad on its unrefined corners first (a stand-in for a cheap early
decode, without slack: an upper bound on its cost and on the real tags it would lose). DecodeTags appends one
line per frame to $SPECTRUM_QS_OUT: detector,quads,sane,tags,early_ok,tag_early_ok,refine_us,decode_us,
refine_us_nontag,decode_us_nontag,early_us,wall_us.
"""
import pathlib
import sys

d = pathlib.Path(sys.argv[1])
c = d / "apriltag.c"
s = c.read_text()
if "spectrum_qs_added" not in s:
    s = s.replace("void quad_decode_index(apriltag_detector_t *td,", "__thread int spectrum_qs_added = 0;\nvoid quad_decode_index(apriltag_detector_t *td,", 1)
    s = s.replace("            zarray_add(detections, &det);", "            zarray_add(detections, &det);\n            spectrum_qs_added++;", 1)
    assert s.count("spectrum_qs_added") == 2, "apriltag.c patch failed"
    c.write_text(s)

cc = d / "apriltag_detect.cc"
s = cc.read_text()
if "spectrum_qs" not in s:
    head = r'''
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
extern "C" __thread int spectrum_qs_added;
namespace spectrum_qs {
std::atomic<long> quads{0}, sane{0}, tags{0}, early_ok{0}, tag_early_ok{0};
std::atomic<long> refine_ns{0}, decode_ns{0}, refine_ns_nontag{0}, decode_ns_nontag{0}, early_ns{0};
inline long Ns(std::chrono::steady_clock::time_point a) {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - a).count();
}
inline bool Early() { static const bool e = std::getenv("SPECTRUM_QS_EARLY") != nullptr; return e; }
}  // namespace spectrum_qs
'''
    s = s.replace("namespace frc::apriltag {", head + "namespace frc::apriltag {", 1)
    s = s.replace("""  for (int quadidx = task->i0; quadidx < task->i1; quadidx++) {
    struct quad quad_original;""", """  for (int quadidx = task->i0; quadidx < task->i1; quadidx++) {
    spectrum_qs::quads++;
    struct quad quad_original;""", 1)
    s = s.replace("""      if (!sane) continue;
    }
""", """      if (!sane) continue;
    }
    spectrum_qs::sane++;
    bool qs_early = false;
    if (spectrum_qs::Early()) {
      static thread_local zarray_t *scratch = zarray_create(sizeof(apriltag_detection_t *));
      struct quad q = quad_original;
      q.H = nullptr, q.Hinv = nullptr;
      const int before = spectrum_qs_added;
      const auto e0 = std::chrono::steady_clock::now();
      quad_decode_index(td, &q, im, task->im_samples, scratch);
      spectrum_qs::early_ns += spectrum_qs::Ns(e0);
      qs_early = spectrum_qs_added > before;
      spectrum_qs_added = before;
      for (int i = 0; i < zarray_size(scratch); ++i) {
        apriltag_detection_t *det;
        zarray_get(scratch, i, &det);
        apriltag_detection_destroy(det);
      }
      zarray_clear(scratch);
      if (q.H) matd_destroy(q.H);
      if (q.Hinv) matd_destroy(q.Hinv);
      spectrum_qs::early_ok += qs_early;
    }
    const auto r0 = std::chrono::steady_clock::now();
""", 1)
    s = s.replace("""    quad_decode_index(td, &quad_original, im, task->im_samples,
                      task->detections);
""", """    const long qs_refine = spectrum_qs::Ns(r0);
    const int qs_before = spectrum_qs_added;
    const auto d0 = std::chrono::steady_clock::now();
    quad_decode_index(td, &quad_original, im, task->im_samples,
                      task->detections);
    const long qs_decode = spectrum_qs::Ns(d0);
    const bool qs_tag = spectrum_qs_added > qs_before;
    spectrum_qs::refine_ns += qs_refine;
    spectrum_qs::decode_ns += qs_decode;
    if (qs_tag) {
      spectrum_qs::tags++;
      spectrum_qs::tag_early_ok += qs_early;
    } else {
      spectrum_qs::refine_ns_nontag += qs_refine;
      spectrum_qs::decode_ns_nontag += qs_decode;
    }
""", 1)
    s = s.replace("""void GpuDetector::DecodeTags() {
""", """void GpuDetector::DecodeTags() {
  using namespace spectrum_qs;
  for (auto *a : {&quads, &sane, &tags, &early_ok, &tag_early_ok, &refine_ns, &decode_ns, &refine_ns_nontag,
                  &decode_ns_nontag, &early_ns})
    *a = 0;
  const auto qs_wall0 = std::chrono::steady_clock::now();
""", 1)
    s = s.replace("""  workerpool_run(tag_detector_->wp);

  FinishDetections();
}""", """  workerpool_run(tag_detector_->wp);
  {
    const long wall = Ns(qs_wall0);
    static FILE *qs_out = [] {
      const char *p = std::getenv("SPECTRUM_QS_OUT");
      return p ? std::fopen(p, "w") : nullptr;
    }();
    if (qs_out)
      std::fprintf(qs_out, "%p,%ld,%ld,%ld,%ld,%ld,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f\\n", static_cast<void *>(this),
                   quads.load(), sane.load(), tags.load(), early_ok.load(), tag_early_ok.load(),
                   refine_ns / 1e3, decode_ns / 1e3, refine_ns_nontag / 1e3, decode_ns_nontag / 1e3,
                   early_ns / 1e3, wall / 1e3);
  }

  FinishDetections();
}""", 1)
    assert s.count("spectrum_qs::") >= 10 and "qs_out" in s, "apriltag_detect.cc patch failed"
    cc.write_text(s)
print("instrumented", d)
