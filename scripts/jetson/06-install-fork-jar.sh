#!/usr/bin/env bash
# Swap the 4143 CUDA PhotonVision fork jar into the photonvision.service created by
# 03-photonvision.sh, and run it on Java 17 (the fork targets 17; the 2027 installer
# made Java 25 the system default).
# Run ON THE JETSON. Usage: 06-install-fork-jar.sh <path/to/photonvision-...-linuxarm64.jar>
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

JAR=${1:?usage: $0 <photonvision-linuxarm64.jar>}
# The Java the jar was compiled for: 2026 jars target 17 (class file 61), 2027 ones 25 (69).
# JAVA_FEATURE=17|25 overrides.
cls=$(unzip -p "$JAR" org/photonvision/Main.class 2>/dev/null | od -An -tu1 -j7 -N1 | tr -d ' ')
JAVA_FEATURE=${JAVA_FEATURE:-$([[ ${cls:-0} -ge 69 ]] && echo 25 || echo 17)}
JAVA17=/usr/lib/jvm/java-$JAVA_FEATURE-openjdk-arm64/bin/java   # (named for 17, its first use)
NET_FLAG=""
[[ ${PV_MANAGE_NETWORK:-1} == 0 ]] && NET_FLAG=" -n"
DEST=/opt/photonvision/photonvision.jar

[[ -x $JAVA17 ]] || { echo "Missing $JAVA17 (sudo apt install openjdk-$JAVA_FEATURE-jdk-headless)" >&2; exit 1; }
# Every entry must read back with a good CRC. Python, not unzip -t: upstream's 2027 CI jars repeat a
# few LICENSE/NOTICE entries, which Ubuntu 24.04's unzip rejects as a zip bomb (Java reads them fine),
# so a repeated name is skipped, everything else must read.
jar_ok() {
  python3 - "$1" <<'PY'
import collections, sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1])
    n = collections.Counter(i.filename for i in z.infolist())
    assert n["org/photonvision/Main.class"] == 1
    for i in z.infolist():
        if n[i.filename] == 1:
            z.read(i)
except Exception as e:
    sys.exit(f"{e}")
PY
}
# Refuse truncated/corrupt jars: a bad jar here leaves the service crash-looping.
# (No pipes here: with pipefail, `unzip -l | grep -q` fails when grep exits early.)
if ! jar_ok "$JAR"; then
  echo "Refusing to install $JAR: not a valid PhotonVision jar ($(stat -c %s "$JAR") bytes)." >&2
  exit 1
fi
[[ -f /usr/lib/lib971apriltag.so ]] || echo "WARNING: /usr/lib/lib971apriltag.so missing; CUDA pipeline will fail to load." >&2

sudo systemctl stop photonvision

# Keep the jar being replaced, once, so we can roll back.
if [[ -f $DEST && ! -f /opt/photonvision/photonvision.jar.orig ]]; then
  sudo cp "$DEST" /opt/photonvision/photonvision.jar.orig
fi
# Also keep the last *valid* jar as .prev for a one-step rollback.
if [[ -f $DEST ]] && jar_ok "$DEST" 2>/dev/null; then
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
sudo tee /etc/systemd/system/photonvision.service.d/java17.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=$JAVA17 -Xmx512m -XX:-CreateCoredumpOnCrash -jar $DEST$NET_FLAG
EOF

# The Match ready page (photonvision-52) runs the health check through this link, so it's always
# the repo's current copy.
sudo ln -sfn "$(cd "$(dirname "$0")" && pwd)/health-check.sh" /opt/photonvision/health-check.sh

sudo systemctl daemon-reload
sudo systemctl start photonvision
sleep 10
systemctl --no-pager --lines=0 status photonvision || true
journalctl -u photonvision --no-pager -n 300 | grep -iE "version|971|cuda|jetson|exception|error" | tail -15 || true

echo
echo "Rollback: sudo cp /opt/photonvision/photonvision.jar.orig $DEST && \\"
echo "  sudo rm /etc/systemd/system/photonvision.service.d/java17.conf && \\"
echo "  sudo systemctl daemon-reload && sudo systemctl restart photonvision"
