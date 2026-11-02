# NAPA (vendored)

NAPA, a sparse-sampling CPU AprilTag detector, by **Zachary Wilson** (https://github.com/zwatx/NAPA).

- Version: v0.5.1, commit `de613adcd5a047e0f9345b7cfebcfd879cac8d98` (2026-11-01).
- Files: `src/napa_vision/_native/` from that commit (`napa_core.c`, `napa_core.h`, `families.h`,
  `families/`), plus `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES`. Unmodified.
- License: **GPL-3.0-only** (`LICENSE`), with the additional term under GPL section 7(b) in `NOTICE`: copies and
  works based on NAPA must keep its notice and credit Zachary Wilson as NAPA's author in their Appropriate Legal
  Notices. Releases before 0.5.0 were PolyForm Noncommercial: never vendor one.
- Used by `detector/napa/` (libspectrum-napa-apriltag.so, the CPU AprilTag backend of the PhotonVision fork).

To update: copy the same files from a newer tag (0.5.0 or later, GPL-3.0-only), update the commit here and in
`scripts/jetson/07-build-napa-detector.sh`, and rerun `tests/napa-eval`.
