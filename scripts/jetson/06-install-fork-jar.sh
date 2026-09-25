#!/usr/bin/env bash
# Install the alpha-7-based SpectrumJetson PhotonVision jar and run it on Java 25.
# Run ON THE JETSON. Usage: 06-install-fork-jar.sh <photonvision-...-linuxarm64.jar>
set -euo pipefail

JAR=${1:?usage: $0 <photonvision-linuxarm64.jar>}
JAVA25=${JAVA25:-/usr/lib/jvm/java-25-openjdk-arm64/bin/java}
NET_FLAG=""
[[ ${PV_MANAGE_NETWORK:-1} == 0 ]] && NET_FLAG=" -n"
DEST=/opt/photonvision/photonvision.jar

[[ -x $JAVA25 ]] || { echo "Missing $JAVA25. Install openjdk-25-jdk." >&2; exit 1; }
java_version=$("$JAVA25" -version 2>&1)
[[ $java_version == *'"25'* ]] || { echo "$JAVA25 is not Java 25" >&2; exit 1; }
[[ -f $JAR ]] || { echo "Missing jar: $JAR" >&2; exit 1; }
if ! unzip -tq "$JAR" >/dev/null 2>&1 || ! unzip -l "$JAR" org/photonvision/Main.class >/dev/null 2>&1; then
  echo "Refusing to install $JAR. It is not a valid PhotonVision jar." >&2
  exit 1
fi
[[ -f /usr/lib/lib971apriltag.so ]] ||
  echo "WARNING: /usr/lib/lib971apriltag.so is missing. CUDA pipelines will fail to load." >&2

sudo systemctl stop photonvision
if [[ -f $DEST && ! -f /opt/photonvision/photonvision.jar.orig ]]; then
  sudo cp "$DEST" /opt/photonvision/photonvision.jar.orig
fi
if [[ -f $DEST ]] && unzip -tq "$DEST" >/dev/null 2>&1; then
  sudo cp "$DEST" /opt/photonvision/photonvision.jar.prev
fi
sudo install -m 644 "$JAR" "$DEST"

sudo mkdir -p /etc/systemd/system/photonvision.service.d
sudo tee /etc/systemd/system/photonvision.service.d/java25.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=$JAVA25 -Xmx512m -XX:-CreateCoredumpOnCrash -jar $DEST$NET_FLAG
EOF

sudo systemctl daemon-reload
sudo systemctl start photonvision
sleep 10
systemctl --no-pager --lines=0 status photonvision || true
journalctl -u photonvision --no-pager -n 300 |
  grep -iE "version|971|cuda|jetson|exception|error" | tail -15 || true

cat <<'EOF'
The alpha-7 jar has not passed a robot-network compatibility test.
Keep the robot on its tested PhotonLib release until a real robot and Jetson pass the joint test.
Rollback: sudo cp /opt/photonvision/photonvision.jar.orig /opt/photonvision/photonvision.jar
Then remove java25.conf, reload systemd, and restart PhotonVision.
EOF
