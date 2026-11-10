# Thriftiest Cam firmware

Thrifty Bot publishes Thriftiest Cam firmware at
<https://docs.thethriftybot.com/software/thriftiest-cam-firmware/latest/overview>.
Check that page for new releases: Thrifty Bot is now shipping updates, so a fix for the
"stuck after a USB hub reset" problem (README, Known issues) may come this way.

The **ThriftyCam** (USB 3, OG02B1B, `05c8:0a00`) is a different camera with no published firmware;
see [CAMERA-OPTIONS.md](CAMERA-OPTIONS.md).

## Where we are (2026-10-29)

Both robot cameras (orin-left on port 2.1, orin-right on 2.3) run the **unofficial "usbrecov" 5.13**
(below), flashed from the Jetson without unplugging them. It **comes back by itself after a USB hub
reset**, where the published 5.13 and the factory firmware stay stuck until replugged; with
PhotonVision's port power toggle (`photonvision-84`) a dropped port is back in about 3 s. Both have
a `gain` control (16–128), stream 1280x800 MJPEG at 120 fps, and pass `health-check.sh`. Neither
camera reset or dropped off USB by itself in the hours of testing (every USB event was a test, a
flash or a replug), but that was on the bench, mostly with the robot disabled.

Not checked yet: PhotonVision's Camera Gain slider on the new firmware, exposure retuning with gain,
usbrecov on a driving robot and through a real EMI or cable-shake drop, and `rename`.

## Update a camera (quick start)

**From PhotonVision** (`photonvision-87`): Settings > **Thriftiest Cam firmware**. It lists each
camera's firmware (factory, published, usbrecov, usbrecov + bwreport) and warns about any camera that
won't recover from a USB drop; Match Ready and `health-check.sh` warn too. Upload a `.bin` once (it's
kept on the Jetson, in `photonvision_config/thriftiest-firmware`, and checked to be a Thriftiest Cam
image), pick it for a camera and press **Flash**. Robot disabled: PhotonVision refuses while it's
enabled. A job outside PhotonVision (`scripts/jetson/thriftiest-flash-job.sh`, a transient systemd
unit) stops PhotonVision, flashes with the same backup and checks as below, and starts PhotonVision
again: about 50 s, and the card shows how it went. Needs pyusb on the Jetson (`09-robot-tuning.sh`
installs `python3-usb`; or run the laptop script below once, which leaves a copy).

**From the laptop**, wired to the Jetson, robot **disabled**. The Jetson has no internet, so
`scripts/host/thriftiest-flash.sh` downloads the firmware and pyusb on the laptop, copies them and
`scripts/jetson/thriftiest-fw.py` to `~/thriftiest-fw` on the Jetson, and runs the tool there:

```bash
export JETSON=10.85.15.15            # the robot (192.168.55.1 over the USB-C cable)
scripts/host/thriftiest-flash.sh list              # each camera's port, firmware and gain control
scripts/host/thriftiest-flash.sh flash 2.1 5.13    # a published version, a URL, or a .bin file
```

`flash` checks the image, asks before writing, flashes, and lists the cameras again. Every flash
saves the camera's whole flash first to `~/thriftiest-backups` on the Jetson, and the script copies
those backups to `~/thriftiest-backups` on the laptop. A camera that already has the image is left
alone ("Already up to date").

What to expect: **PhotonVision is stopped** while it works (every camera is off for about a minute) and
started again after. Its camera watchdog (`photonvision-81`) resets the USB port of a camera that
stops streaming for 5 s, which broke a flash mid-read on 2026-10-29; mid-write it could leave the flash
half-written, so `thriftiest-fw.py` refuses to run while PhotonVision is up. The camera switches into
ROM maintenance mode (it re-enumerates as `1bcf:0b12`), only the 4 KiB sectors that differ are
rewritten, and it **restarts by itself**: no replug on either of our cameras. PhotonVision reopens
it at its saved mode the moment it's back. Flash one camera, check it, then the next.

On the Jetson directly (needs `sudo apt install python3-usb`, which needs internet):

