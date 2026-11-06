# Per-camera frame policy: frame skipping

Status 2026-11-07: **frame skipping only.** The decode-scale option (half resolution) was removed from
NetworkTables, the robot-facing API, PhotonVision (fork: `input/scale`, `input/fullEvery`, `health/scale`,
`health/fullEvery`, `health/scaledFrames`, `SPECTRUM_POLICY_SCALE`, `SPECTRUM_POLICY_FULL_EVERY`, the "Low-CPU
Decode" pipeline switch) and the native code (NAPA sink and native camera: no reduced scale; sc-vision: no `--scale`
/ `--full-every`, no NT scale inputs). Why: live it saved at most ~1 point of a core per camera (see the 2026-11-07
section below). The offline tools keep their test options (`stream_identity --scale/--scaled-min`,
`mjdec_bench --scale`); they don't touch a robot.

## What it does

The camera always streams 1280x800 MJPEG; the UVC mode never changes. For each frame, at its start (before any
decoding), each camera decides to **process** it (full decode, NAPA, pose, publish) or **skip** it (not decoded at
all, which costs almost nothing).

## NetworkTables input (the robot publishes; optional)

| Topic | Values | Default | Meaning |
|---|---|---|---|
| `/photonvision/<camera>/input/processEvery` | N >= 1 | 1 | Process 1 frame in N; the others are skipped at their start |

Missing or <= 0: the default. Defaults when the robot publishes nothing: sc-vision `--every`, PhotonVision
`SPECTRUM_POLICY_PROCESS_EVERY`. In PhotonVision skipping applies only while nobody watches that camera's stream.
Health: `/photonvision/<camera>/health/processEvery` (the value in force) and `health/fps` (the processed rate).

## Proposal for the robot code (2026-FM-SystemCore, not committed there)

One small subsystem publishes `processEvery` for each camera from what the robot knows:

- **Tags predicted in this camera's view, or the robot fast or turning hard** (the pose matters most):
  `processEvery 1`.
- **No tag predicted for this camera**: `processEvery 2` to `4`, so a surprise tag is still seen within about
  17-33 ms at 120 fps.
- **Disabled, or the code doesn't know**: publish nothing (every frame).

Each camera reads only its own topic, so cameras can differ (a camera facing the scoring tags at 1, one facing a
wall at 4). For less CPU at a fixed rate use a larger min tag (min 22 is the measured sweet spot, FINDINGS 40).

## History: decode scale (removed)

## Measured (sc-vision, Thriftiest, exposure setting 2, min tag 32 at full scale; `tests/systemcore-latency/scale-compare.sh 15`)

| Scale | Decode CPU us (mean) | NAPA us | Frame us | Tags per frame | Tag 3 tz sd |
|---|---|---|---|---|---|
| 1 | 2004 | 708 | 3118 | 3.01 | 1.92 mm |
| 1/2 (min 16 on 640x400) | 1568 | 896 | 2859 | 3.00 | (first tag was tag 10) |
| 1/4 (min 8 on 320x200; test option only) | 1491 | 387 | 2258 | 1.98 | 1.49 mm |

mjdec alone (`mjdec_bench --scale`, 200 frames, one core), whole-frame decode p50: full 1.76 ms, 1/2 1.22 ms, 1/4
1.21 ms, 1/8 0.97 ms. Huffman decoding sets the floor. Against libjpeg-turbo's scaled decode: mean |diff| 0.07
grey levels at 1/2 and 0.13 at 1/4, identical at 1/8.

At 1/2 with min tag halved, NAPA costs more than at full scale with min 32 (it searches the same physical tag
sizes on a smaller image). Keeping min 32 at 1/2 would make NAPA cheaper but drop tags under 64 full-res pixels.
1/4 loses the smallest tag here.

Not measured yet (the bench went dark at about 17:58; both cameras' frames are flat, even at a 10 ms exposure):

- the Swyft;
- detection against tag size with the taped tags and the TXMAN1 set;
- pose noise at 1/2 on tag 3;
- the PhotonVision fast path's detection at 1/2. Only its CPU was seen: the Swyft's streaming thread went
  from about 21% to 11% of a core at 1/2, and `processEvery 2` gave 60 results/s.

## 2026-11-07: half scale dropped (then removed)

FINDINGS 40 (3): input/scale=2 engaged but cost ~+0.5 ms a frame on the Swyft (thread 24.6 -> 30.4%). Two causes
in the native backend, both fixed: (1) min_tag / 2 made NAPA sample every half-res pixel at min 32 (base stride
min*3/32: 3 at full scale, 1 at 16 = 2.25x the samples); the reduced min tag is now raised until the half frame is
sampled no denser than the full one (min 32 -> 22 at half scale, i.e. tags of 32-43 px may be missed; min 22 -> 11
and 16 -> 8 unchanged; never below NAPA's 8); (2) the Java image's upscale was a per-pixel divide loop (now row
replication). Offline (stream_identity, decode + NAPA per frame): min 32 1.82 -> 1.28 ms, min 22 2.50 -> 1.83 ms
(Swyft capture). Live, lit, Swyft 120 fps, same PV session, 9 s each (`tests/systemcore-native-camera/scale-cpu.sh`):

| min tag | SpectrumCamera thread, scale 1 -> 2 |
|---|---|
| 32 | 26.2 -> 25.3, 25.8 -> 24.6 (reverse order) |
| 22 | 33.4 -> 33.1 |

Latency equal. So half scale is no longer a cost, but it saves ~1 point of a core at best (and loses the 32-43 px
band at min 32): the live per-frame cost is not the decode + NAPA share the offline numbers suggest. Removed
entirely the same day (Allen): no scale input, health topic, environment option or native code path remains.

