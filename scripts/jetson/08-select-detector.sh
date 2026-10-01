#!/usr/bin/env bash
# Choose which lib971apriltag.so PhotonVision loads, and its runtime options.
# Run ON THE JETSON. Both builds have the same Java API.
#
# Usage: 08-select-detector.sh 4143|bos [--mwbd N] [--jpeg nvjpg|turbo] [--mse N]
#                              [--gpu-connections N] [--no-restart]
#   4143   FRC-Team-4143/GpuDetectorJNI + our patches (05-build-gpudetector.sh)
#   bos    Austin's current detector via frc971/bos (07-build-bos-detector.sh)
#   --mwbd N         min_white_black_diff (bos build only; default 5)
#   --mse N          max_line_fit_mse (bos build only; default 10). Lower (e.g. 2.5, upstream
#                    PhotonVision #2138) rejects tags cut off at the image edge; test range first.
#   --jpeg nvjpg     decode camera JPEGs on the NVJPG hardware engine (bos build only; default
#                    turbo = libjpeg-turbo on the CPU). Check it first with tests/jpeg-hw/run.sh.
#                    For a quick A/B without a restart: echo turbo > /tmp/spectrum-jpeg-decoder
#   --gpu-connections N  CUDA_DEVICE_MAX_CONNECTIONS, the GPU's hardware work queues (default
#                    32; CUDA's own default is 8). With 4 cameras, runs with 32 had ~0.5 ms
#                    lower worst-frame detect times on average: likely but unproven, since the
#                    same setting varies 2 ms between restarts. No CPU or GPU cost.
# Options not given go back to their defaults.
# (Fault injection for testing: echo N > /tmp/spectrum-971-fault-every; rm it to stop.)
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

which=${1:?usage: $0 4143|bos [--mwbd N] [--jpeg nvjpg|turbo] [--mse N] [--gpu-connections N] [--no-restart]}
shift
mwbd=""
jpeg=""
mse=""
connections=32
restart=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --mwbd) mwbd=$2; shift 2 ;;
    --mse) mse=$2; shift 2 ;;
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
  4143) lib=$HOME/build/GpuDetectorJNI/build/lib971apriltag.so ;;
  bos) lib=$HOME/build/bos-detector/lib971apriltag.so ;;
  *) echo "first argument must be 4143 or bos" >&2; exit 1 ;;
esac
[[ -f $lib ]] || { echo "Missing $lib; build it first." >&2; exit 1; }

nvjpg=$(dirname "$lib")/libspectrumnvjpg.so
if [[ $jpeg == nvjpg && ( $which != bos || ! -f $nvjpg ) ]]; then
  echo "--jpeg nvjpg needs the bos build's libspectrumnvjpg.so (07-build-bos-detector.sh)" >&2
  exit 1
fi

sudo install -m 755 "$lib" /usr/lib/lib971apriltag.so
if [[ $which == bos && -f $nvjpg ]]; then
  sudo install -m 755 "$nvjpg" /usr/lib/libspectrumnvjpg.so
fi

dropin=/etc/systemd/system/photonvision.service.d/971.conf
env_lines="Environment=CUDA_DEVICE_MAX_CONNECTIONS=$connections"$'\n'
[[ -n $mwbd ]] && env_lines+="Environment=SPECTRUM_971_MIN_WHITE_BLACK_DIFF=$mwbd"$'\n'
[[ -n $mse ]] && env_lines+="Environment=SPECTRUM_971_MAX_LINE_FIT_MSE=$mse"$'\n'
[[ $jpeg == nvjpg ]] && env_lines+="Environment=SPECTRUM_JPEG_DECODER=nvjpg"$'\n'
printf '[Service]\n%s' "$env_lines" | sudo tee "$dropin" >/dev/null
sudo systemctl daemon-reload

echo "Selected $which detector${mwbd:+, min_white_black_diff $mwbd}${mse:+, max_line_fit_mse $mse}${jpeg:+, JPEG decoder $jpeg}, $connections GPU connections"
if [[ $restart -eq 1 ]]; then
  sudo systemctl restart photonvision
fi