```bash
sudo scripts/jetson/thriftiest-fw.py list [--identity]
scripts/jetson/thriftiest-fw.py check-image FILE.bin
scripts/jetson/thriftiest-fw.py diff A.bin B.bin           # which bytes differ (images or dumps)
sudo scripts/jetson/thriftiest-fw.py dump --port 2.1 OUT.bin  # read 256 KiB of flash, writes nothing
sudo scripts/jetson/thriftiest-fw.py flash --port 2.1 FILE.bin --yes
sudo scripts/jetson/thriftiest-fw.py rename --port 2.1 --name TopLeft --serial TL1 --yes
```

**Going back:** flash the backup: `scripts/host/thriftiest-flash.sh flash 2.1 ~/thriftiest-backups/thriftiest-1-2.1-<date>-fw5.13.bin`.
A backup is the camera's whole 512 KiB flash, so it puts back exactly what was there.

**If it goes wrong:** the tool restores the sectors it touched when a write fails, and says whether
it managed. A camera left in maintenance mode (`list` shows `IN MAINTENANCE MODE`) comes back with
a replug or a power cycle; then run `flash` again. Keep it powered while it's writing.

Firmware internals (JPEG header, sensor modes, candidate latency patch): see
[THRIFTIEST-FIRMWARE-ANALYSIS.md](THRIFTIEST-FIRMWARE-ANALYSIS.md).

## Testing other firmware

For a new release, or a modified image such as the "usbrecov" patch below:

1. **Know what it changes.** `thriftiest-fw.py diff` it against the published 5.13 (or a camera's
   dump). A small, explained diff is a lot less risky than an unknown image.
2. **A spare camera first,** not a robot camera, unless the diff is understood.
3. `flash`, then check: `list` (firmware and gain), `health-check.sh`, PhotonVision streams
   1280x800 at 120 fps on an enabled robot, and whatever the firmware claims to fix
   (`tests/usb-hub-reset/run.sh` for the stuck-camera problem).
4. Add a row to the test log below, including anything that behaved differently from this doc.

## Test log

