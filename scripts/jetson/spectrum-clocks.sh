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
#   spectrum-clocks deep       The deep idle tier (photonvision-99: no robot connected, no web UI
#                              client or stream viewer for 5 min; or PhotonVision stopped 5 min):
#                              throttle, then CPU max DEEP_CPU_KHZ (729.6 MHz), GPU max
#                              DEEP_GPU_HZ (306 MHz), EMC min to its lowest step (dynamic instead
#                              of locked at 3199 MHz), CPU idle states (WFI, c7) on, and cores
#                              DEEP_OFFLINE_CPUS (2 3 4) offline. Saved in /run/spectrum-clocks-deep.
#                              Not in mode full or shallow.
#                              Restore (full, or throttle back to the shallow tier): clocks first
#                              (ms), then EMC and idle states (ms), then the cores (~tens of ms).
#   spectrum-clocks mode auto|shallow|full
#                              full: never throttle (bench tests that need steady clocks); saved in
#                              /etc/spectrum-clocks-mode. shallow: the 20 s throttle only, never
#                              deep. auto (the default): PhotonVision decides, both tiers.
#   spectrum-clocks guard      Mode full: locked, always. Otherwise: throttled (flag) -> leave
#                              alone; PhotonVision not running for 30 s (disabled, not installed)
#                              -> throttle, for DEEP_AFTER_S (300 s) -> deep; else relock if something lowered the clocks
#                              (JetPack 7 did, 2026-10-30).
#   spectrum-clocks status
#
# EMC (memory) clocks stay locked except in deep. Exit 0 on success.
set -uo pipefail
FLAG=/run/spectrum-clocks-throttled
MODE_FILE=/etc/spectrum-clocks-mode
LOCK=/run/spectrum-clocks.lock
CPU_KHZ=${THROTTLE_CPU_KHZ:-1190400}
GPU_HZ=${THROTTLE_GPU_HZ:-612000000}
DEEP=/run/spectrum-clocks-deep
DEEP_CPU_KHZ=${DEEP_CPU_KHZ:-729600}
DEEP_GPU_HZ=${DEEP_GPU_HZ:-306000000}
DEEP_OFFLINE_CPUS=${DEEP_OFFLINE_CPUS:-2 3 4}
DEEP_AFTER_S=${DEEP_AFTER_S:-300}
EMC=/sys/class/devfreq/bwmgr

