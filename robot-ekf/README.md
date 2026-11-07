# robot-ekf: the robot's TagEkf, runnable here

The 2026-FM-SystemCore `TagEkf` as a stand-alone WPILib Java library (same WPILib 2027.0.0-alpha-8 and Java 25 as
the robot), with two drivers:

- **Replay** on the laptop: TXMAN1 frames → NAPA (min tag 22) → full-tag fit → TagEkf, with the match's logged
  odometry. Runs variants side by side.
- **Bench** on the SystemCore / Pi 5: PhotonVision over NT4 (both cameras, native NAPA path, tagfit on, min tag 22)
  → TagEkf, stationary, with zero odometry and a fixed gyro.

## Source

Copied unchanged from `Spectrum3847/2026-FM-SystemCore`, branch **`origin/tagekf-replay-tuner`** at `47f14a9`. The
TagEkf there was last changed in `48e0b78` (2026-11-03, "TagEkf noise re-tune; measured Orin mounts in config").
This is the newest TagEkf on any branch: `origin/2027-Restructure` has the same file. `check-ns-replay-merge`
(`827a91a`) still has the 2026-10-17 version (`465a2c3`). Port changes back by hand; don't commit to that repo.

| here | there |
|---|---|
| `src/main/java/frc/spectrumLib/localization/{TagEkf,TagSighting,CornerSighting,MountEstimator,OdometryGuard}.java` | same path |
| `src/test/java/frc/spectrumLib/localization/{TagEkfTest,TagEkfSmootherTest,MountEstimatorTest,OdometryGuardTest}.java` | same path |

The newer version already has several of the items evaluated below:

- re-tuned noise: bearing 0.25°, range 0.005 + 0.005·r² m, timing 0.625 ms (it was 1°, 0.02 + 0.01·r², 5 ms);
- `addCornerFrame` (corner reprojection), `MountEstimator` (online mount yaw and pitch);
- the tilt policy (tags are skipped only above 20°, and their noise is scaled from 5° to 20°);
- self-checking uncertainty (`setAdaptive`).

`./gradlew test` runs the copied tests (25 pass).

## How to run

```
cd robot-ekf
./gradlew test

# replay, stage 1 (Docker on the laptop): sightings per camera recording, NAPA + fitted corners and both IPPE poses
replay/detect.sh docker ~/build/txman1 OUT/dets              # deployed calibrations
CAL=-refit replay/detect.sh docker ~/build/txman1 OUT/dets-refit
# odometry and Limelight MT1 poses from the match logs (2026-FM-SystemCore tools/export_tagekf_events.py, tagekf-replay-tuner)
python export_tagekf_events.py akit_..._q17_ns.wpilog akit_..._q24_ns.wpilog   # copies of the logs: it writes beside them
# replay, stage 2: every variant (or --variants a,b), per match or pooled
./gradlew replay -Pargs="--dets OUT/dets-refit --cal -refit --logs LOGDIR [--matches Q17] [--variants fit,c-mount-at-capture]"
#   -Pdiag=true: corner residuals against the estimate; -Ptrace=Q17:fit: the estimate against MT1 once a second

# bench (from the laptop): build, copy to ~/tagekf on the target, run under /tmp/camera.lock
robot-ekf/bench.sh --seconds 40 --survey 5            # [--bearing-deg D] [--range BASE,PER] [--timing-ms MS]
# bench, recorded sightings with other noise settings (laptop)
java -cp build/classes/java/main:<wpimath jars> org.spectrum3847.tagekf.BenchEkf file tags.csv --bearing-deg 0.05
# bench A/B of PhotonVision's fit (on the target): off / SPECTRUM_TAGFIT_MAX_CELL=4 / on, then back to on
flock -n /tmp/camera.lock ~/tagekf/bench-ab.sh 30
```

On the bench, `BenchEkf` runs next to the robot program, not in it. It is its own NT4 client of the robot's NT
server, launched with the robot's WPILib jars and natives (`~/wpilib`). The robot program
(`DIYsystemcore-TestRobot`, which logs `can_s0` status), its CAN setup and `robot.service` are not touched, so
there is nothing to restore.

## Data

- **TXMAN1 on this laptop:** Q17 and Q24 only (`~/build/txman1`). That is 60 s from each Orin camera per match,
  1280x800 at 30 fps: 3,818 frames with tags and 6,601 sightings. The other 11 sessions are on the Jetson.
- **Odometry:** the match logs (`2026-FM-SystemCore/logs/txman1-ns/*q17*`, `*q24*`). Module distances and angles
  and the gyro go through `OdometryGuard`, as on the robot.
