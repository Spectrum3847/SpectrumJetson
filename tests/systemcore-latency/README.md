# SystemCore latency and CPU: PhotonVision vs sc-vision (2026-11-05/06)

One Thriftiest Cam (SJ-05, usbrecov 5.13) on a SystemCore (LimelightOS SystemCore beta, Pi 5 / CM5, PREEMPT_RT
6.12, ondemand governor), robot code running, Limelight's visionserver stopped. Tag 3 at 0.8 m, static.

## Files

| File | What |
|---|---|
| `run.sh pv\|native SECS NAME [...]` | One live run: holds `/tmp/camera.lock`, ftrace of the USB/V4L2 events, CPU of the vision process (its own utime+stime), table. |
| `analyze.py` | PhotonVision runs: `tests/latency-breakdown/analyze.py` with the SystemCore's 1600-byte packets. |
| `native_analyze.py CSV` | sc-vision runs: stage table from the app's per-frame CSV, CPU, detection rate, margins, jitter. |
| `native-matrix.sh`, `post-compare.sh`, `pv-config.py` | Several runs in one table; the head-to-head below; set PhotonVision pipeline fields. |

## Latency definitions

- **first USB packet -> pose** is the comparison that needs no assumptions: the frame's first USB packet, from the
  kernel trace (PhotonVision) or the app's reap time less the packets after it in its 0.25 ms URB (sc-vision; the
  tester cross-checked it against the kernel trace within ~0.1 ms).
- **V4L2 timestamp -> pose** is what stock PhotonVision reports as latency on LimelightOS (uvcvideo hwtimestamps=0:
  the buffer is stamped when the first 32-packet URB completes, ~2.4 ms after the first packet, with 4 ms
  granularity).
- **mid-exposure** adds exposure/2 + the camera delay to one of the above (results here before 2026-11-06 used an
  assumed 2.5 ms; the default is now 0.4 ms, LED test: 0.41 +- 0.04 ms on the Thriftiest; camera PTS -> first packet 0.35 ms on both cameras). Older runs: the fork applied it to the
  V4L2 timestamp, sc-vision to the first packet, so those two "mid-exposure" columns are not comparable; the fork now
  converts its reference back to the first packet first.

## Head-to-head (`post-compare.sh 30`, the user's Chief Delphi #46 settings)

1280x800 MJPEG 120 fps, exposure_time_absolute 2, gain 128, gamma 100, backlight compensation 0, sharpness 1,
max hamming 1, NAPA v0.5.1 (+ our patches), 30 s per run (~3,600-4,000 frames), ms p50/p95/p99. CPU: the vision
process, % of one core (of the 4-core system in brackets).

| Config | min tag | first USB packet -> pose | V4L2 ts -> pose | CPU |
|---|---|---|---|---|
| PhotonVision, whole-frame NAPA, libjpeg-turbo (the post's setup) | 32 | 13.79 / 14.74 / 18.60 | 11.41 / 12.16 / 16.01 | 49.7% (12.4%) |
| PhotonVision, stream decode (mjdec) + streaming NAPA | 32 | 11.71 / 12.87 / 15.65 | 9.37 / 10.41 / 12.88 | 46.1% (11.5%) |
| **sc-vision** (CFS) | 32 | **8.26 / 8.34 / 8.35** | - | **35.0% (8.8%)** |
| **sc-vision** (SCHED_FIFO 40) | 32 | **8.26 / 8.33 / 8.34** | - | **34.7% (8.7%)** |
| PhotonVision, whole-frame NAPA, libjpeg-turbo | 16 | 14.64 / 15.66 / 19.55 | 12.27 / 13.16 / 16.96 | 62.1% (15.5%) |
| PhotonVision, stream decode (mjdec) + streaming NAPA | 16 | 12.04 / 13.38 / 15.82 | 9.54 / 10.73 / 12.83 | 56.9% (14.2%) |
| **sc-vision** (CFS) | 16 | **8.29 / 8.38 / 8.40** | - | **49.8% (12.4%)** |
| **sc-vision** (SCHED_FIFO 40) | 16 | **8.29 / 8.37 / 8.40** | - | **50.5% (12.6%)** |

- The PhotonVision baseline reproduces the post (13.1 / 15.1 / 17.7 ms, 12% at min 32; 15.1 / 18.0 / 20.3, 18% at
  min 16) within the method differences.
- Of sc-vision's 8.26 ms, 8.14 ms is the camera streaming the frame (first -> last packet; fixed by the camera at
  every resolution); last packet -> pose is 0.08 / 0.13 / 0.13 ms (min 32), 0.11 / 0.17 / 0.19 (min 16).
- Every frame had the tag (100%, ~4,000 frames per run); identity checks 62-63 per run, 0 differ (decode and NAPA).
- sc-vision CPU per frame (min 32): decode 2.0 ms, NAPA 0.44 ms, pose 0.02 ms; (min 16): decode 2.15, NAPA 1.47.

## Corners and timestamps (what the robot's TagEKF uses)

- **Corners:** the published `detectedCorners` (raw image pixels, AprilTag order) match PhotonVision's on the same
  scene: means over 1,214 results each differ by <= 0.03 px (per-frame sd 0.21-0.32 px at gain 128). Pose
  translation within 2.5 mm (sc-vision IPPE + Gauss-Newton vs PhotonVision's orthogonal iteration).
- **Timestamp jitter** (residual of the frame timestamps against a fitted constant frame period, 30 s):
  sc-vision first-packet time sd 0.037 ms (p1/p99 -0.06/+0.06 ms); PhotonVision's V4L2 timestamp sd 1.26 ms
  (p1/p99 -2.0/+2.0 ms: the 4 ms URB quantization).
- The camera sends PTS + SCR in every payload header (48 MHz clock; PTS is ~7.8 ms before the first packet's SCR,
  about one frame period); logged in sc-vision's CSV for timestamp work, not used yet.
- Every tag in a frame gets the frame's one mid-exposure timestamp: the OV9281 is a global-shutter sensor (all rows
  exposed together; only readout/transfer is row by row). sc-vision's CSV column t_tag_row (when the band with the
  tag's centre row arrived) is a data-availability diagnostic, not a capture time.
