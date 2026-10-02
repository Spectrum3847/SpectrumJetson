#!/usr/bin/env bash
# SystemCore rehearsal: the Jetson against a real WPILib 2027 alpha-6 robot program, without a
# SystemCore. Run ON THE LAPTOP (robot-vision builds and simulates here: see robot-vision/README,
# "Simulating on Ubuntu 22.04"), with the Jetson off the robot:
#
#   run.sh [JETSON_IP]       over Wi-Fi (default 10.100.0.194) or USB (192.168.55.1)
#   run.sh --wired DEV       over an Ethernet cable from this laptop's DEV (a USB Ethernet adapter,
#                            say) to the Jetson's Ethernet port: the way the robot connects. Judges
#                            latency, loss and time sync too, which Wi-Fi can't.
#   run.sh --tags ...        with fake cameras playing a synthetic session with tags, so the Jetson's
#                            per-tag quality reaches the robot side too. (Not yet SpectrumVision's
#                            pose path: 0 candidates on 2026-10-01, likely because the fake cameras
#                            have no lens calibration, so PhotonVision sends no 3D poses.)
#                            (scripts/jetson/fake-cameras.sh: PhotonVision restarts on throwaway
#                            settings; the real cameras and settings are back afterwards.)
#   run.sh --cleanup [JETSON_IP]   remove the redirect, if a run was killed
#   REHEARSAL_PERIOD_MS=10 run.sh ...   the robot loop at 10 ms (default 20): the latency limit
#                            follows it (half a period of it is the wait for robot code's loop)
#
# The robot program (robot-vision/wpilib2027/src/rehearsal, Rehearsal.java) plays a match with
# the simulated Driver Station. It checks what PhotonVision decodes from the real 2027 control word
# and match data, that every camera's results reach PhotonLib 2027 alpha-2, time sync, latency and
# bandwidth. See Rehearsal.java.
#
# How the Jetson reaches this laptop. PhotonVision looks for team 8515's robot at 10.85.15.2.
#   - Wired: the laptop takes 10.85.15.2 on DEV for the test (sudo ip addr add, removed on exit).
#     The Jetson is 10.85.15.15 there.
#   - Wi-Fi or USB: two rules on the Jetson send 10.85.15.2 to this laptop instead. The iptables
#     chain SPECTRUM_REHEARSAL (nat OUTPUT) changes the destination. SPECTRUM_REHEARSAL_SRC (nat
#     POSTROUTING) gives those packets the Jetson's own address on the way out: the Jetson routes
#     10.85.15.2 through its Ethernet port, so without it they'd leave as 10.85.15.15, and the
#     laptop's replies would go nowhere. Removed on exit, never saved (a restart removes them too),
#     and health-check.sh fails while they're there.
# PhotonVision's settings don't change.
#
# The match makes one Rewind recording (named ..._Q42_...) on the Jetson, as a real match would.
# Hard deadline: the phases plus 5 minutes (plus 4 with --tags).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cleanup_only=0 tags=0 wired=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --cleanup) cleanup_only=1; shift ;;
    --tags) tags=1; shift ;;
    --wired) wired=${2:?--wired needs the laptop interface, e.g. enx9cbf0d0041fa}; shift 2 ;;
    *) break ;;
  esac
done
ROBOT_IP=10.85.15.2
JETSON=${1:-$([[ -n $wired ]] && echo 10.85.15.15 || echo 10.100.0.194)}
PHASES=${REHEARSAL_PHASES:-disabled:20,teleop:20,fms-auto:15,fms-teleop:15,fms-disabled:10,teleop:8}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
SSH=(ssh -i "$KEY" -o ConnectTimeout=6 -o BatchMode=yes "${JETSON_USER:-spectrum3847}@$JETSON")

