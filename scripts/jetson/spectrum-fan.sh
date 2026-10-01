#!/usr/bin/env bash
# SpectrumJetson: the Jetson's cooling, chosen on Settings > Robot state (photonvision-71) or by
# 09-robot-tuning.sh FAN=... . Installed as /usr/local/bin/spectrum-fan; PhotonVision runs it as root.
#
#   spectrum-fan quiet   the stock fan on NVIDIA's quiet profile (nvfancontrol): it speeds up as
#                        the chip warms (~2000 rpm at 56 C). For the stock heatsink and fan.
#   spectrum-fan full    the fan at full speed (jetson_clocks --fan, ~5,800 rpm): coolest, loudest.
#   spectrum-fan off     no fan (a heatsink plate, as on our robot): the fan stays stopped, and
#                        spectrum-fan-guard caps every camera at 60 fps from 95 C until under 88 C.
#   spectrum-fan boot    applies the saved mode (spectrum-fan.service, at boot)
#   spectrum-fan status  prints the saved mode ("unknown" without root: the file is root-only)
#
# quiet, full and off apply now and are saved for the next boot. The choice is kept on the settings
# partition (/data/settings/spectrum-fan-mode), so it survives the read-only system (ro-root.sh), and
# not in a settings snapshot: it's this robot's hardware, not a vision setting. Without the data
# partitions it's /etc/spectrum-fan-mode.
set -uo pipefail
if mountpoint -q /data/settings; then STATE=/data/settings/spectrum-fan-mode
elif [[ -e /data && ! -x /data ]]; then STATE=""   # /data is root-only: can't tell without root
else STATE=/etc/spectrum-fan-mode; fi
GUARD=spectrum-fan-guard.service

# The saved mode; quiet when none was saved; "unknown" when it can't be read (/data/settings is
# root-only: status without sudo).
saved() {
  local m
  [[ -n $STATE ]] || { echo unknown; return; }
  if ! m=$(cat "$STATE" 2>/dev/null) && [[ ! -x $(dirname "$STATE") ]]; then echo unknown; return; fi
  [[ $m == quiet || $m == full || $m == off ]] && echo "$m" || echo quiet
}

# The fanless guard takes the fan away from the kernel's thermal zones (user_space policy); the
# fan modes give it back.
give_fan_back() {
  rm -f /run/spectrum-thermal-limit   # the guard's frame-rate cap, if it was on
  for z in /sys/class/thermal/thermal_zone*; do
    grep -qx active "$z"/trip_point_*_type 2>/dev/null || continue
    [[ $(cat "$z/policy") == user_space ]] && echo step_wise > "$z/policy"
  done
  return 0
}

apply() {
  case $1 in
    off)
      [[ -x /usr/local/bin/spectrum-fan-guard ]] || { echo "the fanless guard isn't installed (09-robot-tuning.sh)"; return 1; }
      # The guard's unit Conflicts= nvfancontrol, so this stops NVIDIA's fan control too.
      systemctl start "$GUARD" || { echo "couldn't start $GUARD"; return 1; }
      ;;
    full)
      systemctl stop "$GUARD" 2>/dev/null
      give_fan_back
      jetson_clocks --fan >/dev/null || { echo "jetson_clocks --fan failed"; return 1; }
      ;;
    quiet)
      systemctl stop "$GUARD" 2>/dev/null
      give_fan_back
      systemctl start nvfancontrol || { echo "couldn't start nvfancontrol"; return 1; }
      ;;
  esac
}

case ${1:-} in
  quiet|full|off|boot) [[ -n $STATE ]] || { echo "run it as root (sudo spectrum-fan $1)" >&2; exit 1; } ;;&
  quiet|full|off)
    apply "$1" || exit 1
    if [[ $(saved) != "$1" || ! -f $STATE ]]; then
      echo "$1" > "$STATE.new" && sync "$STATE.new" && mv "$STATE.new" "$STATE" && sync "$(dirname "$STATE")"
    fi
    echo "cooling: $1"
    ;;
  boot) apply "$(saved)" && echo "cooling: $(saved) (saved)" ;;
  status) saved ;;
  *) sed -n '2,18p' "$0" >&2; exit 2 ;;
esac
