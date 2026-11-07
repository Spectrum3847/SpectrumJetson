# ThriftyCam (USB 3) characterization

Bench Pi 5 (LimelightOS SystemCore beta18), 2026-11-06, 22:13-22:42 CST. Measurement only: nothing written to
the camera's flash, only standard UVC GET requests to its extension units.

Camera: Thrifty Bot ThriftyCam (TTB-0241), OmniVision OG02B1B mono global shutter, 1600x1304. USB `05c8:0a00`,
manufacturer "DCX-240524--XH", product "SPCA2630 PC Camera", bcdDevice 5.24, **no serial number**.

Tools (copy to `/dev/shm/tc` on the target; hold `/tmp/camera.lock`):

- `tc_probe.py MODE WxH` (`FMT=MJPG|YUYV`): `grab WxH EXP GAIN` (rate, margin proxy, jitter, tag sizes for
  crop/scale), `mapping` (exposure -> mean DN), `effects` (each control at min/max), `sweep` (exposure, gain,
  sharpness). OpenCV aruco 36h11; "margin" is white-ring minus black-border DN, not AprilTag's decision margin.
- `xu_dump.py /dev/videoN 3:1-5 4:1-24`: GET_LEN/INFO/CUR/MIN/MAX/DEF per extension-unit selector (read only).
- `../camera-reset/reset_timing.py thriftycam METHOD 5`: reset timing at 1600x1304 60 fps; rows now include
  `speed` (5000 = still SuperSpeed after the reset).
- NAPA numbers below come from `sc-vision-fw --usb 05c8:0a00 --size 1600x1304 --fps 60 --min-tag 22`
  (branch sc/mjpeg-napa streaming decoder) and `napa_stats.py`.

## USB

- **USB 3 is real**: bcdUSB 3.10, 512 mA, BOS with SuperSpeed capability, isochronous alt 1-17. Alt 17 has
  33792 B per service interval (about 270 MB/s), and the device asks for 33792 max payload.
- The first plug came up **high speed** on the lower blue port (1-1, the HS side of the SS port 2-1). The
  device then shows a reduced fallback set (bcdUSB 2.10, alt max 3x1024 = 3072 B/uframe, and
  "max payload 3141 exceeds 3072"). After a replug it linked SuperSpeed on both blue ports (4-1 upper,
  2-1 lower), so a marginal cable or insertion caused the HS link, not the port. At HS it still ran
  1600x1304 MJPEG at about 59-60 fps.
- dmesg at SS: "Could not enable U1 link state" (exit latency too large). Harmless.
- Pi 5 layout: each RP1 xHCI controller has one blue port (USB 3 bus 2 or 4, plus its HS side on bus 1 or 3)
  and one black USB 2 port. SS traffic on bus 2/4 doesn't share bandwidth with the USB 2 bus of that
  controller (CANable on 1-2, Thriftiest/Swyft on 3-x).

## Modes

| Link | MJPEG | YUYV |
|---|---|---|
| SuperSpeed | 1600x1304, 1280x720, 640x480, all 60 fps only | same three, 60 fps (1600x1304 delivered 52.5 fps; 1280x720 opened but gave no frames in OpenCV) |
| High speed | 1600x1304, 1280x720, 640x480, 320x240, 60 fps | 1600x1304 at 5 fps |

There is no 1280x800, no 120 fps, and no binned mode. 1280x720 is the **top** 1600x900 of the sensor scaled
0.8x, and 640x480 is the top 1600x1200 scaled 0.4x. Both cut the bottom of the field of view, so
calibrations don't transfer between modes.

## Timing and JPEG (SS, 1600x1304 60 fps, exposure 0.8 ms)

- First to last packet 15.4 ms (uvc_timing) and 17.3-17.6 ms (sc-vision): the camera spreads each frame over the
  whole period. 1280x720 takes 12.7 ms and 640x480 14.0 ms. PTS is about 0.7 ms before the first packet;
  the SCR clock is 125 MHz.
- JPEG: 4:2:2 (Y 2x1, MCU 16x8), DRI = 1 MCU row = 8 pixel rows, 2 DQT, 4 DHT. Frames are 100-140 KB
  in uvc_timing and sc-vision, and 230 KB via uvcvideo/OpenCV.
- sc-vision streaming NAPA, min tag 22: 7 tags in 98% of frames; EOF->pose p50/p95/p99 0.28/0.52/0.68 ms;
  decode 4.5 ms and NAPA 3.0-3.3 ms of CPU per frame; tag 12 (about 2.85 m) margin p50 109, or 117 at
  sharpness 50; side 41.5 px.

## Controls

| Control | Range | Default | Effect |
|---|---|---|---|
| auto_exposure | 1 manual / 3 aperture priority | 3 | |
| exposure_time_absolute | 3-8192 (100 us) | 500 | Roughly linear, no below-6 anomaly; 60 fps holds to 166, 49 fps at 200 |
| gain | 0-4 | 0 | Coarse: each step about +40-60% DN; at 2 or more the frame saturates |
| brightness | -64..64 | 0 | Offset |
| contrast | 0-95 | 0 | Raises tag contrast, loses far tags |
| gamma | 100-300 | 100 | Washes out at 300 |
| sharpness | 0-100 | 0 | 50 improves far tags (tag 14: 43% -> 82%) |
| backlight_compensation | 0-1 | 0 | Small brightening |
| saturation, hue | 0-100, -2000..2000 | 0 | None (mono) |

