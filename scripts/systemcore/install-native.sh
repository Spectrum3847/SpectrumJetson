#!/usr/bin/env bash
# Install sc-vision (native/sc-vision, built with NT=1) on a SystemCore as the service sc-vision-native. Run ON
# THE LAPTOP after:
#   native/sc-vision/fetch-ntcore.sh && NT=1 NT_INC=~/builder/ntcore/inc NT_LIB=~/builder/ntcore/lib native/sc-vision/build.sh
#   scripts/systemcore/install-native.sh [BUILD] [HOST] [CALIB]
#     BUILD  default ~/builder/sc-vision     HOST default systemcore@172.26.0.1
#     CALIB  the camera's PhotonVision calibration JSON (default calibrations/SJ-TC01-1280x800.json: a stand-in)
# On the SystemCore: /opt/sc-vision/{bin,lib,etc}, /etc/systemd/system/sc-vision-native.service (NOT enabled at
# boot unless ENABLE=1; Conflicts= PhotonVision and Limelight's visionserver: one camera owner). Options in
# /etc/default/sc-vision. Switch: sc-vision native | photonvision | limelight | off.
# While it runs, uvcvideo is detached from the camera (no /dev/video0); it is given back when it stops.
set -euo pipefail
# SSH_OPTS: extra ssh/scp options, e.g. "-o HostKeyAlias=172.26.0.1" when reaching the SystemCore by another address
# shellcheck disable=SC2086
ssh() { command ssh ${SSH_OPTS:-} "$@"; }
# shellcheck disable=SC2086
scp() { command scp ${SSH_OPTS:-} "$@"; }
REPO=$(cd "$(dirname "$0")/../.." && pwd)
B=${1:-$HOME/builder/sc-vision}
HOST=${2:-systemcore@172.26.0.1}
CAL=${3:-$REPO/calibrations/SJ-TC01-1280x800.json}
NTL=${NT_LIB:-$HOME/builder/ntcore/lib}
ssh "$HOST" 'mkdir -p ~/builder/native-install'
tar -C "$B" -cf - sc-vision nt_probe mjdec_bench | ssh "$HOST" 'tar -C ~/builder/native-install -xf -'
tar -C "$NTL" -cf - libntcore.so libdatalog.so libwpinet.so libwpiutil.so | ssh "$HOST" 'tar -C ~/builder/native-install -xf -'
scp -q "$CAL" "$HOST:builder/native-install/calib.json"
scp -q "$REPO/scripts/systemcore/sc-vision" "$HOST:builder/native-install/sc-vision-switch"
scp -q "$REPO/native/sc-vision/sc-vision-rebind" "$HOST:builder/native-install/"
ssh "$HOST" ENABLE="${ENABLE:-0}" 'bash -s' <<'REMOTE'
set -euo pipefail
S=~/builder/native-install
sudo systemctl stop sc-vision-native 2>/dev/null || true
sudo mkdir -p /opt/sc-vision/bin /opt/sc-vision/lib /opt/sc-vision/etc
sudo install -m 755 "$S/sc-vision" "$S/nt_probe" "$S/mjdec_bench" "$S/sc-vision-rebind" /opt/sc-vision/bin/
sudo install -m 644 "$S"/lib*.so /opt/sc-vision/lib/
sudo install -m 644 "$S/calib.json" /opt/sc-vision/etc/calib.json
sudo install -m 755 "$S/sc-vision-switch" /usr/local/bin/sc-vision
/opt/sc-vision/bin/sc-vision --selftest >/dev/null || echo "WARNING: pose self-test reported differences"
if [[ ! -f /etc/default/sc-vision ]]; then
  sudo tee /etc/default/sc-vision >/dev/null <<'EOF'
# sc-vision options (sc-vision-native.service). Core 3, SCHED_FIFO 40 (below robot code's RT threads' limit 50),
# 2-packet URBs (0.25 ms), exposure 50 (5 ms) gain 32. NT server: the robot code on this SystemCore.
SC_VISION_ARGS=--serial SJ-05 --cpu 3 --fifo 40 --pkts 2 --exposure 50 --gain 32 --gamma 100 --backlight 0 --sharpness 1 --check 64 --calib /opt/sc-vision/etc/calib.json --nt 127.0.0.1 --name thrifty --camera-delay-ms 0.4
EOF
fi
# An older install pinned --mid-offset-ms 5.0 (exposure/2 2.5 + Team 100's 2.5 ms delay); now the measured 0.4 ms
# delay (LED test, 2026-11-06) and the exposure from the command line. Other values are kept.
if grep -q -- '--mid-offset-ms 5\.0\b' /etc/default/sc-vision; then
  sudo sed -i 's/--mid-offset-ms 5\.0\b/--camera-delay-ms 0.4/' /etc/default/sc-vision
  echo "sc-vision: --mid-offset-ms 5.0 -> --camera-delay-ms 0.4 in /etc/default/sc-vision"
fi
sudo tee /etc/systemd/system/sc-vision-native.service >/dev/null <<'EOF'
[Unit]
Description=sc-vision: native AprilTags from the Thriftiest Cam (SpectrumJetson native/sc-vision)
After=network-online.target
Conflicts=photonvision.service limelight_visionserver.service

[Service]
Type=simple
EnvironmentFile=/etc/default/sc-vision
ExecStart=/opt/sc-vision/bin/sc-vision $SC_VISION_ARGS
# SIGTERM: sc-vision stops its URBs and gives the camera back to uvcvideo
KillSignal=SIGTERM
# after a crash or SIGKILL the camera has no driver: give it back to uvcvideo (no USB reset)
ExecStopPost=/opt/sc-vision/bin/sc-vision-rebind
TimeoutStopSec=5
Restart=on-failure
RestartSec=2
LimitRTPRIO=50
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
if [[ ${ENABLE:-0} == 1 ]]; then sudo systemctl enable sc-vision-native; fi
echo "installed /opt/sc-vision; start with: sc-vision native"
REMOTE
