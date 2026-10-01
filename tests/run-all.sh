#!/usr/bin/env bash
# Every test that runs unattended on the bench: no hands, no reboot, no robot. Run ON THE LAPTOP,
# with the Jetson off the robot and reachable (JETSON, default 10.100.0.194 on Wi-Fi; 192.168.55.1
# on the USB-C cable). About 30 minutes.
#
#   tests/run-all.sh                 everything
#   tests/run-all.sh quiet ui        only tests whose name contains one of these words
#   tests/run-all.sh --list          the tests, without running them
#   NO_SYNC=1 tests/run-all.sh       don't copy this checkout to the Jetson first
#
# First it copies this checkout to the Jetson (as setup-jetson.sh does) so the Jetson-side tests
# are this version's. Then each test runs in turn with its own deadline, and its output goes to
# $LOGS/NAME.log. Prints a table at the end and exits 1 if any test failed or timed out.
# Not here, because they need someone at the bench or a reboot: power-cut, camera-replug,
# usb-hub-reset, storage-fallback, ro-root, thermal, detector-ab (a tag held in view), flicker-check
# (the event's lights). The health check runs last; it's shown but not counted (an unplugged camera
# FAILs it on the bench).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/config.env"
JETSON=${JETSON:-10.100.0.194}
U=$JETSON_USER
SSH=(ssh -i "$KEY" -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 "$U@$JETSON")
LOGS=${LOGS:-/tmp/spectrum-tests-$(date +%Y%m%d-%H%M%S)}

# NAME|WHERE|DEADLINE_S|COMMAND. WHERE: laptop, or jetson (run in ~/SpectrumJetson over SSH).
TESTS=(
  "robot-vision|laptop|900|robot-vision/build.sh"
  "fieldcal-solver|laptop|600|PY=\$HOME/build/fieldcal-venv/bin/python; [[ -x \$PY ]] || PY=python3; \$PY tools/fieldcal/tests/test_observations.py"
  "fieldcal-images|laptop|900|tools/fieldcal/tests/test_images.sh"
  "detector-regression|jetson|1800|tests/regression/run.sh"
  "detector-frame-sizes|jetson|300|tests/detector-frame-sizes/run.sh"
  "detector-handles|jetson|300|tests/gpudetector-handles/run.sh"
  "far-search|jetson|900|tests/far-search/replay.sh"
  "jpeg-hw|jetson|900|tests/jpeg-hw/run.sh"
  "quiet-match|jetson|200|tests/quiet-mode/run.sh"
  "quiet-restart|jetson|260|tests/quiet-mode/restart.sh"
  "quiet-clock-jump|jetson|260|tests/quiet-mode/clock-jump.sh"
  "quiet-leave-fails|jetson|260|tests/quiet-mode/leave-fails.sh"
  "rewind-sessions|jetson|200|tests/rewind-sessions/run.sh"
  "robot-clock|jetson|200|tests/robot-clock/run.sh"
  "jetson-telemetry|jetson|120|tests/jetson-telemetry/run.sh"
  "tag-quality|jetson|600|tests/tag-quality/run.sh"
  "robot-vision-live|jetson|600|tests/robot-vision-live/run.sh"
  "ui|laptop|700|tests/ui/run.sh"
  "systemcore-rehearsal|laptop|700|tests/systemcore-rehearsal/run.sh $JETSON"
)

want=()
for a in "$@"; do
  case $a in
    --list) for t in "${TESTS[@]}"; do IFS='|' read -r n w d c <<<"$t"; printf "%-22s %-7s %5s s  %s\n" "$n" "$w" "$d" "$c"; done; exit 0 ;;
    -*) sed -n '2,19p' "$0"; exit 2 ;;
    *) want+=("$a") ;;
  esac
