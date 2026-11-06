# Camera-side latency and CPU: measurements and firmware proposals

2026-11-05, on the SystemCore-like bench (Raspberry Pi 5, LimelightOS beta18, kernel 6.12.112 PREEMPT_RT).
Cameras:
- **Thriftiest Cam** SJ-05: Sunplus SPCA2089 bridge, `1bcf:28c5`, published 5.13 firmware.
- **Swyft USB Camera** SJ-SW01: Realtek bridge, `0bda:3035`, Swyft's low-exposure firmware.

Both use the OV9281 global-shutter sensor and run MJPEG at 1280x800 and 120 fps.

How it was measured:
- Tools: [tests/camera-timing](../tests/camera-timing/README.md). Every isochronous packet is logged with its
  UVC PTS/SCR through usbfs, using 1-packet URBs.
- Only standard UVC and V4L2 requests were sent: nothing was flashed, and no vendor or XU command was sent.
- Firmware analysis is static, on the published images and the Swyft dump.

"Measured" means timed on the cameras; "est." means arithmetic.

## Summary

1. **The camera delay is ~0.4 ms, not 2.5 ms.** Measured with an LED: exposure end -> first USB packet is
   0.41 +- 0.05 ms, and the PTS marks exposure end (+-0.02 ms). The earlier, LED-free analysis:
   - In the camera's own clock, a frame's first data packet leaves 0.35 ms (Thriftiest) or 0.32 ms (Swyft)
     after its PTS.
   - That gap stays the same for exposures from 0.1 to 5 ms. The sensor readout paces the frame's bytes, so
     neither bridge buffers frames.
   - Exposure end to first packet is therefore about 0.3-0.45 ms. The 2.5 ms in our mid-exposure timestamp
     makes it about 2 ms too early.
   - This is a constant fix (software), with no firmware change. Confirm it once with an LED or spin test.
2. **The frame's 7.2-7.5 ms transfer is the sensor readout.** USB payload size, packet rate and JPEG size
   don't change it. Only fewer rows (a window, or binning) or a faster line time would.
3. **Swyft 640x400 at 210 fps already reads out in 3.75 ms** (2x2 binned, stock firmware), every 4.75 ms.
   It costs half the resolution.
4. **A full-pitch 1280x400 band works on the Thriftiest** (spare, 2026-11-05). It is the repurposed 1280x720
   mode: 120 fps, 0 errors, 3.61 ms transfer instead of 7.24.
   - The sensor reads the band at the end of the frame period, so the latency gain depends on where
     exposure ends. The LED test decides.
   - Every other mode stops streaming until the firmware gets a per-mode sensor table, which is code that
     isn't traced yet.
   - The 640x400 binned-fast-readout patch does nothing: 640x400 is scaled from the full readout.
5. **Decode CPU follows JPEG bytes, and sharpness drives the bytes.**
   - Swyft sharpness 0/50/100 gives 63/84/114 KB a frame. Thriftiest sharpness 1/5/10 gives 57/61/82 KB.
   - Keep both at their minimum. The Swyft's default of 50 costs ~0.8 ms of decode per frame (est.).
6. **The Swyft writes its control values to flash** (found in its dump). It may keep them over a power
   cycle, but frequent control writes wear the flash ([SWYFT-CAMERA-FIRMWARE.md](SWYFT-CAMERA-FIRMWARE.md)).
7. **Not worth doing:**
   - A shorter restart interval: both are already at 1 MCU row (8 rows), the minimum for 4:2:2.
   - A larger USB payload: readout paces the transfer, not the bus.
   - Grayscale JPEG: unavailable on the Thriftiest, and the chroma is cheap.
   - A faster full-resolution line time: past the OV9281's spec, high risk.

## The two cameras (measured)

All at 1280x800 MJPEG, 120 fps, 4 s runs (~480 frames), sharpness at the minimum, gain 128 unless noted.

