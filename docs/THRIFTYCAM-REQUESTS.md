# ThriftyCam (USB 3) — what we'd like improved

Draft notes for The Thrifty Bot, from bench tests on a Raspberry Pi 5
(LimelightOS SystemCore) on 2026-11-06. Camera: OmniVision OG02B1B
1600x1304 mono global shutter, Sunplus SPCA2630 bridge, USB ID 05c8:0a00,
USB 3 (5 Gbps, isochronous). Our use: AprilTag localisation at the lowest
possible latency, several cameras per robot.

## What already works well

- Real USB 3 link on both Pi 5 blue ports (the first USB 2 link was a plug not
  fully seated).
- Best far-tag view of our three cameras: ~1.6x the pixels on target of the
  Thriftiest/Swyft, and the best decode margin on our 2.85 m tag.
- Software resets recover in 0.45–0.87 s and stay at USB 3.
- Saved settings persist.

## Requests, most important first

1. **Higher frame rate / shorter readout.** Every mode is 60 fps, and the
   sensor reads out at 11.7 µs per row: 15.5 ms per full frame, the same in
   YUYV and MJPEG at any USB bandwidth. That readout is our latency floor:
   capture → pose ~17 ms, vs ~9 ms for the 120 fps Thriftiest and Swyft.
   We'd like, in order:
   - a faster sensor readout clock if the OG02B1B allows it;
   - 120 fps (or more) modes: a full-width centre band (e.g. 1600x800 or
     1600x650) and a 2x2 binned full-FOV mode (800x652) — like the
     Thriftiest 5.17's 1280x400 @196 and 640x400 @240;
   - lower modes that are true binning or centre crops. Today 1280x720 and
     640x480 are scaled from the **top** of the sensor, so they lose FOV and
     don't shorten readout.
2. **A unique serial number** in the USB descriptor. Today there is none, so
   we must match the camera by USB port path. On a robot with several of
   these, cameras can't be moved between ports without reconfiguring.
   (The Thriftiest and Swyft each report a serial.)
3. **Exposure in real time units**, linear (e.g. 0.1 ms per step), as the
   Thriftiest 5.17 now does. Today we estimate ~0.8 ms at setting 8 only from
   frame timing.
4. **Gain with usable range.** Gain 0–4 saturates from 1 on our bench, so
   there's effectively one setting. A finer analog gain (or documented
   steps) would let us run shorter exposures.
5. **A frame timestamp from the camera**: the UVC payload header PTS/SCR at
   start of exposure (or start of readout), so we can measure camera delay
   instead of assuming it (we assume 0.7 ms today).
6. **Settings saved to flash only on change**, and documented, so writing the
   same value doesn't wear flash; and settings surviving a power cut while
   streaming (as the Thriftiest 5.17 now does).
7. **Document the vendor extension unit controls** (JPEG quality,
   bandwidth/compression). We read them but haven't written any, since we
   don't know which persist in flash.
8. **Lower isochronous bandwidth option** (smaller alt setting / higher
   compression) so several cameras can share one USB 3 controller.
9. **A firmware update path** we can run ourselves on Linux, with version
   readable over USB (as with the Thriftiest).

## Lower priority

- Published sensor timing (row time, readout per mode) and lens data
  (focal length, distortion) to seed calibration.
