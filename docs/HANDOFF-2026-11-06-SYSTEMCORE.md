# Handoff: SystemCore / Pi 5 vision work (2026-11-05 to 06)

One night of multi-agent work on a Raspberry Pi 5 bench (LimelightOS SystemCore beta18, DIY SystemCore image,
`ssh systemcore@172.26.0.1`) with a Thriftiest Cam (SJ-05) and a Swyft (SJ-SW01). Nothing is merged to `main`.
Running logs on the Pi: `~/shared/BUILDER-LOG.md`, `FINDINGS.md` (tester), `FIRMWARE-LOG.md`, `PVPERF-LOG.md`.
Published summary: https://claude.ai/artifact/2UXdwMdQXJ4XqfPSzuviP9 (private; share from its menu).

## Where the work is

| Branch | What |
|---|---|
| `sc/mjpeg-napa` | Native app `sc-vision` (`native/sc-vision`), luma-only decoder mjdec, streaming NAPA fix napa-04, small-URB uvcvideo build (`scripts/systemcore/build-uvcvideo.sh`), installers, PV patches `photonvision-105..127`, native camera backend (in progress, `docs/SYSTEMCORE-NATIVE-BACKEND.md`), frame policy (`docs/FRAME-POLICY.md`) |
| `sc/mjpeg-napa-bench` | Tester bench `tests/systemcore-mjpeg-napa/` (nt_check, pvboth.sh, pvdb.py, topcpu.py, ...) |
| `sc/camera-firmware` | Camera timing tools, LED camera-delay test, `docs/CAMERA-FIRMWARE-OPTIMIZATION.md` |
| `sc/jetson-carryover` | Jetson camera delay 120 µs, napa-04, `docs/SYSTEMCORE-FINDINGS.md` (what ports to the Jetson) |
| `sc/pv-perf` | PV CPU/GC/UI audit, `docs/PHOTONVISION-PERF.md`, `tests/pv-perf` |
| `sc/systemcore-data` | Data-area plan + `scripts/systemcore/sc-data.sh`, `docs/SYSTEMCORE-DATA-PARTITION.md` (incl. reset investigation) |
| fork `Spectrum3847/photonvision` `sc/mjpeg-napa` | PV changes mirrored above (fork CI: Lint only on main/PRs; other workflows disabled) |

## Key results (lit scene, CD #46 camera settings, min_tag 32)

- First USB packet → pose: sc-vision 8.22 ms p50 / 8.31 p99 (Thriftiest), 7.57 (Swyft). Stock-like PV 13.8 / 18.6.
- PV fast path (small-URB driver + streaming decode + streaming NAPA + native pose + native publish):
  ties sc-vision on latency (same time reference); ~42-46% of a core per camera vs sc-vision ~27-37%.
- Two cameras in one PV (native publish, one NT client per camera): 9.3 / 9.4 ms capture → received p50,
  PV process 88-95% of one core (min 32), 109% (min 22).
- Camera delay (LED test, two independent analyses): exposure end → first USB data packet **0.41 ± 0.04 ms**
  (was assumed 2.5). Defaults: sc-vision/PV 0.4 ms from first packet; Jetson 120 µs on its camera-clock stamps.
- NAPA min_tag: 8-21 identical (every pixel), 22-31 every 2nd, 32+ every 3rd. TXMAN1: min 22 misses 5-13%,
  min 32 misses 10-25% of sightings. Use 16 if CPU allows, else 22.
- Decode scale: 1/2 saves decode; 1/4 decodes no faster (Huffman floor ~1 ms) → robot policy is full or 1/2 + skipping.

## Bugs found and fixed (selection)

- PV fork published a zero alternate pose with ambiguity 0 (photonvision-106) — **affects the robot today**;
  robot-side guard patch `robot-vision/patches/2026-FM-SystemCore-orinsolver-alt-guard.patch` (not committed to 2026-FM-SystemCore).
- Streaming NAPA read rows not yet received (napa-04; also affects the Jetson).
- PV fast path: tag quality never paired with results (photonvision-115); native pose rotation 180° off (36ab7bc, SystemCore only).
- PV frame-rate cap slept after the grab (+17 ms); Rewind never recorded on a 6.8 GB root (small-disk defaults, photonvision-127).

## Bench facts

- SD card (2014, 32 GB) stalls under heavy writes → kernel panic resets (one proven via pstore); keep heavy writes in /dev/shm.
  User keeps this card for testing; training Pis get new high-endurance cards.
- Thriftiest exposure settings 1-4 mis-mapped (2 ≈ 1.1 ms). Swyft writes controls to flash (write only when different).
- Pi 5 per-port USB power switching does not cut VBUS: a Swyft after its boot loader needs a physical replug.
- `limelight_visionserver` must be stopped while PV/sc-vision use the cameras (restarts at boot).

## Update (2026-11-06 morning)

- **Native cameras without cscore work** (fork 97cc032e, 0c39517d, 6f8bcb0e = photonvision-128..130; SpectrumJetson
  de88259, 73359df, 9c542ff; status in `docs/SYSTEMCORE-NATIVE-BACKEND.md`). Thriftiest/Swyft go native automatically
  when `SPECTRUM_NATIVE_PUBLISH=1` (`SPECTRUM_NATIVE_CAMERA=0` opts out); other cameras stay on cscore.
  Dark, single camera: same latency as the fast path, CPU Thriftiest 22.3 → 18.3%, Swyft 28.0 → 24.3% of a core.
  Handover (native → temporary cscore → native) and stream-on-demand verified via a test hook; fallback verified.
- **PV-perf all merged:** photonvision-120..127 on fork sc/mjpeg-napa; identity checks every 1024th frame (49d42c1);
  installer builds a Java AOT cache, PV starts via `/opt/photonvision/run.sh` (d6ed364). Status: `docs/PHOTONVISION-PERF.md`.
- **Pi:** PV installed with native backend, AOT=0, PV stopped, limelight_visionserver stopped, DB restored (both cameras), Swyft exp 10.

## In progress / next

1. Native backend leftovers: real calibration from the UI, passthrough stream (camera JPEG, no re-encode), both
   cameras at once, lit CPU vs sc-vision, full UI controls check, 21 tag-quality seq mismatches during handover,
   enable `SPECTRUM_NATIVE_PUBLISH=1` in the installed drop-in, first AOT-cache install.
2. Lights-on checks: PV min 16 with two cameras, tag 3 decision margin, half-scale CPU, PV-perf lit A/Bs.
3. Apply the data-area plan on the bench Pi when someone is there; provision training Pis from that plan.
4. Port to the Jetson: photonvision-106, mjdec, fast path (see `docs/SYSTEMCORE-FINDINGS.md`).
