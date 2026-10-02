# shellcheck shell=bash
# Shared by the bench tests that stand in for the robot. Source it ON THE JETSON:
#   source "$ROOT/tests/lib/bench.sh"
#
# robot_address_add / robot_address_del: PhotonVision looks for team 8515's robot at 10.85.15.2
# (among other addresses). For a test, the loopback interface answers there, so a NetworkTables
# server on this Jetson is "the robot", with no PhotonVision setting changed. add refuses (exit 1)
# when PhotonVision is connected to a robot already; del removes the address only if add put it
# there. Call del from the test's EXIT trap.
#
# ntp_pause / ntp_restore: PhotonVision only takes the robot's date while the Jetson hasn't got
# internet time this boot (RobotClockSync, patch 08). pause turns NTP off and removes timesyncd's
# "synchronized" flag. restore puts the date back from the monotonic clock (right whether or not
# it was moved), turns NTP back on if it was, and gives timesyncd's clock file today's date (the
# next boot starts from it). Call restore from the EXIT trap.
#
# clock_rate_reset: the kernel's clock back to its own rate, with no correction left to apply
# (adjtimex: frequency 0, offset 0). Turn NTP off first, or timesyncd sets them again. After the
# clock tests, timesyncd on internet time slewed the clock at up to 500 ppm (2026-10-01), and
# PhotonVision's time sync lags that: latency read ~0.5 ms higher every second. At an event there's
# no internet time, and the rate is the kernel's own from boot.

BENCH_ROBOT_IP=10.85.15.2
bench_added_address=0

robot_address_add() {
  local connected
  connected=$(python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=3))["robotConnected"])' 2>/dev/null)
  [[ $connected == False ]] || { echo "PhotonVision is connected to a robot already (or isn't answering); not running." >&2; exit 1; }
  if ! ip -4 addr show dev lo | grep -q " $BENCH_ROBOT_IP/"; then
    sudo -n ip addr add "$BENCH_ROBOT_IP/32" dev lo || { echo "Couldn't add $BENCH_ROBOT_IP to lo (sudo)" >&2; exit 1; }
    bench_added_address=1
  fi
}

robot_address_del() {
  trap '' PIPE  # an SSH drop closes our output; the clean-up must still finish
  if [[ $bench_added_address == 1 ]]; then
    sudo -n ip addr del "$BENCH_ROBOT_IP/32" dev lo 2>/dev/null
    bench_added_address=0
  fi
}

clock_rate_reset() {
  sudo -n python3 - <<'PY'
import ctypes, ctypes.util, sys
class Timex(ctypes.Structure):  # struct timex: modes, offset, freq, then fields left unset
    _fields_ = [("modes", ctypes.c_uint), ("offset", ctypes.c_long), ("freq", ctypes.c_long),
                ("rest", ctypes.c_byte * 192)]
ADJ_OFFSET, ADJ_FREQUENCY = 0x0001, 0x0002
t = Timex(modes=ADJ_OFFSET | ADJ_FREQUENCY)
sys.exit(0 if ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True).adjtimex(ctypes.byref(t)) >= 0 else 1)
PY
}

# The date minus the monotonic clock, in seconds: it changes only when the date is set.
bench_skew() { python3 -c 'import time; print(f"{time.time() - time.monotonic():.3f}")'; }

ntp_pause() {
  bench_skew0=$(bench_skew)
  bench_ntp=$(timedatectl show -p NTP --value)
  if [[ $bench_ntp == yes ]]; then
    sudo -n timedatectl set-ntp false || { echo "Couldn't pause internet time (sudo)" >&2; exit 1; }
  fi
  # Left by timesyncd's last sync this boot; while it's there PhotonVision won't set the date.
  sudo -n rm -f /run/systemd/timesync/synchronized
}

ntp_restore() {
  [[ -n ${bench_skew0:-} ]] || return 0
  # An SSH drop closes our output, and the next echo's SIGPIPE would end this half way: the date
  # put back, NTP still off.
  trap '' PIPE
  if python3 -c 'import sys,time; sys.exit(abs(time.time() - time.monotonic() - float(sys.argv[1])) < 1)' "$bench_skew0"; then
    sudo -n date -s "@$(python3 -c 'import sys,time; print(f"{time.monotonic() + float(sys.argv[1]):.3f}")' "$bench_skew0")" >/dev/null
    echo "Date put back: $(date -u +%FT%TZ)"
  fi
  # PhotonVision gave timesyncd's clock file the date it set. Fix it before timesyncd starts again:
  # it moves the clock forward to that file's date when it starts (and at the next boot), which put
  # the jump straight back on a Jetson without internet time to correct it.
  sudo -n touch /var/lib/systemd/timesync/clock
  if [[ $bench_ntp == yes ]]; then
    sudo -n timedatectl set-ntp true
    for _ in $(seq 30); do [[ -e /run/systemd/timesync/synchronized ]] && break; sleep 1; done
    [[ -e /run/systemd/timesync/synchronized ]] && echo "Internet time back on (synced)" || echo "Internet time back on (not synced yet: no internet?)"
  fi
  bench_skew0=""
}
