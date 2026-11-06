#!/bin/bash
# Swap the SystemCore's camera driver at run time (no /lib/modules, modprobe.d or boot changes; a reboot always comes
# back to the stock driver). Run ON THE SYSTEMCORE with the camera free (holds /tmp/camera.lock).
#   uvcvideo-load.sh urb N [KO]   ours (scripts/systemcore/build-uvcvideo.sh): N packets per isochronous URB
#                                  (N x 125 us; stock is 32 = 4 ms). KO default ~/builder/uvcvideo-sc.ko
#   uvcvideo-load.sh stock        back to the stock module (modprobe: Limelight's options from modprobe.d)
#   uvcvideo-load.sh status
# Ours gets the same options as the stock one (/etc/modprobe.d/uvcvideo.conf: quirks + Limelight's ll_compressed_*).
set -euo pipefail
cmd=${1:-status}
KO=${3:-$HOME/builder/uvcvideo-sc.ko}
exec 9>/tmp/camera.lock
[[ ${SC_VISION_HAVE_LOCK:-0} == 1 ]] || flock -w 60 9 || { echo "camera busy (/tmp/camera.lock)" >&2; exit 1; }
opts() { sed -n 's/^options uvcvideo //p' /etc/modprobe.d/uvcvideo.conf 2>/dev/null | tr '\n' ' '; }
unload() {
  for u in photonvision sc-vision-native limelight_visionserver; do
    [[ $(systemctl is-active "$u") == active ]] && { echo "stop $u first (sc-vision off)" >&2; exit 1; }
  done
  sudo rmmod uvcvideo 2>/dev/null || true
}
case $cmd in
  urb)
    n=${2:?packets per URB}
    unload
    # shellcheck disable=SC2046
    sudo insmod "$KO" $(opts) urb_packets="$n"
    ;;
  stock)
    unload
    sudo modprobe uvcvideo
    ;;
  status) ;;
  *) echo "usage: uvcvideo-load.sh urb N [KO] | stock | status" >&2; exit 2 ;;
esac
sleep 1
echo "uvcvideo: srcversion $(cat /sys/module/uvcvideo/srcversion 2>/dev/null), urb_packets $(cat /sys/module/uvcvideo/parameters/urb_packets 2>/dev/null || echo stock), video0 $(ls /dev/video0 2>/dev/null || echo missing)"
