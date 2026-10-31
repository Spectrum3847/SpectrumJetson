# SystemCore CPU benchmark

How much CPU AprilTags from USB MJPEG cameras cost without a GPU, for PhotonVision on the
SystemCore, which shares its CPU with robot code. Fork branch `systemcore` (photonvision-98) has the
CPU path this measures. See SPECTRUM.md row 16 in the fork.

```
tests/systemcore-cpu/run.sh [--cores 5] [--threads 1,2,4] [--frames 400] [--ref REF_DIR] DIR...
```

`DIR` is any tree of Rewind sessions (`<session>/<camera>/*.mjpeg` plus the `.csv` index), for
example `/opt/photonvision/rewind/regression` or a TXMAN1 replay's `sessions`. `--ref` takes the
GPU detector's replay CSVs (a field-replay match's `out/base`) and runs `compare.py`. The script
needs `javac` and a PhotonVision jar for the machine (`--jar`, default
`/opt/photonvision/photonvision.jar`). It runs at nice 19, pinned with taskset, and has a hard
timeout. On the laptop it needs an x86-64 jar; only the Jetson's arm64 jar was at hand, so it
hasn't run there yet.

For each frame it times:
- three decodes: colour + cvtColor (cscore's gray sink), gray (`IMREAD_GRAYSCALE`), and half-res gray (`IMREAD_REDUCED_GRAYSCALE_2`)
- WPILib's CPU detector with AprilTagPipeline's settings: full res at decimate 2 against half res at decimate 1

## Results, Jetson (2026-10-31)

- CPU: Cortex-A78AE, one core, clock at 1.19 GHz (capped by someone else, not the maximum)
- Frames: 1280x800 field frames from TXMAN1 Q17 (1513 frames) and Q24 (600)

| per frame | ms |
|---|---|
| decode: colour + cvtColor | 9.4 |
| decode: gray | 4.9 |
| decode: half-res gray | 4.0 |
| detect: full res decimate 2, 1 thread | 23.8 (CPU) |
| detect: half res decimate 1, 1 thread | 23.3 |
| detect: full res decimate 2, 2 / 4 threads | 33.5 / 34.7 CPU, 18.2 / 15.6 wall |

Against the GPU detector on the same frames:

| | tags found (Q17) | corner distance, median / p90 |
|---|---|---|
| full res, decimate 2 | 96.0% | 0.08 / 0.21 px |
| half res, decimate 1 | 86.3% | 0.16 / 0.38 px |

The regression corpus (ceiling and synthetic scenes, 1960 frames) gave 37 ms of detection a frame.
The detector's cost depends on the scene.

What this means:
- Decoding to gray instead of colour halves the decode. The fork now does this on the CPU when the detector library is missing.
- Half-res decode saves only 0.9 ms a frame. Decimate 2 already searches at half resolution, so detection costs the same. It loses about 10% of tags (small ones, which apriltag decodes at full resolution) and doubles the corner error. The option is there, but it's off by default and the SystemCore profile doesn't turn it on.
- Extra threads lower latency but cost 40% more CPU in total. One thread is the cheapest.

## Expected cost on a SystemCore: an estimate, not measured

The fork treats the SystemCore as a QCS6490: four Cortex-A78 cores at 2.4 to 2.7 GHz, plus four
A55s. That's the same core as the Jetson's, at about twice the clock. A Raspberry Pi 5's A76 at
2.4 GHz should land close to that. Scaled by clock (about 1.8x, because memory doesn't speed up
with the clock), gray decode plus 1-thread detection is about 29 ms at 1.19 GHz, so about **15 to
20 ms of CPU a 1280x800 frame**. At 50 fps that's **about 0.8 to 1 core per camera**.

My recommendation: 1 camera at 50 fps, or 2 at 30 fps. Use 1280x800 or smaller and pick a camera
mode at or below 50 fps, so the camera itself doesn't send more frames than PhotonVision uses.

The SystemCore profile turns on by itself on a non-Rubik QCS6490 or a Raspberry Pi
(`SPECTRUM_SYSTEMCORE_PROFILE=1` or `=0` overrides it). It caps detection at 2 threads, decimate
at least 2, and 50 fps processed and decoded.

## Measure first on the SystemCore

1. Run `run.sh --cores 3 --threads 1,2` there on a copied Rewind session. The A78 clusters are uneven, so check which core you get with `lscpu`. This replaces the estimate above.
2. Run PhotonVision with one camera at 50 fps and robot code running. Look at `top`, and at robot loop overruns.
3. Check that the log says `MJPEG decoded straight to gray (1280x800, CPU)`. If it says cscore's conversion, the frame layout check refused the frame.
4. Check thermals and clocks under that load: `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`.
