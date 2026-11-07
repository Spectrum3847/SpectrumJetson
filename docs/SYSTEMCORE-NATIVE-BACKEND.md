# Native camera backend for PhotonVision on the SystemCore (design, 2026-11-06)

Goal (user): per camera, the whole per-frame path is native (capture -> mjdec -> streaming NAPA -> pose -> publish,
health, tag quality, Rewind video and vision log). PhotonVision keeps the UI, settings, calibration, pipeline config
and stream-on-demand; Java touches nothing per frame. Target: per-camera CPU near sc-vision's (~27% of a core at
120 fps, min tag 32) instead of the fast path's ~35-42% (PV-perf's photonvision-120..124 bring the fast path to
~29-30% on the dark bench), same latency, same results. Per camera, fallback to today's fast path.

## Where the fast path's extra CPU goes (measured so far)

- The streaming thread (decode + NAPA + pose + publish) is the same work sc-vision does.
- On top: cscore's capture thread dequeues every frame and copies its JPEG into a cscore frame; the Java vision
  thread runs at 30 fps (grab, NAPA result take, health, NT); the JIT; PV's own NT traffic. PV-perf measured the
  wake-ups: 6340/s before, 4880-4965/s with its patches (PVPERF-LOG).

## Capture: own the V4L2 device natively (our uvcvideo), not usbfs

| | V4L2, native owner (chosen) | usbfs (sc-vision's) |
|---|---|---|
| Latency | urb_packets 2: first sight +0.085 ms; camera-clock stamps with hwtimestamps=1 | same; packet-exact first data packet |
| CPU | DQBUF per frame, bytes read straight from the mmap'd buffer while they land (the watcher already does) | URB reaping per 0.25 ms (more wake-ups) |
| Timestamps | QUERYBUF/DQBUF work (we own the queue): camera-clock stamp per frame directly, no Java anchors | own PTS/SCR conversion needed |
| Hot-plug / reconnect | the kernel driver handles it; reopen the node by /dev/v4l/by-id | detach/rebind uvcvideo ourselves; a crash leaves the camera unbound (sc-vision-rebind) |
| Controls | V4L2 ioctls on our own fd (read before write: the Swyft writes them to flash) | needs the node anyway (we already go back to V4L2 for controls) |
| Risk with the user remote | none new (proven driver load) | detach/rebind of a remote camera |

So the backend owns `/dev/v4l/by-id/...` with our uvcvideo (urb_packets 2, hwtimestamps 1). cscore never opens
the camera while the native backend runs it.

## Components (fork + SpectrumJetson)

1. `libspectrum-camera.so` (SpectrumJetson `detector/native_camera.cc`, built with the NAPA libs):
   - one thread per camera: S_FMT/REQBUFS/mmap/STREAMON on its own fd; the watcher's progressive decode
     (mjdec) + streaming NAPA + pose + pv_pack + NT publish (one NT client per camera) + tag quality + health,
     all as today but without cscore or the RefTag handoff;
   - capture time from the dequeued buffer's camera-clock stamp (no Java anchors, no first-sight bias);
   - frame policy (skip / 1/2) decided at frame start, as now;
   - controls: set/get by V4L2 id, read before write;
   - Rewind: the frame's JPEG (already in the mmap buffer) copied into a ring for a low-priority writer thread
     (skip, never block vision), large sequential writes, periodic fdatasync, same file/index format as
     docs/REWIND.md; recording fps independent of the policy; the vision log entries from the native results;
   - stream-on-demand: when a viewer is connected, the latest JPEG (or 1/2-scale gray) handed to Java at the
     stream rate only (cscore RawSource can pass MJPEG through to the MjpegServer without re-encoding).
2. Fork: `NativeCameraSource` (a VisionSource) chosen per camera when the library is there and
   `SPECTRUM_NATIVE_CAMERA=1` (later: a per-camera setting); settings changes (exposure, gain, pipeline params,
   calibration, policy) go to the native side through JNI setters; the Java VisionRunner idles (no per-frame work)
   except for the stream-on-demand pump and health/UI at 1-2 Hz. Fallback per camera: if the library or the
   device open fails, the camera is handed to today's USBCameraSource + fast path.

## Fork files (coordination with PV-perf, branch sc/pv-perf, photonvision-120..124)

PV-perf's changes touch USBFrameProvider, VisionRunner, VisionModule, VisionSourceManager, FrameRateCap,
ClockThrottle, UIDataPublisher, DataSocketHandler. The backend adds new files (NativeCameraSource, its settables,
JNI class) and needs small hooks in VisionSourceManager (choosing the source) and VisionModule (no per-frame
consumers for a native camera). Plan: rebase onto sc/pv-perf once it is merged into sc/mjpeg-napa (or merge it
first), and keep the hooks small; posted in PVPERF-LOG.

## Test plan (until the supply is fixed: single camera, ondemand, <= 20-30 s runs)

- Offline: the capture loop against recorded MJPEG (a fake V4L2 source fed from cd-e2g128.mjpeg) for decode/NAPA/
  pose/serde identity with the fast path; Rewind writer throughput on the SD card with no camera.
- Live (single camera): results identical to the fast path on the same scene (Swyft at exposure 300 while dark,
  restored after), CPU per camera vs sc-vision and the fast path, latency on the same time reference
  (tsref-compare.sh), hot-unplug simulated only by stopping/starting the stream (no physical action).

## First pieces, tested offline (2026-11-06)

- `native/sc-vision/tools/stream_identity.cc` (fake camera): each recorded frame lands in 3200-byte pieces (one
  2-packet URB) in a buffer, decoded as it arrives (mjdec) and fed to streaming NAPA band by band, compared with
  libjpeg-turbo + whole-frame napa_detect. Thriftiest capture (300 frames, min tag 32): 300/300 identical (ids,
  order, corners bit for bit), 1.90 ms CPU per frame; Swyft capture (240): 240/240 identical, 1.83 ms. At 1/2
  scale: same tags on every frame, corners within 0.48 px of full scale, 1.54 ms per frame.
- `native/sc-vision/src/rewind_writer.{h,cc}` + `tools/rewind_bench.cc`: per camera a ring (16 MB), the vision
  thread's push is a reserve + memcpy + append (never waits on the writer; full ring = frame dropped and
  counted), one SCHED_IDLE writer thread writes ~1 MB pieces and fdatasyncs every 2 s; files and CSV as
  docs/REWIND.md. SystemCore SD card, two cameras x 120 fps of the Thriftiest capture (47 KB/frame), 10 s:
  2402/2402 frames kept, 11.6 MB/s, push 9.5-10 us p50 / 15-21 us p99 / 64 us max on the vision thread, writer
  0.6% of a core. The SD card's fdatasync stalled up to 1.9 s once; the 16 MB ring (~2.8 s per camera at this
  rate) absorbed it. For matches: 32 MB rings, or a record fps below 120, gives margin.

