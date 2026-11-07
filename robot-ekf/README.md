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

# every TXMAN1 match with Orin video (14), fetched from robotlog.spectrum3847.org: fetch, export, detect, replay
robot-ekf/replay/batch.sh [~/build/txman1-all]     # -> DATA/results/{deployed,refit}{,-clean}.txt, replay.csv, tables.md

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

- **All TXMAN1 matches (`replay/batch.sh`):** `~/build/txman1-all` on the laptop, never in git. Every match with
  Orin video on robotlog.spectrum3847.org (public read API `/api/v1/matches`, files at `/api/files/<id>/raw`;
  `replay/fetch_robotlog.py`): Q17, Q19, Q24, Q27, Q30, Q32, Q34 and the Saturday FMS runs r4–r20, every session
  and every 5-min file, both cameras. Videos and wpilogs are deleted once detected and exported (~10 GB; the disk
  had 16 GB free); `dets/`, `dets-refit/`, `logs/*.tagekf.txt` and `results/` stay (KEEP_VIDEO=1 keeps all). Q19
  has two robot logs (a reboot before the match): sessions are paired with logs by `robotOffsetUs`, so only
  session 0005 and `15-22-45_txman1_q19` are used. Q1–Q13 have no Orin video.
- **The first replay (sections below):** Q17 and Q24 only (`~/build/txman1`). That is 60 s from each Orin camera per match,
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

### TXMAN1 replay, every match (`replay/batch.sh`, 2026-11-06)

14 matches, 83 recordings per calibration, 72,849 sightings, 10,871 held-out tags. Defaults now match the robot at
2026-FM-SystemCore `aeca58c`: MountEstimator gets the pose at capture time (`fit`, `napa`); `*-newest` is the robot
before it. `fit`/`napa`: PhotonVision's full-tag fit on/off. "clean" leaves out r13 and r19 (below), whose lost
stretches swamp every pooled p90. Lost % is the share of MT1 samples more than 1 m away. Heading is pooled over
Q30, whose MT1 heading is ~167° off for every variant while positions agree (a Limelight heading convention in
that log, not the EKF).

| calibration | variant | held-out p50 / p90 m | NIS | MT1 p50 / p90 m | lost % | heading ° | relocalizations |
|---|---|---|---|---|---|---|---|
| deployed | `fit-newest` | 0.062 / 0.693 | 5.17 | 0.221 / 11.349 | 21.7 | 4.3 | 21 |
| deployed | `fit` | 0.057 / 0.497 | 4.71 | 0.188 / 11.316 | 21.6 | 3.6 | 22 |
| deployed | `napa` | 0.058 / 0.502 | 4.74 | 0.189 / 11.333 | 21.8 | 4.0 | 22 |
| deployed | `a-corners-8.0px` | 0.879 / 12.715 | 25.39 | 1.418 / 20.778 | 54.0 | 5.1 | 232 |
| deployed | `c-bearing-0.1` | 0.059 / 0.657 | 5.59 | 0.198 / 11.286 | 22.4 | 3.8 | 22 |
| deployed | `e-bearing-0.5-at-capture` | 0.057 / 0.488 | 4.22 | 0.197 / 11.274 | 21.5 | 3.7 | 20 |
| deployed-clean | `fit-newest` | 0.060 / 0.349 | 3.88 | 0.174 / 0.829 | 8.5 | 5.2 | 10 |
| deployed-clean | `fit` | 0.054 / 0.293 | 3.34 | 0.147 / 0.815 | 8.5 | 4.0 | 11 |
| deployed-clean | `napa` | 0.057 / 0.289 | 3.36 | 0.147 / 0.829 | 8.7 | 4.5 | 11 |
| deployed-clean | `a-corners-8.0px` | 0.812 / 9.973 | 24.96 | 0.802 / 9.521 | 47.1 | 5.1 | 191 |
| deployed-clean | `c-bearing-0.1` | 0.058 / 0.341 | 4.31 | 0.158 / 0.926 | 9.4 | 4.4 | 11 |
| deployed-clean | `e-bearing-0.5-at-capture` | 0.055 / 0.282 | 2.81 | 0.156 / 0.805 | 8.2 | 4.1 | 9 |
| refit | `fit-newest` | 0.062 / 0.409 | 4.81 | 0.226 / 11.425 | 21.4 | 4.1 | 18 |
| refit | `fit` | 0.060 / 0.401 | 4.65 | 0.216 / 11.373 | 21.5 | 3.9 | 18 |
| refit | `napa` | 0.062 / 0.427 | 4.76 | 0.221 / 11.412 | 21.9 | 3.9 | 20 |
| refit | `a-corners-8.0px` | 0.526 / 12.726 | 24.05 | 0.734 / 15.270 | 45.0 | 5.0 | 195 |
| refit | `c-bearing-0.1` | 0.060 / 0.564 | 5.50 | 0.201 / 11.738 | 22.7 | 4.3 | 26 |
| refit | `e-bearing-0.5-at-capture` | 0.056 / 0.281 | 3.65 | 0.198 / 11.353 | 21.4 | 3.3 | 19 |
| refit-clean | `fit-newest` | 0.060 / 0.271 | 3.51 | 0.181 / 0.810 | 8.2 | 5.0 | 7 |
| refit-clean | `fit` | 0.058 / 0.247 | 3.31 | 0.167 / 0.813 | 8.2 | 4.5 | 7 |
| refit-clean | `napa` | 0.060 / 0.258 | 3.44 | 0.173 / 0.860 | 8.8 | 4.5 | 9 |
| refit-clean | `a-corners-8.0px` | 0.470 / 11.164 | 23.53 | 0.505 / 8.377 | 36.4 | 4.9 | 158 |
| refit-clean | `c-bearing-0.1` | 0.058 / 0.264 | 4.26 | 0.155 / 0.978 | 9.9 | 5.1 | 15 |
| refit-clean | `e-bearing-0.5-at-capture` | 0.053 / 0.191 | 2.18 | 0.155 / 0.790 | 8.1 | 3.7 | 8 |

