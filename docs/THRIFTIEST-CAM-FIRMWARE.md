# Thriftiest Cam firmware

Thrifty Bot publishes Thriftiest Cam firmware at
<https://docs.thethriftybot.com/software/thriftiest-cam-firmware/latest/overview>.
Check that page for new releases: Thrifty Bot is now shipping updates, so a fix for the
"stuck after a USB hub reset" problem (README, Known issues) may come this way.

## Releases

| Version | Date | Status | Notes | Download |
|---|---|---|---|---|
| 5.13 | 2026-09-26 | **Experimental** ("use at your own risk") | OV9281 firmware with the image **gain settings restored** | [ThriftiestCam-Firmware-v5.13.bin](https://software.thethriftybot.com/firmware/thriftiest-cam/5.13/ThriftiestCam-Firmware-v5.13.bin) (111,729 bytes, sha256 `79bfebdb731dff2439ff333abc86cd905d857ad604f869af9fb9a6a19d59616c`) |

Nothing in 5.13's notes mentions USB reconnection, so don't expect it to fix stuck cameras.

**What 5.13 changes for us:** our current firmware reports no `gain` control (`v4l2-ctl -l`), so
PhotonVision's Camera Gain slider was hidden (`photonvision-54`). With 5.13 it should come back by
itself. Test it before relying on it: our tuning so far assumes fixed gain.

## How the camera is updated (found 2026-10-29)

From Thrifty Config 2027.0.0-beta.10's own code (it's an Electron app; the camera code is plain JS):

- The Thriftiest Cam is a **SunplusIT SPCA2089D** UVC bridge, USB **1bcf:28c5**, with a 512 KiB
  Puya P25Q40 SPI flash. The firmware `.bin` is a raw image written from flash offset 0.
- The **firmware version is the USB `bcdDevice`**: 5.13 reports `0x0513`. The 5.13 image carries
  `1bcf:28c5`, `bcdDevice 0x0513` in its USB descriptor.
- Flashing is plain **UVC extension-unit control requests** (SET_CUR/GET_CUR on the vendor XU
  `63610682-5070-49ab-b8cc-b3855e8d221d`): latch an address, read/write 1 KiB blocks, erase 4 KiB sectors.
  To write, the camera is reset into ROM maintenance mode (register 0x20D8 = 0x5A; it re-enumerates
  as 1bcf:0b12) and back (0x20D8 = 0xA5, which Thrifty Bot marks unverified: it may need a replug).
- Thrifty Config already does this on **Linux and macOS through libusb**, detaching `uvcvideo` from the
  camera while it works. Windows is the odd one out (needs a helper). So the Jetson can do it.
- fwupd has a `sunplus-camera` plugin, but it uses a different (DFU stream) path that Thrifty Config
  says this camera doesn't use, so we don't use fwupd.

**The camera's USB name and serial number are stored in flash too** (the "TONY" block at 0x2000),
and Thrifty Config can rewrite them. Firmware updates keep them. That means we could give each camera a
**unique serial** and stop relying on USB ports to tell them apart (README: "Cameras are named after
their USB port"). Not done yet: PhotonVision's matching would need checking first.

## Updating from the Jetson

`scripts/jetson/thriftiest-fw.py` is a Python port of that protocol and its safety checks (controller
and flash profile checks, two matching backup reads, every erase and block read back, a full compare,
restore of the touched sectors on failure, re-verify after restart). **Not yet run on a real camera:
try it on a spare first.** Needs `sudo apt install python3-usb`.

```bash
# On the Jetson. Firmware version of every Thriftiest Cam (no camera is disturbed):
sudo scripts/jetson/thriftiest-fw.py list
# Check a downloaded firmware file:
scripts/jetson/thriftiest-fw.py check-image ThriftiestCam-Firmware-v5.13.bin
# Update one camera (port as health-check.sh shows it). Saves a full flash backup to ~/thriftiest-backups:
sudo scripts/jetson/thriftiest-fw.py flash --port 2.1 ThriftiestCam-Firmware-v5.13.bin --yes
# Give a camera its own name/serial:
sudo scripts/jetson/thriftiest-fw.py rename --port 2.1 --name TopLeft --serial TL1 --yes
```

The camera drops out of PhotonVision during the update (~1 minute) and comes back after. Don't run it
while the robot is enabled. If the camera doesn't restart by itself, unplug/replug it or power-cycle the
robot (the tool waits 2 minutes and then verifies it). Keep it powered while it's writing.

Update one camera first and run it on the robot for a while before doing the rest (it's experimental).
Afterwards recheck its exposure, since gain behaviour changed.

Thrifty Config (2027.0.0-beta.8 or newer, laptop) still works too: camera's **Configuration** tab →
**Firmware** → **Select Firmware File** → **Update Firmware**.

## Checking all cameras

`scripts/jetson/health-check.sh` prints each Thriftiest Cam's firmware, and warns below 5.13. By hand:
`cat /sys/bus/usb/devices/<port>/bcdDevice` (`0513` = 5.13), or `thriftiest-fw.py list`.

## In the PhotonVision UI?

Doable next: the Match Ready page can show each camera's firmware (bcdDevice, no camera access needed),
and an "Update firmware" button could run `thriftiest-fw.py flash` on the Jetson with an uploaded `.bin`.
Wait until the script has been proven on a real camera from the command line.
