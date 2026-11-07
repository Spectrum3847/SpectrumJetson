#!/bin/bash
# sweep.sh SECS OUT "texp tgain sexp sgain" ...   (holds /tmp/camera.lock; restores T 12/128, S 5/96 at the end
# unless KEEP=1). Sets only controls that change (the Swyft stores them in flash).
secs=$1 out=$2; shift 2
exec 9>/tmp/camera.lock; flock -w 120 9 || { echo lock busy; exit 1; }
T=/dev/v4l/by-id/usb-DCX-260513-K_Thrifty_SJ-05-video-index0 S=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0
get() { v4l2-ctl -d $1 -C $2 | awk '{print $2}'; }
setc() { [ "$(get $1 $2)" = "$3" ] || v4l2-ctl -d $1 -c $2=$3; }
cpu() { awk '{print $14+$15}' /proc/$PID/stat; }
PID=$(systemctl show -p MainPID --value photonvision); HZ=100
for s in "$@"; do
  set -- $s
  setc $T exposure_time_absolute $1; setc $T gain $2; setc $S exposure_time_absolute $3; setc $S gain $4
  sleep 2
  a=$(cpu); t1=$(date +%s.%N)
  p=$(python3 ~/bench/exposure/expo_probe.py $secs thrifty swyft)
  b=$(cpu); t2=$(date +%s.%N)
  gt=$(python3 ~/bench/exposure/grab.py 1183 8 2>/dev/null | tail -1); gs=$(python3 ~/bench/exposure/grab.py 1181 8 2>/dev/null | tail -1)
  c=$(echo "$a $b $t1 $t2 $HZ" | awk '{printf "%.1f", 100*($2-$1)/$5/($4-$3)}')
  echo "{\"T\":[$1,$2],\"S\":[$3,$4],\"pv_cpu\":$c,\"probe\":$p,\"imgT\":$gt,\"imgS\":$gs}" | tee -a $out
done
if [ "${KEEP:-0}" != 1 ]; then setc $T exposure_time_absolute 12; setc $T gain 128; setc $S exposure_time_absolute 5; setc $S gain 96; fi
echo restored: T $(get $T exposure_time_absolute)/$(get $T gain) S $(get $S exposure_time_absolute)/$(get $S gain)
