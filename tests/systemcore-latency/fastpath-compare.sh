#!/bin/bash
# PhotonVision's stream path steps toward the fast path vs sc-vision, Thriftiest only, on our uvcvideo
# (urb_packets 2, driver wake), CD settings, min 32, the governor as it is (ondemand while the bench supply is weak).
#   fastpath-compare.sh [SECS] [STEPS]     default 20 s, steps "copy nocopy scv"
#     copy    PV stream decode (mjdec) + streaming NAPA, image copied into the pipeline (SPECTRUM_STREAM_NOCOPY=0)
#     nocopy  the same without the 1 MB image copy while nobody watches the stream (Java pose)
#     nativepose  nocopy + the native IPPE+GN pose (NapaDetectorJNI.poseSquare) instead of the Java pose
#     scv     sc-vision
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/../../scripts/systemcore/uvcvideo-load.sh
secs=${1:-20}
steps=${2:-copy nocopy nativepose scv}
trap '"$L" stock >/dev/null; echo "restored: stock uvcvideo"' EXIT
export OUT=${OUT:-$HOME/shared/latency/fastpath} KTRACE_PSIZE=1600
mkdir -p "$OUT"
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec"
"$L" urb 2
for s in $steps; do
  # shellcheck disable=SC2086
  case $s in
    copy) "$HERE/run.sh" pv "$secs" pv-copy $S SPECTRUM_STREAM_NOCOPY=0 >/dev/null 2>&1 ;;
    nocopy) "$HERE/run.sh" pv "$secs" pv-nocopy $S SPECTRUM_NATIVE_POSE=0 >/dev/null 2>&1 ;;
    nativepose) "$HERE/run.sh" pv "$secs" pv-nativepose $S >/dev/null 2>&1 ;;
    scv) EXPOSURE_MS=0.2 "$HERE/run.sh" native "$secs" scv --serial SJ-05 --cpu 3 --fifo 40 --pkts 2 --exposure 2 \
           --gain 128 --gamma 100 --backlight 0 --sharpness 1 --min-tag 22 --calib /opt/sc-vision/etc/calib.json \
           >/dev/null 2>&1 ;;
  esac
done
for s in $steps; do
  n=pv-$s; [[ $s == scv ]] && n=scv
  printf '%-10s ' "$n"
  grep -E "^(first USB packet -> pose|TAIL last packet -> (tags|pose))" "$OUT/$n.table" |
    awk '{printf "%s %s/%s/%s | ", $1" "$2, $(NF-2), $(NF-1), $NF}'
  awk '{printf "proc %s%% of a core, %s kHz", $4, $6/1000}' "$OUT/$n.cpu"
  [[ -f $OUT/$n.journal ]] && grep -h -o -E "NAPA streaming: [0-9]+ streamed, [0-9]+ whole-frame" "$OUT/$n.journal" | tail -1 | sed 's/^/ | /'
  echo
done