| Date | Camera (port) | Before | Flashed | Result |
|---|---|---|---|---|
| 2026-10-29 | orin-right (2.3) | factory 5.13, no gain | published 5.13 | 4 sectors, 43 s, restarted by itself; gain 16–128; health check READY |
| 2026-10-29 | orin-left (2.1) | factory 5.13, no gain | published 5.13 | same as 2.3 |
| 2026-10-29 | both | published 5.13 | (hub-reset test) | `run.sh` and `run.sh 1-2 10`: **both stuck** both times (`-110` on every descriptor read, "unable to enumerate", not in `lsusb`) until replugged |
| 2026-10-29 | orin-right (2.3) | published 5.13 | usbrecov 5.13 | 1 sector (0x15000), restarted by itself. A first try failed mid-read when PhotonVision's watchdog reset the camera (nothing written); with PhotonVision stopped it worked |
| 2026-10-29 | 2.3 usbrecov, 2.1 published (control) | | (hub-reset test) | `run.sh`: **2.3 streaming again at 22.8 s by itself**, 2.1 stuck. `run.sh 1-2 10`: **2.3 at 21.5 s**, 2.1 stuck. 2.3 enumerated on its first try with no errors; the ~20 s is the hub retrying the stuck 2.1 first. 2.1 needed a replug both times |
| 2026-10-29 | orin-left (2.1) | published 5.13 | usbrecov 5.13 | 1 sector, restarted by itself |
| 2026-10-29 | both usbrecov | | (hub-reset test) | **PASS**: both streaming again 2.2 s and 2.5 s after the hub came back, detectors at 3.4 s |
| 2026-10-29 | both usbrecov, PhotonVision with `photonvision-84` | | `tests/usb-recovery-bench` | every drop came back by itself: port disabled 2.9-3.5 s, gone from USB 2.1-2.7 s, port reset 1.0 s, hub reset 2.2-2.4 s |
| 2026-10-29 | orin-right (2.3), then orin-left (2.1) | no serial | `rename` to `SJ-TC02`, `SJ-TC01` | 1 sector each, restarted by itself; firmware unchanged; `/dev/v4l/by-id/...Thrifty_SJ-TC0x` |
| 2026-10-30 | orin-right (2.3) | usbrecov | usbrecov + bwreport | 1 sector, restarted by itself, serial kept. Bandwidth request at 1280x800 120 fps still 3060 to the capped driver. `tests/usb-recovery-bench`: 3.3 / 2.3 / 1.0 / 2.4 s, as usbrecov |
| 2026-10-30 | orin-right (2.3) | usbrecov + bwreport | usbrecov, **from PhotonVision's Settings card** | ~50 s click to done: PhotonVision stopped, 1 sector, verified, PhotonVision started; serial kept, backup saved |
| 2026-11-05 | SystemCore bench cam (Pi 5, port 1) | factory 5.13, no gain, no serial | usbrecov 5.13 (built with `make-patched.py`), then `rename` to `SJ-05` | Flashed on the SystemCore with `thriftiest-fw.py` (pyusb copied over; PhotonVision stopped first): 5 sectors, verified after restart; rename 1 sector. Gain 16–128 (default 32); `iSerial` SJ-05; 1280x800 MJPEG at 121 fps. Backups in `~/thriftiest-backups` on the Pi and laptop (file dates read 2025-10-15: the Pi's clock was wrong) |
| 2026-11-09 | SystemCore bench cam `SJ-05` (Pi 5, port 1) | usbrecov 5.13 | **5.17 test** from Sam Dare by email (`ThriftiestCam-Firmware-v5.17-test.bin`, 115,712 bytes, sha256 `2a3019e3ae72d9dbd37302a42941b052aef2b1cdc324f374a05f77aabfee3519`) | `check-image`: Thrifty Bot, firmware 5.17. 79 bytes differ from usbrecov in the first 111,729 plus ~4 KiB appended; **the usbrecov patch is gone** (0x15037 back to `70 1e`, 0x1503D `70 18`), so expect it to stick after a hub reset (not tested). PhotonVision stopped; 12 sectors, verified after restart, serial kept. Backup of the usbrecov flash: `~/thriftiest-backups/thriftiest-3-1-20261109-203120-fw5.17.bin` on the Pi (named after the new firmware, holds the old) |
| 2026-11-09 | `SJ-05` | 5.17 test | (feature test, `v4l2-ctl` + OpenCV on the Pi) | MJPEG modes now 1280x800/720 @120, **1280x400 @196**, 800x600/640x480/320x240 @120, **640x400 @240**; MJPEG 640x360 gone (YUYV still lists it at 30). Measured 121.3 / 195.9 / 239.4 fps at 2 ms exposure. **Exposure in 0.1 ms steps: pass**: at 1280x800 the frame rate follows it (100 → 96.9 fps, 125 → 78.4, 200 → 49.5, 400 → 25.0). **1280x400 is the centre band: pass** (corr 0.92 with rows 200–600 of the full frame, 0.48 squashed). **640x400 is full field of view: pass** (corr 0.85 with the full frame downscaled, 0.31 with a centre crop). Readout times not measured. **Settings surviving a power cut while streaming: not tested** (needs a hand unplug). Exposure is not linear in JPEG brightness (tone curve, black level), so use frame rate, not brightness, to check it |
| 2026-11-09 | `SJ-05` | 5.17 test | (readout, `uvc_pkttrace` 20 s per mode, high speed alt 8; PhotonVision's camera taken with `--force`) | **Readout claim: pass.** First to last packet p50 (p5/p95): 1280x800@120 **7.26 ms** (7.22/7.38), 121.28 fps, 55 KB; 1280x400@196 **3.61 ms** (3.50/3.65), 195.87 fps, 26 KB; 640x400@240 **3.73 ms** (3.60/3.76), 239.40 fps, 23 KB. No full packets, no idle intervals: readout-paced, not USB-limited. 1280x400 is 9.0 µs/row like 1280x800; 640x400 reads 800 sensor rows in 3.7 ms (binning doubles the row rate) |
| 2026-11-09 | `SJ-05` | 5.17 test | (sc-vision, `~/builder/tc/sc-vision --min-tag 22 --cpu 3 --calib`, 25 s per mode; exposure 12 gain 128 untouched; 1280x400 calibration = 1280x800 with cy − 200) | first packet → tags p50/p99, last URB → tags p50/p99, CPU of one core (separate 20 s run): **1280x800@120** 7.88/8.26, 0.16/0.49 ms, 37%; **1280x400@196** 4.00/4.52, 0.11/0.30 ms, 28%; **640x400@240** 4.14/4.78, 0.16/0.45 ms, 31%. 0 overload skips (1 at 1280x400), 2 bad frames at 1280x800, decode/NAPA identity checks 0 differ. Bench tags: 1280x800 tag 10 97% (margin 70, 89 px), far tag 12 3% (margin 27, 30 px); 640x400 tag 10 97% (**margin 167**, 45 px), tag 12 3% (margin 64, 15 px): binning more than doubles the margin at the same light, far-tag rate unchanged at this exposure; 1280x400 sees only tag 11 (100%, margin 37, 45 px): tags 10 and 12 fall outside the centre band. ~3.8 ms less first packet → tags in both fast modes |
| 2026-11-09 | `SJ-05` | 5.17 test | (PhotonVision, no change) | PhotonVision reopens it natively at 1280x800 MJPEG 120 fps (`cameraVideoModeIndex` 6 still maps to it), exposure 12 gain 128 kept (12 = 1.2 ms, from the frame-rate check above); NAPA tags found; latency median 12.7–13.0 ms, p95 15.2–15.4 ms. No 640x360 in the saved config (database backup `/dev/shm/t17/photon.sqlite.bak-*`). PhotonVision runs at 1280x400 / 640x400 not tried |

## Releases and images

| Version | Date | Status | Notes | Download |
|---|---|---|---|---|
| 5.13 | 2026-09-26 | **Experimental** ("use at your own risk") | OV9281 firmware with the image **gain settings restored** | [ThriftiestCam-Firmware-v5.13.bin](https://software.thethriftybot.com/firmware/thriftiest-cam/5.13/ThriftiestCam-Firmware-v5.13.bin) (111,729 bytes, sha256 `79bfebdb731dff2439ff333abc86cd905d857ad604f869af9fb9a6a19d59616c`) |

Nothing in 5.13's notes mentions USB reconnection, so don't expect it to fix stuck cameras.

**Factory firmware also says 5.13.** Our cameras shipped reporting `bcdDevice 0x0513` but without a
gain control, so the version number alone doesn't tell the two apart; a `gain` control does
(`health-check.sh` and `thriftiest-flash.sh list` check it). Both cameras' factory flash was the same.
Against the published image it differs in 11 bytes:

| Offset | Factory | Published | What it is |
|---|---|---|---|
| 0x05985, 0x0781d, 0x07844 | `15` | `17` | The Gain bit in the UVC Processing Unit's `bmControls` (0x157f vs 0x177f); 0x05985 is in the descriptor the camera reports |
| 0x12308 (8 bytes), 0x126b0 (3 bytes) | | | Code or a table, presumably the gain handling |
| 0x01f7f (3 bytes) | `0000ff` | `100080` | Just before the identity block: perhaps a checksum or build stamp |

The factory dump is kept with the backups (`port2.3-orin-right-fw5.13-factory-20261029.bin`).

**"ThriftiestCam-Firmware-v5.13-PATCH-usbrecov.bin"** (from a coach, sha256
`9a6eedb66b30c18e741903aa3733d56c0f7c2159ff42d03b41ee04a38aa690a9`, 111,729 bytes): the published 5.13
with 4 bytes changed, `70 1e` → `00 00` at 0x15037 and `70 18` → `00 00` at 0x1503D (two 8051 `JNZ`
branches replaced by `NOP`s, so the code they skipped always runs). Meant to let the camera recover
from a USB reset, and in our hub-reset tests it did (test log). Not from Thrifty Bot, and we don't know
what else those branches guard: on orin-right only, until it has run on the robot for a while.
Going back: `scripts/host/thriftiest-flash.sh flash 2.3 5.13`.

**"ThriftiestCam-Firmware-v5.13-PATCH-recovery+bwreport.bin"** (sha256 `87aa31a7…`, 111,729 bytes):
usbrecov plus 3 bytes, `27 09 9a` → `24 05 00` at 0x1A1D7, which change the camera's default USB
bandwidth request, so it doesn't claim the largest setting (3060 bytes a microframe, enough to crowd
out other cameras on the stock driver). Our capped camera driver (`11-uvcvideo-payload-cap.sh`) sets
the bandwidth itself, so on our Jetsons it makes no difference we can see: at 1280x800 MJPEG 120 fps
the camera's request still reads 3060 to the driver. It should help where the stock driver runs; not
tested there. It recovers from USB drops exactly like usbrecov (test log).

**Which firmware a camera runs** (`thriftiest-fw.py variant`): every variant reports 5.13, so these
are told apart by a few flash bytes, read through the video driver while the camera streams (two
1 KiB reads; nothing is detached and no frame is lost):

| Variant | 0x05985 | 0x15037 | 0x1503D | 0x1A1D7 | Recovers from a USB drop |
| --- | --- | --- | --- | --- | --- |
| factory | `15` | `70 1e` | `70 18` | | no |
| published | `17` | `70 1e` | `70 18` | | no |
| usbrecov | | `00 00` | `00 00` | `27 09 9a` | yes |
| usbrecov + bwreport | | `00 00` | `00 00` | `24 05 00` | yes |

## How the camera is updated (found 2026-10-29)

From Thrifty Config 2027.0.0-beta.10's own code (it's an Electron app; the camera code is plain JS):

- The Thriftiest Cam is a **SunplusIT SPCA2089D** UVC bridge, USB **1bcf:28c5**, with a 512 KiB
  Puya P25Q40 SPI flash. The firmware `.bin` is a raw image written from flash offset 0.
- The **firmware version is the USB `bcdDevice`**: 5.13 reports `0x0513`. The 5.13 image carries
  `1bcf:28c5`, `bcdDevice 0x0513` in its USB descriptor.
- Flashing is plain **UVC extension-unit control requests** (SET_CUR/GET_CUR on the vendor XU
  `63610682-5070-49ab-b8cc-b3855e8d221d`): latch an address, read/write 1 KiB blocks, erase 4 KiB sectors.
  To write, the camera is reset into ROM maintenance mode (register 0x20D8 = 0x5A; it re-enumerates
  as 1bcf:0b12) and back (0x20D8 = 0xA5). Thrifty Bot marks the way back unverified; on our two
  cameras it worked every time, with no replug.
- Thrifty Config does this on **Linux and macOS through libusb**, detaching `uvcvideo` from the
  camera while it works. Windows is the odd one out (needs a helper). Thrifty Config itself is
  Windows/macOS only, so on the Jetson we use our own port of it.
- fwupd has a `sunplus-camera` plugin, but it uses a different (DFU stream) path that Thrifty Config
  says this camera doesn't use, so we don't use fwupd.

`thriftiest-fw.py` keeps Thrifty Config's safety checks: the controller and flash profiles must match,
two full backup reads must agree, every erase and 1 KiB block is read back, the whole flash is
compared at the end, the touched sectors are put back on failure, and the camera is re-read after it
restarts.

**The camera's USB name and serial number are stored in flash too** (the "TONY" block at 0x2000),
and firmware updates keep them. Out of the box both slots are empty, so every camera reports the
built-in "Thrifty" and serial "01.00.00". `scripts/host/thriftiest-flash.sh rename PORT SJ-TC01`
stores a serial (one sector, ~45 s, PhotonVision stopped meanwhile): PhotonVision (`photonvision-86`)
then knows the camera by it, so its settings and calibration follow it to any port. Robot cameras
since 2026-10-29: orin-left `SJ-TC01`, orin-right `SJ-TC02`. See TECHNICAL.md, "Cameras known by
their serial".

Thrifty Config (2027.0.0-beta.8 or newer, laptop, camera plugged into the laptop) still works too:
camera's **Configuration** tab → **Firmware** → **Select Firmware File** → **Update Firmware**.

## In the PhotonVision UI

Since `photonvision-87`: Settings > Thriftiest Cam firmware (see the quick start), and Match Ready
shows each camera's firmware through `health-check.sh`.
