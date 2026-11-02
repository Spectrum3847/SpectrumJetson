# Do NAPA min-16 extras help the robot's pose? (2026-11-01)

These are the extra AprilTag sightings NAPA `min_tag_px` 16 finds over min 32 (`napa`) and over the GPU detector (`d15s_far`), plus the far config (`napafar`). The data is all 13 TXMAN1 sessions. Script: `extras.py` (on top of `../field-replay/analyze.py --dump`). Raw output: `results/extras.txt`.

Method:
- Every camera frame becomes one PhotonVision-style observation: one tag gives a single-tag IPPE solve with its ambiguity; two or more tags give a multi-tag SQPnP solve.
- The camera pose becomes a robot pose through the **CAD mounts** from the robot code. analyze.py's per-match solved mounts fit a bad robot pose in Q19, Q24-right, Q27-right and r19-right (robot z up to 3 m), so they are not used.
- **robot-vision `Gates.recommended()`** is applied as written: insideField 0.5, maxHeight 0.3, maxTilt 20, single-tag ambiguity 0.3, maxDistance 4.5 / 7 m, maxReprojection 3 px, maxYawRate 3.5, heading vs gyro 15 deg. The innovation gate (1 m, reset after 3 agreeing observations) runs inside the filter on the filter's own estimate.
- Std devs come from `TrustModel.recommended()`.
- Quality is measured as in-frame error (pose-independent, bad above 19.9 px) and analyze.py's good/bad labels.
- The logged robot pose is a weak reference. It is useless in Q19 and r19 (the filter sits 2.8 m off in still periods there), so it is only used as a secondary check.
- Hamming distance is not in the replay CSV (max_hamming is 1 for all of these variants), so decision margin stands in for it.

## 1-2. The extras and the gates

| Extras | n | side p50 px | range p50/p90 m | alone in frame | in-frame p50 / bad% | **pass gates** | passed: in-frame p50 / >thr / bad | passed common: in-frame p50 / >thr / bad |
|---|---|---|---|---|---|---|---|---|
| napa16 − napa32 | 10,458 | 32 | 3.6 / 7.3 | 14% | 1.42 / 5.8% | **7,436 (71%)** | 1.27 / 2.2% / 8.2% | 1.18 / 3.4% / 12.2% |
| napa16 − GPU | 5,694 | 32 | 3.5 / 7.3 | 23% | 2.23 / 11.1% | **3,370 (59%)** | 1.52 / 3.4% / 9.3% | 1.17 / 3.0% / 11.5% |
| napafar − napa32 | 8,432 | 30 | 3.9 / 7.3 | 13% | 1.28 / 5.3% | 5,975 (71%) | 1.11 / 1.9% / 5.7% | 1.20 / 3.6% / 12.5% |
| napafar − GPU | 4,950 | 32 | 3.6 / 7.3 | 24% | 2.41 / 11.6% | 2,862 (58%) | 1.43 / 3.4% / 7.7% | 1.15 / 3.2% / 11.5% |

- The extras are mostly **not tiny**: median side is 32 px. They are tags the 32 px rake missed (blur, motion: median speed 1.6–1.7 m/s against 1.3 for common sightings), and 82% are seen while enabled.
- The gates work. Rejected extras are the bad ones: 21% over the in-frame threshold vs napa32, 29% vs the GPU detector. The extras that pass are as good as passed common sightings.
- Extras **alone in a frame** (single-tag) mostly fail. vs GPU: only 347 of 1,296 pass; maxHeight rejects 527 and ambiguity 319. These are where the real junk is (GPU extras have a median ambiguity of 0.43, against 0.17 for common sightings).
- Extras that **join other tags** mostly pass: 3,023 of 4,398 vs GPU, 6,826 of 8,966 vs napa32. In a multi-tag frame the only checks are the gyro heading (425), reprojection (343) and maxHeight.
- Overall accepted observations: GPU 16,058, napa32 14,349, **napa16 16,555 (+3% over the GPU)**, napafar 16,084.

## 3a. Coverage (enabled time with an accepted observation, 100 ms bins)

| | robot (any camera) | orin-left | orin-right |
|---|---|---|---|
| GPU (d15s_far) | 59.5% | 44.7% | 32.0% |
| NAPA 32 | 55.0% | 41.8% | 27.5% |
| **NAPA 16** | **60.2%** | 45.4% | 32.9% |
| NAPA far | 59.0% | 44.5% | 31.9% |

- napa16 vs napa32: +5.65% of enabled time (46 s over 6 matches) goes from no accepted tag to at least one; 1,590 accepted observations are made only of extras.
- napa16 vs the GPU: **gains 2.25% (18 s), loses 1.5%: net +0.7%**. 519 accepted observations are made only of extras.
- napafar vs the GPU: gains 1.64%, loses 2.1%: net slightly negative.

## 3b. Multi-tag

