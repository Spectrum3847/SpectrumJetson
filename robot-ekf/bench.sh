#!/usr/bin/env bash
# TagEkf live on the bench SystemCore / Pi 5, from the laptop: builds the bench jar, copies it to ~/tagekf on the
# target and runs BenchEkf next to the robot program (its own NT4 client; the robot program, its CAN setup and
# PhotonVision are not touched), holding /tmp/camera.lock. It uses the robot's WPILib jars and natives
# (~/wpilib, as robotCommand.args does). Logs go to /dev/shm/tagekf/<stamp> on the target.
#   robot-ekf/bench.sh [BenchEkf live options]      e.g. --seconds 40 --survey 5 --bearing-deg 0.25
# SSH: SC_SSH (default: systemcore@172.30.0.1 over Wi-Fi with the wired address's host key).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
read -r -a SSH <<< "${SC_SSH:-ssh -o HostKeyAlias=172.26.0.1 systemcore@172.30.0.1}"
(cd "$HERE" && ./gradlew -q benchJar)
"${SSH[@]}" 'mkdir -p ~/tagekf'
"${SSH[@]}" 'cat > ~/tagekf/tagekf-bench.jar' < "$HERE/build/libs/tagekf-bench.jar"
STAMP=$(date +%Y%m%d-%H%M%S)
# shellcheck disable=SC2029  # the options are meant to expand here, on the laptop
"${SSH[@]}" "W=/home/systemcore/wpilib; CP=\$(ls \$W/classpath/*.jar | grep -v DIYsystemcore | tr '\n' :); \
  flock -n /tmp/camera.lock java -XX:+UseZGC -Djava.library.path=\$W/third-party/lib --enable-native-access=ALL-UNNAMED \
  -cp ~/tagekf/tagekf-bench.jar:\$CP org.spectrum3847.tagekf.BenchEkf live --out /dev/shm/tagekf/$STAMP $*"
echo "logs: /dev/shm/tagekf/$STAMP on the target"
