#!/usr/bin/env bash
# The robot's field map (photonvision-74). Run ON THE JETSON, off the robot.
#
# A fake robot (FieldMapRobot.java at 10.85.15.2 on lo, as tests/fake-robot) publishes
# /SpectrumVision/FieldMap/{Json,Hash,Name}. Checks, from what the Jetson reports under
# /photonvision/jetson/FieldMap:
#   - the AndyMark map sent with the welded map's hash is refused: Error says so, Hash unchanged;
#   - the AndyMark map with its own hash is loaded: Hash echoes it, Name is the robot's, no Error;
#   - after a PhotonVision restart, with the robot publishing nothing, the saved map is in use;
#   - every camera kept detecting while the map was swapped (its fps on /photonvision/<camera>).
# Puts the Jetson's saved map back afterwards and restarts PhotonVision again. Deadline: 4 min.
set -uo pipefail
if [[ -z ${FIELD_MAP_UNDER_TIMEOUT:-} ]]; then
  rc=0; FIELD_MAP_UNDER_TIMEOUT=1 timeout --kill-after=15 240 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the field-map test didn't finish in 4 min" >&2
  exit "$rc"
fi
HERE=$(cd "$(dirname "$0")" && pwd)
JAVA=/usr/lib/jvm/java-17-openjdk-arm64/bin/java
JAR=/opt/photonvision/photonvision.jar
SAVED=/opt/photonvision/photonvision_config/spectrum/field-map.json
BACKUP=/tmp/field-map-test-backup.json
ANDYMARK=resource:/edu/wpi/first/apriltag/2026-rebuilt-andymark.json
ANDYMARK_HASH=2792cd4e868967b8   # FieldMapHashTest, and robot code's reference
WELDED_HASH=ca28a7c1139ed099
source "$HERE/../lib/bench.sh"
fails=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
api_up() { curl -s -o /dev/null -m 2 http://localhost:5800/api/robotState; }
wait_api() { for _ in $(seq 1 90); do api_up && return 0; sleep 1; done; return 1; }
robot() { "$JAVA" -cp "$JAR" "$HERE/FieldMapRobot.java" "$@" 2>&1 | grep --line-buffered -v -e '^\[' -e '^NT:'; }

api_up || { echo "PhotonVision isn't answering on :5800"; exit 1; }
robot_address_add
had_saved=0
sudo -n test -f "$SAVED" && { sudo -n cp -p "$SAVED" "$BACKUP"; had_saved=1; }
cleanup() {
  trap '' PIPE
  if [[ $had_saved == 1 ]]; then sudo -n cp -p "$BACKUP" "$SAVED"; else sudo -n rm -f "$SAVED"; fi
  sudo -n rm -f "$BACKUP"
  sudo -n systemctl restart photonvision
  robot_address_del
  wait_api && echo "Saved field map put back; PhotonVision restarted"
}
trap cleanup EXIT

echo "== Robot publishes a map with the wrong hash, then the right one"
start=$(date +%s)
out1=$(robot "silent|10" "publish|8|$ANDYMARK|$WELDED_HASH|k2026RebuiltAndymark" \
              "publish|8|$ANDYMARK|$ANDYMARK_HASH|k2026RebuiltAndymark")
sed 's/^/    /' <<<"$out1"
refused=$(grep -A99 "with hash $WELDED_HASH" <<<"$out1" | grep -m1 "Error=Field map from the robot hashes to $ANDYMARK_HASH")
check "a hash mismatch is refused and reported" "[[ -n \$refused ]]"
loaded=$(grep -A99 "with hash $ANDYMARK_HASH" <<<"$out1" | grep "Hash=$ANDYMARK_HASH Name=k2026RebuiltAndymark " | grep -c "Error=$")
check "the robot's map is loaded and echoed (FieldMap/Hash $ANDYMARK_HASH)" "(( loaded > 0 ))"
check "it was saved for the next boot" "sudo -n test -f $SAVED"
# Each camera's slowest second while maps were sent, against its typical second before.
fps_report=$(python3 - <(printf '%s\n' "$out1") <<'PY'
import re, statistics, sys
before, during, publishing = {}, {}, False
for line in open(sys.argv[1]):
    if line.startswith("phase publish"): publishing = True
    if line.startswith("fps "):
        for cam, v in re.findall(r"(\S+)=([\d.]+)", line):
            (during if publishing else before).setdefault(cam, []).append(float(v))
worst = [(cam, min(during.get(cam, [0])), statistics.median(v)) for cam, v in before.items() if v]
print(" ".join(f"{c}:{lo:.0f}/{med:.0f}" for c, lo, med in worst) or "no-cameras")
sys.exit(0 if all(lo >= 0.8 * med for _, lo, med in worst) else 1)
PY
)
fps_ok=$?
check "every camera kept its frame rate through the swap (slowest/typical fps: $fps_report)" "(( fps_ok == 0 ))"
journalctl -u photonvision --since "@$start" --no-pager -o cat | grep -i "field map" | head -3 | sed 's/^/    log: /'

echo "== PhotonVision restarted; the robot publishes nothing"
sudo -n systemctl restart photonvision
wait_api || { echo "PhotonVision didn't come back"; exit 1; }
out2=$(robot "silent|20")
sed 's/^/    /' <<<"$out2"
check "the saved map is in use after the restart" \
      "grep -q 'Hash=$ANDYMARK_HASH Name=k2026RebuiltAndymark .*Error=$' <<<\"\$out2\""
journalctl -u photonvision --since "-1 min" --no-pager -o cat | grep -m1 "saved map" | sed 's/^/    log: /'

echo
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails check(s)"; exit 1; }