G=$(ls -d /sys/devices/platform/bus@0/17000000.gpu/devfreq/* 2>/dev/null | head -1)
CPUS=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq)

mode() { local m; m=$(cat "$MODE_FILE" 2>/dev/null); [[ $m == full || $m == shallow ]] && echo "$m" || echo auto; }

# The lowest frequency, and the highest at or below $2, from a space-separated list $1.
lowest() { tr ' ' '\n' <<<"$1" | grep -E '^[0-9]+$' | sort -n | head -1; }
at_most() { tr ' ' '\n' <<<"$1" | grep -E '^[0-9]+$' | sort -n | awk -v t="$2" '$1<=t{v=$1} END{print v}'; }

# Write min and max in the order the kernel accepts: going down min first, going up max first.
set_pair() { # dir minfile maxfile min max
  local d=$1 cur_max
  [[ -r $d/$3 ]] || return 0  # an offline core (deep): its cluster's policy is set through another
  cur_max=$(cat "$d/$3")
  if (( $5 >= cur_max )); then echo "$5" >"$d/$3"; echo "$4" >"$d/$2"
  else echo "$4" >"$d/$2"; echo "$5" >"$d/$3"; fi
}

throttle() { # [cpu_khz gpu_hz]: the caps (default the shallow tier's)
  local cpu_cap=${1:-$CPU_KHZ} gpu_cap=${2:-$GPU_HZ}
  [[ $(mode) == full ]] && { echo "mode is full: not throttling"; return 0; }
  # From deep back to the shallow tier: cores, EMC, idle states back first.
  [[ -z ${1:-} && -f $DEEP ]] && undeep
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
    set_pair "$G" min_freq max_freq "$(lowest "$av")" "$(at_most "$av" "$gpu_cap")"
  fi
  for c in "${CPUS[@]}"; do
    [[ -r $c/scaling_available_frequencies ]] || continue  # an offline core
    local av; av=$(cat "$c/scaling_available_frequencies")
    set_pair "$c" scaling_min_freq scaling_max_freq "$(lowest "$av")" "$(at_most "$av" "$cpu_cap")"
  done
}

# Something below its maximum lock: the GPU or a CPU with min < max.
unlocked() {
  [[ -n $G && $(cat "$G/min_freq") -lt $(cat "$G/max_freq") ]] && return 0
  local c
  for c in "${CPUS[@]}"; do [[ -r $c/scaling_min_freq && $(cat "$c/scaling_min_freq") -lt $(cat "$c/scaling_max_freq") ]] && return 0; done
  return 1
}

full() {
  if [[ -f $DEEP && ! -s $FLAG ]]; then undeep; fi
  if [[ ! -s $FLAG ]]; then
    # Nothing saved: jetson_clocks, unless already locked.
    rm -f "$FLAG"
    if unlocked; then /usr/bin/jetson_clocks; fi
    return 0
  fi
  local ok=1 kind a b t0=$EPOCHREALTIME t1
  while read -r kind a b; do
    case $kind in
      gpu) [[ -n $G ]] && { set_pair "$G" min_freq max_freq "$a" "$a" || ok=0; } ;;
      cpu) set_pair "$a" scaling_min_freq scaling_max_freq "$b" "$b" || ok=0 ;;
    esac
  done <"$FLAG"
  rm -f "$FLAG"
  # Clocks are back (milliseconds); now the deep tier's slower parts.
  if [[ -f $DEEP ]]; then
    t1=$EPOCHREALTIME
    undeep
    echo "full: clocks in $(ms "$t0" "$t1") ms, then EMC/idle states/cores in $(ms "$t1" "$EPOCHREALTIME") ms"
  fi
  (( ok )) || /usr/bin/jetson_clocks
}

ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) * 1000 }'; }

# photonvision-99: the deep idle tier, on top of throttle.
deep() {
  [[ $(mode) != auto ]] && { echo "mode is $(mode): not going deep"; return 0; }
  if [[ ! -f $DEEP ]]; then
    {
      [[ -r $EMC/min_freq ]] && echo "emc $(cat "$EMC/min_freq")"
      local f
      for f in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/disable; do
        [[ $(cat "$f") == 1 ]] && echo "idle $f"
      done
    } >"$DEEP.tmp" && mv "$DEEP.tmp" "$DEEP"
  fi
  throttle "$DEEP_CPU_KHZ" "$DEEP_GPU_HZ"
  if [[ -w $EMC/min_freq ]]; then lowest "$(cat "$EMC/available_frequencies")" >"$EMC/min_freq"; fi
  local f n
  while read -r kind f; do [[ $kind == idle ]] && echo 0 >"$f"; done <"$DEEP"
  for n in $DEEP_OFFLINE_CPUS; do
    f=/sys/devices/system/cpu/cpu$n/online
    if [[ -w $f && $(cat "$f") == 1 ]] && echo 0 >"$f"; then echo "offline cpu$n" >>"$DEEP"; fi
  done
}

undeep() {
  local kind a ok=1 t0=$EPOCHREALTIME t1
  # EMC and idle states first (sysfs writes, ms), cores last (each ~10-50 ms).
  while read -r kind a; do
    case $kind in
      emc) echo "$a" >"$EMC/min_freq" || ok=0 ;;
      idle) echo 1 >"$a" || ok=0 ;;
    esac
  done <"$DEEP"
  t1=$EPOCHREALTIME
  while read -r kind a; do
    [[ $kind == offline ]] && { echo 1 >"/sys/devices/system/cpu/$a/online" || ok=0; }
  done <"$DEEP"
  rm -f "$DEEP"
  echo "undeep: EMC + idle states $(ms "$t0" "$t1") ms, cores $(ms "$t1" "$EPOCHREALTIME") ms"
  (( ok ))
}

PV_SINCE=/run/spectrum-clocks-pv-inactive-since
guard() {
  if [[ $(mode) == full ]]; then
    if [[ -f $FLAG ]] || unlocked; then logger -t spectrum-clocks "mode full: locking the clocks"; full; fi
    return 0
  fi
  if [[ $(mode) == shallow && -f $DEEP ]]; then logger -t spectrum-clocks "mode shallow: leaving deep idle"; throttle; fi
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
    if [[ ! -f $DEEP && $(mode) == auto ]] && (( DEEP_AFTER_S > 0 && now - since >= DEEP_AFTER_S )); then
      logger -t spectrum-clocks "PhotonVision not running ($state) for $DEEP_AFTER_S s: deep idle"
      deep
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
  if [[ -f $DEEP ]]; then echo "state: deep"; elif [[ -f $FLAG ]]; then echo "state: throttled"; else echo "state: full"; fi
  [[ -r $EMC/cur_freq ]] && echo "emc: $(( $(cat "$EMC/cur_freq") / 1000000 )) MHz (min $(( $(cat "$EMC/min_freq") / 1000000 )))"
  echo "cpus online: $(cat /sys/devices/system/cpu/online)"
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
  deep) deep ;;
  guard) guard ;;
  mode)
    [[ ${2:-} == auto || ${2:-} == full || ${2:-} == shallow ]] || { echo "usage: spectrum-clocks mode auto|shallow|full" >&2; exit 2; }
    echo "$2" >"$MODE_FILE"
    [[ $2 == full ]] && full
    [[ $2 == shallow && -f $DEEP ]] && throttle
    echo "mode: $2" ;;
  status) status ;;
  *) echo "usage: spectrum-clocks throttle|deep|full|guard|mode auto|shallow|full|status" >&2; exit 2 ;;
esac
