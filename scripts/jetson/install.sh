#!/usr/bin/env bash
# The whole Jetson setup in one command, after the flash (scripts/host/02-flash-nvme.sh). Run ON THE
# JETSON, from this repo's copy there, with internet (Wi-Fi) and passwordless sudo:
#
#   ~/SpectrumJetson/scripts/jetson/install.sh [--jar PATH] [--model ONNX] [--settings SQLITE]
#
# It runs every step in order, each with its own time limit and log in ~/install-logs/, and stops
# at the first failure. Run it again and it carries on from the step that failed (finished steps
# are recorded in ~/install-logs/done). --from STEP re-runs from a step, --only STEP runs one.
# About an hour, most of it CUDA's download and the allwpilib build.
#
#   --jar PATH        the PhotonVision fork jar (scripts/host/03-build-photonvision-fork.sh builds
#                     it on a laptop). Default: the newest ~/restore/*linuxarm64.jar.
#   --model ONNX      a YOLO model for game pieces, installed as "Fuel" (optional)
#   --settings FILE   a photon.sqlite to restore (e.g. from a snapshot or an old SSD) (optional)
#   --prebuilt [B]    skip the builds (allwpilib, the detector, the field-calibration tool, the jar):
#                     install a bundle from make-prebuilt-bundle.sh instead. B is a .tar.gz, a URL,
#                     or "latest" (the default: this repo's newest GitHub release). ~25 min shorter.
#   FAN=quiet|full|off   fan mode for 09-robot-tuning.sh (default: config.env's)
#   CAP=...           camera bandwidth caps for 11-uvcvideo-payload-cap.sh (default per model)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# The team's settings (FAN, TEAM_NUMBER, ...), the same file the laptop's scripts use. Variables
# already set (FAN=off install.sh ...) win: config.env only fills in what's unset.
# shellcheck source=../../config.env
[[ -f $HERE/../../config.env ]] && source "$HERE/../../config.env"
LOGS=$HOME/install-logs
DONE=$LOGS/done
mkdir -p "$LOGS"; touch "$DONE"

JAR="" MODEL="" SETTINGS="" FROM="" ONLY="" PREBUILT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --jar) JAR=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --settings) SETTINGS=$2; shift 2 ;;
    --from) FROM=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --prebuilt) if [[ ${2:-} && $2 != --* ]]; then PREBUILT=$2; shift 2; else PREBUILT=latest; shift; fi ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
