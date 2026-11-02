#!/usr/bin/env bash
# Kernel-side latency of the Thriftiest MJPEG stream at several uvcvideo urb_packets values,
# with PhotonVision STOPPED (v4l2-ctl streams the cameras itself). Run on the Jetson as the
# normal user (sudo -n). Not USB-disrupting: urb_packets is a writable module parameter that
# uvcvideo reads when a stream starts; nothing is unbound, reset or reloaded.
#   tests/latency-breakdown/usb-sweep.sh [OUT_DIR] [PACKETS...]   (default 16 8 4 2 1)
# Env: CAMS="/dev/video0" (or "/dev/video0 /dev/video2"), FRAMES=600, EXPOSURE (100 us units,
# unset = leave as is). Each run: ftrace (mono clock) of xhci_urb_giveback, vb2_buf_done and
# v4l2_dqbuf, xhci IRQ count, CPU busy from /proc/stat, sequence gaps (drops). Restores
# urb_packets (and exposure) afterwards. Analyse with ktrace.py.
set -uo pipefail
OUT=${1:-/tmp/lat/sweep}; shift || true
PACKETS=${*:-16 8 4 2 1}
CAMS=${CAMS:-/dev/video0}; FRAMES=${FRAMES:-600}
T=/sys/kernel/tracing; P=/sys/module/uvcvideo/parameters/urb_packets
systemctl is-active -q photonvision && { echo "PhotonVision is running: stop it first"; exit 1; }
mkdir -p "$OUT"; orig=$(cat $P)
declare -A oexp
for c in $CAMS; do oexp[$c]=$(v4l2-ctl -d "$c" -C exposure_time_absolute | awk '{print $2}'); done
restore() {
  echo "$orig" | sudo -n tee $P >/dev/null
  for c in $CAMS; do v4l2-ctl -d "$c" -c exposure_time_absolute="${oexp[$c]}"; done
  sudo -n sh -c "echo 0 > $T/tracing_on; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
  echo "restored urb_packets=$orig, exposure ${oexp[*]}"
}
trap restore EXIT
irq() { awk '/xhci-hcd:usb1/{s=0; for(i=2;i<=7;i++) s+=$i; print s}' /proc/interrupts; }
cpu() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat; }
for n in $PACKETS; do
  echo "$n" | sudo -n tee $P >/dev/null
  for c in $CAMS; do
    [[ -n ${EXPOSURE:-} ]] && v4l2-ctl -d "$c" -c exposure_time_absolute="$EXPOSURE"
  done
  sudo -n sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 16384 > $T/buffer_size_kb;
    for e in xhci-hcd/xhci_urb_giveback vb2/vb2_buf_done v4l2/v4l2_dqbuf; do echo 1 > $T/events/\$e/enable; done; echo 1 > $T/tracing_on"
  i0=$(irq); read -r b0 a0 < <(cpu); s0=$(date +%s.%N)
  pids=()
  for c in $CAMS; do
    timeout $((FRAMES / 60 + 15)) v4l2-ctl -d "$c" --set-fmt-video=width=1280,height=800,pixelformat=MJPG --set-parm=120 \
      --stream-mmap=4 --stream-count="$FRAMES" --stream-to=/dev/null > "$OUT/v4l2-$n-$(basename "$c").log" 2>&1 &
    pids+=($!)
  done
  rc=0; for p in "${pids[@]}"; do wait "$p" || rc=$?; done
  [[ $rc == 124 ]] && echo "TIMEOUT (urb_packets=$n)"
  i1=$(irq); read -r b1 a1 < <(cpu); s1=$(date +%s.%N)
  sudo -n sh -c "echo 0 > $T/tracing_on; cat $T/trace" > "$OUT/trace-$n.txt"
  awk -v n="$n" -v i="$((i1 - i0))" -v s="$(echo "$s1 - $s0" | bc)" -v b="$((b1 - b0))" -v a="$((a1 - a0))" -v t="$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)" \
    'BEGIN{printf "urb_packets=%s irq/s=%.0f cpu_busy=%.1f%% (of 6 cores) secs=%.2f temp=%.1fC\n", n, i/s, 100*b/a, s, t/1000}' | tee -a "$OUT/summary.txt"
done
