# Swyft USB Camera firmware

The **Swyft USB Camera** (Swyft Robotics, `SR-CAMERA-OV9281-USBC-01`,
<https://swyftrobotics.com/electrical/swyft-usb-camera>) is an OV9281-class global-shutter mono
camera behind a Realtek UVC bridge (USB `0bda:3035`), MJPEG only: 1280x800 at 120 fps, 210 fps at
640x400 and below. Swyft publishes **Low Exposure Firmware + Serial Number Changer**
(`LowExposureSWYFTUSBCameraSerial.zip`, 2.77 MB, on the product page):

| Image | Minimum exposure | SHA-256 |
| --- | --- | --- |
| `LowExposureSWYFTUSBOV9281.rfw` | 0.244 ms | `84548d18…` |
| `SWYFTUSBOV9281.rfw` (stock) | 3.91 ms | `06d95d4f…` |
| factory, as the robot's camera came (early 2026) | 5 ms | `d8370e92…` |

The factory image is the stock code with no string records and a different settings block at
`0x1F000` (142 bytes in all); the low-exposure image differs from stock throughout (another build).

The zip's flasher, `SWYFTUSBCameraSerial.exe`, is Realtek's CameraDump 2.84 renamed: Windows only,
not code-signed, needs administrator rights, and installs Realtek's (Microsoft-signed) RtsUpx driver
to reach the camera. `scripts/jetson/swyft-fw.py` does the same from the Jetson.

## Where we are (2026-10-30)

- The robot's Swyft (port 2.4) was flashed from the Jetson with `swyft-fw.py`: **low exposure,
  serial `SJ-SW01`**, 6 s with PhotonVision stopped. Its exposure control now goes down to 2 (0.2 ms;
  it was 50, 5 ms). PhotonVision found it by its new serial (`photonvision-86`: "has a serial of its
  own … its settings and calibration go with it"). Its factory flash is backed up (laptop and Jetson
  `~/swyft-backups`).
- The spare Swyft was flashed from Windows with Swyft's tool: low exposure, serial `SJ-SW02`.
- `swyft-fw.py dump` takes about 3 s; the camera comes back by itself both ways.
- After the flash and a replug it streams 1280x800 MJPEG at 120 fps.
- Not done: tuning its exposure (PhotonVision came back with it at the new minimum, 0.2 ms, too dark:
  set it on the dashboard), checking the calibration still holds on the new firmware, and robot code
  (it only watches orin-left and orin-right, so nothing on the robot alerts on this camera).

**Best: give a Swyft its firmware and serial on the bench, before it's glued in**, from a laptop with
Swyft's own tool (the zip's `SWYFTUSBCameraSerial.exe`: MemType `SPI_128K`, Load the `.rfw`, set the
serial, Update). There it streams straight after, no replug. On the robot the serial can only change
through the boot loader too (it lives in the flash), so a rename is a flash: `swyft-fw.py flash
--serial`, then a robot power cycle.

**After a flash on the robot, power-cycle the robot** (main breaker), or unplug the Swyft and plug it
back in where the cable isn't glued. A Jetson reboot isn't enough: tested 2026-10-30, after a dump
and a full `systemctl reboot` the Swyft came back at 0 fps (USB power stays on through a reboot). Out of the boot
loader it enumerates and answers its controls but sends no frames until it loses power, and the
Jetson's USB hub can't switch a port's power (ClearPortFeature(PORT_POWER) only drops the link).
`swyft-fw.py` says so. The same after a `dump`: any trip through the boot loader does it. Tried
2026-10-30 without a replug, counting frames after each: a USB device reset, a hub port reset,
de-authorizing and re-authorizing the device, unbinding and rebinding uvcvideo, and replaying Swyft's
tool's boot-loader session request for request (its `DevQualify`, the `ff 00 00 00 00 00 00 00`
commands, the register reads) from a camera that was streaming: none brings the video back (the
camera answers `Failed to set UVC probe control: -71`). On Windows the spare streamed straight after
Swyft's tool flashed it, so the laptop's own USB port presumably cuts power when the camera changes
identity (0bda:3035 to 5842 and back); the Jetson's hub can't. Without a replug it would take a hub
that really switches port power, or flashing from a laptop.

**Never send the Swyft a command it doesn't support.** On 2026-10-30 three of CameraDump's commands
this chip doesn't have (`00 c5`, `02 c1`, `00 09`) left its command handler refusing everything
until a port power toggle, *and* its video stopped (03:18) until it was replugged an hour later. A
camera stuck like that still looks right to anything that only reads its mode: PhotonVision logs
"timed out getting frame", its `health/state` reads `stalled`, and `health-check.sh` (since this
date) fails it at 0 fps.

