#!/usr/bin/env bash
# EXTRA_CMD for nativecam.sh: an xhci_urb_giveback trace (mono clock) for SECS s into OUT, for tsresid.py
# (published capture time vs the frame's first USB packet).   EXTRA_CMD="bash xhci-trace.sh OUT SECS"
set -uo pipefail
OUT=${1:?trace file}
SECS=${2:-10}
T=/sys/kernel/tracing
sudo sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo mono > $T/trace_clock; echo 32768 > $T/buffer_size_kb;
  echo 0 > $T/events/enable; echo 1 > $T/events/xhci-hcd/xhci_urb_giveback/enable; echo 1 > $T/tracing_on"
sleep "$SECS"
sudo sh -c "echo 0 > $T/tracing_on; cat $T/trace > $OUT; echo 0 > $T/events/enable; echo > $T/trace; echo local > $T/trace_clock"
echo "trace: $(wc -l < "$OUT") lines"