if [[ -z ${REHEARSAL_UNDER_TIMEOUT:-} && $cleanup_only == 0 ]]; then
  total=$(python3 -c 'import sys; print(int(sum(float(p.split(":")[1]) for p in sys.argv[1].split(","))) + 300 + 240 * int(sys.argv[2]))' "$PHASES" "$tags")
  rc=0
  args=(); [[ $tags == 1 ]] && args+=(--tags); [[ -n $wired ]] && args+=(--wired "$wired")
  REHEARSAL_UNDER_TIMEOUT=1 timeout --kill-after=15 "$total" "$0" "${args[@]}" "$JETSON" || rc=$?
  if [[ $rc == 124 || $rc == 137 ]]; then
    echo "TIMEOUT: the rehearsal didn't finish in $total s" >&2
    # The killed run's own cleanup may not have run.
    if [[ -n $wired ]]; then sudo ip addr del "$ROBOT_IP/24" dev "$wired" 2>/dev/null; else "$0" --cleanup "$JETSON"; fi
    [[ $tags == 1 ]] && "${SSH[@]}" '~/SpectrumJetson/scripts/jetson/fake-cameras.sh stop' >/dev/null 2>&1
  fi
  exit "$rc"
fi

unredirect() {
  "${SSH[@]}" 'for c in OUTPUT:SPECTRUM_REHEARSAL POSTROUTING:SPECTRUM_REHEARSAL_SRC; do
      while sudo -n iptables -t nat -D ${c%%:*} -j ${c#*:} 2>/dev/null; do :; done
      sudo -n iptables -t nat -F ${c#*:} 2>/dev/null; sudo -n iptables -t nat -X ${c#*:} 2>/dev/null
    done
    if sudo -n iptables -t nat -S 2>/dev/null | grep -q SPECTRUM_REHEARSAL; then echo "  WARNING: the redirect is still on the Jetson"; exit 1; fi'
}
if [[ $cleanup_only == 1 ]]; then
  unredirect && echo "Jetson: robot address redirect removed (or wasn't there)"
  exit
fi

redirected=0 addr_added=0 fakes=0 ntp_paused=0
cleanup() {
  [[ $redirected == 1 ]] && unredirect
  if [[ $ntp_paused == 1 ]]; then
    "${SSH[@]}" 'sudo -n timedatectl set-ntp true' || echo "  WARNING: NTP is still off on the Jetson (sudo timedatectl set-ntp true)"
  fi
  if [[ $fakes == 1 ]]; then
    echo "Putting the real cameras back"
    "${SSH[@]}" '~/SpectrumJetson/scripts/jetson/fake-cameras.sh stop' >/dev/null || echo "  WARNING: fake-cameras.sh stop failed: run it on the Jetson"
  fi
  [[ $addr_added == 1 ]] && sudo ip addr del "$ROBOT_IP/24" dev "$wired"
}
trap cleanup EXIT

if [[ -n $wired ]]; then
  ip link show "$wired" >/dev/null 2>&1 || { echo "No interface $wired on this laptop" >&2; exit 2; }
  if ! ip -4 addr show dev "$wired" | grep -q " $ROBOT_IP/"; then
    sudo ip link set "$wired" up && sudo ip addr add "$ROBOT_IP/24" dev "$wired" || { echo "Couldn't give $wired the robot's address" >&2; exit 2; }
    addr_added=1
  fi
  for _ in $(seq 1 15); do timeout 2 ping -c1 -W1 "$JETSON" >/dev/null 2>&1 && break; sleep 1; done
  timeout 2 ping -c1 -W1 "$JETSON" >/dev/null 2>&1 || { echo "The Jetson ($JETSON) doesn't answer on $wired: is the cable in its Ethernet port?" >&2; exit 2; }
  link=wired
else
  dev=$(ip -4 route get "$JETSON" | grep -oP 'dev \K\S+')
  link=$([[ -d /sys/class/net/$dev/wireless ]] && echo wifi || echo usb)
fi

# Off the robot only: refuse if PhotonVision is connected to a robot already.
state=$("${SSH[@]}" 'curl -s -m 3 localhost:5800/api/robotState') || { echo "Can't reach the Jetson at $JETSON" >&2; exit 2; }
grep -q '"robotConnected":false' <<<"$state" || { echo "PhotonVision is connected to a robot already; not running." >&2; exit 2; }
LAPTOP=$(ip -4 route get "$JETSON" | grep -oP 'src \K\S+')
[[ -n $LAPTOP ]] || { echo "No route to $JETSON" >&2; exit 2; }

# As at an event: no internet time on the Jetson during the run, and the clock at its own rate
# (tests/lib/bench.sh, clock_rate_reset: timesyncd's slewing made the latency climb).
if [[ $("${SSH[@]}" 'timedatectl show -p NTP --value') == yes ]]; then
  ntp_paused=1
  "${SSH[@]}" 'sudo -n timedatectl set-ntp false && source ~/SpectrumJetson/tests/lib/bench.sh && clock_rate_reset' \
    || { echo "Couldn't pause internet time on the Jetson (sudo)" >&2; exit 2; }
  echo "Internet time paused on the Jetson for the run"
fi

if [[ $tags == 1 ]]; then
  echo "Starting fake cameras with tags on the Jetson (PhotonVision restarts)"
  fakes=1
  "${SSH[@]}" '~/SpectrumJetson/scripts/jetson/fake-cameras.sh start' 2>&1 | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} == 0 ]] || { echo "fake-cameras.sh start failed" >&2; exit 2; }
