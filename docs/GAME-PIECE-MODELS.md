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

- **Exported** with Ultralytics 8.4.161: `format=onnx imgsz=640 batch=1 dynamic=False opset=17 simplify=True`, plus an explicit `nms` setting.
  - `tools/fuelmodel/export.py` makes `project516_yolo26n_fuel_v1_raw.onnx` on any Linux machine, CPU only (see [its README](../tools/fuelmodel/README.md)). It pins the Hugging Face revision, checks the checkpoint's SHA-256, and fails unless the output is `[1, 5, 8400]`.
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

## Accuracy on the rebuilt-fuel photos

`tools/fuelmodel/eval.py` scores both models the same way: the photo letterboxed to 640 px, NMS at
IoU 0.45 (PhotonVision's default), then COCO-style AP. Team 2826's model here is PhotonVision's
int8 TFLite (`fuelV1-yolo11n.tflite`), not the FP16 engine we run, so its numbers may be a little
low. Run on GitHub Actions on 2026-09-25:

| Model | Photos | Balls | Image | AP50 | AP50-95 | Recall @0.5 | Recall @0.9 |
|---|---|---|---|---|---|---|---|
| Project516 v1 | 11 held out | 13 | colour | 0.990 | 0.923 | 1.000 | 0.769 |
| Team 2826 | 11 held out | 13 | colour | 0.990 | 0.803 | 1.000 | 0.615 |
| Project516 v1 | 11 held out | 13 | gray | 0.990 | 0.836 | 0.923 | 0.000 |
| Team 2826 | 11 held out | 13 | gray | 0.990 | 0.763 | 1.000 | 0.615 |
| Team 2826 | all 53 | 111 | colour | 0.840 | 0.579 | 0.784 | 0.586 |
| Team 2826 | all 53 | 111 | gray | 0.823 | 0.592 | 0.604 | 0.495 |

- **Held out** is the 11 photos v1 didn't train on (v1's own 80/20 split, rebuilt). v1's scores on all
  53 include its training photos, so they're left out.
- **Gray** is the photo converted to one channel and back, which is what a mono camera gives the model.
- **Recall @0.9** is at PhotonVision's default confidence threshold (0.9).
- 13 balls is a small sample; one missed ball moves recall by 0.077.

What this says:
- **v1 works with our TensorRT backend.** The raw export has the same input and output as Team 2826's.
- **In colour, v1 is at least as good,** with tighter boxes (AP50-95 0.923 against 0.803).
- **On a mono camera, v1 needs a lower threshold.** In gray it still finds the balls, but with low
  confidence: none pass 0.9, and 12 of 13 pass 0.5. Team 2826's model keeps its confidence in gray.
- **Neither test is our camera.** These are phone photos, mostly close up.

## Which to use

- **Now:** `wave2826_yolo11n_fuel_raw`. It's installed on the Jetson as "Fuel (Wave 2826 YOLO11n)", and it's the model PhotonVision ships.
- **Mono cameras:** keep Team 2826's model. v1 at the default 0.9 threshold found no balls in gray.
- **Colour camera:** try `project516_yolo26n_fuel_v1_raw` (same input and output, ~17% fewer FLOPs, similar speed) at a 0.5 threshold, and A/B it on Rewind recordings from our own camera before switching.
- **By October:** fine-tune on our own camera's frames, with motion blur, bumpers and yellow distractors, and keep the 640 input. Through an ultrawide lens, a ball 5 m away is only ~9 px wide at 640.
- **Rebuild the engines** from the ONNX after any JetPack or TensorRT change. Engines only run on the TensorRT version and GPU they were built for.
