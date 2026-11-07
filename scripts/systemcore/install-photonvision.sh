#!/usr/bin/env bash
# Install the Spectrum PhotonVision fork (spectrum-2027 + sc/mjpeg-napa) with NAPA, the streaming decoder and
# streaming NAPA on a SystemCore (LimelightOS SystemCore, Raspberry Pi 5 / CM5). Run ON THE LAPTOP:
#   scripts/systemcore/install-photonvision.sh JAR [NAPA_OUT] [HOST]
#     JAR       photonvision-*-linuxarm64.jar (fork: ./gradlew photon-server:shadowJar -PArchOverride=linuxarm64)
#     NAPA_OUT  scripts/systemcore/build-napa.sh's output (default ~/builder/sc-napa)
#     HOST      default systemcore@172.26.0.1 (USB link; or robot.local)
#   KEEP_DROPIN=1 keeps an existing 10-spectrum.conf (else our defaults are written); GOVERNOR=0 skips the
#            performance-governor boot unit (enabled by default since the bench supply was fixed)
#   NATIVE=0 writes 20-native-camera.conf with SPECTRUM_NATIVE_CAMERA=0 (native cameras are on by default)
#   UVC_KO=path  our uvcvideo (build-uvcvideo.sh; default ~/builder/uvcvideo-sc/uvcvideo.ko): installed to
#            /opt/sc-vision/modules with sc-uvcvideo.service, which loads it at boot (stock on any failure;
#            /etc/sc-vision/uvcvideo.conf ENABLED=0 opts out). UVC=0 skips it.
#
# What it changes on the SystemCore (nothing else):
#   /opt/photonvision/photonvision.jar, /opt/photonvision/lib/*.so  (no files in /usr)
#   /opt/photonvision/run.sh (the service's ExecStart) and /opt/photonvision/photonvision.aot{,.stamp}
#   /etc/systemd/system/photonvision.service + photonvision.service.d/10-spectrum.conf
#   /usr/local/bin/sc-vision (the switch below)
# Java AOT cache (unless AOT=0): after installing, PhotonVision runs AOT_TRAIN_S seconds (default 45; with the
# cameras attached, as configured) recording the classes it loads and its method profiles, then the cache is
# built from that for this jar and JVM and kept next to the jar (~45 MB). run.sh uses it when it matches the jar
# and JVM and starts without it otherwise, saying which in the journal (docs/PHOTONVISION-PERF.md, "AOT cache").
# The service is enabled at boot (ENABLE=0 disables it). It runs Java 25 (the image's /usr/bin/java) as root with
# -n (PhotonVision never touches the SystemCore's networking) and serves its UI on port 5880 (5800 belongs to
# Limelight's visionserver). It Conflicts= limelight_visionserver: both want the camera, so starting one stops
# the other. Robot code (robot.service), NetworkTables (5810) and the other Limelight services are untouched.
#
# Switch (on the SystemCore):  sc-vision photonvision | limelight | off | status
# Streaming NAPA etc. are environment switches in /etc/systemd/system/photonvision.service.d/10-spectrum.conf.
set -euo pipefail
# SSH_OPTS: extra ssh/scp options, e.g. "-o HostKeyAlias=172.26.0.1" when reaching the SystemCore by another address
# shellcheck disable=SC2086
ssh() { command ssh ${SSH_OPTS:-} "$@"; }
# shellcheck disable=SC2086
scp() { command scp ${SSH_OPTS:-} "$@"; }
REPO=$(cd "$(dirname "$0")/../.." && pwd)
JAR=${1:?usage: install-photonvision.sh JAR [NAPA_OUT] [HOST]}
NAPA=${2:-$HOME/builder/sc-napa}
HOST=${3:-systemcore@172.26.0.1}
UVC_KO=${UVC_KO:-$HOME/builder/uvcvideo-sc/uvcvideo.ko}
for f in "$JAR" "$NAPA/libspectrum-napa-apriltag.so" "$NAPA/libspectrum-stream.so" "$NAPA/napa_test"; do
  [[ -f $f ]] || { echo "missing $f" >&2; exit 1; }
done
# Staged in RAM (/dev/shm): the SystemCore's old SD card stalls under heavy writes (a >30 s I/O hang panicked the
# kernel at 19:27); only the final copies touch it, each to a temporary name, synced, then renamed (reset-safe).
ssh "$HOST" 'mkdir -p /dev/shm/pv-install'
scp -q "$JAR" "$HOST:/dev/shm/pv-install/photonvision.jar"
scp -q "$NAPA/libspectrum-napa-apriltag.so" "$NAPA/libspectrum-stream.so" "$NAPA/napa_test" \
  "$REPO/scripts/systemcore/sc-vision" "$REPO/scripts/systemcore/photonvision-run.sh" \
  "$REPO/scripts/systemcore/performance-governor.sh" "$REPO/scripts/systemcore/sd-quiet.sh" "$HOST:/dev/shm/pv-install/"
