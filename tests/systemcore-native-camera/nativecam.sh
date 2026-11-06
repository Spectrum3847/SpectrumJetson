#!/usr/bin/env bash
# Native camera backend (NativeCameraSource: no cscore UsbCamera), one camera live, ON THE SYSTEMCORE:
#   nativecam.sh OUT CAMERA [SECS]      CAMERA: PhotonVision nickname(s), comma-separated (swyft | thrifty |
#                                       swyft,thrifty for both in one PV); SECS default 12
# Holds /tmp/camera.lock for the whole run. Stops PV and limelight_visionserver, backs up photon.sqlite (SQLite
# backup API + integrity_check, ~/bench/scmn/pvdb.py), leaves only CAMERA active, loads the small-URB uvcvideo
# (urb 2), adds a TEMPORARY drop-in (stream decoder, mjdec, streaming NAPA + EXTRA_ENV), starts PV,
# waits WARM s (default 10), then for SECS: device ownership (who has /dev/video* open), nt_check, per-thread CPU.
# Afterwards: PV stopped, drop-in removed, DB restored exactly, the driver as it was, the Swyft's exposure written back
# only if the run changed it, PV back to its previous state. PV runs WARM + SECS + ~3 s in all (keep it <= 30).
#   SET="cameraExposureRaw=300"   pipeline settings for CAMERA in the run's DB (dark room: Swyft 300 sees tags)
#   EXTRA_ENV="K=V K=V"           more environment for PV (e.g. SPECTRUM_NATIVE_CAMERA=0 for the fast path)
#   EXTRA_CMD="..."               run (bash -c) during the measurement, output to OUT/extra.txt
set -uo pipefail
OUT=${1:?OUT}
CAM=${2:?CAMERA}
SECS=${3:-12}
MINTAG=${MINTAG:-22}  # every camera's NAPA min tag for the run (tests default to 22: the measured sweet spot)
WARM=${WARM:-10}
B=$HOME/bench/scmn
DB=/opt/photonvision/photonvision_config/photon.sqlite
BK=$HOME/builder/photon.sqlite.builder2-$(date +%H%M%S)
DROP=/etc/systemd/system/photonvision.service.d/zz-builder2.conf
LOAD=$HOME/builder/scripts/systemcore/uvcvideo-load.sh
SW=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 600 9 || { echo "camera lock busy" >&2; exit 1; }
was=$(systemctl is-active photonvision)
sw0=$(v4l2-ctl -d "$SW" -C exposure_time_absolute 2>/dev/null | awk '{print $2}')
backed=0
swapped=0
cleanup() {
  sudo systemctl stop photonvision
  sudo rm -f "$DROP"
  sudo systemctl daemon-reload
  if ((backed)); then
    sudo python3 "$B/pvdb.py" restore "$BK" "$DB" && echo "DB restored from $BK" || echo "DB RESTORE FAILED ($BK)" >&2
  fi
  ((swapped)) && SC_VISION_HAVE_LOCK=1 bash "$LOAD" stock >/dev/null
  local now=""
  for _ in $(seq 20); do
    now=$(v4l2-ctl -d "$SW" -C exposure_time_absolute 2>/dev/null | awk '{print $2}')
    [[ -n $now ]] && break
    sleep 0.5
  done
  if [[ -z $sw0 || -z $now ]]; then
    echo "WARNING: Swyft exposure unreadable (before '$sw0', after '$now'): check by hand" >&2
  elif [[ $now != "$sw0" ]]; then
    v4l2-ctl -d "$SW" -c exposure_time_absolute="$sw0" && echo "Swyft exposure restored $now -> $sw0"
  fi
  sudo systemctl stop limelight_visionserver 2>/dev/null
  [[ $was == active ]] && sudo systemctl start photonvision
}
trap cleanup EXIT
sudo systemctl stop photonvision limelight_visionserver
sudo python3 "$B/pvdb.py" backup "$DB" "$BK" || exit 1
backed=1
# only CAMERA active for this run
sudo python3 - "$DB" "$CAM" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for uniq, contents in db.execute("select unique_name, contents from cameras").fetchall():
    c = json.loads(contents)
    c["deactivated"] = c.get("nickname") not in sys.argv[2].split(",")
    db.execute("update cameras set contents = ? where unique_name = ?", (json.dumps(c), uniq))
db.commit()
print(db.execute("pragma integrity_check").fetchone()[0])
PY
sudo python3 "$B/pvdb.py" mintag "$DB" "$MINTAG" >/dev/null
# SET applies to the first camera named (e.g. the Swyft's exposure in the dark)
# shellcheck disable=SC2086
[[ -n ${SET:-} ]] && sudo python3 "$B/pvdb.py" set "$DB" "${CAM%%,*}" $SET
# our uvcvideo (urb 2, camera clock): loaded at boot by sc-uvcvideo.service; swapped in (and back) only if not
if [[ ! -f /sys/module/uvcvideo/parameters/urb_packets ]]; then
  SC_VISION_HAVE_LOCK=1 bash "$LOAD" urb 2 >/dev/null
  swapped=1
fi
{
  printf '[Service]\n'
  for kv in SPECTRUM_JPEG_DECODER=stream SPECTRUM_NAPA_STREAM=1 SPECTRUM_STREAM_DECODER=mjdec \
    ${EXTRA_ENV:-}; do
    printf 'Environment=%s\n' "$kv"
  done
} | sudo tee "$DROP" >/dev/null
sudo systemctl daemon-reload
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor); env: $(grep -h Environment "$DROP" | cut -d= -f2- | tr '\n' ' ')"
t0=$(date +%s)
sudo systemctl start photonvision
sleep "$WARM"
pid=$(systemctl show -p MainPID --value photonvision)
{
  echo "== who has the video nodes open (PV pid $pid)"
  for v in /dev/video*; do
    users=$(sudo fuser "$v" 2>/dev/null)
    echo "$v -> $(readlink -f "$v") users:${users:- none}"
  done
  echo "== PV's video fds"
  sudo ls -l "/proc/$pid/fd" 2>/dev/null | grep -E "video" || echo "(none)"
} >"$OUT/owners.txt"
sudo python3 "$B/topcpu.py" "$SECS" 12 >"$OUT/cpu.txt" &
for c in ${CAM//,/ }; do
  "$HOME/bench/bin/nt_check" --camera "$c" --secs "$SECS" --dump 0 --csv "$OUT/$c.csv" 2>&1 |
    grep -v -E '^NT:|topic /photon' >"$OUT/$c.nt" &
done
[[ -n ${EXTRA_CMD:-} ]] && bash -c "$EXTRA_CMD" >"$OUT/extra.txt" 2>&1 &
wait
sudo journalctl -u photonvision --since "@$t0" --no-pager |
  grep -i -E "native|handover|moved|exception|error" | cut -c1-260 | tail -40 >"$OUT/pv.journal"
echo "PV ran $(($(date +%s) - t0)) s"
cat "$OUT/owners.txt"
for c in ${CAM//,/ }; do
  echo "== $c"
  grep -E "results in|capture ->|tagQuality|^  id |health" "$OUT/$c.nt"
done
head -10 "$OUT/cpu.txt"
cat "$OUT/pv.journal"
