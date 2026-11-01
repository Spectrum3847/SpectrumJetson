#!/usr/bin/env bash
# Install a YOLO object-detection model (ONNX) into PhotonVision's TensorRT backend
# (photonvision-100 + libspectrumtrt.so) and build its engine now, so the first pipeline that uses
# it starts at once. Run ON THE JETSON. See docs/OBJECT-DETECTION.md.
#
# The ONNX is a YOLOv8/YOLO11 detect export from Ultralytics, e.g.
#   yolo export model=best.pt format=onnx dynamic=True opset=17 simplify=True
# (dynamic=True lets one ONNX serve batches of 1-4 and any input size; a static export works too,
# at its own size and batch). The engine is built here (TensorRT engines only run on the GPU and
# TensorRT version they were built with) at the given input size, FP16, batch 1..4, and cached in
# /opt/photonvision/photonvision_config/trt-cache, where PhotonVision looks for it. Building takes
# a few minutes and uses the GPU: do it in the pit, not on the field.
#
# Usage:
#   12-install-yolo-model.sh <model.onnx> <nickname> <labels> [width height] [version]
#     labels    comma-separated class names in class order, e.g. "Fuel" or "Coral,Algae"
#     width height  the network input, multiples of 32 (default 640 640; 640 384 suits a 16:10
#               camera: same detail, ~40% less work)
#     version   YOLOV8 or YOLOV11 (default; informational: the backend reads the output layout)
# Example:
#   12-install-yolo-model.sh ~/models/fuel_yolo11n.onnx "Fuel YOLO11n" Fuel 640 384
# Then pick the model in an Object Detection or AprilTag + Object pipeline in the web UI.
# You can also upload the ONNX from Settings > Object Detection; the engine is then built the first
# time a pipeline uses it.
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }
SRC=${1:?usage: $0 <model.onnx> <nickname> <labels> [width height] [version]}
NICK=${2:?nickname}
LABELS=${3:?labels, comma-separated}
W=${4:-640}
H=${5:-640}
VERSION=${6:-YOLOV11}
CONFIG=/opt/photonvision/photonvision_config
MODELS=$CONFIG/models
CACHE=$CONFIG/trt-cache
MAX_BATCH=${SPECTRUM_OD_MAX_BATCH:-4}  # must match PhotonVision's (same default)
BENCH=${TRT_YOLO_BENCH:-$HOME/build/gpu-detector/trt_yolo_bench}
[[ -f /usr/lib/libspectrumtrt.so ]] || { echo "libspectrumtrt.so isn't installed (07-build-gpu-detector.sh, then install.sh's trt-backend step)." >&2; exit 1; }
[[ $SRC == *.onnx ]] || { echo "Expected a .onnx file" >&2; exit 1; }
(( W % 32 == 0 && H % 32 == 0 )) || { echo "width and height must be multiples of 32" >&2; exit 1; }

name=$(basename "${SRC%.*}")
name=${name//[^A-Za-z0-9._-]/_}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 - "$tmp/$name.json" "$NICK" "$LABELS" "$W" "$H" "$VERSION" <<'PY'
import json, sys
out, nick, labels, w, h, version = sys.argv[1:7]
json.dump({"nickname": nick, "labels": [l.strip() for l in labels.split(",") if l.strip()],
           "width": int(w), "height": int(h), "version": version}, open(out, "w"), indent=2)
PY
sudo install -d "$MODELS" "$CACHE"
sudo install -m 644 "$SRC" "$MODELS/$name.onnx"
sudo install -m 644 "$tmp/$name.json" "$MODELS/$name.json"
echo "==> Installed $MODELS/$name.onnx (+ $name.json)"

if [[ -x $BENCH ]]; then
  echo "==> Building the TensorRT engine (${W}x${H}, FP16, batch 1..$MAX_BATCH; a few minutes)"
  sudo timeout 1800 "$BENCH" --model "$MODELS/$name.onnx" --cache "$CACHE" --size "${W}x${H}" \
    --max-batch "$MAX_BATCH" --build-only || { echo "engine build failed or TIMEOUT; PhotonVision will retry on first use" >&2; }
else
  echo "==> $BENCH not built: PhotonVision builds the engine the first time the model is used"
fi
echo "==> Restart PhotonVision to see the model (sudo systemctl restart photonvision)"
