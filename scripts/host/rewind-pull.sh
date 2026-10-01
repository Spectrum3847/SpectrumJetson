#!/usr/bin/env bash
# Copy Rewind recordings from the Jetson to this laptop and export them to video.
# Run ON THE LAPTOP, over Ethernet or the USB-C cable (a match is ~1-2 GB: not over the radio).
#
# Usage: rewind-pull.sh [--list] [--all] [--mp4] [SESSION_NAME_OR_PART ...]
#   (no names)   the newest recording
#   --list       list the recordings on the Jetson and exit
#   --all        every recording
#   Q12          any recording whose name contains "Q12"
#   --mp4        also make H.264 .mp4 files (needs ffmpeg: sudo apt install ffmpeg)
#
# Environment: JETSON (default 192.168.55.1, the USB-C cable; 10.85.15.15 on the robot),
#              DEST (default ~/rewind).
set -euo pipefail
JETSON=${JETSON:-192.168.55.1}
DEST=${DEST:-$HOME/rewind}
KEY=${KEY:-$HOME/.ssh/jetson_ed25519}
JETSON_USER=${JETSON_USER:-spectrum3847}
REMOTE=/opt/photonvision/rewind/sessions
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=(ssh -i "$KEY" -o ConnectTimeout=5 "$JETSON_USER@$JETSON")

mp4=() all=0 list=0 want=()
for a in "$@"; do
  case $a in
    --mp4) mp4=(--mp4) ;;
    --all) all=1 ;;
    --list) list=1 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) want+=("$a") ;;
  esac
done

mapfile -t sessions < <("${SSH[@]}" "ls -1 $REMOTE 2>/dev/null")
if [[ ${#sessions[@]} -eq 0 ]]; then echo "No recordings on the Jetson ($JETSON)."; exit 0; fi
if [[ $list == 1 ]]; then
  "${SSH[@]}" "cd $REMOTE && du -sh -- * | sort -k2"
  exit 0
fi

pick=()
if [[ $all == 1 ]]; then pick=("${sessions[@]}")
elif [[ ${#want[@]} -eq 0 ]]; then pick=("${sessions[-1]}")
else
  for w in "${want[@]}"; do
    for s in "${sessions[@]}"; do [[ $s == *"$w"* ]] && pick+=("$s"); done
  done
fi
[[ ${#pick[@]} -gt 0 ]] || { echo "No recording matches: ${want[*]} (try --list)"; exit 1; }

mkdir -p "$DEST"
for s in "${pick[@]}"; do
  echo "==> $s"
  rsync -a --info=progress2 -e "ssh -i $KEY" "$JETSON_USER@$JETSON:$REMOTE/$s" "$DEST/"
  python3 "$HERE/rewind-export.py" "$DEST/$s" "${mp4[@]}"
done
echo
echo "Videos are in $DEST/<recording>/export/"