| | Thriftiest SJ-05 | Swyft SJ-SW01 |
|---|---|---|
| Firmware | published 5.13 (`bcdDevice 0x0513`, has gain) | low exposure (dump = Swyft's `LowExposureSWYFTUSBOV9281.rfw` + serial record + settings block); `bcdDevice 0x0001`, strings "Generic" / "USB Camera" |
| UVC | 1.00, clock 48 MHz | 1.00, clock 15 MHz |
| MJPEG modes | 1280x800, 640x360, 1280x720, 800x600, 640x480, 640x400, 320x240, all 120 fps only | 1280x800 @120; 1280x720, 1024x768, 800x600 @120; 640x400 @**210**; 352x288, 320x240, 160x120 @210/120/90/60 |
| Uncompressed | YUY2, 0.5-30 fps | YUY2 1280x800 @10, 640x400 @30 |
| Streaming alts (bytes/microframe) | 12 alts: 192 ... 3060 (3x1020) | 8 alts: 128, 512, 1024, 1536, 2048, 2688, 3072 |
| Camera's bandwidth request | 3060 (alt 11) | 3072 (alt 7) at 1280x800; 2048 (alt 5) at 640x400 |
| Frame period | 8.245 ms (121.3 fps) | 8.336 ms (120.0 fps) |
| **First -> last data packet** | **7.24 ms** | **7.50 ms** |
| Last packet -> next frame's first | 1.0 ms | 0.87 ms |
| Data packets per frame | 58-60 (~1 per microframe) | 60-61 |
| **PTS -> first data packet (camera clock)** | **0.35 ms** (0.29-0.44, 125 us steps) | **0.32 ms** (0.26-0.37) |
| PTS/SCR | in every header; SCR = per-packet source clock + 11-bit SOF | same |
| JPEG | APP0 "AVI1", 2 DQT, the 4 standard DHT, **DRI 80 MCUs = 8 rows**, SOF0 3 components 4:2:2 (Y 2x1) | **no APP0**, 2 DQT, 4 standard DHT, **DRI 80 = 8 rows**, SOF0 4:2:2 |
| Quantization | DQT sum 5781 here (1462 in an older capture): the firmware's rate control picks it | fixed (DQT sum 5111 at every exposure): bytes follow content |
| Bytes per frame (exp ~1 ms) | 21-60 KB (scene and gain) | 45-87 KB |
| Bytes vs sharpness | 1: 57 KB, 5: 61 KB, 10: 82 KB | 0: 63 KB, 50: 84 KB, 100: 114 KB |
| Exposure control | 1..5000 (100 us units). **Not monotonic below 6**: 1, 3, 4 read nearly black; 2 is as bright as ~1.1 ms. Rising from 6 | 2..10000. Roughly linear from 2 to 4 (luma 22, 35, 43 = ~110 per ms). Usable images at 0.2-0.4 ms with gain 128 |
| Gain | 16..128 | 1..128 (default 64) |
| Control defaults | gamma 150, sharpness 5, backlight 1, gain 32 | gamma 300, sharpness 50, contrast 40, gain 64, exposure 6 |
| Controls at power-up | reset to defaults | saved in flash (settings block at 0x1F000), not yet verified across a power cycle |

Notes:
- **Thriftiest exposure mapping.** Measured with brightness 0, gamma 100, gain 128 and 4 s per setting, so
  the 120 Hz bench flicker averages out:
  - mean luma 2.0 (setting 1), 21.4 (2), 2.0 (3), 2.0 (4), 4.1 (6), 8.8 (8), 14.5 (10), 42.9 (15), 64.7 (20).
  - Setting 2 falls between 1.0 and 1.5 ms: ~1.1 ms, which confirms the known bug. 1, 3 and 4 are very short
    (the tester's ~0.3 ms for 3/4), but they sit under the black clip here.
  - In practice: use 2 when you want ~1.1 ms, and 3/4 when you want ~0.3 ms. A firmware fix isn't needed.
- **Exposure longer than the frame** (Thriftiest 100 = 10 ms) stretches the frame to 10.09 ms. The extra
  time shows up between PTS and the first data packet (2.27 ms).
- **Mid-frame PTS.** Each Thriftiest frame starts with ~8 header-only packets that carry the new FID but the
  previous frame's PTS. The real PTS comes with the first data packet. Anything that timestamps "FID
  toggled" is ~1 ms early, and `analyze.py` handles it.

### Modes: real transfer time, and crop or scale (measured)

Each mode's frames were matched against 1280x800 frames of the same scene (`mode_map.py`).

| Camera, mode | First -> last data | PTS -> first data | What it is |
|---|---|---|---|
| Thriftiest 1280x800 | 7.24 ms | 0.35 | full sensor (table 0x1810: 1288x808, HTS 728, VTS 910) |
| Thriftiest 1280x720 | 6.49 ms | **0.71** | **centered crop, rows 40..760, of the full readout**: first data 0.36 ms later (40 rows x 9.05 us), last 0.45 ms earlier. No saving for a tag in the middle |
| Thriftiest 800x600, 640x480 | 6.99 ms | 0.51-0.52 | 4:3 centre (x 107..1173, all rows) scaled down |
| Thriftiest 640x400 | 7.24 ms | 0.38 | 2x2 binned, at the slow line time (binned-fast-readout would halve it) |
| Thriftiest 640x360 | 6.49 ms | 0.75 | the 720 crop, binned |
| Swyft 1280x800 | 7.50 ms | 0.32 | full sensor (1280x800 table: HTS 728, VTS 910) |
| Swyft 1280x720 | 7.00 ms | **0.32** | **centered crop, rows 39..759, but first data comes no later than at 1280x800**, and the frame ends 0.47 ms sooner |
| Swyft 1024x768, 800x600 | 7.39 ms | 0.32 | scaled |
| **Swyft 640x400 @ 210** | **3.75 ms** | 0.22 | 2x2 binned (table: 640x400, HTS 728, VTS 520), frame period 4.75 ms |
| Swyft 352x288 @ 210 | 3.75 ms | 0.22 | binned and scaled |

## Camera delay: what was measured and how sure it is

### LED measurement (2026-11-05, Thriftiest SJ-05, usbrecov 5.13, 1280x800 MJPEG 120 fps)

`uvc_timing --led` pulsed the Pi's green ACT LED for 0.29 ms. Pulses came at 0..8.3 ms after every 4th
frame's first packet, in 0.05 ms steps: 453 pulses in 15 s, scheduling error p99 0.5 us. The camera
faced the LED from ~15 cm, at exposure 10 and gain 64. `led_analyze.py --invert` fitted the dip that
each pulse left in the LED spot as an overlap trapezoid, with error bars from 40 bootstrap resamples.

| | Result |
|---|---|
| **Exposure end -> first USB data packet** | **0.41 +- 0.05 ms** (host clock) |
| Exposure end -> PTS | 0.045 +- 0.02 ms (camera clock): **PTS marks the end of exposure** |
| Exposure at setting 10 | 0.91-0.94 ms |

- **The camera delay constant should be ~0.4 ms, not 2.5 ms.** Published mid-exposure times are ~2.1 ms early.
- **The ACT LED polarity is inverted on this LimelightOS board:** brightness 0 lights it, 1 turns it off.
  Toggle check: 213 vs 69 grey. So the pulses were 0.3 ms dark gaps on a lit LED.
- **The 1280x400 band (VTS 910) gives no latency gain.** Its first data came 4.06 ms after PTS. If PTS is
  exposure end there too, exposure end -> last row stays ~7.6 ms. The band only pays off with a shorter
  VTS (~240 fps), which needs the frame-rate code. The flicker test (+2.7 ms) agrees roughly.

Data (laptop scratch, kept for re-analysis): frames, index and pulse log of this run.

### Before the LED test

- **Measured.** The SCR carries the camera's source clock for every packet. Its fit to host time has
  residuals of a few microseconds and a slope of exactly 48.000 / 15.000 MHz. So "PTS -> first data
  packet" is a camera-clock interval, with no host jitter in it. It is 0.35 ms (Thriftiest) and 0.32 ms
  (Swyft) at 1280x800, and 0.22 ms on the Swyft at 640x400.
- **The same at every exposure.** From 0.1 to 5 ms the interval doesn't move (Thriftiest 1-50, Swyft
  2-20). So PTS isn't exposure start. It is a fixed point of the sensor frame (VSYNC, just before readout).
- **Readout-paced, so nothing is held back.** A frame's first-to-last time is 7.24 ms whether it carries
  21 KB or 60 KB. Data starts 1 MCU row (8 sensor rows, 0.07 ms) into readout.
- **The inference (not measured).** The OV9281 global shutter ends exposure when it starts the frame
  readout (shutter, then readout from the storage nodes). So **exposure end -> first USB packet ≈ PTS ->
  first packet ≈ 0.3-0.45 ms**, plus less than 0.1 ms if exposure actually ends a few lines before
  readout. An exposure that ended much earlier, with the image held in the pixel storage nodes, would show
  up as a gap. Only an LED or spin test can rule that out.
- **Confidence: medium-high.** The camera's part (PTS -> packet) is exact. The sensor's (exposure end vs
  PTS) comes from how the OV9281 works plus the exposure-invariance above.
- **Consequence.** Mid-exposure = first packet - 0.35 ms - exposure/2 (and minus the host's packet latency,
  ~0.1 ms with 0.5 ms URBs). The 2.5 ms constant (Team 100's figure) is probably a host-side number: with
  uvcvideo's 32-packet URBs, timestamps land up to 4 ms after the packet. **Proposal:** a camera delay of
  0.4 ms for the native app (which timestamps the first packet), after one LED test.
- **How to confirm without new gear:** a phone-screen or LED flash test with `uvc_timing`. Flash an LED from
  a GPIO at a known `CLOCK_MONOTONIC` time and find the first frame that shows it. The same tool's packet
  times give the rest.

## Proposals, ranked

Gains are per frame. "Readout" means the time until the frame's last row reaches the host. With streaming
decode and NAPA, pose is ready ~0.1 ms after that, so a readout saving is an end-to-end saving.

| # | Change | Kind | Expected gain | Risk | Recovery | Approval |
|---|---|---|---|---|---|---|
| 1 | **Camera delay 2.5 -> 0.4 ms** in the timestamp | software constant | Timestamps ~2.1 ms more accurate; reported mid-exposure->pose drops ~2.1 ms. No real latency change | none (one LED/spin check first) | revert the constant | none |
| 2 | **Sharpness at minimum** (Swyft 0, Thriftiest 1), gamma 100, gain as low as the exposure allows | V4L2 settings | Swyft 84 -> 63 KB: ~-0.8 ms decode per frame (est., at ~0.039 ms/KB from the builder's decode numbers), ~10% of a core at 120 fps. Thriftiest ~-0.15 ms | none | | none |
| 3 | **Swyft 640x400 @ 210 fps** where half resolution is enough (near tags) | mode choice | readout 7.5 -> 3.75 ms (-3.75 ms), frame every 4.75 ms (-1.8 ms average age) | none; detection range halves | | none |
| 4 | **Thriftiest exposure: use 2 (~1.1 ms) or 3/4 (~0.3 ms)**, never assume 1-6 is linear | setting | correct exposure and timestamps (exposure/2) | none | | none |
| 5 | ~~Thriftiest binned-fast-readout~~ **tested 2026-11-05: no effect** | 14-byte sensor-table patch | none: 640x400 MJPEG is the bridge scaling the full readout (see the window tests); the binned table isn't used by any MJPEG mode | | | |
| 6 | **Full-pitch window, 1280x400 at 120 fps** (`window400-test` + `window400-mode`, **tested on the spare**) | sensor table + bridge mode record + descriptor values | transfer 7.24 -> **3.61 ms** measured; latency gain **unproven**: the band is read at the end of the frame (below), and every other mode stops streaming | medium: works, but breaks 1280x800 until a per-mode sensor table exists (code) | reflashed over USB 3 times, fine | LED test first, then code tracing |
| 7 | Thriftiest 1280x720 as a real sensor window (rows 40..760) | sensor table + mode mapping | first data 0.36 ms sooner, readout -0.7 ms | medium (mode mapping not traced) | reflash | yes |
| 8 | Thriftiest JPEG quality clamp (rate-control limits in the struct at 0x77FF) | data constant | fewer bytes: ~0.04 ms of decode per KB (est.) | low/medium; needs a tag-decode check | reflash | yes |
| 9 | Swyft power-up defaults (sharpness 0, gamma 100) in the settings block at 0x1F000 | data block | none if software sets them; fewer flash writes | low (data sector) | boot loader + power cycle | yes; check how the camera saves first |
| - | Larger USB payloads / higher packet rate | | none: readout-paced (59-61 packets of 0.8-1.4 KB a frame, well under alt 8/5) | | | |
| - | Smaller restart interval | | none: already 8 rows, the minimum for 4:2:2 | | | |
| - | Grayscale JPEG | | ~15% fewer bytes on the Thriftiest; the encoder's format register is unknown | high | | |
| - | Faster full-resolution line time (PLL / HTS < 728) | | readout down to ? | high: past the OV9281's 120 fps spec, unknown bridge input limit | | |

**Test first:**
- 1, 2, 3 and 4 need no approval: they are settings and constants.
- Firmware: run the LED test on both full height and the 1280x400 band before any more flashing (see
  "Tested on the spare"). Then trace the code (Ghidra, ~450 MB download, needs approval) for a per-mode sensor
  table.

## Windowed (cropped) full-resolution readout

### Tested on the spare Thriftiest SJ-05 (2026-11-05, user-approved)

Each image was built with `firmware/thriftiest/patches/make-patched.py` from the published 5.13 and flashed
with `thriftiest-fw.py` while holding the camera lock. The camera was backed up first, restarted by itself
every time, and kept its serial.

| Image | sha256 | Result |
|---|---|---|
| usbrecov + binned-fast-readout | `3a3cb04d…` | 1 sector. **No change anywhere**: 640x400 still takes 7.24 ms, period 8.25 ms. 1280x800 unchanged (7.24 ms, 121 fps). NAPA at 640x400: first packet -> pose 8.40 ms vs 8.41 before; 100% tags; decode 0.60 ms + NAPA 0.62 ms per frame, vs 1.95 + 1.53 ms at 1280x800. Asking for 160/200/240 fps at 640x400 (standard probe) is clamped to 120 |
| usbrecov + window400-test (sensor table 0x1810: rows 200..615, 408 output rows) | `1500cdd9…` | The sensor reads the band: 30 data packets, 3.61 ms. But the bridge still expects 808 rows: every frame is flagged ERR, one frame per two sensor frames (16.5 ms), no EOI. **1280x800 and every mode derived from the full table stop streaming** (a plain `v4l2-ctl` 1280x800 capture hangs) |
| usbrecov + window400-test + **window400-mode** (1280x720 -> 1280x400: bridge mode records at 0x72AC/0x743C, frame descriptor 3, still-image list) | `f9e1976a…` | Enumerates with **1280x400 @ 120 fps** in place of 1280x720. **Works**: 120 fps (8.25 ms), 0 ERR, SOF 1280x400, DRI 80 = 8 rows, 50 restart intervals, ~20 KB a frame, **first -> last packet 3.61 ms**. 1280x800 is still broken (shared sensor table) |
| usbrecov (restore) | `9a6eedb6…` | 1280x800 streams again (121 fps, 7.24 ms). This is what the camera runs now |

**Where the band lands in the frame.** With VTS unchanged (910 lines), the sensor reads the 408-row band at
the **end** of the frame: first data comes 4.06 ms after PTS (0.35 ms at full height), and the last data at
7.65 ms after PTS, the same as full height. Whether this cuts latency depends on where exposure ends:
- **If exposure ends just before readout** (OV9281 global-shutter behaviour), exposure end -> last row drops
  from ~7.6 to ~4.0 ms. That is -3.6 ms.
- **If exposure stays tied to the frame start (PTS)**, nothing is gained.

A first flicker-phase test (`flicker_phase.py`, the Swyft streaming at the same time as reference) moved
the Thriftiest's apparent exposure by +2.7 ms between full height (-1.6 ms vs the Swyft) and the band
(+1.1 ms). That is between the two predictions (0 and +3.7 ms), with no repeat runs yet, so it is
inconclusive. **The LED test (`led-test.sh`) settles it.**

If the band only helps once it is read early, add **VTS 910 -> ~460**: the band then runs at ~240 fps, read
right after a short blanking. That needs a frame-interval change in the descriptor, and the firmware
clamps probe requests to 120 fps, so it also needs the interval-to-rate-slot code (not traced).

**The bridge's per-mode records** (found 2026-11-05) explain both results. There are two copies: 0x7270
(from 0x727A) and 0x7400, 26 bytes per UVC frame in descriptor order, big-endian:
`09 00 00 00`, a flags/mode word, sensor output W,H, crop x,y, crop W,H, scaler W,H, output W,H.
- 1280x800 crops 1284x804 at (2,2) of 1288x808.
- 1280x720 crops 1284x724 at (2,42).
- 640x400 and 640x360 *scale* the same crops by 1/2.
- 800x600 and 640x480 scale a 1028x772 crop at (130,18).
- Every MJPEG mode takes the full 1288x808 sensor frame: the binned (0x19E4) and 656x488 window (0x1B54)
  sensor tables aren't used.

**A production 1280x400 needs its own sensor table**, so that 1280x800 keeps working:
- Either the code that loads the full table must pick a table by mode, or the window registers must be
  written after it for that mode.
- Both need the code traced: Ghidra 12.x with `firmware/thriftiest/tools/DumpListing.java`. It isn't
  installed here (a ~450 MB download).
- Until then, a camera flashed with window400-mode is a 1280x400-only camera.

**Calibration for 1280x400 (rows 200..599 of the 1280x800 image).**
- Same fx, fy, cx and distortion coefficients.
- **cy_400 = cy_800 - 200**. The window starts at sensor row 200 and the bridge crop starts at row 2 of
  the sensor output, as for 1280x800, so the offset is exactly 200 rows.
- For the stand-in calibration (cal.json, cy 417.8) that gives cy 217.8.

Goal: read a band of full-pitch rows (e.g. 1280x400) where field tags appear. Readout time drops in
proportion to rows and tag range is kept. 2x2 binning halves the range instead.

### What the cameras already offer (measured above)

- **Neither has a band mode narrower than 720 rows.** The only 1280-wide crop is 1280x720.
- **Thriftiest 1280x720** reads the whole sensor and drops 40 rows at each end in the bridge. That makes it
  *worse* for the first rows (+0.36 ms) and only 0.45 ms better for the last.
- **Swyft 1280x720** is a centered window whose first data comes as early as at 1280x800, ending 0.47 ms
  sooner. It looks sensor-side (or retimed), but the Swyft image holds only two sensor tables (full and
  binned), so the window must be set in code at stream start.
- The Thriftiest also has an unused-looking sensor table **0x1B54**: a full-pitch **656x488 window**
  (X 256..975, Y 160..655), HTS 663, VTS 574. No UVC mode we measured uses it: 640x480 turned out to be the
  scaled 4:3 centre. It shows the firmware's table format already handles windows.

### OV9281 windowing registers (from the firmware tables)

| Register | Full (Thriftiest 0x1810 / Swyft) | 1280x400 window, centered | Note |
|---|---|---|---|
| 0x3800/01, 0x3804/05 | X 0..0x50F (1295) | unchanged | full width |
| **0x3802/03** | Y start 0 | **0x00C8 (200)** | the band's top row; move it to shift the band |
| **0x3806/07** | Y end 0x32F (815) | **0x0257 (599)** = start + 399 + 8 (ISP margin) | |
| 0x3808/09 | output width 0x508 / 0x500 | unchanged | |
| **0x380A/0B** | output height 0x328 (808) / 0x320 | **0x0198 (408)** / 0x0190 | Thriftiest outputs 8 extra rows (ISP offset 0x3813 = 8) |
| 0x380C/0D | HTS 0x2D8 (728) | **unchanged** | the line time (9.05 us/row measured) stays: readout = rows x 9.05 us |
| **0x380E/0F** | VTS 0x38E (910) = 120 fps | **unchanged** for 120 fps; 0x1CA (458) for ~240 fps | keeping VTS keeps the frame rate, so no frame-interval change is needed |
| 0x3810-0x3813 | ISP offsets | unchanged | |
| 0x3501/02 | exposure | unchanged | max exposure stays ~VTS-limited (8 ms at VTS 910) |

400 rows x 9.05 us = 3.6 ms of readout, against 7.24 ms now. At 120 fps (VTS 910) the remaining 4.6 ms is
blanking. At VTS 458 the band runs at ~240 fps, which needs a frame-interval change in the descriptor.

### Thriftiest: what a 1280x400 mode would take

The least risky route repurposes the **1280x720 mode**: nothing uses it, and its descriptors are the same
length as the 1280x800 ones.

1. **Descriptor (same length, values only).**
   - MJPEG frame descriptor at **0x5A35** (`1e 24 07 03 ...`): wHeight at 0x5A3C `d0 02` -> `90 01` (400).
     dwMaxVideoFrameBufferSize at 0x5A42 `00 20 1c 00` -> `00 a0 0f 00` (1,024,000). The bit-rate fields
     are informational.
   - The still-image list at 0x5ACB (720 at 0x5ADA) should match.
   - The YUY2 copy at 0x5B4E can stay or be changed the same way.
   - Enumeration itself survives wrong values in these fields: the structure and lengths don't change.
2. **Resolution table** at 0x7270 (width/height pairs in descriptor order): the 720 entry -> 400. The
   bridge's scaler and JPEG encoder (SOF height, MCU-row count) take their size from it. That is inferred
   from the earlier analysis: verify that SOF reads 400 and 50 restart intervals arrive.
3. **Sensor table.** 1280x720 shares table 0x1810 with 1280x800 today; its 40-row crop is in the bridge.
   - It needs its own table: a copy of 0x1810 with the Y registers above, VTS 910.
   - Tables are listed in a directory at 0x1E01 (`{count16, 00 80, ptr16}`, 3 entries), plus a per-rate
     HTS directory at 0x1D21 (3 modes x 8 rates).
   - **The code that maps a UVC frame index to a sensor-table index isn't traced yet.** A 4th directory
     entry needs that code changed, or a table/rate slot reused. One option: repoint the 0x1B54 (656x488
     window) entry at a new 1280x400 table placed in free flash, if 0x1B54 is really unused.
   - Possible shortcut: if the frame-to-table map is a data table, it's a 1-byte change; if it's code, a
     small code patch.
4. **The bridge's crop of the 720 mode** (the 40-row offset, probably 0x27xx/0x37xx pipe registers from the
   tables at 0x6CB9-0x6EAD) must become 0. Otherwise it drops 40 of the 400 rows.

**Risk.**
- Descriptor value edits: low for enumeration. The camera still enumerates and the XU / maintenance-mode
  path is untouched, so it can be reflashed over USB.
- The real risk is the bridge mishandling a 400-row frame: a stall, garbage, or a watchdog reset. All of
  these keep the camera reachable.
- **Never on a robot camera before a spare passes.** The patch must not touch USB/XU code, so there is no
  path to a bricked enumeration.

**A simpler experiment** (same risk class as binned-fast-readout, no descriptor change): window the
*binned* 640x400 table instead.
- That keeps binning, so it's of little value. Shown here only because it needs no code.
- A sensor-only change to the 1280x800 table, with the descriptor still saying 800 rows, would most likely
  make the bridge wait for rows that never come. Not proposed.

**Expected:** first->last data 7.24 -> ~3.6 ms; first packet -> pose 8.3 -> ~4.7 ms (est.); bytes and decode
CPU about halved (half the rows); vertical FOV 50%.

### Swyft: what it would take

- The Realtek image keeps only two sensor tables (full at 0x1AFB, binned 640x400 at 0x19EC). Each entry is
  3 bytes, `RH RL VV`.
- Per-rate HTS lists sit just before them (`00 fps HTS16` + `00 09 89 68` per entry).
- There are no UVC descriptor bytes in clear form (no `00 05 20 03` / `85 45 01 00` patterns), so the
  descriptors are generated or stored in another layout.
- 1280x720 is evidently windowed in code. The same code path could produce 1280x400 by changing its
  window constants, but finding it needs an 8051 disassembly of the Realtek image (not done; no Ghidra on
  this laptop).
- **Risk:** medium-high.
- **Recovery:** the boot loader (XU write 0xFF92 + vendor request) needs working application firmware.
  Swyft's tool writes the `55 AA` tag at 0x0FFE last, presumably so a broken image falls back to the
  boot loader (untested). Every boot-loader trip needs a real power cycle (neither the Jetson nor the Pi can
  cut port power).
- Lower priority than the Thriftiest route.

### Making the window position adjustable

- **Fixed offset (recommended):** bake Y start into the table for each camera's mount, e.g. the band from the
  horizon down. One image per mount height, or two images (upper and middle band).
- **Live control:** OV9281 0x3802/03 can change between frames (group hold 0x3208), so a UVC control could
  move the band. That needs firmware code to route an existing control to it.
  - The Swyft advertises Roll (Absolute) on its input terminal, and both advertise Hue (useless on mono).
  - It is a code patch in the XU/control handler area: higher risk, and not proposed for a first test.
- **Zero-flash prototyping isn't possible within our rules.** The Thriftiest's XU register writes
  (`thriftiest-fw.py Cam.wreg`) could try a sensor window live, but that is a vendor/XU command and needs
  approval. The OV9281 I2C path through the bridge registers is also unknown.

### Timestamp and calibration with a window

- **Timestamp:** unchanged if it is referenced to the first packet. Exposure end -> first packet stays
  ~0.35 ms, because the first windowed row is read first. A pipeline that timestamps the *last* packet (or
  frame completion) must subtract the shorter transfer (3.6 ms instead of 7.24).
- **Calibration:** same pixel pitch, so fx, fy, the distortion coefficients and cx stay. **cy shifts by
  -Y_offset**, measured in output rows. For a window starting at sensor row 200, with the Thriftiest's
  8-row ISP offset and a 1280x800 calibration whose row 0 is sensor row 8: cy_400 = cy_800 - 200.
  - Make a 1280x400 calibration by copying the 1280x800 one and editing cy. Check it once with a target.
  - Distortion is a function of the full-frame coordinates: shifting cy (with the same coefficients) is
    exact, because the model is centered on (cx, cy).

## Firmware facts found on the way (Swyft)

- The **low-exposure and stock images have identical sensor tables**. The only difference is 0x0100
  (stream on) at the end of the stock full table. The exposure range differs in code: the GET_MIN
  constant is `00 02` in low exposure and `00 32` in stock (0x24A9 / 0x24E6). The ~63 KB of other
  differences are a different build.
- **Binned 640x400** runs at HTS 728, VTS 520 (210 fps). The per-rate list also has a 120 fps entry at
  HTS 1282 (slow readout), but the low-exposure descriptors advertise 640x400 at 210 fps only.
- **Settings block 0x1F000:** see [SWYFT-CAMERA-FIRMWARE.md](SWYFT-CAMERA-FIRMWARE.md). The camera
  writes its control values there.

## Firmware facts found on the way (Thriftiest)

- **Rate control.**
  - At start, RAM 0x98E/0x98F (the JPEG quality-index clamps used by the per-frame rate control at
    0x818114) are loaded from offsets 0x10/0x11 of a config struct at flash **0x77FF**: `00` and `2F`.
    That struct's pointer is stored by `7E 34 77 FF; 7E 24 00 80; 7A 1F 04 EC` at 0x18A73.
  - The struct's other fields go to 0x986/0x991/0x987/0x9A0 etc. The size buckets 0x988-0x98D are written
    elsewhere (0x18584).
  - A quality clamp (proposal 8) would edit 0x780F/0x7810, but which end of the index is coarse needs one
    live comparison of DQT vs index first.
- The 640x480 and 800x600 UVC modes are the 4:3 centre of the full readout, scaled. The windowed 656x488
  sensor table at 0x1B54 isn't used by any MJPEG mode we measured.