## Status 2026-11-06 evening: code complete, blocked on device ownership

Done (fork 2442bfec + 76a39d03 = photonvision-117/118; SpectrumJetson NapaDetectorJNI camera*):
the native thread (V4L2 queue, decode-as-it-lands, streaming NAPA, pose, publish, tag quality, camera-clock
capture time from the dequeued stamp, frame policy, Rewind ring writer, latest image for Java), the PhotonVision
side (USBFrameProvider native mode, controls mirrored natively with read-before-write, RewindRecorder.forNative,
NapaDetector/NativePublish on the camera's handle) and the fallback to the cscore fast path.

Blocked: on the SystemCore the native open fails with EBUSY at VIDIOC_S_FMT. cscore's UsbCamera keeps the
device open whatever its connection strategy (UsbCameraImpl's thread reconnects whenever its fd is closed; the
strategy only decides streaming), and its S_FMT at connect holds uvcvideo's per-device "privileges"
(uvc_acquire_privileges), which only the holder's close releases; S_FMT/REQBUFS from any other handle then get
EBUSY. The camera falls back to the fast path (checked live: 121 fps, 17.6% of a core, dark scene).

Options:
1. Don't create the UsbCamera for a native camera at all: settings go to the native side (cameraSetControl,
   read first) through a NativeCameraSettables, video modes from VIDIOC_ENUM_FMT. Most work, cleanest.
