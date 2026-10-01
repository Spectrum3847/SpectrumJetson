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
# Refuse truncated/corrupt jars: a bad jar here leaves the service crash-looping.
# (No pipes here: with pipefail, `unzip -l | grep -q` fails when grep exits early.)
if ! unzip -tq "$JAR" >/dev/null 2>&1 || ! unzip -l "$JAR" org/photonvision/Main.class >/dev/null 2>&1; then
  echo "Refusing to install $JAR. It is not a valid PhotonVision jar." >&2
  exit 1
fi
[[ -f /usr/lib/lib971apriltag.so ]] ||
  echo "WARNING: /usr/lib/lib971apriltag.so is missing. CUDA pipelines will fail to load." >&2

sudo systemctl stop photonvision

# Keep the jar being replaced, once, so we can roll back.
if [[ -f $DEST && ! -f /opt/photonvision/photonvision.jar.orig ]]; then
  sudo cp "$DEST" /opt/photonvision/photonvision.jar.orig
fi
# Also keep the last *valid* jar as .prev for a one-step rollback.
if [[ -f $DEST ]] && unzip -tq "$DEST" >/dev/null 2>&1; then
  sudo cp "$DEST" /opt/photonvision/photonvision.jar.prev
fi
# Copied beside it and renamed over it, with syncs: a power cut mid-install (a pit update, then the
# robot switched off) leaves the old jar or the new one, never a truncated one that crash-loops.
sudo install -m 644 "$JAR" "$DEST.new"
sync
sudo mv -f "$DEST.new" "$DEST"
sync

# Drop-in override instead of editing the installer's unit.
# PhotonVision manages networking (static IP, hostname) from its UI unless
# PV_MANAGE_NETWORK=0, which passes -n (--disable-networking). Before enabling it,
# make sure PV's Hostname field holds the name you want: PV applies it to the system.
# -XX:-CreateCoredumpOnCrash: a native crash otherwise dumps core through Apport, which took
# ~28 s (and 156 MB) before systemd could restart PhotonVision.
sudo mkdir -p /etc/systemd/system/photonvision.service.d
# The 2026 jar's drop-in would override this one.
sudo rm -f /etc/systemd/system/photonvision.service.d/java17.conf
sudo tee /etc/systemd/system/photonvision.service.d/java25.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=$JAVA25 -Xmx512m -XX:-CreateCoredumpOnCrash -jar $DEST$NET_FLAG
EOF

# The Match ready page (photonvision-52) runs the health check through this link, so it's always
# the repo's current copy.
sudo ln -sfn "$(cd "$(dirname "$0")" && pwd)/health-check.sh" /opt/photonvision/health-check.sh

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