done
selected() { [[ ${#want[@]} -eq 0 ]] && return 0; local w; for w in "${want[@]}"; do [[ $1 == *"$w"* ]] && return 0; done; return 1; }

mkdir -p "$LOGS"
"${SSH[@]}" true 2>/dev/null || { echo "Can't reach the Jetson at $JETSON (set JETSON=...)" >&2; exit 2; }
state=$("${SSH[@]}" 'curl -s -m 3 localhost:5800/api/robotState')
grep -q '"robotConnected":false' <<<"$state" || { echo "PhotonVision is connected to a robot (or isn't answering); these are bench tests." >&2; exit 2; }

if [[ -z ${NO_SYNC:-} ]]; then
  commit=$(git -C "$ROOT" rev-parse HEAD)
  git -C "$ROOT" diff --quiet HEAD -- . ':!.claude' || commit=$commit-dirty
  echo "Copying this checkout ($commit) to the Jetson"
  timeout 600 rsync -a --delete -e "ssh -o BatchMode=yes -i $KEY" --exclude out/ --exclude node_modules/ \
    --exclude .claude/ --exclude logs/ --exclude 'tests/ui/.state/' --exclude .spectrum-commit \
    --exclude 'robot-vision/.gradle/' --exclude build/ --exclude __pycache__/ \
    "$ROOT/" "$U@$JETSON:SpectrumJetson/" || { echo "Copy failed" >&2; exit 2; }
  "${SSH[@]}" "echo $commit > ~/SpectrumJetson/.spectrum-commit"
fi
# robot-vision-live runs the library's 2026 build against PhotonLib 2026 on the Jetson.
if selected robot-vision-live; then
  jar=$ROOT/robot-vision/wpilib2026/build/libs/wpilib2026-0.1.0.jar
  photonlib=$(find "$HOME/.gradle/caches/modules-2" -name 'photonlib-java-v2026.*.jar' 2>/dev/null | sort | tail -1)
  if [[ -f $jar && -n $photonlib ]]; then
    scp -q -i "$KEY" "$jar" "$U@$JETSON:/tmp/spectrum-vision.jar" && scp -q -i "$KEY" "$photonlib" "$U@$JETSON:/tmp/photonlib.jar"
  fi
fi

results=() fails=0
for t in "${TESTS[@]}"; do
  IFS='|' read -r name where deadline cmd <<<"$t"
  selected "$name" || continue
  log=$LOGS/$name.log
  printf "%-22s " "$name"
  start=$SECONDS rc=0
  if [[ $where == laptop ]]; then
    (cd "$ROOT" && timeout --kill-after=20 "$deadline" bash -c "$cmd") >"$log" 2>&1 || rc=$?
  else
    timeout --kill-after=20 $((deadline + 30)) "${SSH[@]}" "cd ~/SpectrumJetson && timeout --kill-after=20 $deadline $cmd" >"$log" 2>&1 || rc=$?
  fi
  secs=$((SECONDS - start))
  case $rc in
    0) result=PASS ;;
    124|137) result=TIMEOUT; fails=$((fails + 1)) ;;
    *) result="FAIL ($rc)"; fails=$((fails + 1)) ;;
  esac
  printf "%-12s %4d s\n" "$result" "$secs"
  results+=("$(printf "%-22s %-12s %4d s  %s" "$name" "$result" "$secs" "$log")")
  # A test that died half way may have left fake cameras running, the scratch partition's device
  # read-only (leave-fails) or quiet mode on: the next test would refuse to run or measure the
  # wrong thing. (A fake robot's own run.sh removes its address when it ends.)
  if [[ $result != PASS ]]; then
    "${SSH[@]}" 'cd ~/SpectrumJetson; touch /tmp/fake-robot-stop; sleep 3
      scripts/jetson/fake-cameras.sh status 2>/dev/null | grep -q playing && scripts/jetson/fake-cameras.sh stop >/dev/null 2>&1
      sudo -n blockdev --setrw "$(findmnt -n -o SOURCE /data/scratch)" 2>/dev/null
      findmnt -n -o OPTIONS /data/scratch | tr , "\n" | grep -qx ro && timeout 90 tests/fake-robot/run.sh enabled:2 >/dev/null 2>&1' || true
  fi
done

echo "== health check (shown, not counted)"
"${SSH[@]}" '~/SpectrumJetson/scripts/jetson/health-check.sh' >"$LOGS/health-check.log" 2>&1
grep -E "^\s*(FAIL|WARN)|READY" "$LOGS/health-check.log" | sed 's/^/  /'
echo
echo "== Results (logs in $LOGS)"
printf '%s\n' "${results[@]}"
((fails == 0)) && echo "ALL PASSED" || { echo "$fails test(s) failed"; exit 1; }
