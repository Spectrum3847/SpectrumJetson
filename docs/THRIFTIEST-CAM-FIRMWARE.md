# Thriftiest Cam firmware

Thrifty Bot publishes Thriftiest Cam firmware at
<https://docs.thethriftybot.com/software/thriftiest-cam-firmware/latest/overview>.
Check that page for new releases: Thrifty Bot is now shipping updates, so a fix for the
"stuck after a USB hub reset" problem (README, Known issues) may come this way.

## Releases

| Version | Date | Status | Notes | Download |
|---|---|---|---|---|
| 5.13 | 2026-09-26 | **Experimental** ("use at your own risk") | OV9281 firmware with the image **gain settings restored**. Needs Thrifty Config 2027.0.0-beta.8 or newer to install | [ThriftiestCam-Firmware-v5.13.bin](https://software.thethriftybot.com/firmware/thriftiest-cam/5.13/ThriftiestCam-Firmware-v5.13.bin) |

Nothing in 5.13's notes mentions USB reconnection, so don't expect it to fix stuck cameras.

## What 5.13 changes for us

Our cameras' current firmware reports no `gain` control (`v4l2-ctl -l`), so PhotonVision's Camera
Gain slider was hidden (`photonvision-54`, README "How the tags look"). With 5.13 the camera
should report `gain` again and the slider should come back by itself. Test it before relying on it:
more gain means more noise, and our tuning so far assumes fixed gain.

## Updating a camera

From Thrifty Bot's instructions:

1. Install Thrifty Config 2027.0.0-beta.8 or newer on a laptop and download the `.bin` above.
2. Plug the camera into the laptop. In the camera's **Configuration** tab, **Firmware** section:
   **Select Firmware File**, then **Update Firmware**.
3. Keep it connected until the update finishes. The app backs up the camera's current firmware first,
   and the camera keeps its name.
4. Label the camera as updated, and put it back **in the same USB port** (calibrations follow the port).
   Recheck its calibration and exposure afterwards: gain behaviour changed.

Update one camera first and run it on the robot for a while before doing the rest (it's experimental).

## Checking all cameras

On the Jetson, `scripts/jetson/health-check.sh` prints a line per camera:

- `PASS <name>: USB rev X, has gain control`: 5.13 (or newer).
- `WARN <name>: USB rev X, no gain control: ... older than 5.13?`: not updated.

By hand: `v4l2-ctl -d /dev/videoN -l | grep gain`. When the first camera is updated, write down the
USB rev (`bcdDevice`) it reports here, so we can check the exact version, not just the gain control.

| Camera | Port | Firmware | Updated on |
|---|---|---|---|
| TopLeft | | | |
| TopRight | | | |
| BottomLeft | | | |
| BottomRight | | | |

## Updating from the PhotonVision UI?

Not practical now. The updater is Thrifty Config, a closed desktop app, and Thrifty Bot hasn't published
how it talks to the camera (likely a vendor USB command or a bootloader mode). We'd have to reverse-engineer
that, and a failed flash on the robot could brick a camera mid-season. What we can do in PhotonVision:
show each camera's firmware revision and gain-control status (the same check as `health-check.sh`) on
the Match Ready page, so an un-updated camera is visible. If Thrifty Bot publishes the update protocol or a
Linux command-line updater, flashing from the Jetson becomes worth doing; ask them.
