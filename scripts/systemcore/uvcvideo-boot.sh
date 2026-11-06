#!/bin/bash
# Our uvcvideo at boot on the SystemCore (sc-uvcvideo.service, before photonvision / limelight_visionserver), with
# the stock driver as the fallback for ANY failure. Installed by install-photonvision.sh as /opt/sc-vision/uvcvideo-boot.sh.
#   uvcvideo-boot.sh start    (the unit) swap stock -> ours, or leave/put back the stock one and say why
#   uvcvideo-boot.sh status   which driver is loaded (ours: urb_packets/hwtimestamps; stock), and the boot result
# Ours: /opt/sc-vision/modules/uvcvideo-sc.ko (kept outside /lib/modules: modprobe and kernel updates never see it;
# stock is never blacklisted, so a failed or disabled unit always leaves the stock driver working).
# Checks before loading: the .ko's sha256 equals uvcvideo-sc.ko.sha256 next to it, its vermagic's kernel equals
# `uname -r` (a LimelightOS update changes the kernel: stock then). After loading: the cameras the stock driver had
# come back (by-id video-index0 nodes) within CAMERA_WAIT_S, else stock again.
# Config /etc/sc-vision/uvcvideo.conf (shell): ENABLED=1 (0: stock, nothing touched), URB_PACKETS=2, HWTIMESTAMPS=1,
# CAMERA_WAIT_S=10. Result in /run/sc-uvcvideo.status and the journal.
set -uo pipefail
DIR=/opt/sc-vision/modules
KO=$DIR/uvcvideo-sc.ko
CONF=/etc/sc-vision/uvcvideo.conf
STATUS=/run/sc-uvcvideo.status
ENABLED=1
URB_PACKETS=2
HWTIMESTAMPS=1
CAMERA_WAIT_S=10
# shellcheck disable=SC1090
[[ -f $CONF ]] && . "$CONF"

say() { echo "sc-uvcvideo: $*"; }
driver() {
  if [[ ! -d /sys/module/uvcvideo ]]; then echo "none"
  elif [[ -f /sys/module/uvcvideo/parameters/urb_packets ]]; then
    echo "ours (urb_packets $(cat /sys/module/uvcvideo/parameters/urb_packets), hwtimestamps $(cat /sys/module/uvcvideo/parameters/hwtimestamps))"
  else echo "stock"
  fi
}
cameras() { find /dev/v4l/by-id -name '*-video-index0' 2>/dev/null | wc -l; }
opts() { sed -n 's/^options uvcvideo //p' /etc/modprobe.d/uvcvideo.conf 2>/dev/null | tr '\n' ' '; }
result() {  # STATE REASON
  printf '%s %s: %s\n' "$(date '+%F %T')" "$1" "$2" >"$STATUS"
  say "$1: $2 (driver: $(driver))"
}
stock() {  # REASON: back to (or stay on) the stock driver
  if [[ -f /sys/module/uvcvideo/parameters/urb_packets ]]; then rmmod uvcvideo 2>/dev/null; fi
  [[ -d /sys/module/uvcvideo ]] || modprobe uvcvideo || say "modprobe uvcvideo FAILED"
  result stock "$1"
  exit 0
}

case ${1:-status} in
  status)
    echo "uvcvideo: $(driver); cameras: $(cameras); boot: $(cat "$STATUS" 2>/dev/null || echo 'no result (unit not run)')"
    exit 0
    ;;
  start) ;;
  *) echo "usage: uvcvideo-boot.sh start | status" >&2; exit 2 ;;
esac

[[ $ENABLED == 1 ]] || stock "disabled in $CONF"
[[ -f $KO ]] || stock "$KO missing"
want=$(cat "$KO.sha256" 2>/dev/null | awk '{print $1}')
have=$(sha256sum "$KO" | awk '{print $1}')
[[ -n $want && $want == "$have" ]] || stock "sha256 mismatch ($have, expected ${want:-none})"
vm=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[[ $vm == "$(uname -r)" ]] || stock "vermagic ${vm:-unreadable} != kernel $(uname -r)"
[[ -f /sys/module/uvcvideo/parameters/urb_packets ]] && { result ours "already loaded"; exit 0; }
# the cameras the stock driver brings up at boot: wait for them to settle so we know how many must come back
before=0
for _ in $(seq $((CAMERA_WAIT_S * 2))); do
  n=$(cameras)
  if ((n > 0 && n == before)); then break; fi
  before=$n
  sleep 0.5
done
before=$(cameras)
if [[ -d /sys/module/uvcvideo ]]; then
  rmmod uvcvideo || stock "rmmod of the stock uvcvideo failed (device in use?)"
fi
# shellcheck disable=SC2046
if ! insmod "$KO" $(opts) urb_packets="$URB_PACKETS" hwtimestamps="$HWTIMESTAMPS"; then
  stock "insmod $KO failed"
fi
after=0
for _ in $(seq $((CAMERA_WAIT_S * 4))); do
  after=$(cameras)
  ((after >= before)) && break
  sleep 0.25
done
((after >= before)) || stock "only $after of $before cameras came back within ${CAMERA_WAIT_S} s"
result ours "loaded, $after camera(s) (stock had $before)"
