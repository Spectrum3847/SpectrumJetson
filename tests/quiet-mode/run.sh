#!/usr/bin/env bash
# Quiet mode test (photonvision-56). Run ON THE JETSON, off the robot. A fake robot (tests/fake-robot)
# plays a match: auto 5 s, teleop 5 s, disabled 20 s, then enabled 10 s, all with the field
# attached. Checks:
#   - quiet mode starts 20 s after the match ends (photonvision-83), not before and within 5 s more,
#   - the scratch partition is then mounted read-only, and Rewind isn't recording,
#   - the cameras keep running while quiet,
#   - a recording someone asks for (Record now, as field calibration does) ends quiet mode and
#     records; when it stops, quiet mode comes back,
#   - enabling makes the scratch partition writable again, and how long that took
#     (from the enable to the remount, as the fake robot and this script see it).
# Deadline: 3 min.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LOG=$(mktemp)
PHASES=/tmp/fake-robot.log   # tests/fake-robot/run.sh writes FakeRobot's phase lines here
rm -f "$PHASES"
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
state() { python3 - <<'PY' 2>/dev/null
import json, urllib.request
s = json.load(urllib.request.urlopen("http://localhost:5800/api/robotState", timeout=2))
# The reason last, "-" when empty: an empty field would shift the ones after it.
print(s.get("quietNow"), s.get("enabled"), s.get("fmsAttached"), s.get("quietLastLeaveMs"), s.get("quietReason", "").replace(" ", "_") or "-")
PY
}
ro() { [[ ,$(findmnt -n -o OPTIONS /data/scratch), == *,ro,* ]]; }
ms() { date +%s%3N; }
# GET (no body) or POST to Rewind's API; prints the reply.
rewind() { python3 -c '
import sys, urllib.request
body = sys.argv[1]
req = urllib.request.Request("http://localhost:5800/api/rewind", data=body.encode() if body else None,
                             headers={"Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=2).read().decode())' "${1:-}" 2>/dev/null; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
t_rec_on="" t_rec_quiet_off="" t_rec_seen="" t_rec_off="" t_requiet=""

findmnt -n /data/scratch >/dev/null || { echo "No scratch partition: run 10-data-partition.sh first"; exit 1; }
[[ -x /usr/local/bin/spectrum-quiet ]] || { echo "No /usr/local/bin/spectrum-quiet: run 10-data-partition.sh"; exit 1; }
[[ -n $(state) ]] || { echo "PhotonVision's /api/robotState isn't answering"; exit 1; }
ro && { echo "The scratch partition is already read-only: leave quiet mode first"; exit 1; }

echo "== Fake match: fms-auto 5 s, fms-enabled 5 s, fms-disabled 60 s (a bench recording in it), fms-enabled 10 s"
timeout -k 10 150 "$ROOT/tests/fake-robot/run.sh" fms-auto:5 fms-enabled:5 fms-disabled:60 fms-enabled:10 > "$LOG" 2>&1 &
robot=$!

# Watch 20 times a second until the fake robot finishes.
t_disabled="" t_quiet="" t_ro="" t_enabled="" t_rw="" quiet_reason="" fps_while_quiet=""
end=$((SECONDS + 180))
while kill -0 $robot 2>/dev/null && ((SECONDS < end)); do
  now=$(ms)
  # FakeRobot prints "phase <n> <state> <unix ms>" to the fake robot's own log.
  if [[ -z $t_disabled ]] && grep -q "phase 2 fms-disabled" "$PHASES" 2>/dev/null; then t_disabled=$(grep "phase 2 fms-disabled" "$PHASES" | awk '{print $4}'); fi
  if [[ -z $t_enabled ]] && grep -q "phase 3 fms-enabled" "$PHASES" 2>/dev/null; then t_enabled=$(grep "phase 3 fms-enabled" "$PHASES" | awk '{print $4}'); fi
  read -r q en fms lastleave reason <<<"$(state)"
  if [[ -n $t_disabled && -z $t_quiet && $q == True ]]; then t_quiet=$now; quiet_reason=$reason; fi
  if [[ -n $t_disabled && -z $t_ro && -z $t_enabled ]] && ro; then t_ro=$now; fi
  if [[ -n $t_ro && -z $t_enabled && -z $fps_while_quiet ]] && (( now - t_ro > 3000 )); then
    fps_while_quiet=$(python3 -c "import json,urllib.request;print(len(json.load(urllib.request.urlopen('http://localhost:5800/api/robotState',timeout=2))))" 2>/dev/null)
    rewind_rec=$(ls /run/spectrum-quiet 2>/dev/null && echo quiet-file)
    writers=$(sudo fuser -vm /data/scratch 2>&1 | awk 'NR>1' | grep -c " F" || true)
  fi
  # 6 s after going read-only: ask for a bench recording (as field calibration does), 4 s later stop.
  if [[ -n $t_ro && -z $t_rec_on && -z $t_enabled ]] && (( now - t_ro > 6000 )); then
    rewind '{"manual": true}' >/dev/null; t_rec_on=$now
  fi
  if [[ -n $t_rec_on && -z $t_rec_quiet_off && $q == False ]] && ! ro; then t_rec_quiet_off=$now; fi
  if [[ -n $t_rec_quiet_off && -z $t_rec_seen && $(rewind | field recording) == True ]]; then t_rec_seen=$now; fi
  if [[ -n $t_rec_on && -z $t_rec_off ]] && (( now - t_rec_on > 4000 )); then rewind '{"manual": false}' >/dev/null; t_rec_off=$now; fi
  if [[ -n $t_rec_off && -z $t_requiet && -z $t_enabled && $q == True ]]; then t_requiet=$now; fi
  if [[ -n $t_enabled && -z $t_rw ]] && ! ro; then t_rw=$now; fi
  sleep 0.05
done
wait $robot 2>/dev/null

echo "== Results"
check "quiet mode started after the match ended ($( [[ -n $t_quiet ]] && echo "$(( t_quiet - t_disabled )) ms after disable, reason: ${quiet_reason//_/ }" || echo never))" \
      "[[ -n \$t_quiet ]] && (( t_quiet - t_disabled >= 19000 && t_quiet - t_disabled < 25000 ))"
check "the reason was the match ending" "[[ \$quiet_reason == *match* ]]"
check "the scratch partition went read-only" "[[ -n \$t_ro ]]"
check "nothing was writing to it while quiet" "[[ \${writers:-0} == 0 ]]"
check "PhotonVision kept answering while quiet" "[[ -n \$fps_while_quiet ]]"
check "a requested recording ended quiet mode ($( [[ -n $t_rec_quiet_off ]] && echo "$(( t_rec_quiet_off - t_rec_on )) ms after Record now" || echo never))" \
      "[[ -n \$t_rec_quiet_off ]] && (( t_rec_quiet_off - t_rec_on < 2000 ))"
check "...and Rewind recorded" "[[ -n \$t_rec_seen ]]"
check "quiet mode came back after the recording stopped" "[[ -n \$t_requiet ]]"
check "enabling made it writable again ($( [[ -n $t_rw ]] && echo "$(( t_rw - t_enabled )) ms after enable" || echo never))" \
      "[[ -n \$t_rw ]] && (( t_rw - t_enabled < 2000 ))"
read -r q en fms lastleave reason <<<"$(state)"
echo "  PhotonVision's own timing of the switch back: ${lastleave} ms"
check "quiet mode off at the end" "[[ \$q == False ]] && ! ro"
grep -i -E "quiet" /opt/photonvision/photonvision_config/logs/*.log 2>/dev/null | tail -4 | sed 's/^/    log: /'
rm -f "$LOG"
echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