2. Create it, read its properties/modes, then close() it before the native open; settables write natively.
3. Our uvcvideo: a module parameter that skips the privileges check (a kernel-module change: needs approval).
4. usbfs (sc-vision's capture): detaching uvcvideo removes the node from under cscore; hot-plug handling ours.
Recommended: 1 (or 2 as a first step).

## Status 2026-11-06 night (BUILDER2): option 1 built and running live: no cscore UsbCamera

Fork `sc/mjpeg-napa` 97cc032e (= patches/photonvision-128-native-camera-source.patch), SpectrumJetson native side
(NapaDetectorJNI.cc: `device*` JNI, `cameraLatestJpeg`, scaled-frame upscale for Java, driver-wait fix).

- `VisionSourceManager`: a USB camera whose VID:PID is 1bcf:28c5 (Thriftiest) or 0bda:3035 (Swyft)
  (`SPECTRUM_NATIVE_CAMERA_IDS` overrides the list) and that has MJPEG modes gets `NativeCameraSource`, when
  native publish is on (`SPECTRUM_NATIVE_PUBLISH=1`) and libspectrum-napa-apriltag loads. `SPECTRUM_NATIVE_CAMERA=0`
  opts out. Anything else, or any failure in the check, is a normal `USBCameraSource` (cscore). No UsbCamera is
  ever created for a native camera, so uvcvideo's streaming privileges are free (the EBUSY blocker is gone).
- `NativeCameraSettables`: controls and modes from the driver through `NapaDetectorJNI.device*` on a control-only
  fd (no S_FMT on it, so it works while the capture thread or a temporary UsbCamera streams). Names as cscore
  normalizes them, cscore's 0-100 percentage properties (brightness, contrast, saturation, hue, sharpness, gain,
  exposure) with `raw_*` in the camera's units, the same mode list order (saved mode indices keep their meaning),
  Thriftiest exposure range 1-2400, the real-exposure table (USBFrameProvider.realExposureUs, shared), every write
  read first and skipped when equal (Swyft flash).
- `NativeFrameProvider`: opens the native capture in the selected mode (reopens on a mode change), gives the Java
  pipeline a fresh latest image at `SPECTRUM_NATIVE_CAMERA_JAVA_FPS` (default 5) while no stream is watched, at
  the stream rate (`SPECTRUM_NATIVE_PUBLISH_JAVA_FPS`, 30) while one is; Rewind through RewindRecorder.forNative;
  health getters (CameraHealthPublisher). cscore handover: the calibration pipeline, a non-MJPEG mode or a failed
  native open close the native capture and stream the device through a temporary UsbCamera + CvSink (closed and
  native reopened afterwards). The old in-cscore variant needs `SPECTRUM_NATIVE_CAMERA=cscore-legacy`.
- Native fixes: the capture loop passed a stale sequence to UVCIOC_SJ_WAIT, which returns at once: the
  SpectrumCamera thread spun at 98% of a core (now 16.6% dark at 33 fps). Java's latest image is now always the
  next frame (the kept one was a Java period old: 210 ms "latency" in the Java loop, now 28 ms).
- Test: `tests/systemcore-native-camera/nativecam.sh OUT CAMERA [SECS]` (one camera, lock held throughout, DB
  backup/restore, temporary drop-in, Swyft exposure restored).

Live, Swyft only, DARK room, exposure 300 (30 ms: the camera runs ~33 fps), 12 s (`/dev/shm/b2-run3`): PV is the
only owner of /dev/video0 (2 fds: control + capture; no cscore), 397 results (33.1/s), 387 with targets, tag
quality 387/387 matched by sequence ID, health/fps 33.1, capture->publish p50 23.2 ms (mid-exposure of a 30 ms
exposure), PV 24.3% of a core (SpectrumCamera 16.6%, VisionRunner 1.7%).


Fast path vs native, same scene (Swyft, DARK, exposure 300, 12 s; `/dev/shm/b2-fast1` vs `b2-run3`):

| | fast path (SPECTRUM_NATIVE_CAMERA=0) | native (no UsbCamera) |
|---|---|---|
| results / with targets | 397 / 388 | 397 / 387 |
| tag quality matched by seq | 388/388 | 387/387 |
| capture->publish p50/p95/p99 ms | 23.12 / 23.56 / 24.36 | 23.19 / 23.39 / 23.95 |
| tag 10 distance (sd mm), ambiguity | 1.7617 m, 0.205 | 1.7622 m, 0.201 |
| PV % of one core | 28.0 (SpectrumStream 16.2, VisionRunner 2.4) | 24.3 (SpectrumCamera 16.6, VisionRunner 1.7) |

