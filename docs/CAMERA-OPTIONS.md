# Camera options (research, 2026-10-29)

Nothing here is bought or tested yet. Prices and specs are from vendor pages on 2026-10-29; recheck
before ordering.

## Game-piece camera

**Wanted:** colour, global shutter preferred, USB-C (locking preferred), 10-32 mounting holes,
USB 3 nice to have.

**No FRC vendor sells this.** Checked Thrifty Bot, SWYFT, AndyMark, WCP, REV:

- Thrifty Bot **ThriftyCam** ($120): USB 3.0, locking USB-C cable included, 1600x1304 at 60 fps,
  80° lens. Closest on everything else, but **mono** (OmniVision OG02B1B).
- SWYFT USB Camera: mono OV9281 (see below).
- AndyMark: only the mono Arducam OV9281. WCP: Limelights (smart cameras, not USB cameras).

So: an industrial colour camera on a 10-32 plate we make.

| Camera | Sensor | Link, plug | Speed | Notes |
|---|---|---|---|---|
| [Arducam AR0234 USB3, with enclosure](https://www.arducam.com/arducam-2-3mp-ar0234-color-global-shutter-usb-3-0-camera-module-without-enclosure.html) (SKU B0495C; [RobotShop](https://www.robotshop.com/products/arducam-23mp-ar0234-color-global-shutter-usb-30-camera-module-w-encolsure)) | AR0234, 2.3 MP colour global shutter | USB 3.2 Gen 1, USB-C (not locking) | 1920x1200 at 50 fps, 960x600 at 80 fps | **First pick.** Cased; we add a 10-32 plate. Only 960x600 at 10 fps on a USB 2.0 port |
| [e-con See3CAM_24CUG](https://www.e-consystems.com/industrial-cameras/ar0234-usb3-global-shutter-camera.asp) | AR0234 colour GS | USB 3.1 Gen 1, USB-C | 120 fps at 720p | Industrial build, external trigger input, pricier. Step up if the Arducam disappoints |
| [TechNexion VCS-AR0234](https://www.technexion.com/shop/usb-vision/usb3-cameras/vcs/vcs-ar0234-c-s191-ir/) | AR0234 | USB 3, USB-C enclosure | 1920x1200 at 60 fps (UYVY) | Same class as the e-con |
| [Arducam OV9782 board](https://www.arducam.com/100fps-global-shutter-color-usb-camera-board-1mp-ov9782-uvc-webcam-module-with-low-distortion-m12-lens-without-microphones-for-computer-laptop-android-device-and-raspberry-pi-arducam.html) (B0385) | OV9782, 1 MP colour GS (colour twin of the Thriftiest's OV9281) | USB 2.0, bare board | 1280x800 at 60, 640x400 at 120 | Chief Delphi's usual pick. Needs a case and a USB-C conversion: [Etsy adapter PCB](https://www.etsy.com/listing/1842851233/arducam-ov9281ov9782-usb-c-converter-pcb) (USB-C to A cables only) or [solder-on board](https://www.chiefdelphi.com/t/arducam-usb-c-conversion/475162) |
| [Vadzo Vajra-235CGS](https://www.newswire.com/news/vadzo-imaging-launches-vajra-235cgs-2-3-mp-global-shutter-color-usb-3-2-gen-2-2) | AR0235 colour GS | USB 3.2 Gen 2x2, USB-C | | Overkill |

**Why USB 3 matters for us:** a USB 3 camera streams over the Jetson's SuperSpeed lanes, not the shared
USB 2.0 bus the Thriftiest Cams have nearly filled (5 capped cameras use ~6,400 of ~6,720 bytes per
microframe; README, Performance). An OV9782 would compete with the AprilTag cameras; an AR0234 on
USB 3 doesn't. That's why the AR0234 is the first pick over the cheaper OV9782.

**Caveats**
- Global shutter matters less for game pieces than for AprilTags: detection runs at low resolution and
  moderate fps. Teams report ordinary 60 fps webcams working
  ([thread](https://www.chiefdelphi.com/t/robot-camera-recommendations/451312)); Limelight 4 uses a
  rolling-shutter colour sensor (IMX462). Nice to have, not required.
- None has a locking USB-C. On our own plate: a cable clamp right behind the plug, plus hot glue
  (README hardware checklist).
- The AR0234 may only offer uncompressed (YUYV) at full speed; our hardware JPEG decoding only helps
  with MJPEG. Check `v4l2-ctl --list-formats-ext`.
- Unverified: AR0234 enclosure mounting holes, Jetson USB 3 port behaviour, PhotonVision/YOLO
  performance.

**Bench test plan (one Arducam AR0234):**
1. Plug into a Jetson USB 3 port; `lsusb -t` shows it at 5000M.
2. `v4l2-ctl --list-formats-ext`: which modes are MJPEG vs YUYV, and at what fps.
3. `scripts/jetson/usb-bandwidth.py`: the AprilTag cameras' USB 2.0 budget is unchanged with it streaming.
4. Run the FUEL YOLO pipeline ([GAME-PIECE-MODELS.md](GAME-PIECE-MODELS.md)) on it: fps, latency, CPU, GPU.
5. `tests/usb-hub-reset/run.sh`: does it come back by itself after a hub reset?
6. Design the 10-32 plate (1.5" spacing, like the SWYFT camera) with a cable clamp.

Chief Delphi background: [object detection camera, 2026](https://www.chiefdelphi.com/t/object-detection-camera-sensor-frc-2026-rebuilt/513413),
[PhotonVision object cameras](https://www.chiefdelphi.com/t/photonvision-object-cameras/470053),
[Arducam housings](https://www.chiefdelphi.com/t/housing-for-arducam-global-shutter-camera/441822).

## AprilTag camera alternative: SWYFT USB Camera vs Thriftiest Cam

[SWYFT USB Camera](https://swyftrobotics.com/electrical/swyft-usb-camera) ($49.99, cable $4.99).
Same sensor (OV9281), different USB bridge chip, so different firmware, tools and USB behaviour.

| | Thriftiest Cam | SWYFT USB Camera |
|---|---|---|
| Sensor | OV9281 | OV9281 ("OV9281-class") |
| USB bridge | SunplusIT SPCA2089D (`1bcf:28c5`) | Realtek (`0bda:3035`) |
| Flash | 512 KiB | 128 KiB |
| Fastest modes | 120 fps at every resolution | 120 fps at 640x480 and up; **210 fps** at 640x400 and below |
| Gain control | Only with firmware 5.13 (experimental) | Yes |
| Exposure minimum | Not published | 3.91 ms stock; **0.244 ms** with their "Low Exposure" firmware |
| Serial number | Same on every camera; settable with `thriftiest-fw.py rename` | Settable with their Windows tool |
| Lens | Interchangeable, focus yourself | Fixed, glued at 5 ft, factory calibrated, 81°x52°; PhotonVision calibration JSON provided |
| Case | Moulded plastic | Billet aluminium, isolated from robot ground; 10-32 at 1.5" and M4 at 40 mm |
| Connector | Locking USB-C | Locking USB-C |

Their firmware and serial tool:
[LowExposureSWYFTUSBCameraSerial.zip](https://cdn.shopify.com/s/files/1/0875/8486/6598/files/LowExposureSWYFTUSBCameraSerial.zip?v=1788512771)
(Windows `.exe`, `.rfw` images, "MemType SPI_128K").

**To check before switching:** our Thriftiest's minimum exposure (`v4l2-ctl --list-ctrls`; if it can't
go well under 1 ms, the SWYFT's low-exposure firmware is a real advantage); its USB bandwidth
reservation (`usb-bandwidth.py`; our 82 Mbps cap and the 4-5 camera budget were measured on the
Thriftiest); and `tests/usb-hub-reset/run.sh` (the stuck-after-hub-reset problem is the Sunplus
bridge's, so the Realtek one may not have it, or may have its own).