- **Tilt:** these logs have no pitch or roll (no `T` events), so the tilt policy can't be exercised here.
- **Reference:** there is no ground truth. Two scores stand in for it:
  - **Held-out tags:** every 4th frame is never fed. Each of its tags is scored by its innovation against the
    smoothed estimate at capture time. It is measured with the fitted corners' pose, so every variant is scored on
    the same numbers. This is the same method as TagEkfTuner.
  - **Limelight MT1 multi-tag poses:** independent cameras, with their own error of several cm.
- **Lost:** an estimate more than 1 m from MT1.
- **Mounts:** the measured `orinRobotToCamera` from `48e0b78`.
- **Field:** AndyMark layout.
- **Seed:** the first MT1 pose.
- **Calibrations:** `calibrations/SJ-TC01` (orin-left) and `SJ-TC02` (orin-right), deployed or `-refit`.
- **Q24:** it has one stretch, about 236–243 s, where every variant loses lock for about 8 s. That stretch
  dominates Q24's p90, so Q17 is the cleaner comparison.
- **The robot is never still** for more than 0.5 s while the cameras record. Stationary noise therefore comes from
  the bench only.

## Results

### Bench (Pi 5, Thriftiest + Swyft, 120 fps, min tag 22, tagfit on, stationary, 30 s after a 5 s survey)

The truth is "doesn't move". The survey sets the bias to zero by construction, so only the scatter is measured.
Tags: thrifty 3 (0.77 m) and 10 (1.67 m); swyft 3 (0.82 m), 10 (1.76 m) and 11 (3.65 m).

| PhotonVision fit | pose std x / y mm | theta std deg | per-tag bearing std deg | per-tag range std mm (thrifty 3, 10 / swyft 3, 10, 11) | NIS | PV CPU (% of 1 core) |
|---|---|---|---|---|---|---|
| on (default) | 0.07 / 0.03 | 0.004 | 0.003–0.006 | 0.26, 1.09 / 2.35, 10.6, 12.6 | 0.00–0.11 | 81.0 |
| `SPECTRUM_TAGFIT_MAX_CELL=4` | 0.52 / 0.08 | 0.006 | 0.002–0.004 | 1.30, 2.58 / 5.93, 23.2, 32.1 | 0.01–0.50 | 71.6 |
| off | 0.17 / 0.04 | 0.003 | 0.002–0.003 | 1.25, 2.70 / 4.66, 21.0, 22.9 | 0.01–0.41 | 71.9 |

**Per-tag noise.** Still per-tag noise is about 50–100× below the EKF's configured noise (0.25°, 5 + 5·r² mm), so
NIS ≈ 0. Re-filtering the recorded sightings with the noise set to 0.05° or 1° gives the same 0.1 mm pose. Going
down to 0.01° starts gating out tags. Swyft's range is 5–10× noisier than Thriftiest's at the same distance.

### TXMAN1 replay

Columns:

- **held-out p50 / p90:** metres;
- **NIS:** 2 means the filter's uncertainty is honest;
- **MT1:** metres;
- **heading:** median |heading − MT1|, degrees;
- **fit µs/frame:** Pi 5 time, estimated from the per-cell-size table in FULL-TAG-REFINEMENT.md.

Q17, refit calibrations (the clean match):

| variant | held-out p50 / p90 | NIS | MT1 p50 / p90 | lost % | heading ° | fit µs/frame |
|---|---|---|---|---|---|---|
| old noise (1°, 0.02 + 0.01 r², 5 ms) | 0.092 / 0.210 | 1.30 | 0.182 / 0.346 | 1.1 | 6.2 | 0 |
| robot today, NAPA corners | 0.067 / 0.148 | 2.06 | 0.113 / 0.264 | 1.4 | 7.6 | 0 |
| + tagfit (`fit`) | 0.065 / 0.147 | 2.01 | 0.111 / 0.264 | 1.4 | 7.4 | 114 |
| deployed calibrations, `fit` | 0.065 / 0.236 | 3.11 | 0.109 / 0.325 | 3.9 | 5.4 | 111 |
| a: corners 8 px | 0.466 / 5.85 | 17.6 | 0.62 / 7.0 | 41 | 4.4 | 114 |
| a: corners 16 px | 0.201 / 4.82 | 10.9 | 0.23 / 5.1 | 26 | 5.7 | 114 |
| b: timing std 0.25 / 1 / 2 ms | 0.065 / 0.146–0.147 | 2.01–2.03 | 0.111–0.114 / 0.262–0.267 | 1.4 | 7.1–7.4 | 114 |
| b: capture time +8 ms | 0.062 / 0.146 | 1.83 | 0.103 / 0.244 | 1.3 | 6.2 | 114 |
| c: mounts fixed (measured) | 0.056 / 0.147 | 1.91 | 0.110 / 0.248 | 1.4 | 2.7 | 114 |
| **c: MountEstimator fed the pose at capture time** | **0.057 / 0.136** | **1.74** | 0.109 / 0.248 | 1.3 | **2.9** | 114 |
| c: bearing 0.1° | 0.066 / 0.157 | 2.80 | 0.111 / 0.254 | 1.4 | 7.5 | 114 |
| e: bearing 0.35° + pose at capture | 0.056 / 0.143 | 1.69 | 0.113 / 0.255 | 1.4 | 2.7 | 114 |
| e: range 0.002 + 0.002 r² | 0.063 / 0.136 | 2.80 | 0.106 / 0.255 | 1.3 | 7.9 | 114 |
| e: no self-checking (adaptive off) | 0.093 / 6.01 | 10.9 | 0.21 / 7.1 | 41 | 9.8 | 114 |
| g: fit only cells ≤ 4 px | 0.065 / 0.147 | 2.04 | 0.112 / 0.262 | 1.4 | 7.6 | 29 |
| g: fit only cells ≤ 6 px | 0.065 / 0.147 | 2.05 | 0.112 / 0.264 | 1.4 | 7.5 | 73 |