Dark numbers (33 fps at a 30 ms exposure) are not comparable with lit 120 fps runs.

cscore handover + stream on demand (`stream-handover.sh` as EXTRA_CMD, `/dev/shm/b2-hand2`): input/output streams
served (1181: 83 JPEG frames in 3 s, 1182: 80; the Java pipeline at 30 fps while watched, 5 fps otherwise), the
handover test file closed the native capture and a temporary UsbCamera streamed (results continued from the Java
path), removing it closed the UsbCamera and the native capture reopened, no crash. Two bugs fixed on the way: a
stale native handle used after the close (fork 6f8bcb0e, PV aborted) and a double join in
`spectrum_stream_release` (stream_decode.cc Reap, would abort on the reopen after cscore streamed).

Not done / not verified yet: the real calibration pipeline switching (VisionRunner sets the handover when the
pipeline is Calibrate3dPipeline; only the test file was exercised); passthrough stream (cameraLatestJpeg exists,
the stream still re-encodes the Java frame); both cameras at once (Pi rule: single camera); lit-scene CPU.

Thriftiest, DARK (no tags in view), 120 fps, 12 s: native `/dev/shm/b2-thr1` vs the cscore fallback forced with
`SPECTRUM_NATIVE_CAMERA_IDS=dead:beef` (`b2-thrfb`, = the fast path; this is also the non-matching-camera fallback
check: the camera came up as USBCameraSource/USBFrameProvider and ran normally):

| | fast path (fallback) | native |
|---|---|---|
| results/s | 121.2 | 121.5 (health/fps) |
| capture->publish p50/p95/p99 ms | 8.368 / 8.480 / 8.506 | 8.372 / 8.474 / 8.507 |
| PV % of one core | 22.3 (SpectrumStream 12.8, VisionRunner 1.7) | 18.3 (SpectrumCamera 11.8, VisionRunner 1.0) |

The saved pipelines' video-mode index opened 1280x800 MJPEG 120 fps natively on both cameras, the same mode cscore
set in the handover (mode lists in cscore's order); a full UI check of every control/mode was not done (no
websocket client here).

### Next steps (for whoever continues)
1. Real calibration: start a calibration from the UI (Calibrate3dPipeline) and check the handover log lines,
   the calibration frames at the calibration resolution, and the native reopen after it ends.
2. Passthrough stream: the input stream could serve `cameraLatestJpeg` through a cscore `raw.RawSource` (MJPEG,
   server compression -1) instead of re-encoding the Java gray frame; the output stream (overlays) re-encodes.
3. Both cameras at once (when the Pi rules allow two-camera runs): ownership, per-camera CPU, pvboth.sh/nt_check.
4. Lit-scene CPU vs sc-vision (~27%) and the UI controls check (exposure/gain/brightness sliders, extra controls).

## Leftovers round (BUILDER2, 2026-11-06 late): passthrough stream, sequence IDs, real calibration, installer

Fork sc/mjpeg-napa 69646b4c, 70a41692, 38f8d479 (= photonvision-131..133); native: `cameraOpenSeq`, `cameraSequence`,
`cameraStop` (NapaDetectorJNI.cc).

**Passthrough stream (done).** NativeFrameProvider's `NativeStream-<camera>` thread hands the camera's own JPEG
(`cameraLatestJpeg`) to the input MjpegServer through a cscore `raw.RawSource` at the stream rate while the input
stream is watched (`SPECTRUM_STREAM_PASSTHROUGH=0`: off). The server's compression is -1 from the start (a
connection keeps the compression it began with; switched later, cscore decoded + re-encoded every JPEG at 75, 33%
of a core); Mats (handover) are still encoded at 75. The Java pipeline goes to the stream rate only for Mat-fed
streams (`MJPGFrameConsumer.anyMatViewers`: the output overlay stream). Thriftiest, DARK, 120 fps, 5 s each
(`stream-cpu.sh`, `/dev/shm/b2-scpu{0,2}`), PV % of one core:

