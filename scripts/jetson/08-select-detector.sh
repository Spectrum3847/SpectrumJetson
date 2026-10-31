#!/usr/bin/env bash
# Choose which GPU AprilTag detector library (libspectrum-gpu-apriltag.so) PhotonVision loads,
# and its runtime options.
# Run ON THE JETSON. Both builds have the same Java API.
#
# Usage: 08-select-detector.sh gpu|gpu-4143 [--mwbd N] [--jpeg nvjpg|turbo] [--mse N]
#                              [--edge N] [--gpu-connections N] [--no-restart]
#   gpu       our GPU detector: Austin Schuh's CUDA AprilTag code from frc971/bos + our patches
#             (07-build-gpu-detector.sh). The one the robot uses.
#   gpu-4143  the older FRC-Team-4143/GpuDetectorJNI build + our patches (05-build-gpudetector.sh)
#   (Before 2026-10-31 these were "bos" and "4143"; both still work.)
#   --mwbd N         min_white_black_diff (gpu build only; default 20, the robot config: the detector
#                    is 30-40% faster than at the library default 5, docs/TECHNICAL.md)
#   --mse N          max_line_fit_mse (gpu build only; default 10). Lower (e.g. 2.5, upstream
#                    PhotonVision #2138) rejects tags cut off at the image edge; test range first.
#   --edge N         drop tags within N full-resolution pixels of the image edge, early in the GPU
#                    blob filter (gpu build only; default 0 = off; AOS uses 50 on corners).
#   --jpeg nvjpg     decode camera JPEGs on the NVJPG hardware engine (gpu build only; default
#                    turbo = libjpeg-turbo on the CPU). Check it first with tests/jpeg-hw/run.sh.
#                    For a quick A/B without a restart: echo turbo > /tmp/spectrum-jpeg-decoder
#   --gpu-connections N  CUDA_DEVICE_MAX_CONNECTIONS, the GPU's hardware work queues (default
#                    32; CUDA's own default is 8). With 4 cameras, runs with 32 had ~0.5 ms
#                    lower worst-frame detect times on average: likely but unproven, since the
#                    same setting varies 2 ms between restarts. No CPU or GPU cost.
# Options not given go back to their defaults.
# (Fault injection for testing: echo N > /tmp/spectrum-detector-fault-every; rm it to stop.)
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

which=${1:?usage: $0 gpu|gpu-4143 [--mwbd N] [--jpeg nvjpg|turbo] [--mse N] [--edge N] [--gpu-connections N] [--no-restart]}
shift
mwbd=20  # the robot config (JetPack 7 setup ran at 5 by leaving it out: detect 2.4 vs 1.6 ms)
jpeg=""
mse=""
edge=""
connections=32
restart=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --mwbd) mwbd=$2; shift 2 ;;
    --mse) mse=$2; shift 2 ;;
    --edge) edge=$2; shift 2
            [[ $edge =~ ^[0-9]+$ ]] || { echo "--edge must be a whole number of pixels" >&2; exit 1; } ;;
    --jpeg) jpeg=$2; shift 2
            [[ $jpeg == nvjpg || $jpeg == turbo ]] || { echo "--jpeg must be nvjpg or turbo" >&2; exit 1; } ;;
    --gpu-connections) connections=$2; shift 2
            [[ $connections =~ ^[0-9]+$ && $connections -ge 1 && $connections -le 32 ]] ||
              { echo "--gpu-connections must be 1 to 32" >&2; exit 1; } ;;
    --no-restart) restart=0; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

case $which in
  bos) echo "Note: \"bos\" is now called \"gpu\" (2026-10-31 rename)"; which=gpu ;;
  4143) echo "Note: \"4143\" is now called \"gpu-4143\" (2026-10-31 rename)"; which=gpu-4143 ;;
esac
case $which in
  gpu-4143) lib=$HOME/build/GpuDetectorJNI/build/lib971apriltag.so ;;
  gpu) lib=$HOME/build/gpu-detector/libspectrum-gpu-apriltag.so
       # Built before the rename (~/build/bos-detector/lib971apriltag.so): rerun 07 to move it.
       if [[ ! -f $lib && -f $HOME/build/bos-detector/lib971apriltag.so ]]; then
         lib=$HOME/build/bos-detector/lib971apriltag.so
       fi ;;
  *) echo "first argument must be gpu or gpu-4143" >&2; exit 1 ;;
esac
[[ -f $lib ]] || { echo "Missing $lib; build it first." >&2; exit 1; }

nvjpg=$(dirname "$lib")/libspectrumnvjpg.so
if [[ $jpeg == nvjpg && ( $which != gpu || ! -f $nvjpg ) ]]; then
  echo "--jpeg nvjpg needs the gpu build's libspectrumnvjpg.so (07-build-gpu-detector.sh)" >&2
  exit 1
fi

sudo install -m 755 "$lib" /usr/lib/libspectrum-gpu-apriltag.so
# The old name, for PhotonVision jars from before the 2026-10-31 rename (they load lib971apriltag).
sudo ln -sfn libspectrum-gpu-apriltag.so /usr/lib/lib971apriltag.so
if [[ $which == gpu && -f $nvjpg ]]; then
  sudo install -m 755 "$nvjpg" /usr/lib/libspectrumnvjpg.so
fi

# Rewritten whole each time, so settings under their old names (SPECTRUM_971_*, in 971.conf
# before the 2026-10-31 rename) are replaced by the new SPECTRUM_DETECTOR_* ones.
dropin=/etc/systemd/system/photonvision.service.d/detector.conf
old_dropin=/etc/systemd/system/photonvision.service.d/971.conf
if [[ -f $old_dropin ]]; then
  echo "Replacing $old_dropin (old SPECTRUM_971_* names) with $dropin"
  sudo rm -f "$old_dropin"
fi
# Any other drop-in (a hand-made test one) with the old names: rename them in place.
for f in /etc/systemd/system/photonvision.service.d/*.conf; do
  if [[ -f $f ]] && grep -q 'SPECTRUM_971_' "$f"; then
    echo "Renaming SPECTRUM_971_* to SPECTRUM_DETECTOR_* in $f"
    sudo sed -i 's/SPECTRUM_971_/SPECTRUM_DETECTOR_/g' "$f"
  fi
done
env_lines="Environment=CUDA_DEVICE_MAX_CONNECTIONS=$connections"$'\n'
[[ -n $mwbd ]] && env_lines+="Environment=SPECTRUM_DETECTOR_MIN_WHITE_BLACK_DIFF=$mwbd"$'\n'
[[ -n $mse ]] && env_lines+="Environment=SPECTRUM_DETECTOR_MAX_LINE_FIT_MSE=$mse"$'\n'
[[ -n $edge && $edge != 0 ]] && env_lines+="Environment=SPECTRUM_DETECTOR_EDGE_BORDER_PX=$edge"$'\n'
[[ $jpeg == nvjpg ]] && env_lines+="Environment=SPECTRUM_JPEG_DECODER=nvjpg"$'\n'
printf '[Service]\n%s' "$env_lines" | sudo tee "$dropin" >/dev/null
sudo systemctl daemon-reload

echo "Selected $which detector${mwbd:+, min_white_black_diff $mwbd}${mse:+, max_line_fit_mse $mse}${edge:+, edge border $edge px}${jpeg:+, JPEG decoder $jpeg}, $connections GPU connections"
if [[ $restart -eq 1 ]]; then
  sudo systemctl restart photonvision
fi
