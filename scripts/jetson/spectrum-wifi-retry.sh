#!/usr/bin/env bash
# SpectrumJetson: bring the Wi-Fi back when NetworkManager has given up on it. Installed as
# /usr/local/bin/spectrum-wifi-retry by 09-robot-tuning.sh, run every 2 minutes by
# spectrum-wifi-retry.timer.
#
# Why: on a headless Jetson, an access point that rejects it a few times (2026-10-01: a channel
# switch, then "ASSOC-REJECT" twice) ends with NetworkManager failing the connection as "no
# secrets". With nobody to ask for a password it never tries again, and the Jetson was off the
# network for the rest of that boot (2 h 20 min). "nmcli device connect" is a user's request, which
# NetworkManager acts on even then.
#
# Only while the Wi-Fi radio is on (Settings > Networking's switch, photonvision-05: off at events)
# and the device is disconnected: not while it's connecting, connected or switched off.
set -uo pipefail
[[ $(nmcli -t radio wifi 2>/dev/null) == enabled ]] || exit 0
while IFS=: read -r dev type state; do
  [[ $type == wifi && $state == disconnected ]] || continue
  echo "$dev: disconnected with the radio on; asking NetworkManager to connect it"
  if nmcli -w 45 device connect "$dev" >/dev/null 2>&1; then
    echo "$dev: connected ($(nmcli -t -g GENERAL.CONNECTION device show "$dev" 2>/dev/null))"
  else
    echo "$dev: no connection yet; trying again in 2 minutes"
  fi
done < <(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null)
exit 0