| | no viewer | 1 input viewer | 1 output viewer |
|---|---|---|---|
| re-encoded (before) | 17.6 | 27.0 (+9.4) | 26.4 |
| passthrough | 20.5 | 19.2 (~0) | 27.1 |

The input viewer gets the full 1280x800 camera JPEG at 28.8/s (0.61 MB/s dark); the output stream is unchanged.

**The 21 tag-quality mismatches in the handover test (explained, fixed).** They were sequence IDs going back,
not wrong data: the native publish counted from where its handle started, the Java path (during the handover)
from its own frame counter, and the reopened native handle from 1 again (`b2-hand2/swyft.csv`: 297..535, then
222..333, then 1..128). nt_check pairs tag-quality arrays to results by sequence ID, so reused IDs paired results
with older arrays of other frames. Now IDs keep rising: the native publish starts at the Java path's last ID + 1
(`cameraOpenSeq`), the Java path continues from the native publish's final ID (`cameraStop` returns it after the
thread stopped). Handover test after the fix (`b2-hand3` with only the first half, `b2-cal1` with both): 0
backwards steps, 0 mismatches.

**Real calibration through the API (done).** `tests/systemcore-native-camera/calibration.sh`: the websocket
message the UI sends (`startPnpCalibration`, msgpack on /websocket_data, charuco 8x8, video mode index 0), then
`POST /api/calibration/cancel`. Swyft: "Starting calibration at resolution index 0" -> mode 160x120 MJPEG 60 ->
"Native camera: cscore handover (calibration)"; cancel -> mode 1280x800 MJPEG 120 -> "cscore handover ended" ->
"captured natively"; sequence IDs rose throughout (295..1209), tag quality 25/25 matched. (That run lasted ~10
minutes instead of ~30 s: the first version of calibration.sh read the websocket until it went quiet, which PV
never does; fixed to read 1 s. Dark room, single camera, no harm seen; the cleanup restored everything.)

**Installer.** `install-photonvision.sh` now writes `20-native-camera.conf` (`SPECTRUM_NATIVE_PUBLISH=1`) so a
plain PV start runs verified cameras natively; `NATIVE=0` removes it; 10-spectrum.conf is left as it is.

**Both cameras in one PV (done; DARK).** `nativecam.sh OUT swyft,thrifty 12` (urb 2 uvcvideo, Swyft exposure 300 so
~33 fps, Thriftiest 120 fps with no tags), `/dev/shm/b2-two-{native,fast}`:

| | fast path (SPECTRUM_NATIVE_CAMERA=0) | native |
|---|---|---|
| device ownership | PV only (video0, video2: cscore + watcher fds) | PV only (video0, video2: control + capture fds, no cscore) |
| Swyft results / targets / tag quality | 395 / 395 / 395 of 395 | 396 / 396 / 396 of 396 |
| Swyft capture->publish p50/p95/p99 ms | 23.17 / 24.68 / 26.61 | 23.42 / 24.52 / 26.07 |
| Thriftiest results/s, capture->publish p50/p95/p99 ms | 121.2, 8.142 / 8.306 / 8.408 | 121.2, 8.375 / 8.481 / 8.556 |
| PV % of one core | 42.4 (SpectrumStream 16.4 + 11.9, VisionRunner 2.2) | 39.2 (SpectrumCamera 17.3 + 12.0, VisionRunner 1.8) |

The Thriftiest's native capture->publish is 0.23 ms above the fast path's in this two-camera run (single camera:
8.372 vs 8.368): not explained yet (both are camera-clock stamps; check with tsref-compare / tsresid against USB).

**Installed with the AOT cache (done).** `AOT=1 AOT_TRAIN_S=28` (training run held to 28 s): 44.8 MB cache;
20-native-camera.conf present. A plain start (only 10-spectrum.conf + 20-native-camera.conf, STOCK uvcvideo, no test
drop-in): both cameras native (PV the only owner, 4 video fds), both 120 fps (Swyft at exposure 10), capture->publish
p50 10.9 ms on both, PV 46.4% of a core (SpectrumCamera 27.2 + 12.5: with the stock driver there is no
UVCIOC_SJ_WAIT, so the capture threads poll every 0.1 ms; our urb-2 uvcvideo is not loaded at boot). The
SystemCore RESET right after that run, while PV stopped and its settings DB was being restored (journal of the
previous boot: "Voltage normalised" just before; boot dmesg shows undervoltage again). After it came back: DB
restored from the run's backup (integrity ok, both cameras active), limelight_visionserver stopped, Swyft exposure 10.