**Controls persist** through a physical unplug and through every software reset, so they look stored in
non-volatile memory, as on the Swyft. Write a control only when it differs.

Recommended for tags: manual exposure 8, gain 0, sharpness 50 at 1600x1304 MJPEG 60. 
Exposure 5-6 with sharpness 50 if motion blur matters.

### Sweep at SS (1600x1304, OpenCV, rate/margin proxy/jitter px)

| exp/gain/sharp | mean DN | tag 12 | tag 13 | tag 14 | tag 15 |
|---|---|---|---|---|---|
| 3/0/0 | 53 | 0.98/59/0.47 | 0.85 | 0.07 | 0 |
| 5/0/0 | 79 | 1.00/91/0.46 | 0.92 | 0.48 | 0.02 |
| 6/0/0 | 98 | 0.98/112/0.40 | 0.90 | 0.65 | 0 |
| 8/0/0 | 109 | 1.00/123/0.34 | 0.95 | 0.43 | 0.02 |
| 10/0/0 | 120 | 1.00/132/0.33 | 0.85 | 0.22 | 0 |
| 5/1/0 | 131 | 0.98/144/0.40 | 0.85 | 0.17 | 0 |
| 5/0/50 | 85 | 0.97/114/0.53 | 0.90 | 0.65 | 0.05 |
| **8/0/50** | 104 | 1.00/136/0.47 | 0.98 | 0.82 | 0.17 |
| 8/0/100 | 103 | 1.00/135/0.45 | 1.00 | 0.75 | 0.13 |

Same tags in PhotonVision, 8 s: the Thriftiest SJ-05 at 12/128 has tag 12 margin 49, side 25.5 px, and tag 13 at 2.5%.
The Swyft at 5/96 has tag 12 margin 85, side 27 px, and tag 13 at 99%. Both run 120 fps. The ThriftyCam has
about 1.6x the pixels per tag at half the rate.

## Firmware (read only)

- SunplusIT **SPCA2630** bridge (VID 05c8), bcdDevice 5.24; the manufacturer string is likely a 2024-05-24 build tag.
  The Thriftiest is an SPCA2089D (1bcf:28c5, 5.13).
- XU unit 3 `{0fb885c3-68c2-4547-90f7-8f47579d95fc}` (5 controls) is the same GUID as on the Thriftiest.
  XU unit 4 `{7d5a1d99-5b32-428b-8cad-671b8a65f37a}` (23 controls) differs from the Thriftiest's flash XU
  `{63610682-...}`. Selector 22 is a 64-byte window that reads like 8051 code, and selectors 18, 19 and 23 look like
  address/latch registers. Selectors 10 and 15 are 1024-byte blocks; 3:5 and 4:17 are not readable.
- **usbrecov and `thriftiest-fw.py` don't apply**: different chip, XU and flash protocol. Don't send
  them to this camera.
- **Serial**: none, and there's no known way to write one. Two ThriftyCams would share the by-id name. Until Thrifty
  Config (or a reverse-engineered SPCA2630 flash map) supports a serial, identify each one by USB port path
  (`/dev/v4l/by-path/...-usb-0:1:1.0-video-index0`), one camera per fixed blue port.

## Resets (SS, 1600x1304 60 fps, 5 repeats each, PV running the other two cameras)

| Method | Node back (s) | First frame (s) | First tag (s) | Link after | Controls |
|---|---|---|---|---|---|
| reopen | n/a | 0.45-0.60 | same | 5000 | kept |
| usbreset | 0.23-0.25 | 0.72-0.74 | same | 5000 | kept |
| rebind | 0.12-0.13 | 0.60-0.61 | same | 5000 | kept |
| authorize | 0.21-0.22 | 0.70-0.71 | same | 5000 | kept |
| yank (3 s) | 0.22-0.24 | 0.86-0.88 | same | 5000 | kept |

## Integration notes

- MJPEG 1600x1304 at 60 fps, 4:2:2, one restart interval per 8 rows: the streaming NAPA decoder handles it
  as is. Use a 1600x1304 calibration. There is no 1280x800.
- Frame data arrives over about 16-17 ms, so end of exposure to pose is about 17.5 ms even with streaming.
  The Thriftiest/Swyft at 120 fps take about 9.5 ms.
- No serial: match by port path. Controls persist in the camera, so set them only when they differ.
- Bandwidth: SS on its own bus. Three cameras fit: the Thriftiest and Swyft on one controller's USB 2 bus
  (as now), the ThriftyCam on the other controller's SuperSpeed bus. The CANable shares only the HS bus
  of the ThriftyCam's controller.

## USB timing and host latency (2026-11-06, 23:27-23:32 CST)