fi

if [[ $link == wired ]]; then
  echo "Laptop is the robot ($ROBOT_IP on $wired); the Jetson is $JETSON, over Ethernet"
else
  echo "Laptop $LAPTOP plays the robot ($ROBOT_IP) for the Jetson at $JETSON, over $link"
  redirected=1
  "${SSH[@]}" "set -e; ipt='sudo -n iptables -t nat'
    \$ipt -N SPECTRUM_REHEARSAL 2>/dev/null || \$ipt -F SPECTRUM_REHEARSAL
    \$ipt -A SPECTRUM_REHEARSAL -d $ROBOT_IP -j DNAT --to-destination $LAPTOP
    \$ipt -C OUTPUT -j SPECTRUM_REHEARSAL 2>/dev/null || \$ipt -I OUTPUT -j SPECTRUM_REHEARSAL
    \$ipt -N SPECTRUM_REHEARSAL_SRC 2>/dev/null || \$ipt -F SPECTRUM_REHEARSAL_SRC
    \$ipt -A SPECTRUM_REHEARSAL_SRC -d $LAPTOP -j MASQUERADE
    \$ipt -C POSTROUTING -j SPECTRUM_REHEARSAL_SRC 2>/dev/null || \$ipt -I POSTROUTING -j SPECTRUM_REHEARSAL_SRC" \
    || { echo "Couldn't set up the redirect on the Jetson" >&2; exit 2; }
fi

cd "$ROOT/robot-vision" || exit 2
paths=()
for j in "${JAVA17_HOME:-}" "${JAVA25_HOME:-}" "$HOME/wpilib/2026/jdk" "$HOME/wpilib/2027/jdk" "$HOME/build/tools/jdk17"; do
  [[ -n $j && -x $j/bin/java ]] && paths+=("$j")
done
export JAVA_HOME=${JAVA_HOME:-${paths[0]}}
out=$(mktemp)
./gradlew -q --console=plain -Dorg.gradle.java.installations.paths="$(IFS=,; echo "${paths[*]}")" \
  -Dorg.gradle.java.installations.auto-download=false \
  -Prehearsal.jetson="$JETSON" -Prehearsal.link="$link" -Prehearsal.phases="$PHASES" \
  -Prehearsal.periodMs="${REHEARSAL_PERIOD_MS:-20}" :wpilib2027:rehearsal 2>&1 \
  | grep --line-buffered -v -E "^NT: |sim-natives/.*: changed " | tee "$out"
rc=${PIPESTATUS[0]}
# The robot program's own verdict: WPILib exits 0 even when robot code throws.
grep -q "^rehearsal: PASS" "$out" || rc=1
rm -f "$out"

# The robot program has exited: PhotonVision should notice the robot is gone.
gone=0
for _ in $(seq 1 20); do
  sleep 1
  "${SSH[@]}" 'curl -s -m 3 localhost:5800/api/robotState' | grep -q '"robotConnected":false' && { gone=1; break; }
done
[[ $gone == 1 ]] && echo "PASS  PhotonVision saw the robot leave" || { echo "FAIL  PhotonVision still thinks the robot is connected 20 s after it exited"; rc=1; }
exit "$rc"