Per match: held-out p50 / p90 m, NIS, median heading error vs MT1, lost %, relocalizations.

| match | held-out tags | robot before aeca58c, deployed cal | -refit | -refit + mount at capture | same, fit off |
|---|---|---|---|---|---|
| Q17 | 971 | 0.062 / 0.246, 2.33, 10.5°, 1.1%, 0 | 0.059 / 0.177, 1.73, 10.3°, 0.8%, 0 | 0.056 / 0.170, 1.52, 6.5°, 0.8%, 0 | 0.065 / 0.213, 2.09, 6.8°, 0.9%, 0 |
| Q19 | 720 | 0.058 / 0.202, 3.10, 5.5°, 30.2%, 1 | 0.056 / 0.179, 2.84, 6.0°, 30.4%, 1 | 0.054 / 0.152, 2.41, 5.4°, 30.4%, 1 | 0.053 / 0.151, 2.36, 5.6°, 30.4%, 1 |
| Q24 | 1037 | 0.062 / 0.411, 4.56, 3.1°, 13.8%, 2 | 0.056 / 0.192, 3.66, 2.4°, 12.9%, 2 | 0.058 / 0.192, 3.55, 3.0°, 13.2%, 2 | 0.058 / 0.196, 3.67, 3.1°, 14.8%, 2 |
| Q27 | 743 | 0.051 / 0.320, 2.31, 3.6°, 3.0%, 0 | 0.052 / 0.149, 1.13, 3.8°, 2.4%, 0 | 0.051 / 0.149, 1.19, 2.3°, 2.6%, 0 | 0.051 / 0.155, 1.58, 2.4°, 5.4%, 1 |
| Q30 | 1303 | 0.063 / 1.295, 4.91, 166.8°, 10.2%, 5 | 0.059 / 0.212, 4.10, 166.3°, 9.4%, 2 | 0.059 / 0.214, 4.05, 167.2°, 9.4%, 2 | 0.060 / 0.264, 4.19, 167.1°, 10.0%, 3 |
| Q32 | 1702 | 0.101 / 0.800, 6.90, 9.1°, 3.8%, 0 | 0.106 / 0.945, 7.42, 6.5°, 3.4%, 0 | 0.103 / 0.836, 7.06, 8.5°, 3.4%, 0 | 0.105 / 0.858, 7.20, 9.2°, 3.8%, 0 |
| Q34 | 522 | 0.034 / 0.159, 1.56, 4.1°, 7.6%, 1 | 0.038 / 0.181, 1.58, 3.9°, 8.3%, 1 | 0.030 / 0.142, 1.20, 5.0°, 7.8%, 1 | 0.031 / 0.140, 1.18, 4.4°, 7.8%, 1 |
| r4 | 342 | 0.037 / 0.146, 2.56, 1.8°, 2.8%, 0 | 0.038 / 0.144, 2.16, 2.1°, 2.1%, 0 | 0.042 / 0.141, 2.30, 2.4°, 2.8%, 0 | 0.040 / 0.142, 2.30, 2.3°, 2.8%, 0 |
| r7 | 675 | 0.059 / 0.297, 3.05, 4.5°, 1.2%, 0 | 0.056 / 0.237, 2.39, 4.9°, 1.2%, 0 | 0.049 / 0.190, 1.65, 1.8°, 1.2%, 0 | 0.048 / 0.191, 1.68, 1.8°, 1.2%, 0 |
| r10 | 675 | 0.057 / 0.171, 2.46, 4.0°, 1.9%, 1 | 0.063 / 0.154, 1.92, 3.7°, 1.6%, 1 | 0.059 / 0.143, 2.02, 2.5°, 1.9%, 1 | 0.061 / 0.141, 2.01, 2.5°, 1.9%, 1 |
| r13 | 433 | 0.042 / 6.027, 4.08, 6.2°, 49.1%, 5 | 0.046 / 6.260, 3.77, 5.7°, 49.1%, 5 | 0.043 / 6.931, 3.66, 5.3°, 49.4%, 5 | 0.043 / 6.800, 3.65, 5.6°, 49.2%, 5 |
| r16 | 552 | 0.038 / 0.243, 2.53, 4.2°, 6.1%, 0 | 0.041 / 0.277, 3.02, 3.2°, 5.4%, 0 | 0.039 / 0.296, 3.05, 4.1°, 5.5%, 0 | 0.039 / 0.290, 2.77, 4.1°, 5.3%, 0 |
| r19 | 1157 | 0.151 / 49.267, 16.00, 1.4°, 59.5%, 6 | 0.138 / 49.383, 15.69, 1.4°, 59.4%, 6 | 0.150 / 49.339, 15.83, 1.5°, 59.4%, 6 | 0.147 / 49.336, 15.82, 1.5°, 59.4%, 6 |
| r20 | 39 | 0.065 / 0.155, 1.76, 1.4°, 2.4%, 0 | 0.069 / 0.148, 1.85, 1.4°, 2.4%, 0 | 0.063 / 0.141, 1.63, 0.9°, 2.4%, 0 | 0.070 / 0.141, 1.67, 0.9°, 2.4%, 0 |
| **pooled** | 10871 | 0.062 / 0.693, 5.17, 4.3°, 21.7%, 21 | 0.062 / 0.409, 4.81, 4.1°, 21.4%, 18 | 0.060 / 0.401, 4.65, 3.9°, 21.5%, 18 | 0.062 / 0.427, 4.76, 3.9°, 21.9%, 20 |

