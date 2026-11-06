# Lessons from the SystemCore work, for the Jetson (2026-11-06)

In November 2026 three agents worked on a SystemCore-like Raspberry Pi 5 (LimelightOS beta, PREEMPT_RT 6.12)
with the same cameras as the robot (Thriftiest Cam, Swyft):
- the builder, on branch `sc/mjpeg-napa`: the native `sc-vision` app and the PhotonVision fork patches
  photonvision-105..111;
- the tester, on `sc/mjpeg-napa-bench`;
- the firmware/camera agent, on `sc/camera-firmware`.

This page lists what carries over to the Jetson, with numbers measured on the SystemCore and the commit
where each change lives.

**Status:**
- **ported**: done on this branch (`sc/jetson-carryover`).
- **port next**: worth doing, with the expected Jetson gain.
- **n/a**: doesn't apply to the Jetson.

The Pi 5's A76 cores and the Orin's A78AE are close in per-clock speed, so CPU numbers should carry over roughly.
Jetson gains are estimates until measured there.

| # | Finding | SystemCore numbers | Where | Jetson status | Expected Jetson gain |
|---|---|---|---|---|---|
| 1 | **Camera delay measured with an LED.** The PTS is 0.045 ± 0.02 ms after the end of exposure. The first USB data packet is 0.41 ± 0.05 ms after it. The `hwtimestamps=1` stamp is 0.348 or 0.224 ms before that packet, one USB microframe apart, picked per stream start. | Was assumed 2.5 ms (Team 100) | `tests/camera-timing` (LED test, `v4l2_ts`, `ts_vs_pts.py`); `sc/camera-firmware` 20b2edf | **ported**: `SPECTRUM_CAMERA_DELAY_US` 2500 -> **120**, the midpoint of 0.06/0.19 ms, so ±0.06 (`09-robot-tuning.sh`). **port next**: the per-session offset (photonvision-112) removes the ±0.06, `health-check.sh` warns on 2500, docs. **Not LED-tested on a Jetson yet**: tests/camera-timing/README.md, "LED test on a Jetson" | Accuracy, not latency: published mid-exposure times move ~2.3 ms later, i.e. right. A robot turning at 360°/s gains 0.8° of heading consistency |
| 2 | **Streaming NAPA read-ahead bug.** A finished blob's candidate was decoded while rows below it were still the previous frame's bytes. Margins (in principle hamming/accept too) depended on stale data for tags near the arrived edge. The existing identity checks can't see it: they feed bands of an already complete image. | Tester probe (rows pre-filled 0/255 until fed): 8-10 frames in 1,200-2,400 differed; 0 after the fix | `patches/napa-04-stream-fed-gate.patch` (`sc/mjpeg-napa` ea1519b) | **ported** (patch file; applies after napa-03, checked with `napa-src.sh`). Takes effect at the next `07-build-napa-detector.sh` on the Jetson. **Rebuild before turning `SPECTRUM_NAPA_STREAM=1` on** | Correctness of streaming NAPA (off by default on the Jetson) |
| 3 | **Luma-only JPEG decoder `mjdec`.** Bit-identical to libjpeg-turbo ISLOW grayscale on every test set, including 1,820 TXMAN1 match frames. Faster because it skips chroma, uses 4x4-sparse NEON IDCTs and a branchless Huffman decoder. libjpeg-turbo also falls back to its slow Huffman path when restart markers are present, which every frame of our cameras has (DRI = 8 rows). | Per frame, CPU: TXMAN1 (87 KB) 2.39-2.51 vs 2.88-3.06 ms; bench 29 KB 0.91 vs 1.79; 51 KB 1.17 vs 1.93 | `native/sc-vision/src/mjdec.c` (`sc/mjpeg-napa` 1ab9065); PhotonVision stream watcher can use it (24fc99b) | **port next**: build mjdec into `libspectrum-stream.so` (the Jetson's `SPECTRUM_JPEG_DECODER=stream`), with the identity check | -0.5 to -0.9 ms CPU per frame per camera (~6-10% of a core per camera at 120 fps); ~0.1 ms less tail |
| 4 | **PhotonVision returned altCameraToTarget = (0,0,0) and poseAmbiguity = 0** whenever orthogonal iteration found one minimum. The robot's ambiguity gate then accepts every single-tag pose, and the "alternate" puts the robot at the tag. **This affects the robot today.** | Fixed fork: ambiguity 0.03-0.07 on a static tag, real alt pose | photonvision-106 (`sc/mjpeg-napa` 647283f); robot-side guard `robot-vision/patches/2026-FM-SystemCore-orinsolver-alt-guard.patch` | **port next (high priority)**: the fork patch on the Jetson's PhotonVision, or at least the robot-side guard | Correct ambiguity gating; no zero alternate pose |
| 5 | **Camera FPS limit applied before the grab**, not after: the old code slept after grabbing, aging every frame by up to a period. | ~+17 ms median at the SystemCore's 50 fps cap | photonvision-105 (647283f) | **port next** (only matters when a camera FPS limit is set; Tag FPS max is already before the grab, photonvision-100) | Up to one frame period when a camera FPS limit is used |
| 6 | **Stamp-lag correction** for `hwtimestamps=0` drivers (32-packet URBs stamp ~2.5 ms late) | 2.51 ms stock, 0.13 ms at urb_packets 4 | photonvision-106/107 | **n/a**: the Jetson uses camera-clock timestamps (`hwtimestamps=1`), lag 0 | - |
| 7 | **PhotonVision fast path**: no 1 MB image copy when nobody watches the stream, native IPPE+GN pose (0.28 ms -> ~10 us), native NT publish from the streaming thread | first packet -> pose 9.03 -> 8.51 ms, 57.7% -> 47.5% of a core; capture -> robot 12.19 -> 11.33 ms | photonvision-108/109/110/111 (9e1c465, 1e311b6, b92c84b) | **port next** (needs `SPECTRUM_NAPA_STREAM=1`, i.e. #2 first) | ~0.5-0.9 ms and ~5-10 points of a core per camera (estimate) |
| 8 | **Camera controls: read, then write only if different.** The Thriftiest resets its controls at power-up, so they must be re-applied on every open. The Swyft **writes control changes to its flash** (settings sector 0x1F000), so needless writes wear it | - | photonvision-109 (`setChecked`); docs/SWYFT-CAMERA-FIRMWARE.md | **port next** (the robot has a Swyft) | Swyft flash life; fewer USB control transfers at start |
| 9 | **Sharpness at the minimum.** Thriftiest 1 (default 5), Swyft 0 (default 50). Bytes per frame, and so decode CPU, follow it | Swyft 84 -> 63 KB; Thriftiest 61 -> 57 KB | docs/CAMERA-FIRMWARE-OPTIMIZATION.md | **port next** (a camera setting in PhotonVision) | Swyft ~-0.8 ms decode per frame; Thriftiest ~-0.15 ms |
| 10 | **Thriftiest exposure settings below 6 are not monotonic**: 2 is ~1.1 ms, 1/3/4 are ~0.1-0.3 ms | Brightness sweep, 4 s per setting | docs/CAMERA-FIRMWARE-OPTIMIZATION.md | **applies** (settings): use 2 for ~1 ms, 3/4 for ~0.3 ms; never interpolate 1-6. The robot runs 50 (5 ms), unaffected | Correct exposure, so correct half-exposure shift |
| 11 | **NAPA min_tag 16 vs 22 vs 32 on real TXMAN1 footage.** min 22 misses 5-13% of sightings at every size (blur, occlusion, edges, angles); min 32 misses 10-25%. On the static bench, min 22 = min 16 | NAPA CPU per frame: min16 1.9 ms, min22 0.74, min32 0.39 | tester FINDINGS entry 28 (`sc/mjpeg-napa-bench` 021417a/a7995e3) | **applies**: keep **min 16** on the Jetson (it has the CPU); min 22 only if short of CPU; not 32 for pose | Keeps every sighting |
| 12 | **CPU governor `performance`** vs `ondemand` | -16% CPU time, p95 frame CPU -32%, latency p50 -0.02 ms, +1.7 °C | `tests/systemcore-latency/governor-ab.sh` (dcf9faf) | **ported (equivalent)**: the Jetson's `spectrum-clocks mode full` (jetson_clocks) | - |
| 13 | **Smaller URBs**: urb_packets 2 vs 4 | Same latency (8.95 ms both) | `tests/systemcore-latency/urb-compare.sh` | **n/a**: the Jetson already runs urb_packets 4 | - |
| 14 | **The frame's 7.2-7.5 ms transfer is the sensor readout**, not USB. Payload size, packet rate and JPEG size don't change it | Transfer 7.24 ms for 21-60 KB frames | docs/CAMERA-FIRMWARE-OPTIMIZATION.md | **applies**: don't spend effort on USB bandwidth for latency | - |

Firmware results that bear on the Jetson's cameras (docs/CAMERA-FIRMWARE-OPTIMIZATION.md):
- Thriftiest 640x400 is the bridge scaling the full readout, so it is no faster.
- A 1280x400 full-pitch band reads out in 3.6 ms but at the end of the frame: no latency gain at 120 fps.
- The Swyft's 640x400 at 210 fps does read out in 3.75 ms (half resolution).
