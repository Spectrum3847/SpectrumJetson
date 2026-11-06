#!/usr/bin/env bash
# Both cameras in one PhotonVision for pvmulti.sh, inside ONE /tmp/camera.lock hold, ON THE PI:
#   pvboth.sh OUT [SECS]
# stop PV -> SQLite-API backup of photon.sqlite (+ integrity_check) -> activate both cameras -> pvmulti.sh ->
# stop PV -> restore exactly that backup (+ integrity_check) -> PV back to its previous state. Posts START/DONE in
# ~/shared/FINDINGS.md.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
SECS=${2:-20}
DB=/opt/photonvision/photonvision_config/photon.sqlite
BK=$HOME/bench/photon.sqlite.tester-$(date +%H%M%S)
note() { printf '\n%s\n' "$1" >/tmp/sec.md; awk 'BEGIN{d=0} {print} /^---$/ && !d {while((getline l < "/tmp/sec.md")>0) print l; d=1}' ~/shared/FINDINGS.md >/tmp/f.md && mv /tmp/f.md ~/shared/FINDINGS.md; }
mkdir -p "$OUT"
exec 9>/tmp/camera.lock
flock -w 600 9 || { echo "camera lock busy" >&2; exit 1; }
was=$(systemctl is-active photonvision)
note "PV DB EDIT START $(date +%T) (tester, holding /tmp/camera.lock): backup $BK, both cameras activated for pvmulti.sh, then restore."
sudo systemctl stop photonvision
sudo python3 "$HERE/pvdb.py" backup "$DB" "$BK" || { note "PV DB EDIT ABORTED $(date +%T): backup/integrity failed, DB untouched"; exit 1; }
sudo python3 "$HERE/pvdb.py" activate "$DB" thrifty swyft
[[ -n ${MINTAG:-} ]] && sudo python3 "$HERE/pvdb.py" mintag "$DB" "$MINTAG"  # same min_tag on both cameras
# SWYFT_SET="cameraExposureRaw=300 ...": extra pipeline settings for the Swyft in the run's DB (detection-only runs)
# shellcheck disable=SC2086
[[ -n ${SWYFT_SET:-} ]] && sudo python3 "$HERE/pvdb.py" set "$DB" swyft $SWYFT_SET
SW=/dev/v4l/by-id/usb-Generic_USB_Camera_SJ-SW01-video-index0
sw_exp0=$(v4l2-ctl -d "$SW" -C exposure_time_absolute 2>/dev/null | awk '{print $2}')
SCMN_HAVE_LOCK=1 "$HERE/pvmulti.sh" "$OUT" "$SECS"
sudo systemctl stop photonvision
sudo python3 "$HERE/pvdb.py" restore "$BK" "$DB"
rc=$?
# the Swyft stores controls in flash: write its exposure back only if the run changed it
now=$(v4l2-ctl -d "$SW" -C exposure_time_absolute 2>/dev/null | awk '{print $2}')
if [[ -n $sw_exp0 && -n $now && $now != "$sw_exp0" ]]; then
  v4l2-ctl -d "$SW" -c exposure_time_absolute="$sw_exp0" && echo "Swyft exposure restored $now -> $sw_exp0"
fi
[[ $was == active ]] && sudo systemctl start photonvision
note "PV DB EDIT DONE $(date +%T): restored from $BK (integrity $( ((rc == 0)) && echo ok || echo FAILED)); PV $(systemctl is-active photonvision)."