UVC=${UVC:-1}
if [[ $UVC == 1 && -f $UVC_KO ]]; then
  scp -q "$UVC_KO" "$HOST:/dev/shm/pv-install/uvcvideo-sc.ko"
  scp -q "$REPO/scripts/systemcore/uvcvideo-boot.sh" "$REPO/scripts/systemcore/sc-uvcvideo.service" "$HOST:/dev/shm/pv-install/"
elif [[ $UVC == 1 ]]; then
  echo "no $UVC_KO (scripts/systemcore/build-uvcvideo.sh): boot-time uvcvideo not installed" >&2
  UVC=0
fi
ssh "$HOST" ENABLE="${ENABLE:-1}" NATIVE="${NATIVE:-1}" UVC="$UVC" KEEP_DROPIN="${KEEP_DROPIN:-0}" GOVERNOR="${GOVERNOR:-1}" TZ_NAME="${TZ_NAME:-America/Chicago}" AOT="${AOT:-1}" AOT_TRAIN_S="${AOT_TRAIN_S:-45}" 'bash -s' <<'REMOTE'
set -euo pipefail
S=/dev/shm/pv-install
TRAIN_DROPIN=/etc/systemd/system/photonvision.service.d/zz-aot-train.conf
trap 'sudo rm -f "$TRAIN_DROPIN"; sudo systemctl daemon-reload; rm -rf /dev/shm/pv-install' EXIT
# put SRC at DST: a temporary name next to it, synced, renamed, then checked against the staged copy
put() {
  # an identical file is left as it is (no SD write; the jar keeps its time, so its AOT cache stays valid)
  if sudo test -f "$2" && [[ $(sha256sum < "$1") == $(sudo sha256sum < "$2") ]]; then
    sudo chmod "$3" "$2"
    return 0
  fi
  sudo install -m "$3" "$1" "$2.new"
  sync -f "$2.new" 2>/dev/null || sync
  sudo mv -f "$2.new" "$2"
  [[ $(sha256sum < "$1") == $(sudo sha256sum < "$2") ]] || { echo "install: $2 differs from $1" >&2; exit 1; }
}
chmod +x "$S/napa_test"
# a Windows checkout (core.autocrlf) has CRLF scripts: "#!/bin/sh\r" fails to exec (status 203/EXEC)
sed -i 's/\r$//' "$S/sc-vision" "$S/photonvision-run.sh"
"$S/napa_test" >/dev/null || { echo "napa_test failed on this machine" >&2; exit 1; }
# A truncated jar would crash-loop the service.
python3 -c "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); z.getinfo('org/photonvision/Main.class')" \
  "$S/photonvision.jar" || { echo "not a valid PhotonVision jar" >&2; exit 1; }
# Another agent's run may own PhotonVision: take the bench's camera lock before touching the running service, and
# hold it until the install is done (released when this shell exits).
exec 9>/tmp/camera.lock
flock -w 600 9 || { echo "camera lock busy for 10 min: not installing" >&2; exit 1; }
sudo systemctl stop photonvision 2>/dev/null || true
sudo mkdir -p /opt/photonvision/lib
put "$S/photonvision.jar" /opt/photonvision/photonvision.jar 644
put "$S/libspectrum-napa-apriltag.so" /opt/photonvision/lib/libspectrum-napa-apriltag.so 755
put "$S/libspectrum-stream.so" /opt/photonvision/lib/libspectrum-stream.so 755
put "$S/sc-vision" /usr/local/bin/sc-vision 755
put "$S/photonvision-run.sh" /opt/photonvision/run.sh 755
# our uvcvideo at boot (sc-uvcvideo.service; stock on any failure). Takes effect at the next boot; nothing is
# swapped now.
if [[ ${UVC:-0} == 1 ]]; then
  sed -i 's/\r$//' "$S/uvcvideo-boot.sh" "$S/sc-uvcvideo.service"
  sudo mkdir -p /opt/sc-vision/modules /etc/sc-vision
  put "$S/uvcvideo-sc.ko" /opt/sc-vision/modules/uvcvideo-sc.ko 644
  sha256sum "$S/uvcvideo-sc.ko" | awk '{print $1}' > "$S/uvcvideo-sc.ko.sha256"
  put "$S/uvcvideo-sc.ko.sha256" /opt/sc-vision/modules/uvcvideo-sc.ko.sha256 644
  put "$S/uvcvideo-boot.sh" /opt/sc-vision/uvcvideo-boot.sh 755
  put "$S/sc-uvcvideo.service" /etc/systemd/system/sc-uvcvideo.service 644
  if [[ ! -f /etc/sc-vision/uvcvideo.conf ]]; then
    printf '%s\n' '# sc-uvcvideo.service (/opt/sc-vision/uvcvideo-boot.sh): our uvcvideo at boot, stock on any failure' \
      'ENABLED=1' 'URB_PACKETS=2' 'HWTIMESTAMPS=1' 'CAMERA_WAIT_S=10' | sudo tee /etc/sc-vision/uvcvideo.conf >/dev/null
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable sc-uvcvideo.service 2>&1 | tail -1
  echo "boot uvcvideo: $(/opt/sc-vision/uvcvideo-boot.sh status)"
