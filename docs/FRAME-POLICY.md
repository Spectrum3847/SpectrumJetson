# Per-camera frame policy: decode scale and frame skipping

Status 2026-11-06: implemented in sc-vision and in the PhotonVision fork's fast path (photonvision-113). CPU was
measured on the bench for sc-vision. Detection and pose quality at 1/2 and 1/4 were only partly measured, on the
Thriftiest, before the bench went dark (see "Measured").

## What it does

The camera always streams 1280x800 MJPEG; the UVC mode never changes. For each frame, at its start (before any
decoding), each camera decides:

- **skip**: the frame is not decoded at all, which costs almost nothing;
- **full** (1/1) or **half** (640x400): mjdec still decodes all of the Huffman data, but at half scale it
  reconstructs each 8x8 block at 4x4 pixels from its lowest coefficients (a reduced IDCT). NAPA runs on that smaller
  image with min tag / 2. Corners go back to full-res pixels (x = 2 x' + 0.5, pixel centres at integers), and the
  pose uses the full-res calibration.

**The policy is full or 1/2 scale plus skipping; never 1/4 or 1/8** (user decision, 2026-11-06). At 1/4 the decode
is no faster than at 1/2 (1.21 vs 1.22 ms: the Huffman decoding is the floor). It saves only about 0.6 ms of NAPA
and loses the smallest tag. Skipping saves far more without losing range. The 1/4 and 1/8 code paths stay as
internal test options only (`mjdec_set_scale`, sc-vision `--scale 4`, PhotonVision `SPECTRUM_POLICY_SCALE=4`). The
robot's `scale` input accepts only 1 or 2; any other value is ignored.

Full scale is bit-identical to before: same decoder path, same results.

## NetworkTables inputs (the robot publishes; all optional)

Under `/photonvision/<camera>/input/`, integers. A value that is missing or <= 0 means "use the default".

| Topic | Values | Default | Meaning |
|---|---|---|---|
| `scale` | 1, 2 | 1 | Decode scale of processed frames (anything else is ignored) |
| `fullEvery` | N >= 0 | 0 | Every Nth processed frame at full scale anyway (0: never forced) |
| `processEvery` | N >= 1 | 1 | Process 1 frame in N; the others are skipped at their start |

With nothing published, every frame is processed at full resolution, exactly as before. Defaults when the robot
publishes nothing can also be set per process:

- sc-vision: `--scale`, `--full-every`, `--every`.
- PhotonVision: `SPECTRUM_POLICY_SCALE`, `SPECTRUM_POLICY_FULL_EVERY`, `SPECTRUM_POLICY_PROCESS_EVERY`.

In PhotonVision, scale and skipping apply only while nobody watches that camera's stream (the image copy is off).
A frame the Java pipeline asks for that was skipped or decoded small is decoded by Java itself. The health topic
`fps` reports the processed rate.

## Proposal for the robot code (2026-FM-SystemCore, not committed there)

One small subsystem publishes the three knobs for each camera from what the robot knows:

- **Tags predicted close** (odometry + field map + the camera's pose and field of view; closer than about 2 m,
  where a tag is at least 2 x min tag at half scale): `processEvery 1`, `scale 2`.
- **Far tags predicted, or the robot fast or turning hard** (small tags, motion; the pose matters most):
  `processEvery 1`, `scale 1`.
- **No tag predicted for this camera**: `processEvery 4` at `scale 1`, or `scale 2` if only close tags could appear,
  so a surprise tag is still seen within about 33 ms.
- **Disabled, or the code doesn't know**: publish nothing (or 1/0/1), which gives the defaults.

Each camera reads only its own topics, so a role can differ by camera, for example a far-looking camera at full
scale and a near one at half.

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