Q24 (refit), for the same rows. It is noisy, because the lost stretch dominates p90.

| variant | held-out p90 | MT1 p50 | lost % | heading ° |
|---|---|---|---|---|
| `fit` | 2.33 | 0.151 | 14.8 | 4.5 |
| MountEstimator pose at capture | 2.80 | 0.168 | 15.0 | **2.7** |
| bearing 0.5° | 0.88 | 0.149 | 14.2 | 6.2 |
| bearing 0.5° + pose at capture | **0.72** | 0.181 | 13.5 | **2.5** |
| bearing 0.1° | 8.09 | 0.258 | 39.8 | 7.4 |

### Corners against the estimate (`-Pdiag=true`, Q17, refit, pose at capture)

A tag's **shape** (corners about their own centre) agrees with the projection from the estimate to 0.5–1.1 px
median. The tag's **centre** is off by 12–16 px median and 35–50 px p90, which is about 1–1.4° of bearing. The
fitted corners are good to about 0.1 px, so the error left over is not in the detector. It is the pose, timing,
mounts and lens, and it is shared by all four corners of a tag. Treating the 8 coordinates as independent at 0.1–16
px is therefore wrong at any setting. With the deployed TC02 (orin-right) calibration, edge tags project
hundreds of px off. Its 8-coefficient model has no valid ray near the edges (calibrations/README.md), and that
alone made corners unusable there.

## Verdicts