Open items: polling cost with the stock uvcvideo (load ours at boot, or a cheaper wait without it); the 0.23 ms
two-camera Thriftiest offset; lit-scene CPU vs sc-vision; a UI pass over every control.

## Our uvcvideo at boot (sc-uvcvideo.service; user-approved), verified across one reboot

`scripts/systemcore/uvcvideo-boot.sh` + `sc-uvcvideo.service`, installed and enabled by `install-photonvision.sh`
(`UVC=0` skips; `UVC_KO` = the module, default `~/builder/uvcvideo-sc/uvcvideo.ko` from build-uvcvideo.sh):
- the module lives in `/opt/sc-vision/modules/uvcvideo-sc.ko` (+ `.sha256`), outside /lib/modules; the stock
  uvcvideo is never blacklisted, so a failed or disabled unit always leaves a working driver;
- the unit runs early (after local-fs/udev, before photonvision, limelight_visionserver, multi-user): checks the
  .ko's sha256 and that its vermagic kernel equals `uname -r` (a LimelightOS update -> stock), waits for the stock
  driver's cameras to settle, rmmods stock, insmods ours with `/etc/sc-vision/uvcvideo.conf` (ENABLED=1,
  URB_PACKETS=2, HWTIMESTAMPS=1, CAMERA_WAIT_S=10) plus Limelight's modprobe.d options, and waits for the same
  number of cameras to come back; ANY failure (sha, vermagic, rmmod, insmod, cameras missing) loads stock and says
  why (journal, `/run/sc-uvcvideo.status`). `ENABLED=0` opts out;
- health: `/opt/sc-vision/uvcvideo-boot.sh status` -> e.g. `uvcvideo: ours (urb_packets 2, hwtimestamps 1);
  cameras: 2; boot: ... ours: loaded, 2 camera(s) (stock had 2)`.