Tools: `native/sc-vision/tools/uvc_pkttrace` (per-frame packet timing; `--alt`, `--yuyv`, `--fps`, `--frame-index`)
and `scv_stats.py` (sc-vision CSV summary). Both take the camera from PhotonVision with `--force`; PhotonVision
reconnects by itself when they exit.

**The ~15.2 ms spread is the sensor readout, not the encoder or USB.** At alt 17 MJPEG packets average 1.8 KB
(max 2.5 KB of 33.8 KB allowed), one every 125 us, no idle gaps, sized by image content: the camera sends rows as
the sensor reads them. YUYV has the same spread as MJPEG in every mode (1600x1304 15.3 ms, 1280x720 10.4-10.5 ms,
640x480 14.0 ms), and the spread scales with the rows read from the top of the sensor (1304/1200/900 rows, 11.7 us a
row). At 30 fps the spread doubles to 30.4 ms: the readout clock follows the frame rate. The camera's own SCR clock
agrees with host timing within 0.05 ms; first packet - PTS 0.69 ms.

| Run (1600x1304 MJPEG unless noted) | fps | spread p50 ms | KB/frame p50 | full packets |
|---|---|---|---|---|
| alt 17 (33792 B, default) | 60.27 | 15.25 | 219 | 0% |
| alt 8 (2048 B) | 60.27 | 15.25 | 219 | 24% |
| alt 4 (640 B) | 60.23 | 16.37 | 80 (encoder lowers quality) | 99% |
| alt 2 (384 B) | 40.2 | 26.3 | 78 | 100% |
| alt 1 (192 B) | 30.1 | 32.4 | 46 | 100% |
| YUYV alt 17 | 60.28 | 15.31 | 4075 | 99% (at the bus limit) |

Hidden modes: none. The camera accepts any frame interval in PROBE/COMMIT (120, 90 echoed back) but still
delivers 60 fps; 30 fps works. Frame indices 4 and 5 (unlisted) stream as 1600x1304 and 1280x720.

Host side, sc-vision `--min-tag 22`, 10 s each, back to back (EOF = reap of the URB with the last packet):

| Option | first pkt -> tags p50/p99 ms | EOF -> tags p50/p99 ms |
|---|---|---|
| defaults (4 pkts, 32 URBs, no pinning) | 15.85/17.41 | 0.29/0.71 |
| --cpu 3 --fifo 50 | 15.84/16.02 | 0.28/0.55 |
| --cpu 0 --fifo 50 (the xhci IRQ core) | 15.84/16.04 | 0.29/0.56 |
| --urbs 8, cpu 3 fifo 50 | 15.82/15.99 | 0.27/0.54 |
| --pkts 8 | 16.27/16.48 | 0.52/0.76 |
| --pkts 2 | 15.62/15.86 | 0.19/0.31 |
| --pkts 1 | 15.53/15.69 | 0.03/0.06 |

U1/U2 hardware LPM are already disabled on 2-1. xhci interrupts all land on CPU0.
| --pkts 1, no pinning (new SuperSpeed default) | 15.57/17.93 | 0.03/0.13 |

CPU (sc-vision, cpu 3 fifo 50, 8 s): 4 packets 58.8% of a core, 2 packets 60.6%, 1 packet 63.6%. More URBs (8 or 32)
change nothing; 128 URBs aborted (usbfs memory). Pinning + SCHED_FIFO trims the p99 (17.41 -> 16.02 ms first ->
tags). **Applied:** uvc_usb defaults to 1 packet a URB at SuperSpeed (4 at high speed), saving ~0.3 ms p50 and
~0.5 ms p99 for ~5% of a core. The remaining ~15.5 ms is readout and can't be removed from the host side; only a
shorter mode (1280x720: 10.5 ms, but a crop of the top of the sensor) shortens it.

### Tags and JPEG quality

- Frame bytes are the same at alt 8 and alt 17 (219-229 KB), and drop only when the alt forces it (alt 4: 80 KB).
  More bandwidth doesn't give cleaner MJPEG beyond ~2.5 KB per interval; alt 17 (the default) is fine.
- Luma DQT (first row 21 13 13 21 13 13 21 21 ...): a mid quality (~60), not near-lossless, with plenty of USB
  headroom (1.8 KB used of 33.8 KB per interval). A quality control would be the one tag-side gain left.
- Same light, 8 s each: tag 13 at 100%, margin p50 132, side 35.2 px, 5 tags a frame (8/0/sharpness 50).

### Extension-unit candidates (read only; not written)

GET_CUR/MIN/MAX/DEF only. Possible quality/rate controls, for the user to decide on (each write may persist):
unit 3 sel 4 (2 B, 0x0400-0x0800, cur = max 0x0800; same GUID as the Thriftiest), unit 3 sel 2 (0-6, cur 1),
unit 3 sel 3 (1-4, cur 1), unit 4 sel 7 (1-13, cur 1), unit 4 sel 8 (0-255, cur 3, default 0), unit 4 sel 16
(0-3, cur 0). Sharpness/contrast sweeps were not repeated (they are flash writes; see the sweep table above).
