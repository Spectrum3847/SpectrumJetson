#!/usr/bin/env bash
# SpectrumJetson: lower the CPU and GPU clocks while the Jetson has nothing to do, and put them
# back at once when it does. Installed by 09-robot-tuning.sh as /usr/local/bin/spectrum-clocks.
# A fanless Orin Nano reached 98 C idling on the bench; throttled it drew 8.9 W instead of 11.8 W
# (one replay running). Who runs it:
#   - PhotonVision (photonvision-90, ClockThrottle): throttle after the robot (or no robot) has
#     been disabled for 20 s, full the moment it's enabled.
#   - photonvision.service's drop-in: full before it starts, throttle after it stops or crashes.
#   - spectrum-clocks-guard (every 15 s): `guard` below.
#
#   spectrum-clocks throttle   CPU and GPU min to their lowest step, max to THROTTLE_CPU_KHZ /
#                              THROTTLE_GPU_HZ (default 1190.4 / 612 MHz). Saves the locked maxima
#                              in /run/spectrum-clocks-throttled first; while that file exists
#                              spectrum-clocks-guard leaves the clocks alone. Does nothing when the
#                              mode is "full".
#   spectrum-clocks full       Back to min = max = the saved maxima (what jetson_clocks set),
#                              written straight to sysfs (milliseconds); /usr/bin/jetson_clocks if
#                              nothing was saved. Removes the flag. Safe to run any time.
#   spectrum-clocks mode auto|full
#                              full: never throttle (bench tests that need steady clocks); saved in
#                              /etc/spectrum-clocks-mode. auto (the default): PhotonVision decides.
#   spectrum-clocks guard      Mode full: locked, always. Otherwise: throttled (flag) -> leave
#                              alone; PhotonVision not running for 30 s (disabled, not installed)
#                              -> throttle; else relock if something lowered the clocks
#                              (JetPack 7 did, 2026-10-30).
#   spectrum-clocks status
#
# EMC (memory) clocks are left locked. Exit 0 on success.
set -uo pipefail
FLAG=/run/spectrum-clocks-throttled
MODE_FILE=/etc/spectrum-clocks-mode
LOCK=/run/spectrum-clocks.lock
CPU_KHZ=${THROTTLE_CPU_KHZ:-1190400}
GPU_HZ=${THROTTLE_GPU_HZ:-612000000}

