# Bench session

One command for a bench day with 4-5 cameras and AprilTags: it walks you through each test with
prompts, measures, puts every setting back, and writes one results file.

Clocks: the bench has no robot, so the session holds `spectrum-clocks mode full` and puts the old mode back at the end.

## Before you start

- PhotonVision running with all cameras streaming; tags printed and a tag on a stick for the edge test.
- The repo copied to the Jetson (`~/SpectrumJetson`), e.g. from the laptop:
  `rsync -a tests scripts jetson:SpectrumJetson/`
- `sudo true` once on the Jetson (the script uses `sudo -n`).
- No browser previews open (stream viewers cost CPU; the results show how many there were).

## Run it (on the Jetson)

```
~/SpectrumJetson/tests/bench-session/run.sh            # everything except USB (~45-60 min)
~/SpectrumJetson/tests/bench-session/run.sh graphs 3d  # only these steps
~/SpectrumJetson/tests/bench-session/run.sh all usb    # everything, USB recovery too
```

At each `>>>` prompt, do what it says and press Enter. Type `s` + Enter to skip that step.
Ctrl-C at any time stops and puts everything back.

| step | what you do | what it measures | changes (put back after) |
|---|---|---|---|
| inventory | nothing | cameras, fps, every camera on NVJPG (no libjpeg-turbo frames, no fallback lines since start), clocks locked, temperatures, spectrum-rt, detector options | nothing |
| baseline | cameras away from tags, then at tags | fps, latency median/p95/max per camera, detect times, PhotonVision CPU, perf profile per thread, GPU, power, temperature | nothing |
| graphs | tags in view, keep still | CUDA graphs on vs off, interleaved | `/tmp/spectrum-971-graphs` |
| far | tags in view, some 5+ m away | far search on vs off, interleaved: turn it on for the robot if the live cost is near the replay's 1.7 ms/frame | `/api/robotState` farSearch |
| 3d | tags in view, keep still | 3D (solvePNPEnabled) on vs off: CPU, latency | each camera's active pipeline setting, via PhotonVision's websocket |
| rt | tags in view, keep still | spectrum-rt off vs on with LOAD=0 and LOAD=4 (tests/rt-ab) | spectrum-rt mode |
| edge | slide a tag off each image edge, then walk it out for range (40 s per value) | detections per camera with the edge filter at 0, 25, 50 px | detector options drop-in (one PhotonVision restart per value, one more at the end) |
| usb (opt-in) | watch | seconds until each camera streams again after disable/remove/reset and a hub reset | cuts camera USB links; refuses unless every camera's firmware reports `"recovers": true` |

Every step has a hard time limit; when it runs out the step is marked TIMEOUT and the session moves on.

## Results

`~/bench-results/<yyyymmdd-HHMMSS>/results.md`: a table per camera/detector and one for the whole
Jetson (A/B rounds averaged, max columns are the worst), then the checks and notes. Next to it:
`session.log` (everything printed), the raw `cams.tsv`/`sys.tsv`, `profile-cpu.txt`, `rt-ab.txt`.
Copy to the laptop: `rsync -a jetson:bench-results/ logs/bench-results/`

Notes:
- Camera rows (fps, latency) come from PhotonVision's 10 s "Loop timing" lines; detector rows
  (`h0`, `h1`, ...) from the "971 stats" lines. The log doesn't say which detector is which camera.
- 3D changes nothing unless the camera has a calibration for its resolution.
- The edge step is skipped if the installed detector has no `SPECTRUM_971_EDGE_BORDER_PX`, or if
  `~/build/bos-detector` differs from what's installed (08-select-detector.sh would swap it).
- CPU profiling uses perf, never async-profiler (its SIGPROF stops cscore camera threads).
- Tunables: `BENCH_SECS` (window, 30), `BENCH_ROUNDS` (A/B rounds, 2), `RT_SECS` (45), `EDGE_VALUES` ("0 25 50").