fi
sudo tee /etc/systemd/system/photonvision.service >/dev/null <<'EOF'
[Unit]
Description=PhotonVision (Spectrum fork, SpectrumJetson scripts/systemcore)
After=network-online.target
# Both want the Thriftiest camera: starting PhotonVision stops Limelight's visionserver and the reverse.
Conflicts=limelight_visionserver.service

[Service]
Type=simple
WorkingDirectory=/opt/photonvision
Environment=LD_LIBRARY_PATH=/opt/photonvision/lib
Environment=SPECTRUM_WEBPORT=5880
# /usr/bin/java -Xmx512m [-XX:AOTCache=...] ... -jar /opt/photonvision/photonvision.jar -n (run.sh)
ExecStart=/opt/photonvision/run.sh
Restart=on-failure
RestartSec=3
# Below robot code's real-time threads (robot.service LimitRTPRIO=50); normal CFS otherwise.
Nice=0

[Install]
WantedBy=multi-user.target
EOF
sudo mkdir -p /etc/systemd/system/photonvision.service.d
# Our current defaults (docs/SYSTEMCORE-NATIVE-BACKEND.md), for native cameras and the cscore/Java fallback path
# alike. A different existing 10-spectrum.conf is kept next to it as 10-spectrum.conf.before-<date> (systemd reads
# only *.conf); KEEP_DROPIN=1 leaves an existing one alone.
D=/etc/systemd/system/photonvision.service.d/10-spectrum.conf
cat > "$S/10-spectrum.conf" <<'EOF'
[Service]
# SpectrumJetson defaults (install-photonvision.sh). Native cameras (Thriftiest, Swyft) need none of these; the
# fallback (cscore) path uses them: the stream decoder (decodes while the frame arrives), mjdec, streaming NAPA.
Environment=SPECTRUM_JPEG_DECODER=stream
Environment=SPECTRUM_STREAM_DECODER=mjdec
Environment=SPECTRUM_NAPA_STREAM=1
# Exposure end -> first USB packet (measured 0.41 ms on the Thriftiest, LED test)
Environment=SPECTRUM_CAMERA_DELAY_US=400
# No SystemCore 50 fps cap and no idle-mode rate while disabled: cameras at their full 120 fps (as measured)
Environment=SPECTRUM_SYSTEMCORE_PROFILE=0
Environment=SPECTRUM_IDLE_FPS=0
EOF
if [[ ${KEEP_DROPIN:-0} == 1 && -f $D ]]; then
  echo "10-spectrum.conf kept (KEEP_DROPIN=1)"
elif ! sudo cmp -s "$S/10-spectrum.conf" "$D"; then
  if [[ -f $D ]]; then sudo cp "$D" "$D.before-$(date +%Y%m%d-%H%M%S)"; fi
  put "$S/10-spectrum.conf" "$D" 644
  echo "10-spectrum.conf: SpectrumJetson defaults written"
fi
# CPU governor performance at boot (performance-governor.sh's unit; GOVERNOR=0 leaves it as it is)
if [[ ${GOVERNOR:-1} == 1 ]]; then
  sed -i 's/\r$//' "$S/performance-governor.sh"
  bash "$S/performance-governor.sh" enable >/dev/null
  echo "governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor) (enabled at boot)"
fi
# Logs in RAM (sd-quiet.sh: journald volatile, tmpfs over PV's logs dir): SD stalls reset the Pi. SDQUIET=0 skips
if [[ ${SDQUIET:-1} == 1 ]]; then
  sed -i 's/\r$//' "$S/sd-quiet.sh"
  sudo sh "$S/sd-quiet.sh"