G=$(ls -d /sys/devices/platform/bus@0/17000000.gpu/devfreq/* 2>/dev/null | head -1)
CPUS=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq)

mode() { local m; m=$(cat "$MODE_FILE" 2>/dev/null); [[ $m == full ]] && echo full || echo auto; }

# The lowest frequency, and the highest at or below $2, from a space-separated list $1.
lowest() { tr ' ' '\n' <<<"$1" | grep -E '^[0-9]+$' | sort -n | head -1; }
at_most() { tr ' ' '\n' <<<"$1" | grep -E '^[0-9]+$' | sort -n | awk -v t="$2" '$1<=t{v=$1} END{print v}'; }

# Write min and max in the order the kernel accepts: going down min first, going up max first.
set_pair() { # dir minfile maxfile min max
  local d=$1 cur_max; cur_max=$(cat "$d/$3")
  if (( $5 >= cur_max )); then echo "$5" >"$d/$3"; echo "$4" >"$d/$2"
  else echo "$4" >"$d/$2"; echo "$5" >"$d/$3"; fi
}

throttle() {
  [[ $(mode) == full ]] && { echo "mode is full: not throttling"; return 0; }
  if [[ ! -f $FLAG ]]; then
    # The maxima to go back to: what jetson_clocks locked, before we lower anything. Only when they
    # are locked (min = max): clocks lowered some other way (by hand) leave the flag empty, and
    # `full` runs jetson_clocks instead.
    if unlocked; then : >"$FLAG"; else {
      [[ -n $G ]] && echo "gpu $(cat "$G/max_freq")"
      for c in "${CPUS[@]}"; do echo "cpu $c $(cat "$c/scaling_max_freq")"; done
    } >"$FLAG.tmp" && mv "$FLAG.tmp" "$FLAG"; fi
  fi
  if [[ -n $G ]]; then
    local av; av=$(cat "$G/available_frequencies")
    set_pair "$G" min_freq max_freq "$(lowest "$av")" "$(at_most "$av" "$GPU_HZ")"
  fi
  for c in "${CPUS[@]}"; do
    local av; av=$(cat "$c/scaling_available_frequencies")
    set_pair "$c" scaling_min_freq scaling_max_freq "$(lowest "$av")" "$(at_most "$av" "$CPU_KHZ")"
  done
}

# Something below its maximum lock: the GPU or a CPU with min < max.
unlocked() {
  [[ -n $G && $(cat "$G/min_freq") -lt $(cat "$G/max_freq") ]] && return 0
  local c
  for c in "${CPUS[@]}"; do [[ $(cat "$c/scaling_min_freq") -lt $(cat "$c/scaling_max_freq") ]] && return 0; done
  return 1
}

full() {
  if [[ ! -s $FLAG ]]; then
    # Nothing saved: jetson_clocks, unless already locked.
    rm -f "$FLAG"
    if unlocked; then /usr/bin/jetson_clocks; fi
    return 0
  fi
  local ok=1 kind a b
  while read -r kind a b; do
    case $kind in
      gpu) [[ -n $G ]] && { set_pair "$G" min_freq max_freq "$a" "$a" || ok=0; } ;;
      cpu) set_pair "$a" scaling_min_freq scaling_max_freq "$b" "$b" || ok=0 ;;
    esac
  done <"$FLAG"
  rm -f "$FLAG"
  (( ok )) || /usr/bin/jetson_clocks
}

PV_SINCE=/run/spectrum-clocks-pv-inactive-since
guard() {
  if [[ $(mode) == full ]]; then
    if [[ -f $FLAG ]] || unlocked; then logger -t spectrum-clocks "mode full: locking the clocks"; full; fi
    return 0
  fi
  local state now since
  state=$(systemctl is-active photonvision 2>/dev/null)
  if [[ $state == active || $state == activating || $state == reloading ]]; then
    rm -f "$PV_SINCE"
  else
    now=$(cut -d. -f1 /proc/uptime)
    [[ -f $PV_SINCE ]] || echo "$now" >"$PV_SINCE"
    since=$(cat "$PV_SINCE")
    if [[ ! -f $FLAG ]] && (( now - since >= 30 )); then
      logger -t spectrum-clocks "PhotonVision not running ($state) for 30 s: lowering the clocks"
      throttle
    fi
    return 0
  fi
  if [[ -f $FLAG ]]; then return 0; fi   # PhotonVision lowered them on purpose (robot disabled)
  local low=""
  [[ -n $G && $(cat "$G/min_freq") -lt $(cat "$G/max_freq") ]] && low+=" GPU min $(( $(cat "$G/min_freq") / 1000000 )) MHz"
  local c
  for c in "${CPUS[@]}"; do
    [[ $(cat "$c/scaling_min_freq") -lt $(cat "$c/scaling_max_freq") ]] && { low+=" CPU min $(( $(cat "$c/scaling_min_freq") / 1000 )) MHz"; break; }
  done
  [[ -z $low ]] && return 0
  logger -t spectrum-clocks "clocks were unlocked ($low ); locking again"
  /usr/bin/jetson_clocks
}

status() {
  echo "mode: $(mode)"
  [[ -f $FLAG ]] && echo "state: throttled" || echo "state: full"
  [[ -n $G ]] && echo "gpu: $(( $(cat "$G/cur_freq") / 1000000 )) MHz (min $(( $(cat "$G/min_freq") / 1000000 )), max $(( $(cat "$G/max_freq") / 1000000 )))"
  local c=${CPUS[0]}
  [[ -d $c ]] && echo "cpu0: $(( $(cat "$c/scaling_cur_freq") / 1000 )) MHz (min $(( $(cat "$c/scaling_min_freq") / 1000 )), max $(( $(cat "$c/scaling_max_freq") / 1000 )))"
}

[[ $(id -u) == 0 || ${1:-} == status ]] || { echo "run as root" >&2; exit 1; }
# One at a time, with spectrum-clocks-guard too (it takes the same lock).
if [[ ${1:-} != status ]]; then exec 9>"$LOCK"; flock -w 5 9 || { echo "lock busy" >&2; exit 1; }; fi
case ${1:-} in
  throttle) throttle ;;
  full) full ;;
  guard) guard ;;
  mode)
    [[ ${2:-} == auto || ${2:-} == full ]] || { echo "usage: spectrum-clocks mode auto|full" >&2; exit 2; }
    echo "$2" >"$MODE_FILE"
    [[ $2 == full ]] && full
    echo "mode: $2" ;;
  status) status ;;
  *) echo "usage: spectrum-clocks throttle|full|guard|mode auto|full|status" >&2; exit 2 ;;
esac
