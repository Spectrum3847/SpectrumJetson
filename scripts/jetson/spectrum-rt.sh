#!/usr/bin/env bash
# SpectrumJetson: lower-jitter camera handling (971's approach), OFF by default. Installed by
# 09-robot-tuning.sh as /usr/local/bin/spectrum-rt, re-applied every 15 s by spectrum-rt.timer
# (PhotonVision makes new threads on every restart and camera rebuild).
#
# When on:
#   - The USB host controller's interrupt (xhci-hcd) goes to one core (RT_USB_CPU, default 5).
#     By default every USB interrupt and every finished transfer (HI softirq) lands on CPU0, the
#     core with most of the other system work, where camera threads also run.
#   - PhotonVision's camera threads (VisionRunner, one per camera) and decode threads
#     (SpectrumDecoder, Java threads only) run SCHED_FIFO at RT_PRIO (default 10): below the
#     kernel's interrupt threads (50), above everything else. They block on frames and the GPU,
#     so they can't starve the system, and a frame that's ready is handled at once.
#   - Those threads are kept off the USB core (all other cores allowed).
# Expected: a lower p95/max frame latency under load, not a lower median. A/B it before keeping it.
#
# Usage: spectrum-rt on|off|status|apply     (on/off are saved in /etc/spectrum-rt and survive
#        reboots; apply is what the timer runs)
set -uo pipefail
MODE_FILE=/etc/spectrum-rt
USB_CPU=${RT_USB_CPU:-5}
PRIO=${RT_PRIO:-10}
NCPU=$(nproc)
ALL="0-$((NCPU - 1))"
others=$(seq 0 $((NCPU - 1)) | grep -vx "$USB_CPU" | paste -sd,)

# Scheduling policy of a thread (1 = FIFO). The name in /proc/.../stat can hold spaces
# ("VisionRunner - ..."), so count fields after its closing parenthesis.
policy() { sed 's/.*) //' "$1/stat" 2>/dev/null | awk '{print $39}'; }

usb_irqs() { grep -E 'xhci-hcd' /proc/interrupts | cut -d: -f1 | tr -d ' '; }

# Java threads that should be real-time: the VisionRunner and SpectrumDecoder threads, by the
# native thread ids jcmd reports (a native thread can inherit the same name; it must stay normal).
camera_tids() {
  local pid=$1
  jcmd "$pid" Thread.print 2>/dev/null | grep -E '^"(VisionRunner|SpectrumDecoder)' |
    grep -oE 'nid=[0-9]+' | cut -d= -f2
}

apply() {
  local on=$1 pid tids t
  for irq in $(usb_irqs); do
    echo "$([[ $on == on ]] && echo "$USB_CPU" || echo "$ALL")" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null
  done
  pid=$(systemctl show -p MainPID --value photonvision)
  [[ $pid != 0 && -d /proc/$pid ]] || return 0
  if [[ $on == on ]]; then
    # jcmd only when something changed: a new process, a VisionRunner that isn't real-time yet
    # (a rebuilt camera), or a thread we set that's gone (a restarted decoder thread).
    local need=0 cache=/run/spectrum-rt.tids
    [[ $(head -1 "$cache" 2>/dev/null) == "$pid" ]] || need=1
    for t in /proc/"$pid"/task/*; do
      [[ $(cat "$t/comm" 2>/dev/null) == "VisionRunner -"* && $(policy "$t") != 1 ]] && need=1
    done
    for t in $(tail -n +2 "$cache" 2>/dev/null); do [[ -d /proc/$pid/task/$t ]] || need=1; done
    ((need)) || return 0
    tids=$(camera_tids "$pid")
    for t in $tids; do
      chrt -f -p "$PRIO" "$t" 2>/dev/null
      taskset -p -c "$others" "$t" >/dev/null 2>&1
    done
    { echo "$pid"; echo "$tids"; } > "$cache"
    logger -t spectrum-rt "camera threads real-time (FIFO $PRIO, off CPU $USB_CPU): $(echo "$tids" | wc -w); USB IRQ on CPU $USB_CPU"
  else
    rm -f /run/spectrum-rt.tids
    for t in /proc/"$pid"/task/*; do
      [[ $(policy "$t") == 1 ]] || continue
      chrt -o -p 0 "${t##*/}" 2>/dev/null
      taskset -p -c "$ALL" "${t##*/}" >/dev/null 2>&1
    done
  fi
}

status() {
  echo "mode: $(cat $MODE_FILE 2>/dev/null || echo off)"
  for irq in $(usb_irqs); do echo "USB IRQ $irq: CPUs $(cat /proc/irq/"$irq"/smp_affinity_list)"; done
  local pid; pid=$(systemctl show -p MainPID --value photonvision)
  [[ $pid != 0 ]] && ps -L -o tid,cls,rtprio,psr,comm -p "$pid" | grep -E 'CLS|VisionRun|SpectrumDec'
}

case ${1:-status} in
  on|off) echo "$1" > "$MODE_FILE"; apply "$1"; status ;;
  apply) apply "$(cat $MODE_FILE 2>/dev/null || echo off)" ;;
  status) status ;;
  *) echo "usage: $0 on|off|status|apply" >&2; exit 2 ;;
esac