Tested without a reboot (swap; forced sha mismatch -> stock; ENABLED=0 -> stock; via systemd -> ours), then one
controlled `systemctl reboot`: the SystemCore was back in ~1.5 min, the unit had loaded ours at boot ("ours:
loaded, 2 camera(s) (stock had 2)"). PhotonVision started plainly (10-spectrum.conf + 20-native-camera.conf only):
both cameras native ("driver wake per URB"), PV the only owner of video0/video2. The room was LIT by then (tags on
both cameras), 120 fps each, 4 s per camera with nt_check:

| | Thriftiest | Swyft |
|---|---|---|
| results/s, with targets | 121.2, all | 120.0, all |
| tag quality matched by sequence ID | 485/485 | 480/480 |
| capture->publish p50/p95/p99 ms | 8.437 / 8.673 / 9.112 | 8.686 / 8.852 / 9.058 |
| SpectrumCamera thread, % of one core | 29.8 | 25.3 |

PV in all 67.3% of a core for both cameras LIT (the ~39% earlier was DARK: not comparable); per camera ~25-30%,
in line with sc-vision's ~27% lit. That run started without the AOT cache: reinstalling the same jar had renewed its
mtime (the cache stamp and the JVM's own check include it). The installer now leaves identical files untouched;
the cache was rebuilt (28 s training) and its stamp matches. Pi left: our uvcvideo loaded, PV stopped (not enabled
at boot, as before), limelight_visionserver stopped (it starts at boot), DB restored from the run's backup.

## Frame policy and the two-camera Thriftiest offset (BUILDER2, next session)

- Half scale: fixed (it no longer costs: NAPA's reduced min tag keeps the full-scale sampling stride, cheap upscale)
  but live it saves at most ~1 point of a core, so the native backend ignores `scale` unless SPECTRUM_POLICY_SCALE
  is set: the policy is skipping only. Details and numbers: docs/FRAME-POLICY.md (2026-11-07).
- The +0.23 ms Thriftiest capture->publish (two cameras, dark) does not reproduce. Two cameras, LIT, 12 s each,
  with an xhci trace (`xhci-trace.sh`) and tsresid.py (published capture vs the frame's first USB packet):

| | Thriftiest capture->publish p50 | Thriftiest first packet - capture p50 | Swyft capture->publish p50 | Swyft first packet - capture p50 |
|---|---|---|---|---|
| fast path | 8.412 ms | 0.858 ms | 8.538 ms | 0.808 ms |
| native | 8.436 ms | 0.895 ms | 8.542 ms | 0.806 ms |

  Differences of 0.02-0.04 ms, inside the trace's +-0.125 ms URB uncertainty; both stamp mid-exposure the same way.
  The dark-run 0.23 ms was most likely run-to-run variation; no change made.

**2026-11-07: decode scale removed** (Allen): no `input/scale`, `input/fullEvery`, `health/scale`, `health/fullEvery`,
`health/scaledFrames`, `SPECTRUM_POLICY_SCALE`/`_FULL_EVERY`, Low-CPU Decode switch, or native half-scale path any more;
the frame policy is `processEvery` only (docs/FRAME-POLICY.md). Tests now default to min tag 22.

## Flag cleanup 2026-11-07 (Allen-approved; fork 0fc4b12e, 1ae05f4b, f6e5f329 = photonvision-134..136)

- **Decode scale removed** everywhere robot-facing: `input/scale`, `input/fullEvery`, `health/scale`,
  `health/fullEvery`, `health/scaledFrames`, `SPECTRUM_POLICY_SCALE`, `SPECTRUM_POLICY_FULL_EVERY`, the AprilTag
  tab's "Low-CPU Decode" switch (the saved setting is ignored), the native sink's reduced-scale path, sc-vision's
  `--scale`/`--full-every` and NT scale inputs. Policy = `processEvery` only (docs/FRAME-POLICY.md). Offline
  tools keep test options (stream_identity `--scale/--scaled-min`, mjdec_bench `--scale`).
- **SPECTRUM_NATIVE_PUBLISH gate removed**: native publish is always on (it engages per camera when its frames are
  streamed/captured natively); verified cameras are native by default; `SPECTRUM_NATIVE_CAMERA=0` is the only
  opt-out (installer `NATIVE=0` writes it in 20-native-camera.conf; otherwise that drop-in is removed).
- **One Java-rate flag**: `SPECTRUM_NATIVE_JAVA_FPS` (default 5) replaces SPECTRUM_NATIVE_PUBLISH_JAVA_FPS (30) and
  SPECTRUM_NATIVE_CAMERA_JAVA_FPS (5), for the fast path and native cameras; `SPECTRUM_STREAM_FPS` (30) while a
  Java-fed stream is watched. (The fast path's Java pipeline therefore drops from 30 to 5 fps while unwatched.)
- `SPECTRUM_NATIVE_POSE=0`: kept as a DEBUG switch only (Java path, WPILib orthogonal iteration).
- **sc-vision NT**: the legacy top-level `heartbeat`, `latencyMillis`, `fps`, `hasTarget`, `targetYaw/Pitch/Area`
  are gone (no readers in robot-vision/, tests or docs: they use PhotonLib on rawBytes); `health/*` stays.
- `SPECTRUM_CAMERA_PTS_DELAY_US` is still read (USBFrameProvider and NativeFrameProvider, the camera-clock shift):
  kept.
- Tests (`nativecam.sh`) default to min tag 22 and keep the boot-loaded uvcvideo (swap only if stock is loaded).

Lit sanity check after it (both cameras, min 22, 12 s, plain env + the test drop-in, no SPECTRUM_NATIVE_PUBLISH):
both "Native camera source", PV the only owner; Swyft 119.6 results/s, Thriftiest 120.6/s, all with targets,
tag quality 1435/1435 and 1447/1447 matched, health/processEvery 1, no health/scale. Latency/CPU of that run
are NOT representative: another agent's tagfit_bench was using ~93% of a core meanwhile (p50 capture->publish
9.0/8.9 ms, PV 99.4%).

## Reconnect after a USB reset (fork 093b69de = photonvision-137, 2026-11-06)

A native camera now recovers by itself from a USB reset, a uvcvideo rebind, a deauthorize/authorize, or an unplug and re-plug:
- **Native side.** The capture thread detects a lost device: a V4L2 error, or no frame for `SPECTRUM_NATIVE_FRAME_TIMEOUT_MS`, default 500 ms. It then releases the device at once.
- **Fork side.** `NativeFrameProvider` reopens the camera by its by-id path every 100 ms, with its mode and controls. The log shows `lost` and `reconnected` lines; health shows `state` `disconnected`/`recovering` and counts `recoveries`.
- **Reopen bug fixed.** Reopened handles now get the pipeline's NAPA settings. Before, a reused handle address left NAPA on its defaults.
- **Results.** All 40 resets (4 methods x 2 cameras x 5) came back to 120 fps at p50 8.8-9.0 ms, with a first result 0.5-1.0 s after the reset.
- Root causes and the full table are in `tests/camera-reset/README.md`.

The cscore path is unchanged. `USBFrameProvider`'s StuckCameraWatchdog still reconnects it, then escalates to USB resets. The superseded `SPECTRUM_NATIVE_CAMERA=cscore-legacy` path gets the native loss detection but no Java reopen.

## ThriftyCam, USB 3 (fork ad8691de = photonvision-138, 2026-11-06)

The Thrifty Bot ThriftyCam (`05c8:0a00`, SunplusIT SPCA2630, OmniVision OG02B1B mono global shutter) is a verified
native camera: MJPEG 1600x1304 at 60 fps on a blue (USB 3) port. Characterization: `tests/thriftycam/README.md`.

- **Identity.** No serial, so it keeps PhotonVision's by-path uniquePath (`platform-xhci-hcd.0-usb-0:1:1.0`; the same
  path at SuperSpeed and at high speed) and a new one is named by model and port, `ThriftyCam_xhci0-1`. One camera per
  fixed port; moving it to another port makes it a new camera. Reconnect reopens that path (unchanged code).
- **Mode.** The pipeline's video mode (index into the MJPEG-only list, `MJPEGOnly` quirk); 1600x1304 60 is the first.
  1280x720 and 640x480 are crops of the top of the sensor: don't use them.
- **Controls.** As for the other cameras: read first, written only where they differ (they persist in its flash).
  Tags: manual exposure 8, gain 0, sharpness 50, **brightness 50%** (PhotonVision's default 100% maps to +64, a large
  offset on this camera).
- **Timestamps.** Camera delay (exposure end -> first packet) 0.7 ms and PTS delay 0, per model in the fork and in
  sc-vision. Not measured: it assumes the PTS (0.7 ms before the first data packet) marks the end of exposure. An LED
  test would settle it; `SPECTRUM_CAMERA_DELAY_US=...,ThriftyCam=NNN` overrides.
- **No calibration yet.** solvePNP is skipped without a calibration (2D targets, no NullPointerException), until a
  1600x1304 calibration is added.
- **Frame timing.** The camera spreads each frame over ~15.6 ms of the 16.7 ms period, so capture -> pose is ~17 ms
  even with streaming (the Thriftiest/Swyft at 120 fps: ~9 ms).

Bench Pi 5, 2026-11-06 23:15 CST, all three native in PhotonVision at once, 30 s, min tag 22, full-tag fit on,
performance governor (capture -> publish from the results; PhotonVision CPU from /proc):

| Camera | Settings | fps | p50 ms | p99 ms | max ms | tags/frame | seq gaps |
|---|---|---|---|---|---|---|---|
| Thriftiest SJ-05 | 12/128, 1280x800 | 121.2 | 8.91 | 10.32 | 27.7 | 3.25 | 2 |
| Swyft SJ-SW01 | 5/96, 1280x800 | 120.0 | 9.19 | 17.81 | 29.2 | 4.90 | 0 |
| ThriftyCam_xhci0-1 | 8/0/sh50, 1600x1304 | 60.2 | 16.76 | 20.56 | 40.0 | 2.25 | 3 |

PhotonVision 184% of a core (two cameras before: ~180%). ThriftyCam `usbreset` x3 under PhotonVision
(`PV_NAME=ThriftyCam_xhci0-1 reset_timing.py thriftycam usbreset 3 --pv`): node back 0.30 s, first result with
tags 0.54-0.56 s, then 60-61 fps at p50 16.6-16.8 ms, still SuperSpeed, controls unchanged; reconnected 171-377 ms
after the loss, 1 open attempt each.

sc-vision (user-space usbfs reader) on the same camera: `native/sc-vision/README.md`, "ThriftyCam".
