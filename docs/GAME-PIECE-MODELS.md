# FUEL game-piece models (2026)

The models we have for PhotonVision's TensorRT backend (`photonvision-14`), how they were made, and
which to use. Prepared 2026-09-24 by a Claude subagent; setup and usage are in the
[README](../README.md#game-piece-detection-tensorrt).

## Models

| | Wave Robotics 2826, YOLO11n | Project516, YOLO26n (v1) |
|---|---|---|
| Source | [Chief Delphi thread](https://www.chiefdelphi.com/t/introducing-wave-robotics-yolov11-model-for-rebuilt/512701) (Google Drive `PyTorch_model.pt`) | [Hugging Face](https://huggingface.co/project516/rebuilt-fuel-model) `rebuilt-fuel-model-v1.pt` |
| License | None stated; carries Ultralytics' AGPL-3.0 stamp. Wave gave PhotonVision (GPLv3) permission, and it ships in PhotonVision. | AGPL-3.0 |
| Class | `object` (we label it `Fuel`) | `fuel` |
| Trained on | ~60 photos augmented to ~2,600, 640 px | ~53 phone photos, 640 px |
| sha256 (.pt) | `2d0f99d2…` | `94954a46…` |

## Exports and engines

- **Exported on the laptop** with Ultralytics 8.4.161: `format=onnx imgsz=640 batch=1 dynamic=False opset=17 simplify=True`, plus an explicit `nms` setting.
  - The venv is `~/build/yolo/venv`, and the export script is `~/build/yolo/export_fuel.py`.
  - The ONNX files are in `staging/fuel-models/` (not in git) and `~/models` on the Jetson.
- **Engines are built on the Jetson** with `trtexec --fp16` (TensorRT 10.3, ~7–8 min each, no warnings). `scripts/jetson/12-install-yolo-model.sh` does this and installs the result.

| Variant | Output | Use |
|---|---|---|
| `*_raw` (`nms=None`) | `[1, 5, 8400]`: cx, cy, w, h, score (already sigmoid) | **Recommended.** Our runner does NMS, thresholds are tunable, and inference is fully async. |
| `*_nms` (`nms=True`) | `[1, 300, 6]`: x1, y1, x2, y2, score, class | Works (runner fallback). NMS is baked in (conf 0.25, IoU 0.7), and the CPU thread blocks for the whole inference. |
| `*_e2e` (YOLO26 `nms=False`) | `[1, 300, 6]`, all rows filled | **Avoid:** this checkpoint's NMS-free head missed a small ball and added false boxes (the same happens in PyTorch). |

**Checks:**
- The FP16 engine outputs match the FP32 ONNX outputs (box overlap ≥ 0.987).
- The raw and NMS variants found all 4 balls in 3 test photos.
- Those photos are probably Project516's training data, so this proves correctness, not accuracy.

**Speed** (`trtexec`, GPU compute, sharing the GPU with PhotonVision): 4.3–5.5 ms mean, 5.0–9.9 ms p99.
In PhotonVision the full pipeline (colour decode, letterbox, inference, NMS) ran at 76 fps uncapped;
we cap it at 30 fps.

## Which to use

- **Now:** `wave2826_yolo11n_fuel_raw`. It's installed on the Jetson as "Fuel (Wave 2826 YOLO11n)", and it's the model PhotonVision ships.
- **Next:** A/B it against `project516_yolo26n_fuel_v1_raw` (same input and output, ~17% fewer FLOPs, similar speed) on footage from our own colour camera. Rewind recordings are good for this.
- **By October:** fine-tune on our own camera's frames, with motion blur, bumpers and yellow distractors, and keep the 640 input. Through an ultrawide lens, a ball 5 m away is only ~9 px wide at 640.
- **Rebuild the engines** from the ONNX after any JetPack or TensorRT change. Engines only run on the TensorRT version and GPU they were built for.

Camera hardware for game pieces (colour, global shutter, USB 3): see [CAMERA-OPTIONS.md](CAMERA-OPTIONS.md).
