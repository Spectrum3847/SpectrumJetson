#!/usr/bin/env bash
# Install a YOLO object-detection model (e.g. a FUEL game-piece detector) into PhotonVision's
# TensorRT backend (patch photonvision-14 + libspectrumtrt.so). Run ON THE JETSON.
#
# TensorRT engines only run on the GPU and TensorRT version they were built with, so the engine
# is built here from an ONNX export (Ultralytics: format=onnx imgsz=640 opset=17 simplify=True,
# static shape, batch 1). Either output layout works: raw ([1, 4+nc, N]; nms=None) or end-to-end
# ([1, K, 6]; nms=True). Building takes several minutes and uses the GPU, so AprilTag fps dips
# while it runs: do it in the pit, not on the field.
#
# Usage:
#   12-install-yolo-model.sh <model.onnx|model.engine> <nickname> <labels> [width height] [version]
#     labels    comma-separated class names, e.g. "Fuel"
#     version   YOLOV8 or YOLOV11 (default; use YOLOV11 for YOLO26 too: the backend reads the
#               output layout from the engine)
# Example:
#   12-install-yolo-model.sh ~/models/wave2826_yolo11n_fuel_raw.onnx "Fuel (Wave 2826)" Fuel
# Then pick the model in the camera's Object Detection pipeline in the web UI.
set -euo pipefail
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }
SRC=${1:?usage: $0 <model.onnx|model.engine> <nickname> <labels> [width height] [version]}
NICK=${2:?nickname}
LABELS=${3:?labels, comma-separated}
W=${4:-640}
H=${5:-640}
VERSION=${6:-YOLOV11}
MODELS=/opt/photonvision/photonvision_config/models
TRTEXEC=/usr/src/tensorrt/bin/trtexec
[[ -f /usr/lib/libspectrumtrt.so ]] || { echo "libspectrumtrt.so isn't installed (07-build-bos-detector.sh, then install it to /usr/lib)." >&2; exit 1; }

name=$(basename "${SRC%.*}")
name=${name//[^A-Za-z0-9._-]/_}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case $SRC in
  *.onnx)
    echo "==> Building a TensorRT FP16 engine from $SRC (several minutes)"
    "$TRTEXEC" --onnx="$SRC" --saveEngine="$tmp/$name.engine" --fp16 \
      --memPoolSize=workspace:1024M --skipInference > "$tmp/build.log" 2>&1 \
      || { tail -20 "$tmp/build.log"; echo "trtexec failed" >&2; exit 1; }
    grep -E "Engine built in|Created engine" "$tmp/build.log" | tail -1 || true
    ;;
  *.engine) cp "$SRC" "$tmp/$name.engine" ;;
  *) echo "Expected a .onnx or .engine file" >&2; exit 1 ;;
esac

python3 - "$tmp/$name.json" "$NICK" "$LABELS" "$W" "$H" "$VERSION" <<'PY'
import json, sys
out, nick, labels, w, h, version = sys.argv[1:7]
json.dump({"nickname": nick, "labels": [l.strip() for l in labels.split(",") if l.strip()],
           "width": int(w), "height": int(h), "version": version}, open(out, "w"), indent=2)
PY
sudo install -m 644 "$tmp/$name.engine" "$MODELS/$name.engine"
sudo install -m 644 "$tmp/$name.json" "$MODELS/$name.json"
echo "==> Installed $MODELS/$name.engine (+ $name.json)"
echo "==> Restarting PhotonVision to pick it up"
sudo systemctl restart photonvision
