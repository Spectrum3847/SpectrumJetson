# Field replay: TXMAN1 matches, detector settings against ground truth

Data: 6 TXMAN1 recordings from FM (team 8515) with our Jetson: Q17, Q19, Q24, Q27 (Friday), Q32 and
"Test r19" (Saturday). That's 54k frames from orin-left and orin-right at 1280x800 with a 5 ms
exposure, plus each match's AdvantageKit log. Each detector variant replayed through `far_replay`
on the Jetson GPU (2026-10-31). The base is what runs now: mwbd 20, mse 10, far search off, each
camera's calibration from `session.json`. The base finds 38,489 sightings (camera x frame x tag).

Run: `tests/field-replay/run.sh` on the Jetson. It replays one session at a time at nice 19, and
waits for tj < 85 C before each replay. Full report: `/data/scratch/txman1/replay/report.txt`.

## Ground truth, and how far to trust it

Each sighting is checked in up to three ways:

1. **In-frame.** Solve the camera's pose (SQPnP) from the *other* tags in the same frame, then
   reproject this tag's corners. This doesn't depend on the robot's pose. It covers 49% of base
   sightings (the frame needs 2+ other tags, or 1 of 40+ px).
2. **Shape.** Compare the corners, minus their mean, with the outline the robot pose predicts.
   Pose error affects this only weakly.
3. **Robot pose.** The logged fused pose, placed with odometry for the short-term motion, plus the
   camera mount (see below), calibration and field layout. Used as a gross check only.

Reference set: sightings 50+ px from the edge, 30+ px across, margin 50+, robot still. **Bad**
means above the reference set's p95: in-frame error > 20.4 px, or shape error > 11.4 px, or total
error > 709 px. The in-frame error has median 1.3 px and p90 8.5 px.

**Caveat: the robot pose is a weak reference.** With the best mount, the median corner error with
the robot still is 5–25 px. Moving, it is 45–130 px, which is the fused pose lagging or jumping.
Q19's pose is unusable (300+ px). Q24 is borderline (32/45 px), so both are excluded from the
robot-pose checks. So the robot-pose "bad" labels (12.9% of sightings) are mostly pose error. They
rise with speed and turn rate, and in-frame error doesn't. **Trust the in-frame numbers**
(4.6% bad), and use the robot-pose counts only as a cross-check.

## 1. Timing and the half pixel

**Time shift.** Method: each tag's motion between consecutive recorded frames (33 ms apart),
compared with the motion odometry predicts. A constant pose error cancels in this difference.

| Match | orin-right best shift | orin-left best shift |
|---|---|---|
| Q17 | +9.0 ms | +5.0 ms |
| Q24 | +10 (wide scan: +14) | +9.0 |
| Q27 | +9.0 | 0 |
| Q32 | +3.5 | +9.5 |
| r19 | −5 | 0..+6 |

Q19 is excluded (its pose is bad). The shifts cluster at **about +5 to +9 ms**: the frames'
`robot_us` sits ~5–9 ms earlier than odometry's clock says the image happened. That covers half
the exposure (2.5 ms) plus time-sync and odometry-log latency. Time sync is not off by tens of
ms: the ±60 ms scans agree with the fine scans.

The minimum is shallow. The residual improves only 1–5% (9.8 → 9.7 px), so treat this as weak
evidence. A deliberate spin test on the bench (a still tag, a gyro-logged turn) would pin it down.

**−0.5 px.** Not measurable here. With and without the shift, the robot-pose error differs by
<0.4 px against 50–120 px of pose noise. A uniform 0.5 px shift is also absorbed by the in-frame
solve.

The 2026 recordings' PhotonVision used the raw 971 convention (no shift). `far_replay` reports
that same raw convention, so these replays match what ran at TXMAN1. Our current JNI (e405a0d,
2026-10-30) applies −0.5 for OpenCV, which is correct by construction (≈0.04° bias). The field data
neither confirms nor refutes it.

## 2. Detector settings

