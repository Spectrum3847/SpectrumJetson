#!/usr/bin/env bash
# Run ON THE JETSON: check the NVJPG hardware JPEG decoder (libspectrumnvjpg.so) against
# libjpeg-turbo on Rewind recordings, plus bad input and 4 decoders at once. Run it after every
# L4T/JetPack update: the obvious way of calling libnvjpeg once returned stale frames with no
# error (docs/VISION-RESEARCH.md), so the output is checked pixel for pixel.
#
#   tests/jpeg-hw/run.sh [file.mjpeg...]   (default: every camera of the 3 newest sessions, plus
#                                          colour recordings from make-colour-recordings.py)
#   LIB=<path> tests an uninstalled build (default ~/build/bos-detector/libspectrumnvjpg.so,
#   else /usr/lib/libspectrumnvjpg.so).
set -uo pipefail
cd "$(dirname "$0")" || exit
lib=${LIB:-$HOME/build/bos-detector/libspectrumnvjpg.so}
[[ -f $lib ]] || lib=/usr/lib/libspectrumnvjpg.so
[[ -f $lib ]] || { echo "No libspectrumnvjpg.so; build it with scripts/jetson/07-build-bos-detector.sh" >&2; exit 1; }

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  mapfile -t files < <(ls -d /opt/photonvision/rewind/sessions/*/ 2>/dev/null | sort | tail -3 |
                       while read -r s; do ls "$s"*/0000.mjpeg 2>/dev/null; done)
fi
[[ ${#files[@]} -gt 0 ]] || { echo "No Rewind recordings found; pass .mjpeg files" >&2; exit 1; }
# Colour content (our cameras are mono): real photos as 4:2:2, 4:2:0 and 4:4:4 JPEGs.
if [[ $# -eq 0 ]]; then
  colour=/tmp/jpeg-hw-colour
  [[ -f $colour/colour_422_q80.mjpeg ]] || ./make-colour-recordings.py "$colour" >/dev/null || exit 1
  files+=("$colour"/colour_*.mjpeg)
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
g++ -O2 -std=c++17 NvjpgCheck.cc -o "$tmp/NvjpgCheck" -ljpeg -ldl -lpthread || exit 1
echo "Library: $lib"
"$tmp/NvjpgCheck" "$lib" "${files[@]}"