**After a flash, check the Swyft's Resolution in PhotonVision.** The low-exposure firmware lists its
video modes in another order (1280x800 first, several frame rates per size, and YUYV modes too), and
PhotonVision saves a mode as its index: after the flash the robot's Swyft came up at 352x288 60 fps.
Set it back to **1280x800 at 120 FPS, MJPEG** (and the stream resolution to the smallest).
- **Serial numbers**: every Swyft ships with `200901010001` (the stock image's placeholder is
  `EnterUniqueID(EG:FRONT/BACK/INTAKE)`), so PhotonVision tells them apart by USB port. Give each one
  its own: `flash --serial SJ-SW01`, and label the camera with it.

The serial isn't the built-in string at `0x1785`: the firmware's USB strings can be overridden by a
record table at `0xAE00`, header `55 A5 92`, a 16-bit total length (header included) and an entry
count, then entries `[length, type, payload]`. Types 01/02/03 are the manufacturer, product and serial
strings, each payload a USB string descriptor in ASCII (`bLength 03 text`). Swyft's tool sets a serial
by adding (or replacing) the type 03 entry and changes nothing else: the low-exposure image's table
goes from `55 a5 92 0f 00 02 06 2f 42 58 60 10 03 08 d2` to the same plus `0b 03 09 03 "SJ-SW02"`,
length `1a 00`, count 3.

## Use

PhotonVision stopped, robot disabled:

```bash
sudo systemctl stop photonvision
sudo python3 swyft-fw.py dump --port 2.4 swyft.bin          # backup, ~3 s
sudo python3 swyft-fw.py flash --port 2.4 LowExposureSWYFTUSBOV9281.rfw --serial SJ-SW01 --yes
sudo systemctl start photonvision
```

pyusb: `09-robot-tuning.sh` installs `python3-usb`; without internet, use the copy
`scripts/host/thriftiest-flash.sh` leaves in `~/thriftiest-fw/lib`
(`sudo env PYTHONPATH=$HOME/thriftiest-fw/lib python3 swyft-fw.py …`).

## The protocol

Captured 2026-10-30 from Swyft's tool flashing the spare camera (Frida on the tool, logging the URBs
it passes to RtsUpx; capture and decoder in the laptop's `~/swyft-backups`).

**Application firmware** (`0bda:3035`): extension unit 4, GUID `{1229a78c-47b4-4094-b0ce-db07386fb938}`,
on the control interface. Selector 10 takes an 8-byte command
`[group, op, addrLo, addrHi, lenLo, lenHi, 0, 0]`; selector 11 carries its data.

| Command | Use |
| --- | --- |
| `00 d0`, 8 | DevQualify: reads `REALSIL\0` |
| `00 cd page`, 8 | device status pages (page 0: VID/PID; page 2: build date, `12/31/19`) |
| `00 c2 addr`, n | read XDATA (`0xFE21` = chip ID `10 60`) |
| `00 82 addr`, n | write XDATA (the data goes to selector 11, exactly n bytes) |

To reach the boot loader: write XDATA `0xFF92 = 01`, then vendor request `40 01`, wIndex 7. The
camera drops off USB and comes back as **`0bda:5842` "USB Boot"**.

Commands this firmware doesn't support (`00 09` ResetToRom, `00 c5` NorFlash_Read, `02 c1`
SPI ReadID, all in CameraDump's command table) are refused with UVC error 2 ("wrong state") **and
leave the command handler stuck**: every command after is refused until the camera loses power
(a hub port power cycle, or a replug). Send it only the commands above.

**Boot loader** (`0bda:5842`): vendor requests to the device.

| Request | Use |
| --- | --- |
| `c0 07` wValue page, 8 | info pages (page 0 `da0b4258…`, page 3 `REALSIL`) |
| `c0 25` wIndex addr, n / `40 24` wIndex addr, 1 | read / write a register |
| `c0 30`, 1 / `40 31`, 1 | read / write the flash status register |
| `40 32` | chip erase |
| `c0 2e` / `40 2f`, 4096 | read / write 4 KiB at wValue<<8 &#124; wIndex (the upper 64 KiB is wValue `0x0100`) |
| `40 22` | reset (after `0xFF92 = 01`: boots the firmware) |

The flash, as Swyft's tool does it: SPI setup `FEA0=81 FEA6=11 FEA1=0C FEA7=0C` (it reads
`80 10 00 00` before); flash status `00` (unprotect), check it reads `00`; chip erase; read all 128 KiB
(blank); write all 32 blocks, with the `55 AA` at `0x0FFE` held back; read it all back; write
`55 AA` at `0x0FFE` and read it back; `FEA0=81 FEA6=10 FEA1=0C FEA7=08`; flash status `8C`
(protect); `0xFF92 = 01` and `40 22`. The camera boots the new firmware. Writing the tag last is
presumably so that a write cut off part way leaves an image the boot loader won't run (not tested).