| Variant | Sightings | Lost vs base (good / bad / ?) | Gained (good / bad / ?) | Detect time |
|---|---|---|---|---|
| base (mse 10, mwbd 20, half-res, far off) | 38,489 | | | 3.1 ms |
| **mse 2.5** | 38,383 | 107 (48 / 26 / 33) | 1 (1/0/0) | 3.2 ms |
| mse 15 | 38,493 | 0 | 4 (0/1/3) | (6.4 ms, PV live) |
| mse 20 | 38,496 | 0 | 7 (1/1/5) | (6.4 ms, PV live) |
| mwbd 5 | 38,483 | 7 (6/1/0) | 1 | ~same |
| mwbd 10 | 38,483 | 7 (6/1/0) | 1 | ~same |
| mwbd 30 | 38,482 | 11 (7/1/3) | 4 (1/1/2) | ~same |
| min_cluster_pixels 50 | 38,489 (identical) | 0 | 0 | ~same |
| min_cluster_pixels 100 | 35,130 | 3,359 (3,043 / 156 / 160) | 0 | ~same |
| full-res search | 41,711 (+8.4%) | 1,278 (757/231/290) | 4,500 (3,585/482/433) | **11.0 ms** |
| far search on (default budget) | 40,217 (+4.5%) | 0 | 1,728 (1,306/232/190) | +1.7 ms/frame |
| 640x400 (2x downscale) | 22,384 (−42%) | 16,369 | 264 | 2.7 ms |

Detect times are from `far_replay` with the GPU shared with nothing, but at nice 19 with thermal
waits. Differences under ~0.5 ms are noise.

**max_line_fit_mse 10 vs 2.5.**
- It changes almost nothing. 2.5 drops 107 of 38,489 sightings (0.28%) and moves no corners on
  the rest (corner shift 0.000 px).
- **The 107 it drops are mixed, not clearly bad.** In-frame: 32 checkable, 2 bad, median in-frame
  error 6.2 px (typical: 1.3 px). They are worse than average but mostly usable.
- Robot-pose labels: 48 good, 26 bad, 33 unknown.
- Where the bad ones are:
  - Edge 0–10 px: 15 (1 good / 9 bad).
  - Close, large tags (side > 60 px): 47 (7 good / 24 bad).
  - Mid-image, mid-size: 71 (44 good / 6 bad).
- What it buys: about 20 bad sightings removed per 6 matches. The cost is ~50 good ones and a few
  cut-off ones.

**max_line_fit_mse 15 / 20 (2026-10-31).** Going above 10 does nothing useful.
- Nothing is lost and no corner moves on the 38,489 shared sightings (shift 0.000 px).
- mse 15 adds 4 sightings (0 good / 1 bad / 3 unknown); mse 20 adds 7 (1 / 1 / 5). Only one
  of them can be checked in-frame (10.6 px error, vs 1.3 px typical).
- All are close, large tags (side 98–500 px, range 0.8–1.55 m), mid-image, margin 30–100. No
  far/small tags are gained: smallest good side (p1 18.5 px) and range (p99 7.73 m, max 9.24 m)
  are unchanged.
- Detect time 6.0–6.6 ms/frame for both, but these ran with PhotonVision live on 2 cameras and
  throttled clocks; base's 3.1 ms was measured on an idle GPU. Not a real difference.
- **Keep 10.** 10 is already past the point where the line-fit test rejects anything that matters.

**Edge filter (AOS style) on the base output:**

| Border N | Removed | good / bad / ? (robot pose) | In-frame: checked / bad / median error |
|---|---|---|---|
| 5 px | 980 (2.5%) | 856 / 61 / 63 | 153 / 11 / 5.3 px |
| 10 px | 1,878 (4.9%) | 1,657 / 113 / 108 | 255 / 17 / 5.5 px |
| 25 px | 2,592 (6.7%) | 2,108 / 248 / 236 | 593 / 29 / 5.0 px |
| 50 px | 4,175 (10.8%) | 3,059 / 512 / 604 | 1,282 / 52 / 4.0 px |

The sightings away from the edge have a median in-frame error of 1.2–1.3 px. So tags near the edge
are measurably less accurate (4–5.5 px median), but 85–95% are still within the "good" threshold.
A 50 px border (AOS's, at their lower resolution) throws away 11% of sightings to remove ~12% of
the bad ones. That's no better than chance.

**The others:**
- **min_white_black_diff 5–30:** no effect (±10 sightings). Keep 20.
- **min_cluster_pixels:** 50 is identical to 24. 100 loses 3,359 mostly good sightings (small
  tags). Keep 24.
- **Full-res search:** +3,585 good sightings, but 3.5x the detect time (11 ms/frame, too slow for
  live use). It also loses 1,278 that half-res finds. The in-frame error of the full-res-only finds
  is good (median 1.18 px).
- **Far search (default budget):** gets ~40% of full-res's gain (+1,306 good, in-frame median
  0.95 px) for +1.7 ms/frame, and loses nothing. Keep it on.
- **640x400 vs 1280x800:** loses 42% of sightings. Range: the smallest tag found is 22 px (full-frame
  px) against 18.5 px. The single-tag-solve distance p99 is 7.1 m against 7.7 m, and the farthest is
  7.2 m against 9.2 m. Corners on the common tags move 0.27 px rms (median). Not worth the 0.4 ms.

