# SystemCore MJPEG + NAPA bench (tester side)

Independent checks for the SystemCore (Raspberry Pi 5 / CM5, 4x A76, LimelightOS) path: one Thriftiest Cam, MJPEG
-> luma -> streaming NAPA -> pose, in PhotonVision or a native app. Findings go to `~/shared/FINDINGS.md` on the Pi.

LimelightOS has no compiler, `timeout`, `taskset` or `perf`, so everything is cross-built on the laptop with WPILib's
SystemCore toolchain (`build.sh`, Git Bash) and pinned/timed by the programs themselves.

| File | What |
|---|---|
| `build.sh [WORK]` | Cross-builds `scmn_bench`, `scmn_live`, `napa_stream_replay`, `napa_test` (NAPA exactly as `07-build-napa-detector.sh`). |
| `bench.cc` -> `scmn_bench MODE SESSION` | `decode`: luma identity vs libjpeg-turbo gray + CPU per decoder. `fused`: bytes arrive over `--frame-ms` in `--chunk` pieces, decoder bands feed streaming NAPA; tail (last byte -> tags), CPU, tag identity vs whole-frame NAPA. `probe`: does streaming NAPA read rows not yet fed (unfed rows filled with `--fill`)? `fuzz`: corrupt/truncated frames in a forked child with a watchdog. `SCMN_BUILDER_LIB=lib.so` adds the builder's decoder through the `scmn_dec_*` C ABI. |
| `live.cc` -> `scmn_live` | Reference native loop on the camera (`--mode whole|stream|fused`): per-frame v4l2 ts -> EOI seen -> tags -> pose, drops, CPU, pose mean/sd. Run under `flock /tmp/camera.lock`. |
| `run.sh offline|decode|fused|fuzz|soak` | On the Pi: the offline suite over `~/bench/data/*`, results in `~/bench/results/<date>-<label>/`. |
| `sysmon.py OUT.csv [--pid ...]` | Per-second busy % per core, MHz, temp, firmware throttle flags (mailbox, no vcgencmd), xhci IRQ/s, per-process CPU/threads/RSS/fds. |
| `pvcsv.py CSV` | Stage table from PhotonVision's `SPECTRUM_LATENCY_TRACE` CSV alone, plus frame gaps. |
| `gen_synth.py OUT` | Rendered Rewind sessions with field tags, encoded like the camera (4:2:2, restart every 8 rows). The TXMAN1 recordings were on the lost Jetson SSD. |
| `mjpeg2rewind.py CAP.mjpeg OUT` | `v4l2-ctl --stream-to` capture -> Rewind folder; prints the JPEG layout. |
| `jpegbits.py CAMDIR` | Entropy bits per component, DC-only blocks, SOF/DRI/DHT layout (pure Python). `scmn_bench split` times entropy vs IDCT. |
| `expsweep.sh OUT ...` | Exposure x gain sweep on the live tag (scmn_live + captures; restores the controls). |
| `burn.py CORES SECS` | Pinned spin load standing in for robot code. `livecsv.py` per-frame stages of a `scmn_live --csv`. |
| `soak.sh OUT MIN CMD...` / `soakreport.py OUT` | Long run under the lock with sysmon; per-5-min latency, CPU, gaps, RSS, fds, temperature, throttling. Re-binds uvcvideo if a usbfs app left the camera without a driver. |
| `scvtrace.py APP.csv TRACE` | A native app's own frame timestamps against the kernel's `xhci_urb_giveback` trace. |
| `topcpu.py [SECS]` | Exact per-thread CPU (schedstat), all threads as % of 4 cores and per core. `/proc/stat` aliases with the 2 kHz USB rhythm (`cpucal.py` shows the method is fine for ordinary loads). |
| `prof.c` -> `scmn_prof PID SECS` + `profsym.py` | Sampling profiler (perf_event_open; no perf on LimelightOS), symbolized on the laptop. |
| `pvconfig.py` | Read-only dump of PhotonVision's settings DB. |
| `nt_check.cc` (+ `fetch-ntcore.sh`) | Decodes `/photonvision/<camera>/rawBytes` from the publisher's own photonstruct schemas: PhotonVision and sc-vision with one tool. |
| `hh.sh OUT SECS native MIN \| pv NAME` | Head-to-head runs with the same camera settings, exact CPU, kernel-trace check. |
| `prototypes/napa-04-stream-readahead.patch` | The proved fix for streaming NAPA reading unfed rows (`scmn_bench probe`). |

```
tests/systemcore-mjpeg-napa/build.sh ~/build/scmn            # laptop
scp ~/build/scmn/{scmn_bench,scmn_live,napa_stream_replay,napa_test} systemcore@robot.local:bench/bin/
ssh systemcore@robot.local 'flock /tmp/camera.lock ~/bench/scmn/run.sh offline'
```