**Do the Q17/Q24 conclusions hold?**

- **`-refit` helps: yes, pooled.** Clean held-out p90 0.349 → 0.271 m and NIS 3.88 → 3.51 (robot before
  `aeca58c`). It is the big gain on Q24, Q27 and Q30 (p90 0.41 → 0.19, 0.32 → 0.15, 1.30 → 0.21 m). It is slightly
  worse on Q32, Q34 and r16 (p90 +0.02–0.15 m).
- **The capture-time mount fix helps: yes, pooled.** Refit, clean: p90 0.271 → 0.247 m, NIS 3.51 → 3.31, MT1 p50
  0.181 → 0.167 m. Heading improves in Q17 (10.3° → 6.5°), Q27, r7 (4.9° → 1.8°), r10 and r20. It is worse in
  Q32 (6.5° → 8.5°), Q34 and r16. Q32 and Q34 are the matches where `-refit` didn't help either.
- **Corner reprojection is worse: yes, everywhere.** At 8 px: clean held-out p90 11 m, lost 36–47%,
  158–191 relocalizations against 7–11.
- **Lower bearing noise gets lost: yes.** At 0.1°: clean lost 9.9% vs 8.2%, relocalizations 15 vs 7, NIS 4.3.
- **The fit:** on is a little better than off (clean p90 0.247 vs 0.258 m, NIS 3.31 vs 3.44).
- **New: the noise is too tight beyond Q17.** NIS is 2–7 on most matches at 0.25°. Bearing 0.5° plus the
  capture-time fix is the best row in every pool: clean p90 0.191 m, NIS 2.18, heading 3.7°. That is the step
  "raise bearing to 0.35–0.5°" in the recommended order, now on 12 matches. 0.35° is not enough (NIS 3.3).

**Matches that behave differently:**

- **r19** (59% lost, p90 49 m, every variant): no frames with tags reach the filter after ~262 s, though both
  cameras record until 395 s. Meanwhile the logged odometry runs off by tens of metres. This is a data or robot
  fault, not tuning. Cause not determined.
- **r13** (49% lost): orin-right stops after 34 s (617 of 814 s), so most of the match is one camera.
- **Q19** (30% lost, every variant): the cameras record robot time 14–322 s, but the log's enabled odometry ends at
  96 s. Cause not determined.
- **Q32**: the worst clean match (held-out p50 0.10 m, NIS 7). `-refit` and the mount fix both make it slightly
  worse. Check its mounts and calibration separately.
- **Q30**: MT1 heading is ~167° off (above), so its heading column means nothing. Its positions are fine.
- **Q24**: the 236–243 s bump with wheel slip is already documented; it is the 13% lost.
- **Not studied again here:** timestamp offset and tilt, which the Jetson and 2026-FM-SystemCore docs cover. The
  replay still ignores the logs' `T` (tilt) events.

### TXMAN1 replay (first pass: Q17 and Q24)

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
- `replay/batch.sh`: every match: fetch, export (2026-FM-SystemCore `tools/export_tagekf_events.py` at `aeca58c`,
  read with `git show`), detect with both calibrations, replay, tables. It resumes: detected matches are skipped.
- `replay/fetch_robotlog.py`: lists and fetches matches from robotlog.spectrum3847.org.
- `replay/table.py`: the Markdown tables above, from `replay.csv`.
- `bench.sh`: the bench runner, run from the laptop.
- `bench-ab.sh`: the PV fit A/B, run on the target.