| | frames where an extra joins other tags | newly accepted / newly rejected | accepted both ways: reprojection p50 | trust xy sd p50 | pose shift p50 / p90 |
|---|---|---|---|---|---|
| napa16 − napa32 | 6,068 (2,902 were single-tag) | 1,745 / 112 | 0.14 → 0.35 px | 0.29 → 0.16 m | 2.8 / 8.5 cm |
| napa16 − GPU | 3,673 (2,003 were single-tag) | 775 / 280 | 0.20 → 0.42 px | 0.25 → 0.18 m | 2.6 / 9.1 cm |

- An extra mostly turns a single-tag frame (ambiguous, heading ignored) into a multi-tag one. TrustModel then gives about 1.4–1.8x smaller xy std devs.
- Reprojection rises because more points are fitted, but stays far under the 3 px gate.
- **Left/right camera agreement** (simultaneous accepted pairs, an internal check): GPU 2,069 pairs, p50 6.0 / p90 12.4 cm; napa16 2,161 pairs, 6.1 / 13.3 cm; napa32 1,777 pairs, 5.9 / 12.2 cm. napa16 gives more pairs at essentially the same consistency, with a slightly wider p90.

## 3c. Pose filter (odometry + accepted vision, enabled time)

Heading comes from the gyro and position from Kalman-filtered x, y, with TrustModel std devs.

| | updates/min | NIS mean (ideal 2) | innovation p50 / p95 m | jumps/min | time since last correction p50 / p90 s | >1 s without a correction | still-robot vs logged pose p50 (Q17/Q24/Q27/Q32) |
|---|---|---|---|---|---|---|---|
| GPU | 1,118 | 5.85 | 0.20 / 0.72 | 9.25 | 0.04 / 3.44 | 20.2% | 8.4 / 21.4 / 11.7 / 21.0 cm |
| NAPA 32 | 1,002 | 5.33 | 0.20 / 0.72 | 9.25 | 0.06 / 3.69 | 22.1% | 8.7 / 21.0 / 13.4 / 22.7 cm |
| **NAPA 16** | 1,155 | 5.80 | 0.21 / 0.74 | 9.03 | **0.03 / 3.25** | **19.8%** | 8.4 / 21.6 / 11.4 / 21.1 cm |
| NAPA far | 1,120 | 5.52 | 0.21 / 0.74 | 9.39 | 0.04 / 3.44 | 20.2% | 8.4 / 21.5 / 11.3 / 20.7 cm |

- The napa16 and GPU filter estimates differ by p50 1.8 cm and p90 9 cm (more than 10 cm 9% of the time). napa16 vs napa32: p50 3.7 cm, p90 21 cm.
- NIS of about 5.8 for every variant means TrustModel's std devs are too optimistic by a factor of about 1.7. That holds equally with and without the extras.
- The still-robot p90 against the logged pose is worse for napa16 in Q27/Q32 (1.2 / 1.1 m vs 0.5 / 0.9 m for the GPU). But that reference wanders, and the innovation and jump statistics don't show it, so treat it as noise or reference error, not a finding.

## Answer

- **The min-16 extras that pass the robot's gates are good.** They match or beat passed common sightings on in-frame error and bad rate. The robot's existing gates (ambiguity, maxHeight, reprojection, heading) remove the bad ones.
- **Against NAPA 32 they matter.** min 32 loses 4.5 points of enabled coverage and about 10% of accepted observations compared with the GPU detector. min 16 gets all of that back.
- **Against our GPU detector they barely matter.** Coverage is +0.7% net, there are +3% accepted observations, the longest gaps between corrections are slightly shorter, and the filter is unchanged within noise (estimates within 2 cm at the median). The real gain is about 775 frames upgraded from single-tag to multi-tag.
- **For the robot:** NAPA 32 is the one to avoid. NAPA 16 is about the same as the GPU detector (very slightly better). The far config is about equal to the GPU detector and gives most of min 16's benefit at half min 16's CPU. So choose between 16 and far on CPU budget, not pose quality.

Suggested gate tweaks (from this data, not tested on the robot):
1. Keep the single-tag ambiguity 0.3 and maxHeight 0.3 gates. They are what keeps the junk extras out (about 60% of rejected single-tag extras).
2. Inflate TrustModel's std devs by about 1.7x (`xyPerMeterSquared` 0.02 → about 0.035) or the filter is over-confident. This applies to all detectors.
3. maxDistance 4.5 m for single tags cuts few extras (27 vs the GPU detector), so leave it. The multi-tag 7 m limit rejects 219, which is worth revisiting only if the far tags prove accurate on the robot.
4. The heading gate rejects about 10% of multi-tag extras, concentrated in Q32 and r19 where the logged gyro offset is suspect. Check it against the real robot gyro before trusting the count.

Reproduce (Jetson, nice 19):
`analyze.py REPLAY --base d15s_far --variants napa,napa16,napafar --dump dump.npz`, then `extras.py dump.npz REPLAY`
