#!/bin/bash
# Holds the camera lock; ~/bench/exposure on the target. Usage: ssh ... bash -s < verify.sh
# Photometric exposure check under PhotonVision: mean luma (30 frames from the input stream) per exposure setting.
# Thriftiest at gain 128 gamma 100; Swyft temporarily at gamma 100 gain 32 (restored to gamma 300, 5/96).
exec 9>/tmp/camera.lock; flock -w 120 9 || exit 1
T=/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0 S=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0
for e in 1 3 4 2 6 8 10 11 12 13 14 16 20; do v4l2-ctl -d $T -c exposure_time_absolute=$e; sleep 2; echo "T $e $(python3 ~/bench/exposure/grab.py 1183 90 2>/dev/null|tail -1)"; done
v4l2-ctl -d $T -c exposure_time_absolute=12
v4l2-ctl -d $S -c gamma=100,gain=32
for e in 2 3 4 5 6 8 10 12 2; do v4l2-ctl -d $S -c exposure_time_absolute=$e; sleep 2; echo "S $e $(python3 ~/bench/exposure/grab.py 1181 90 2>/dev/null|tail -1)"; done
v4l2-ctl -d $S -c gamma=300,gain=96,exposure_time_absolute=5
v4l2-ctl -d $S -C gamma,gain,exposure_time_absolute
