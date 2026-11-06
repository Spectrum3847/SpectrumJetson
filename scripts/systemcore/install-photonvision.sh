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
#   /etc/systemd/system/photonvision.service + photonvision.service.d/10-spectrum.conf
#   /usr/local/bin/sc-vision (the switch below)
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
ssh "$HOST" 'mkdir -p ~/builder/pv-install'
scp -q "$JAR" "$HOST:builder/pv-install/photonvision.jar"
scp -q "$NAPA/libspectrum-napa-apriltag.so" "$NAPA/libspectrum-stream.so" "$NAPA/napa_test" \
  "$REPO/scripts/systemcore/sc-vision" "$HOST:builder/pv-install/"
ssh "$HOST" ENABLE="${ENABLE:-0}" 'bash -s' <<'REMOTE'
set -euo pipefail
S=~/builder/pv-install
chmod +x "$S/napa_test"
"$S/napa_test" >/dev/null || { echo "napa_test failed on this machine" >&2; exit 1; }
# A truncated jar would crash-loop the service.
python3 -c "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); z.getinfo('org/photonvision/Main.class')" \
  "$S/photonvision.jar" || { echo "not a valid PhotonVision jar" >&2; exit 1; }
sudo systemctl stop photonvision 2>/dev/null || true
sudo mkdir -p /opt/photonvision/lib
[[ -f /opt/photonvision/photonvision.jar ]] && sudo cp /opt/photonvision/photonvision.jar /opt/photonvision/photonvision.jar.prev
sudo install -m 644 "$S/photonvision.jar" /opt/photonvision/photonvision.jar.new
sudo mv -f /opt/photonvision/photonvision.jar.new /opt/photonvision/photonvision.jar
sudo install -m 755 "$S/libspectrum-napa-apriltag.so" "$S/libspectrum-stream.so" /opt/photonvision/lib/
sudo install -m 755 "$S/sc-vision" /usr/local/bin/sc-vision
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
ExecStart=/usr/bin/java -Xmx512m -XX:-CreateCoredumpOnCrash -Djava.library.path=/opt/photonvision/lib -jar /opt/photonvision/photonvision.jar -n
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
if [[ ${ENABLE:-0} == 1 ]]; then sudo systemctl enable photonvision; fi
echo "installed: $(ls -la /opt/photonvision/photonvision.jar /opt/photonvision/lib/*.so | awk '{print $5, $9}' | tr '\n' ' ')"
echo "start with: sc-vision photonvision   (UI http://<systemcore>:5880)"
REMOTE