## 3. Robot-side gates

These use in-frame labels: 18,936 sightings, 4.6% bad. Each gate is listed with the fraction of
good and bad sightings it rejects.

| Gate | Good rejected | Bad rejected | Verdict |
|---|---|---|---|
| Decision margin 50 (AOS) | 8.0% | 14.7% | weak |
| Decision margin 80 | 45% | 56% | weak |
| \|yaw rate\| > 1.6 rad/s (FM) | 5.9% | 3.9% | rejects **more good than bad** |
| \|yaw rate\| > 3.5 | 0.1% | 0% | |
| Robot speed | | | no separation at any threshold |
| Single-tag reprojection error | 2.2% at 0.5 px | 2.9% | no separation |
| Ambiguity | | | worse than chance |
| Distance | | | weak (J ≤ 0.03) |
| Tag side < 20 px | 2.7% | 8.1% | best of a weak lot (J 0.05) |
| Edge distance | | | no separation |

- **No single gate separates bad detections well** (best Youden J 0.11). Nothing in these
  features predicts the ~5% of in-frame-bad sightings.
- **The detections don't get worse with motion.** In-frame median error by \|yaw rate\| 0–0.5 /
  0.5–1.6 / 1.6–3 / 3–5 rad/s: 1.23 / 1.38 / 1.74 / 1.87 px, with p90 flat at 6–10 px. By speed it
  is flat (1.0–1.4 px).
- What grows with motion is the robot-pose error (total median 44 → 179 px). That's pose and
  timing, not detection.
- So **FM's 1.6 rad/s yaw-rate gate costs good data and catches nothing the detector got wrong.**
  Raise it to 3.5 rad/s (review item C2), or drop it for the Orin. If a gate is kept, it's to
  protect against the timestamp/pose-lag effect from item 1, not blur.

## 4. Camera setup

- **Exposure / blur:** `exposure_time_absolute` is 50 (5 ms) on both cameras in all matches. Up to
  3–5 rad/s and 3+ m/s, the in-frame error doesn't grow (item 3), so the 5 ms exposure is fine at
  these speeds.
- **Mounts:** solved from the data, one per camera per match. The robot code's CAD mount fits far
  worse than the solved one (still-robot median 43–245 px vs 5–25 px).
  - **orin-left** is consistent across matches: x 0.03–0.20, y 0.29–0.32, z 0.45–0.53 m,
    roll +0.5–2.4°, pitch −16.6 to −18.5°, yaw 83.7–87.2°.
  - So against the code's CAD mount (yaw 90°, pitch −18°), **yaw is ~3–6° off** and roll is
    +1–2°.
  - **orin-right** solves sanely only in Q17 (pitch −18.9°, yaw −87.0°) and Q32 (−24.6°, −85.1°).
    Elsewhere it trades mount for pose error, and a joint solve didn't converge.
  - Pitch moved between Friday and Saturday (−18.9 → −24.6°), consistent with the review's −21°
    (F7). The right camera was probably re-aimed or knocked. Re-measure both mounts before the next
    event. The code's yaw −84.5° for the right camera is closer than its 90° for the left.
- **Field:** AndyMark fits Q17/Q19/Q24/Q27 slightly better, welded fits Q32/r19 slightly better.
  The differences (≤1.5 px, plus 10 px in r19-left) are within the pose noise. **Inconclusive**:
  this data can't tell the two layouts apart.
- **640x400:** see item 2. Keep 1280x800.

## Recommendations

1. **Keep max_line_fit_mse at 10.** 2.5 removes 0.28% of sightings, of which only a minority are
   bad (in-frame: 2 of 32 checkable). It changes nothing else. 15 and 20 add only 4 / 7
   close-tag sightings (0–1 good) and no range.
2. **No AOS-style edge filter.** At 10/25/50 px it removes 5/7/11% of sightings, 85–90% of them
   good. If anything, a 5–10 px border trims the least accurate (median in-frame error 5 px vs
   1.3), but it isn't needed.
3. **Keep mwbd 20, min_cluster_pixels 24, half-res + far search on, 1280x800.**
4. **Robot side:** for the Orin, drop the 1.6 rad/s yaw-rate gate or raise it to ≥3.5. Re-measure
   the camera mounts: left yaw is ~4° off, right pitch is −19 to −25°.
5. **Timing:** frames look ~5–9 ms early against odometry. Confirm with a bench spin test before
   compensating.