fi
# Time zone America/Chicago (TZ_NAME=... overrides), like the robot's build stamps and the Driver Station, so logs
# read in local time. Display only. LimelightOS has no timedated, so /etc/localtime is linked directly.
tz=${TZ_NAME:-America/Chicago}
if [[ -f /usr/share/zoneinfo/$tz ]]; then
  sudo ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
  echo "time zone: $tz ($(date +%Z))"
else
  echo "time zone: /usr/share/zoneinfo/$tz missing, left as $(readlink /etc/localtime)"
fi
# Native cameras (docs/SYSTEMCORE-NATIVE-BACKEND.md) are on by default for verified cameras; NATIVE=0 turns them off
# with its own drop-in (20-native-camera.conf: SPECTRUM_NATIVE_CAMERA=0). Older installs' 20-native-camera.conf
# (SPECTRUM_NATIVE_PUBLISH=1, no longer read) is replaced or removed.
if [[ ${NATIVE:-1} == 0 ]]; then
  printf '%s\n' '[Service]' '# native cameras off (cscore fast path for every camera)' \
    'Environment=SPECTRUM_NATIVE_CAMERA=0' | sudo tee /etc/systemd/system/photonvision.service.d/20-native-camera.conf >/dev/null
else
  sudo rm -f /etc/systemd/system/photonvision.service.d/20-native-camera.conf
fi
# An older install pinned Team 100's 2.5 ms; the LED test measured 0.41 ms (2026-11-06). Other values are kept.
if sudo grep -q '^Environment=SPECTRUM_CAMERA_DELAY_US=2500$' /etc/systemd/system/photonvision.service.d/*.conf 2>/dev/null; then
  sudo sed -i 's/^Environment=SPECTRUM_CAMERA_DELAY_US=2500$/Environment=SPECTRUM_CAMERA_DELAY_US=400/' \
    /etc/systemd/system/photonvision.service.d/*.conf
  echo "camera delay: 2500 -> 400 us in the PhotonVision drop-ins"
fi
sudo systemctl daemon-reload
# Java AOT cache for this jar: a training run records what PhotonVision loads (configuration in RAM), then the cache
# is built from it (no camera) and put next to the jar with the stamp run.sh compares.
if [[ ${AOT:-1} == 1 ]]; then
  conf=$S/pv.aotconf
  { printf '[Service]\nExecStart=\n'
    printf 'ExecStart=/usr/bin/java -Xmx512m -XX:AOTMode=record -XX:AOTConfiguration=%s ' "$conf"
    printf -- '-XX:-CreateCoredumpOnCrash -Djava.library.path=/opt/photonvision/lib -jar %s -n\n' \
      /opt/photonvision/photonvision.jar
  } | sudo tee "$TRAIN_DROPIN" >/dev/null
  sudo systemctl daemon-reload
  echo "AOT cache: training run (${AOT_TRAIN_S:-45} s)"
  sudo systemctl start photonvision
  sleep "${AOT_TRAIN_S:-45}"
  sudo systemctl stop photonvision
  sudo rm -f "$TRAIN_DROPIN"
  sudo systemctl daemon-reload
  if sudo test -s "$conf" &&
    sudo /usr/bin/java -Xmx512m -XX:AOTMode=create -XX:AOTConfiguration="$conf" -XX:AOTCache="$S/pv.aot" \
      -cp /opt/photonvision/photonvision.jar > "$S/aot-create.log" 2>&1 && sudo test -s "$S/pv.aot"; then
    put "$S/pv.aot" /opt/photonvision/photonvision.aot 644
    /opt/photonvision/run.sh --stamp > "$S/pv.aot.stamp"
    put "$S/pv.aot.stamp" /opt/photonvision/photonvision.aot.stamp 644
    echo "AOT cache: $(du -h /opt/photonvision/photonvision.aot | cut -f1) for $(cat "$S/pv.aot.stamp")"
  else
    sudo rm -f /opt/photonvision/photonvision.aot /opt/photonvision/photonvision.aot.stamp
    echo "AOT cache: not built (see below); PhotonVision starts without one" >&2
    tail -5 "$S/aot-create.log" 2>/dev/null >&2 || true
  fi
fi
if [[ ${ENABLE:-1} == 1 ]]; then sudo systemctl enable photonvision; else sudo systemctl disable photonvision; fi
echo "installed: $(ls -la /opt/photonvision/photonvision.jar /opt/photonvision/lib/*.so | awk '{print $5, $9}' | tr '\n' ' ')"
echo "start with: sc-vision photonvision   (UI http://<systemcore>:5880)"
REMOTE
