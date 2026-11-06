#!/usr/bin/env bash
# Install the Spectrum PhotonVision fork (spectrum-2027 + sc/mjpeg-napa) with NAPA, the streaming decoder and
# streaming NAPA on a SystemCore (LimelightOS SystemCore, Raspberry Pi 5 / CM5). Run ON THE LAPTOP:
#   scripts/systemcore/install-photonvision.sh JAR [NAPA_OUT] [HOST]
#     JAR       photonvision-*-linuxarm64.jar (fork: ./gradlew photon-server:shadowJar -PArchOverride=linuxarm64)
#     NAPA_OUT  scripts/systemcore/build-napa.sh's output (default ~/builder/sc-napa)
#     HOST      default systemcore@172.26.0.1 (USB link; or robot.local)
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
# The service is NOT enabled at boot unless ENABLE=1. It runs Java 25 (the image's /usr/bin/java) as root with
# -n (PhotonVision never touches the SystemCore's networking) and serves its UI on port 5880 (5800 belongs to
# Limelight's visionserver). It Conflicts= limelight_visionserver: both want the camera, so starting one stops
# the other. Robot code (robot.service), NetworkTables (5810) and the other Limelight services are untouched.
#
# Switch (on the SystemCore):  sc-vision photonvision | limelight | off | status
# Streaming NAPA etc. are environment switches in /etc/systemd/system/photonvision.service.d/10-spectrum.conf.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
JAR=${1:?usage: install-photonvision.sh JAR [NAPA_OUT] [HOST]}
NAPA=${2:-$HOME/builder/sc-napa}
HOST=${3:-systemcore@172.26.0.1}
for f in "$JAR" "$NAPA/libspectrum-napa-apriltag.so" "$NAPA/libspectrum-stream.so" "$NAPA/napa_test"; do
  [[ -f $f ]] || { echo "missing $f" >&2; exit 1; }
done
# Staged in RAM (/dev/shm): the SystemCore's old SD card stalls under heavy writes (a >30 s I/O hang panicked the
# kernel at 19:27); only the final copies touch it, each to a temporary name, synced, then renamed (reset-safe).
ssh "$HOST" 'mkdir -p /dev/shm/pv-install'
scp -q "$JAR" "$HOST:/dev/shm/pv-install/photonvision.jar"
scp -q "$NAPA/libspectrum-napa-apriltag.so" "$NAPA/libspectrum-stream.so" "$NAPA/napa_test" \
  "$REPO/scripts/systemcore/sc-vision" "$REPO/scripts/systemcore/photonvision-run.sh" "$HOST:/dev/shm/pv-install/"
ssh "$HOST" ENABLE="${ENABLE:-0}" AOT="${AOT:-1}" AOT_TRAIN_S="${AOT_TRAIN_S:-45}" 'bash -s' <<'REMOTE'
set -euo pipefail
S=/dev/shm/pv-install
TRAIN_DROPIN=/etc/systemd/system/photonvision.service.d/zz-aot-train.conf
trap 'sudo rm -f "$TRAIN_DROPIN"; sudo systemctl daemon-reload; rm -rf /dev/shm/pv-install' EXIT
# put SRC at DST: a temporary name next to it, synced, renamed, then checked against the staged copy
put() {
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
if [[ ! -f /etc/systemd/system/photonvision.service.d/10-spectrum.conf ]]; then
  sudo tee /etc/systemd/system/photonvision.service.d/10-spectrum.conf >/dev/null <<'EOF'
[Service]
# Decoder: stream (Y-only libjpeg-turbo, decodes while the frame arrives) | turbo
Environment=SPECTRUM_JPEG_DECODER=stream
# Streaming NAPA (tags while the frame arrives; needs a pipeline with Tags on CPU (NAPA))
Environment=SPECTRUM_NAPA_STREAM=1
# Exposure end -> first USB packet, per camera ("N" or "N,name=N"); measured 0.41 ms on the Thriftiest
# (LED test), the Swyft uses the same until measured. The fork converts its own time reference (driver stamp
# or the streaming watcher's first sight) back to the first packet before applying it.
Environment=SPECTRUM_CAMERA_DELAY_US=400
EOF
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
if [[ ${ENABLE:-0} == 1 ]]; then sudo systemctl enable photonvision; fi
echo "installed: $(ls -la /opt/photonvision/photonvision.jar /opt/photonvision/lib/*.so | awk '{print $5, $9}' | tr '\n' ' ')"
echo "start with: sc-vision photonvision   (UI http://<systemcore>:5880)"
REMOTE
