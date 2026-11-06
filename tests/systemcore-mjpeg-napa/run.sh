#!/usr/bin/env bash
# SystemCore MJPEG + NAPA bench, run ON THE PI (binaries from build.sh in ~/bench/bin, sessions in ~/bench/data).
#   run.sh offline [SESSION...]      decode + fused (min16, far) + napa_stream_replay identity + fuzz
#   run.sh decode|fused|fuzz SESSION [scmn_bench options]
#   run.sh live SECS [LABEL]         measure what is running now (PhotonVision or the native app) under
#                                    /tmp/camera.lock: sysmon + xhci/v4l2 trace (see live.md)
#   run.sh soak MINUTES PID...       sysmon only (leaks, temps, throttling) for the given processes
# Results go to ~/bench/results/<date>-<label>/ with a summary.txt. The builder's decoder is included when
# SCMN_BUILDER_LIB points at a library with the scmn_dec_* ABI (bench.cc). Pins to core ${SCMN_CPU:-3}.
# LimelightOS has no `timeout`; tmo() below stands in for it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
B=${SCMN_BIN:-$HOME/bench/bin}
D=${SCMN_DATA:-$HOME/bench/data}
CPU=${SCMN_CPU:-3}
OUT=$HOME/bench/results/$(date +%Y%m%d-%H%M%S)-${SCMN_LABEL:-run}
mkdir -p "$OUT"

tmo() {  # tmo SECS CMD...: run CMD, kill it after SECS (prints TIMEOUT)
  local s=$1
  shift
  "$@" &
  local p=$!
  (sleep "$s" && kill -TERM "$p" 2>/dev/null && echo "TIMEOUT after ${s}s: $*" >&2) &
  local k=$!
  wait "$p"
  local rc=$?
  kill "$k" 2>/dev/null
  wait "$k" 2>/dev/null
  return $rc
}

sysinfo() {
  {
    echo "date $(date) uptime $(cut -d' ' -f1 /proc/uptime)"
    uname -a
    echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) max $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
    echo "temp $(cat /sys/class/thermal/thermal_zone0/temp)"
    echo "builder lib ${SCMN_BUILDER_LIB:-none} $( [[ -n ${SCMN_BUILDER_LIB:-} ]] && md5sum "$SCMN_BUILDER_LIB" | cut -c1-12)"
    md5sum "$B"/* 2>/dev/null | sed 's/^/bin /'
    top -bn1 | head -5
  } >"$OUT/sysinfo.txt"
}

offline() {
  local sessions=("$@")
  [[ ${#sessions[@]} -gt 0 ]] || sessions=("$D"/*/)
  sysinfo
  for s in "${sessions[@]}"; do
    s=${s%/}
    local n
    n=$(basename "$s")
    echo "== $n" | tee -a "$OUT/summary.txt"
    tmo 900 "$B/scmn_bench" decode "$s" --cpu "$CPU" --times "$OUT/$n-decode.csv" >>"$OUT/summary.txt" 2>>"$OUT/stderr.txt"
    for cfg in min16 far; do
      tmo 1800 "$B/scmn_bench" fused "$s" --cpu "$CPU" --config $cfg --times "$OUT/$n-fused-$cfg.csv" \
        >>"$OUT/summary.txt" 2>>"$OUT/stderr.txt"
      tmo 1800 "$B/napa_stream_replay" "$s" --config $cfg --mode identity --band 16 >>"$OUT/summary.txt" 2>>"$OUT/stderr.txt"
    done
    tmo 1800 "$B/scmn_bench" fuzz "$s" --max-frames 200 >>"$OUT/summary.txt" 2>>"$OUT/stderr.txt"
  done
  echo "results: $OUT"
  grep -E "^==|IDENTICAL|DIFFERENT|FUZZ|tail ms|CPU ms|CPU decode|TIMEOUT" "$OUT/summary.txt"
}

cmd=${1:-}
shift || true
case $cmd in
  offline) offline "$@" ;;
  decode | fused | fuzz)
    sysinfo
    s=$1
    shift
    tmo 3600 "$B/scmn_bench" "$cmd" "$s" --cpu "$CPU" "$@" | tee "$OUT/summary.txt"
    ;;
  live) exec "$HERE/live.sh" "$OUT" "$@" ;;
  soak)
    mins=$1
    shift
    sysinfo
    sudo python3 "$HERE/sysmon.py" "$OUT/sysmon.csv" --secs $((mins * 60)) --pid "$@" | tee "$OUT/summary.txt"
    ;;
  *)
    sed -n 2,12p "$0"
    exit 2
    ;;
esac