| | item | measured | cost | verdict |
|---|---|---|---|---|
| a | corner reprojection instead of bearing and range | Much worse at every pixel std (0.1–16 px): held-out p90 4.8–19 m vs 0.15 m. The per-tag error is a shared 1–1.4° offset, not independent 0.1 px corners. | 8 rows and a numeric Jacobian per tag | **No.** Revisit only with a per-tag correlated error term (centre offset ~1° + shape ~1 px) and sane lens models. |
| b | tighter timing noise | 0.25–2 ms are identical. 5 ms is slightly worse on Q17. The timing term is tiny next to bearing noise. A capture-time offset of +4 to +12 ms helps Q17 a little (MT1 p50 0.111 → 0.103 m, NIS 2.0 → 1.8) but is mixed on Q24. | none | **Leave timing std at 0.625 ms.** Measure the latency offset on the bench with a spin test before changing timestamps. |
| c | mount yaw per camera / calibrate it out, then drop bearing noise | MountEstimator ≈ fixed measured mounts. **Feeding MountEstimator the pose at the frame's capture time** (`smoothedAt`) instead of the newest pose: heading vs MT1 7.4° → 2.9° (Q17) and 4.5° → 2.7° (Q24), held-out p90 0.147 → 0.136 (Q17). Bearing noise below 0.25° hurts: at 0.1°, Q24 is lost 40%. | one `smoothedAt` call per frame | **Yes to the capture-time fix** (port back). **No to lower bearing noise:** the bearing error isn't mount yaw. |
| d | use tilted frames with measured pitch and roll | Not testable here (no pitch or roll in Q17/Q24, and the bench has no IMU). The newer TagEkf already feeds tags up to 20° with scaled noise; on r19 that took lost from 11.9% to 0.3% (TagEkfTuner). | — | **Keep the existing policy.** Retest a 3-D tilt model with a log that has tilt. |
| e | noise from data | Bench detector noise is 50–100× below the settings, so the in-match budget is model error. With refit calibrations the current noise is honest on Q17 (NIS 2.0). With deployed ones it is too tight (NIS 3.1). Self-checking is essential: off, Q17 is lost 41%. Bearing 0.35–0.5° with the capture-time fix is as good or better (Q24 p90 2.3 → 0.7 m). | none | **Keep 0.25° / 0.005 + 0.005 r² until the recalibration.** Then re-run this replay; if NIS stays under 2 on more matches, raise bearing to 0.35–0.5°. |
| f | skip multi-tag, the second solution and the ambiguity check | Multi-tag is already off in both pipelines (`doMultiTarget false`). IPPE gives both solutions from one closed-form solve; ambiguity is a ratio. The EKF uses only the best translation (+ corners for MountEstimator). | microseconds | **Not worth a fork change.** |
| g | skip the fit on close tags (`SPECTRUM_TAGFIT_MAX_CELL`) | EKF unchanged in replay at max cell 4 / 6 / 9. Fit time per frame on the Pi falls 114 → 29 / 73 / 93 µs (31 / 64 / 83% of tags fitted). Bench: the fit costs 9 points of a core at 2 × 120 fps (81.0 vs 71.9%); max cell 4 removes it (71.6%), since the bench tags are bigger. On the bench the fit cuts range scatter 2–5×, but the stationary pose is 0.07 vs 0.17 mm either way. | env var | **Optional.** The fit's EKF gain doesn't show in matches. Set `SPECTRUM_TAGFIT_MAX_CELL=4` if CPU is needed; keep the fit on otherwise (still targets, calibration). |
| h | drop excluded or out-of-range (0.2–8 m) tags before decode and fit | 1.1–1.9% of sightings are out of range; their fit is ~1–2 µs/frame on average. The ID is only known after decode, so only the fit can be skipped. No tags are excluded at FM. | trivial | **Low value.** Do it only as tidiness (before the fit). |
| i | predicted search windows + full scan every Nth frame | Estimate: decode must still cover the whole MJPEG frame, so only NAPA's share shrinks. With ~20% of the frame searched and a full scan every 8th frame, NAPA work falls ~60–70%, about 10–20% of PV CPU. Risks: a new tag is late by up to N frames; tags are missed when the pose is wrong (relocalization, the Q24 stretch), so detection depends on the estimate it feeds. | weeks; NAPA ROI support | **Not now:** PV uses 72–81% of one of 4 cores. Revisit if CPU binds. |
| j | adaptive frame rate from speed and odometry | The robot is never still for more than 0.5 s in the recorded match windows, so there are few slow periods to save on. It doesn't help the EKF. | moderate | **Later.** Tie it to the multi-camera plan. |
| k | publish corners only | The EKF needs the per-tag translation (bearing and range) because (a) lost; MountEstimator needs the corners. A result is about 0.6 KB per tag over loopback. | fork + robot change | **No.** |

## Recommended order

1. **Camera calibrations: deploy the `-refit` files** (TC01/TC02) on the cameras. This was the biggest replay gain:
   Q17 held-out p90 0.236 → 0.147 m, NIS 3.1 → 2.0. Corners are unusable with the deployed TC02 model. This is a
   camera-side change: PV's calibration, which the robot reads over NT.
2. **MountEstimator on the pose at capture time:** robot side, port back.
3. Recalibrate, then re-run this replay (and TagEkfTuner on more logs) before touching the noise. If NIS stays under
   2, raise bearing to 0.35–0.5°.
4. Optional CPU: `SPECTRUM_TAGFIT_MAX_CELL=4` in PhotonVision's environment.
5. A bench spin test to pin the capture-time offset (b) before changing timestamps.

### Port back to 2026-FM-SystemCore (by hand)

- `Vision.feedTagEkf`: pass the pose at the result's capture time to the mount estimator:

  ```java
  double[] sm = ekf.smoothedAt(r.getTimestampSeconds());
  Pose2d atCapture = sm == null ? ekf.getPose() : new Pose2d(sm[0], sm[1], new Rotation2d(sm[2]));
  mountEstimator.update(atCapture, corners);
  ```

  Do the same in `TagEkfTuner`, which also passes `ekf.getPose()`.
- Nothing else. The TagEkf sources here are unchanged copies.

## Files

- `replay/detect.sh`: stage 1. It uses `native/sc-vision/tools/tagfit_bench replay --dump`, which this branch adds.
- `src/main/java/org/spectrum3847/tagekf/TxmanReplay.java`: stage 2, the variants, the scores.
- `BenchEkf.java`, `PhotonResult.java`: the bench driver, and the fork's `PhotonPipelineResult` decoder (no
  PhotonLib).
- `bench.sh`: the bench runner, run from the laptop.
- `bench-ab.sh`: the PV fit A/B, run on the target.