done
PREBUILT_JAR=$HOME/restore/prebuilt-photonvision.jar
if [[ -n $PREBUILT && -z $JAR ]]; then JAR=$PREBUILT_JAR; fi
[[ -n $JAR ]] || JAR=$(ls -t "$HOME"/restore/*linuxarm64.jar 2>/dev/null | head -1)

sudo -n true 2>/dev/null || { echo "install.sh needs passwordless sudo (see README Step 2)." >&2; exit 1; }
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }
timeout 10 ping -c1 -W5 github.com >/dev/null 2>&1 || { echo "No internet: join Wi-Fi first (sudo nmcli --ask dev wifi connect <SSID>)." >&2; exit 1; }
[[ -n $PREBUILT || -f $JAR ]] || { echo "No PhotonVision jar: pass --jar (build it with scripts/host/03-build-photonvision-fork.sh)." >&2; exit 1; }

export PATH=$PATH:/usr/local/cuda/bin
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/cuda/lib64
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64/
# apt must never stop to ask (sudo drops DEBIAN_FRONTEND, so set it in apt's and debconf's own
# config for the install, and put it back at the end).
APT_NOASK=/etc/apt/apt.conf.d/99spectrum-install-noninteractive
echo 'Dpkg::Options { "--force-confdef"; "--force-confold"; };' | sudo tee "$APT_NOASK" >/dev/null
echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections
trap 'sudo rm -f "$APT_NOASK"; echo "debconf debconf/frontend select Dialog" | sudo debconf-set-selections' EXIT

restore_settings() {
  [[ -z $SETTINGS ]] && { echo "no --settings given: PhotonVision starts with its defaults"; return 0; }
  local db=/opt/photonvision/photonvision_config/photon.sqlite
  sudo systemctl stop photonvision
  [[ -f $db ]] && sudo cp -a "$db" "$db.before-restore-$(date +%Y%m%d-%H%M%S)"
  sudo install -m 644 "$SETTINGS" "$db"
  sudo rm -f "$db-wal" "$db-shm"
  sudo systemctl start photonvision
}

# --prebuilt: fetch and check the bundle, then put each file where the build steps would have.
prebuilt_install() {
  local b=$PREBUILT dir=$HOME/restore
  mkdir -p "$dir"
  # A fresh JetPack has no curl (found 2026-10-01: --prebuilt latest failed on it).
  command -v curl >/dev/null || sudo apt-get install -y curl >/dev/null || return 1
  if [[ $b == latest ]]; then
    b=$(curl -fsSL https://api.github.com/repos/Spectrum3847/SpectrumJetson/releases/latest \
        | python3 -c "import json,sys; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].startswith('spectrum-jetson-prebuilt-') and a['name'].endswith('.tar.gz')))") \
      || { echo "No prebuilt bundle in the latest release"; return 1; }
  fi
  if [[ $b == http* ]]; then
    echo "downloading $b"
    curl -fsSL -o "$dir/$(basename "$b")" "$b" && curl -fsSL -o "$dir/$(basename "$b").sha256" "$b.sha256" || return 1
    b=$dir/$(basename "$b")
  fi
  [[ -f $b ]] || { echo "No bundle at $b"; return 1; }
  if [[ -f $b.sha256 ]]; then (cd "$(dirname "$b")" && sha256sum -c "$(basename "$b").sha256") || return 1
  else echo "WARNING: no $b.sha256 next to the bundle: not checked against its published checksum"; fi
  local t; t=$(mktemp -d)
  tar -C "$t" -xzf "$b" || return 1
  # Built for this exact system? The libraries link against L4T's CUDA and TensorRT.
  local l4t cuda
  l4t=$(head -1 /etc/nv_tegra_release | sed -E 's/.*R([0-9]+).*REVISION: ([0-9.]+).*/\1.\2/')
  cuda=$(/usr/local/cuda/bin/nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')
  grep -qx "l4t: $l4t" "$t/MANIFEST" && grep -qx "cuda: $cuda" "$t/MANIFEST" \
    || { echo "The bundle was built for $(grep -E '^(l4t|cuda):' "$t/MANIFEST" | tr '\n' ' '), this Jetson has l4t $l4t, cuda $cuda"; return 1; }
  (cd "$t" && sed -n 's/^  //p' MANIFEST | sha256sum -c --quiet) || { echo "A file in the bundle doesn't match its MANIFEST"; return 1; }
  sed -n '1,7p' "$t/MANIFEST"
  # The runtime packages the builds would have installed.
  # build-essential: the camera driver is still compiled here, for the exact kernel.
  sudo apt-get install -y openjdk-17-jdk libprotobuf23 libjpeg-turbo8 libtbb12 unzip build-essential >/dev/null || return 1
  # Each copy checked: a step that half-installed must fail, not be marked done.
  sudo install -m 755 "$t"/usr/local/lib/*.so /usr/local/lib/ || return 1
  sudo ldconfig || return 1
  mkdir -p "$HOME/build/bos-detector" "$HOME/build/fieldcal-detect" || return 1
  install -m 755 "$t"/build/bos-detector/*.so "$HOME/build/bos-detector/" || return 1
  # The synthetic-tag generator for fake-cameras.sh (in bundles from 2026-10-01 on).
  if [[ -f $t/build/bos-detector/far_search_test ]]; then
    install -m 755 "$t/build/bos-detector/far_search_test" "$HOME/build/bos-detector/" || return 1
  fi
  install -m 755 "$t/build/fieldcal-detect/fieldcal_detect" "$HOME/build/fieldcal-detect/" || return 1
  install -m 644 "$t"/photonvision-spectrum-*-linuxarm64.jar "$PREBUILT_JAR" || return 1
  # The field-calibration tool's install (13-build-fieldcal-detect.sh --install, minus the build).
  sudo install -d -m 755 /opt/spectrum/fieldcal/fieldcal || return 1
  sudo rm -f /opt/spectrum/fieldcal/fieldcal/*.py
  sudo install -m 644 "$HERE"/../../tools/fieldcal/fieldcal/*.py /opt/spectrum/fieldcal/fieldcal/ || return 1
  sudo install -m 755 "$HOME/build/fieldcal-detect/fieldcal_detect" /opt/spectrum/fieldcal/fieldcal_detect || return 1
  rm -rf "$t"
  echo "prebuilt bundle installed: $(basename "$b")"
}

# name | time limit (s) | command
STEPS=(
  "verify|600|$HERE/01-verify.sh </dev/null"
  "jetpack|3600|$HERE/02-jetpack.sh"
  "tools|600|sudo apt-get install -y smartmontools gdisk rsync curl && sudo smartctl -A /dev/nvme0 | tee $LOGS/ssd-smart-at-install.txt"
  "photonvision|1200|$HERE/03-photonvision.sh"
  "data-partitions|600|$HERE/10-data-partition.sh"
  "allwpilib|5400|$HERE/04-build-allwpilib.sh"
  "detector|3600|$HERE/07-build-bos-detector.sh"
  "prebuilt|1200|prebuilt_install"
  "fork-jar|600|$HERE/06-install-fork-jar.sh '$JAR'"
  "select-detector|600|$HERE/08-select-detector.sh bos --mwbd 20 --jpeg nvjpg"
  "camera-driver|1800|$HERE/11-uvcvideo-payload-cap.sh --install"
  "trt-backend|300|sudo install -m 755 $HOME/build/bos-detector/libspectrumtrt.so /usr/lib/ && ls -l /usr/lib/libspectrumtrt.so"
  "yolo-model|1800|[[ -z '$MODEL' ]] && echo 'no --model: skipped' || $HERE/12-install-yolo-model.sh '$MODEL' Fuel Fuel"
  "fieldcal-tool|1800|$HERE/13-build-fieldcal-detect.sh --install"
  "usb-watchdog|300|$HERE/14-usb-watchdog.sh --install"
  "fake-cameras|900|sudo apt-get install -y v4l2loopback-dkms v4l2loopback-utils && if [[ -f $HOME/build/bos-detector/CMakeCache.txt ]]; then cmake --build $HOME/build/bos-detector --target far_search_test --parallel 3; elif [[ -x $HOME/build/bos-detector/far_search_test ]]; then echo 'synthetic-tag generator from the prebuilt bundle'; else echo 'no synthetic-tag generator (an older bundle): fake-cameras.sh plays real Rewind recordings'; fi"
  "robot-tuning|900|FAN=${FAN:-} $HERE/09-robot-tuning.sh"
  "restore-settings|300|restore_settings"
)
export -f restore_settings prebuilt_install; export SETTINGS PREBUILT PREBUILT_JAR HERE

# --prebuilt swaps the three builds for the bundle; without it the bundle step is skipped.
if [[ -n $PREBUILT ]]; then SKIP="allwpilib detector fieldcal-tool"; else SKIP="prebuilt"; fi
# A mistyped --from/--only (or one this install skips) would otherwise run nothing and still
# print "Setup finished".
for want in $FROM $ONLY; do
  known=0
  for s in "${STEPS[@]}"; do [[ ${s%%|*} == "$want" ]] && known=1; done
  ((known)) || { echo "No step named '$want'. Steps: $(for s in "${STEPS[@]}"; do printf '%s ' "${s%%|*}"; done)" >&2; exit 2; }
  [[ " $SKIP " != *" $want "* ]] || { echo "Step '$want' is skipped in this install (${PREBUILT:+--prebuilt}${PREBUILT:-no --prebuilt})." >&2; exit 2; }
done

started=${FROM:+0}; started=${started:-1}
for s in "${STEPS[@]}"; do
  IFS='|' read -r name limit cmd <<<"$s"
  [[ -n $ONLY && $name != "$ONLY" ]] && continue
  [[ " $SKIP " == *" $name "* ]] && continue
  [[ -n $FROM && $name == "$FROM" ]] && started=1
  [[ $started == 1 ]] || continue
  if [[ -z $ONLY && -z $FROM ]] && grep -qx "$name" "$DONE"; then echo "== $name: done before"; continue; fi
  echo "== $name (limit $((limit / 60)) min, log $LOGS/$name.log) $(date +%T)"
  t0=$SECONDS
  # errexit and pipefail inside each step: a failing command in the middle (or on the left of a
  # pipe, like smartctl | tee) fails the step instead of being hidden by the last command's 0.
  timeout -k 30 "$limit" bash -c "set -eo pipefail; $cmd" >"$LOGS/$name.log" 2>&1; rc=$?
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "TIMEOUT: $name ran past $((limit / 60)) min. Last lines of its log:"; tail -15 "$LOGS/$name.log"; exit 1
  elif [[ $rc -ne 0 ]]; then
    echo "FAILED: $name (exit $rc). Last lines of its log:"; tail -25 "$LOGS/$name.log"
    echo "Fix it, then run $0 again to carry on from here."; exit 1
  fi
  grep -qx "$name" "$DONE" || echo "$name" >> "$DONE"
  echo "   ok in $(( (SECONDS - t0) / 60 )) min $(( (SECONDS - t0) % 60 )) s"
done

echo "== health check"
hc=$(sudo "$HERE/health-check.sh" 2>&1); hc_rc=$?
tail -40 <<<"$hc"
echo "Setup finished. Reboot once (sudo reboot) so the boot-time settings take effect."
# Before the first reboot some checks can't pass yet (clocks, the camera driver); say so plainly.
((hc_rc == 0)) || echo "NOTE: the health check reported FAIL lines above. Reboot, then run scripts/jetson/health-check.sh again."
