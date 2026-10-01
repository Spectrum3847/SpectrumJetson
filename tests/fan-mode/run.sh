#!/usr/bin/env bash
# The cooling setting (photonvision-71, Settings > Robot state > Cooling). Run ON THE JETSON. Through
# PhotonVision's /api/robotState, as the Settings page does, it switches to each mode in turn and
# checks what's running, the fan's speed (its tachometer) and the saved choice, then puts the mode
# it found back. About a minute; the fan spins up and stops again.
#   full    jetson_clocks --fan: the fan at full speed, NVIDIA's fan control and the guard stopped
#   quiet   NVIDIA's fan control (nvfancontrol) running, the guard stopped
#   off     the fanless guard running (fan at 0, thermal cap armed), nvfancontrol stopped
# Deadline: 3 min.
set -uo pipefail
if [[ -z ${FAN_MODE_UNDER_TIMEOUT:-} ]]; then
  rc=0; FAN_MODE_UNDER_TIMEOUT=1 timeout --kill-after=15 180 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the cooling test didn't finish in 3 min" >&2
  exit "$rc"
fi
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
# POST a mode the way the Settings page does; prints the HTTP status.
set_mode() { python3 - "$1" <<'PY'
import json, sys, urllib.error, urllib.request
req = urllib.request.Request("http://localhost:5800/api/robotState", data=json.dumps({"fanMode": sys.argv[1]}).encode(),
                             headers={"Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(req, timeout=30).status)
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
PY
}
api() { python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=3)).get("'"$1"'"))' 2>/dev/null; }
active() { systemctl is-active --quiet "$1" && echo yes || echo no; }
pwm() { cat /sys/devices/platform/pwm-fan*/hwmon/hwmon*/pwm1 2>/dev/null | head -1; }
# The tachometer (the pwm_tach hwmon, as health-check reads it): the highest of 3 reads.
rpm() {
  local t r best=0
  t=$(grep -lx pwm_tach /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1)
  [[ -n $t ]] || { echo 0; return; }
  for _ in 1 2 3; do r=$(cat "${t%/name}/rpm" 2>/dev/null || echo 0); ((r > best)) && best=$r; sleep 0.3; done
  echo "$best"
}

[[ $(api fanAvailable) == True ]] || { echo "No cooling setting (spectrum-fan isn't installed: 09-robot-tuning.sh, or an older jar)"; exit 1; }
start=$(api fanMode)
echo "== Cooling now: $start"
trap 'set_mode "$start" >/dev/null; echo "Put back: $(api fanMode)"' EXIT

echo "== full"
check "the API accepted it" "[[ \$(set_mode full) == 200 ]]"
sleep 8
# The setting's job is the command (pwm); whether the fan turns is hardware: health-check.sh fails a
# fan that doesn't (ours, under its plate, reads 0 rpm).
check "fan told full speed: pwm $(pwm) ($(rpm) rpm)" "(( \$(pwm) >= 250 ))"
check "guard and NVIDIA's fan control stopped" "[[ \$(active spectrum-fan-guard) == no && \$(active nvfancontrol) == no ]]"
check "saved and reported as full" "[[ \$(api fanMode) == full && \$(sudo -n spectrum-fan status) == full ]]"

echo "== quiet"
check "the API accepted it" "[[ \$(set_mode quiet) == 200 ]]"
sleep 3
check "NVIDIA's fan control running, guard stopped" "[[ \$(active nvfancontrol) == yes && \$(active spectrum-fan-guard) == no ]]"
echo "    pwm $(pwm) on NVIDIA's quiet profile (it holds the thermal zones itself while it runs)"
check "saved and reported as quiet" "[[ \$(api fanMode) == quiet && \$(sudo -n spectrum-fan status) == quiet ]]"

echo "== off"
check "the API accepted it" "[[ \$(set_mode off) == 200 ]]"
sleep 10
check "fanless guard running, NVIDIA's fan control stopped" "[[ \$(active spectrum-fan-guard) == yes && \$(active nvfancontrol) == no ]]"
check "fan told to stop: pwm $(pwm) (it spins down: $(rpm) rpm)" "(( \$(pwm) == 0 ))"
check "saved and reported as off" "[[ \$(api fanMode) == off && \$(sudo -n spectrum-fan status) == off ]]"

echo "== a bad mode"
check "refused, saying why" "[[ \$(set_mode turbo) == 400* ]]"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
