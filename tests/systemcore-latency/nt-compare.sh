#!/bin/bash
# What the robot receives: PhotonVision (Java publish vs the fast path's native publish) vs sc-vision, measured by a
# PhotonLib-style NT subscriber on the same SystemCore (nt_probe: capture timestamp -> received, results/s, ambiguity,
# corners, health). Thriftiest, our uvcvideo urb_packets=2, CD settings, min 32, governor as it is. Short runs.
#   nt-compare.sh [SECS] [CONFIGS]     default 15 s, "pvjava pvnative scv"
# Both publishers stamp capture = first bytes/packet - (exposure/2 + camera delay, 2.5 ms before 2026-11-06, now 0.4 ms); PhotonVision's "first bytes" are when
# its watcher saw the first 0.25 ms URB (up to ~0.3 ms after sc-vision's first-packet estimate), so PhotonVision's
# capture -> received reads up to ~0.3 ms shorter than the same delay for sc-vision.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/../../scripts/systemcore/uvcvideo-load.sh
secs=${1:-15}
configs=${2:-pvjava pvnative scv}
OUT=${OUT:-$HOME/shared/latency/nt}
CAM=${CAM:-thrifty}   # the PhotonVision / sc-vision camera name (topic)
SCV_ARGS=${SCV_ARGS:---serial SJ-05 --cpu 3 --fifo 40 --pkts 2 --exposure 2 --gain 128 --gamma 100 --backlight 0 --sharpness 1 --min-tag 22 --calib /opt/sc-vision/etc/calib.json}
mkdir -p "$OUT"
DROPIN=/etc/systemd/system/photonvision.service.d/zz-ntcompare.conf
PROBE=/opt/sc-vision/bin/nt_probe
exec 9>/tmp/camera.lock
flock -w 120 9 || { echo "camera busy"; exit 1; }
export SC_VISION_HAVE_LOCK=1
cleanup() {
  sudo -n systemctl stop photonvision 2>/dev/null
  sudo -n rm -f "$DROPIN"; sudo -n systemctl daemon-reload
  "$L" stock >/dev/null
}
trap cleanup EXIT
ticks() { sudo -n awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
"$L" urb 2
S="SPECTRUM_IDLE_FPS=0 SPECTRUM_SYSTEMCORE_PROFILE=0 SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec"
for c in $configs; do
  case $c in
    pvjava|pvnative)
      { printf '[Service]\n'; for v in $S; do printf 'Environment=%s\n' "$v"; done
        [[ $c == pvnative ]] && printf 'Environment=SPECTRUM_NATIVE_PUBLISH=1\n'; } | sudo -n tee "$DROPIN" >/dev/null
      sudo -n systemctl daemon-reload; sudo -n systemctl start photonvision
      sleep 45
      pid=$(systemctl show -p MainPID --value photonvision)
      ;;
    scv)
      # shellcheck disable=SC2086
      sudo -n /opt/sc-vision/bin/sc-vision $SCV_ARGS --nt 127.0.0.1 --name "$CAM" --secs $((secs + 8)) \
        > "$OUT/scv.log" 2>&1 &
      sleep 4
      pid=$(pidof sc-vision | cut -d" " -f1)
      ;;
  esac
  t0=$(ticks "$pid")
  "$PROBE" 127.0.0.1 "$CAM" "$secs" > "$OUT/$c.probe" 2>&1
  t1=$(ticks "$pid")
  echo "proc_pct_of_1 $(awk -v p=$((t1 - t0)) -v s="$secs" 'BEGIN{printf "%.1f", p/s}')" > "$OUT/$c.cpu"
  if [[ $c == scv ]]; then wait; else
    journalctl -u photonvision --since "-$((secs + 5))s" --no-pager | grep -o -E "NAPA streaming: .*|native publish.*" | tail -2 > "$OUT/$c.journal"
    sudo -n systemctl stop photonvision
  fi
done
for c in $configs; do
  printf '== %s: %s\n' "$c" "$(cat "$OUT/$c.cpu")"
  grep -E "results|poseAmbiguity|health" "$OUT/$c.probe"
done
