#!/bin/bash
# PhotonVision (the user's Chief Delphi NAPA post #46 setup) vs sc-vision, same camera settings, on the SystemCore.
#   post-compare.sh [SECS] [MINTAGS]       default 30 s, min tag px "32 16"
# Camera: 1280x800 MJPEG 120 fps, exposure_time_absolute 2 ("0.2 ms"), gain 128, gamma 100, backlight comp 0.
# PhotonVision: whole-frame NAPA (SPECTRUM_NAPA_STREAM=0), libjpeg-turbo CPU decode (SPECTRUM_JPEG_DECODER=turbo),
# no SystemCore 50 fps cap (SPECTRUM_SYSTEMCORE_PROFILE=0), no idle mode, max hamming 1, single tag.
# Also PhotonVision with the stream decoder + streaming NAPA, and sc-vision under CFS and SCHED_FIFO.
# Restores the PhotonVision settings DB afterwards. Results: OUT (run.sh) *.table / *.cpu.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
secs=${1:-30}
mins=${2:-32 16}
DB=/opt/photonvision/photonvision_config/photon.sqlite
OUT=${OUT:-$HOME/shared/latency/$(date +%Y%m%d)}
export OUT
mkdir -p "$OUT"
sudo -n systemctl stop photonvision
sudo -n cp "$DB" "$OUT/photon.sqlite.post-compare.bak"
trap 'sudo -n systemctl stop photonvision; sudo -n cp "$OUT/photon.sqlite.post-compare.bak" "$DB"' EXIT
CAM="cameraAutoExposure=false cameraExposureRaw=2 cameraGain=128 cameraGamma=100 cameraBacklightCompensation=0"
NAT="--exposure 2 --gain 128 --gamma 100 --backlight 0"
CAL=${CAL:-$HOME/builder/sc-vision/cal.json}
export EXPOSURE_MS=0.2
summ() {
  local f=$OUT/$1.table
  printf '%-22s ' "$1"
  grep -E "^(TOTAL mid-exposure -> pose|first USB packet -> pose|V4L2 timestamp -> pose)" "$f" | awk '{printf "%s %s/%s/%s | ", $1" "$2" "$3, $(NF-2), $(NF-1), $NF}'
  awk '{printf "sys %s%% of 4, proc %s%% of 1 core (%.1f%% of system)", $2, $4, $4/4}' "$OUT/$1.cpu"
  grep -h -E "^frames with a tag" "$f" | sed 's/^/ | /'
  echo
}
for m in $mins; do
  # shellcheck disable=SC2086
  sudo -n python3 "$HERE/pv-config.py" napa=true napaMinTagPx="$m" napaMaxHamming=1 napaFarSearch=false tagFpsMax=0 $CAM >/dev/null
  "$HERE/run.sh" pv "$secs" "pv-post-m$m" SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_NAPA_STREAM=0 \
    SPECTRUM_JPEG_DECODER=turbo >/dev/null 2>&1
  "$HERE/run.sh" pv "$secs" "pv-stream-m$m" SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_NAPA_STREAM=1 \
    SPECTRUM_JPEG_DECODER=stream SPECTRUM_STREAM_DECODER=mjdec >/dev/null 2>&1
  # shellcheck disable=SC2086
  "$HERE/run.sh" native "$secs" "nat-cfs-m$m" --cpu 3 --pkts 2 --min-tag "$m" $NAT --calib "$CAL" >/dev/null 2>&1
  # shellcheck disable=SC2086
  "$HERE/run.sh" native "$secs" "nat-fifo-m$m" --cpu 3 --fifo 40 --pkts 2 --min-tag "$m" $NAT --calib "$CAL" >/dev/null 2>&1
done
for m in $mins; do
  for n in pv-post-m$m pv-stream-m$m nat-cfs-m$m nat-fifo-m$m; do summ "$n"; done
done
