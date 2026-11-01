# Object detection (TensorRT YOLO) on the Jetson

How to train, install and use a game-piece model with PhotonVision's TensorRT backend
(`photonvision-100` in the `spectrum-2027` fork, `detector/trt_yolo.cu` here). For how it works inside
and the measured numbers, see [TECHNICAL.md](TECHNICAL.md#object-detection-tensorrt-photonvision-100).

## What you get

- **Object Detection pipeline** (TensorRT): a camera runs only the model. Its "Object FPS max"
  (default 30 on the Jetson) caps how many frames go to the model.
- **AprilTag + Object pipeline**: the camera runs the GPU AprilTag detector on every frame (up to
  "Tag FPS max") and publishes tags exactly as an AprilTagCuda pipeline does, with no added latency.
  At most "Object FPS max" of those frames (default 15) also go to the model. The objects are
  published on a second table, `<camera>-objects`, each result stamped with the capture time of
  the frame they came from. On the robot:

  ```java
  PhotonCamera front = new PhotonCamera("front");                 // tags, unchanged
  PhotonCamera frontObjects = new PhotonCamera("front-objects");  // game pieces
  for (var r : frontObjects.getAllUnreadResults()) {
      for (var t : r.getTargets()) {
          int cls = t.getDetectedObjectClassID();
          float conf = t.getDetectedObjectConfidence();
          double yaw = t.getYaw(), pitch = t.getPitch();          // from the camera's calibration
          // r.getTimestampSeconds() is this frame's own capture time
      }
  }
  ```

- **One engine for every camera.** All cameras using the same model share one TensorRT engine. Frames
  that arrive within 2 ms of each other run as one batch, which costs much less than separate runs.
  The model runs on a lowest-priority CUDA stream, so it doesn't delay the tag detector.
- **"Tag FPS max"** (AprilTag pipelines): process at most N frames a second without changing the
  camera mode, e.g. 122 on the front camera and 60 on the sides. The skipped frames are never
  decoded. Idle mode's lower rate still wins when the robot is disabled.

Everything is off until you choose one of these pipelines or set a max.

## 1. Collect frames

Use the same cameras, mounts and exposure you'll run on the robot.

- **From Rewind recordings** (best: real match lighting and motion blur): record a practice session
  with Rewind ([REWIND.md](REWIND.md)), then pull frames out of it. Every 5th frame of a 122 fps
  recording is plenty. Recordings are MJPEG, so `ffmpeg -i cam.mjpeg -vf "select=not(mod(n\,5))" -vsync vfr out/%05d.jpg`
  works, as does `tools/` Rewind export (`scripts/jetson/export-match.sh`).
- Include the bad cases: pieces partly hidden, at the edge of the frame, far away, under bumpers,
  blurred, and look-alike distractors (yellow bumpers, posters). Add frames with **no** pieces in them.
- 300-1000 labelled frames is a good first model. Fine-tuning from COCO weights needs far fewer than
  training from scratch.

## 2. Label

- **Roboflow** (web, free for public projects) or **CVAT** (open source, self-hostable). Draw
  axis-aligned boxes; one class per kind of game piece.
- Export in **YOLO format** (Ultralytics `data.yaml` + `images/` + `labels/`).
- Keep a validation split (~15%) from *different* sessions than the training frames, or the scores
  will be optimistic.

## 3. Train (YOLO11n)

On a laptop/desktop with an NVIDIA GPU, or Google Colab:

```bash
pip install ultralytics
yolo detect train model=yolo11n.pt data=data.yaml imgsz=640 epochs=150 batch=32 \
     hsv_s=0.5 hsv_v=0.4 degrees=5 mosaic=1.0
```

**Grayscale augmentation, so one model serves mono and colour cameras.** Our tag cameras are mono:
the backend copies the grey frame into R, G and B. A model trained only on colour will be worse on
those frames. Ultralytics has no grayscale switch on the command line, but the albumentations
pipeline applies `ToGray` when albumentations is installed; set its probability to ~0.5 with a small
callback, or simply convert ~half of the training images to grey (3-channel) before training:

```python
# make_gray_copies.py: duplicate half the training set as 3-channel grey (labels copied too)
import cv2, glob, random, shutil, os
for p in glob.glob("train/images/*.jpg"):
    if random.random() < 0.5:
        g = cv2.cvtColor(cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2GRAY), cv2.COLOR_GRAY2BGR)
        q = p.replace(".jpg", "_gray.jpg"); cv2.imwrite(q, g)
        lbl = p.replace("images", "labels").replace(".jpg", ".txt")
        shutil.copy(lbl, lbl.replace(".txt", "_gray.txt"))
```

Use `yolo11n` (nano) first: it fits several cameras at 15-30 fps. `yolo11s` finds smaller, farther
pieces but costs about 2.5x the GPU time (TECHNICAL.md has the numbers).

## 4. Export ONNX

```bash
yolo export model=runs/detect/train/weights/best.pt format=onnx dynamic=True opset=17 simplify=True
```

- `dynamic=True` lets one ONNX run at any batch and input size; the Jetson picks the size when it
  builds the engine.
- **Input size:** 640x640 is the default. For our 16:10 cameras (1280x800), **640x384** keeps the
  same detail with ~40% less work (the 640x640 letterbox is mostly grey padding). Width and height
  must be multiples of 32. Train at 640; the model still works at 640x384 because YOLO is fully
  convolutional.
- Leave `nms` off (the default): our runner does NMS on the GPU-decoded candidates, so the
  confidence and IoU sliders work.

## 5. Install on the Jetson

Either:

- **Web UI:** Settings > Object Detection > upload the `.onnx`, with the class labels (in class
  order), the input width/height and the version. The engine is built the first time a pipeline
  uses the model (a few minutes; tags keep running and the objects start when it's ready).
- **Script (builds the engine now):** copy the ONNX to the Jetson, then
  `scripts/jetson/12-install-yolo-model.sh best.onnx "Fuel YOLO11n" Fuel 640 384`
  and restart PhotonVision.

Engines are cached in `/opt/photonvision/photonvision_config/trt-cache`, keyed by the model file,
input size, batch size, precision, TensorRT version and GPU. A new model or a JetPack update
rebuilds them; nothing else does. Build in the pit, never on the field.

Then pick the model in the camera's **Object Detection** or **AprilTag + Object** pipeline.

## Licensing

- **Ultralytics YOLOv8/YOLO11 are AGPL-3.0**, and so are models trained with their code. That's fine
  for us: our robot and vision code is open source (FRC teams publish it), and PhotonVision itself is
  GPLv3. If a team ever needs closed code, Ultralytics sells an enterprise licence.
- **Apache-2.0 alternatives**, if licensing ever matters: **YOLOX-nano** (Megvii) and **D-FINE-N**
  (a small DETR-style detector; NMS-free). Both export to ONNX. YOLOX's output is the raw
  `[1, N, 5+nc]` layout with objectness (transposed from ours, and not yet decoded by our runner);
  D-FINE outputs boxes + scores like our end-to-end `[1, K, 6]` path after a small reshape. Either
  would need a few lines in `trt_yolo.cu`'s decode; not done yet.

## From a box to a floor position (for the robot library, later)

PhotonLib gives each object's yaw and pitch (from the camera calibration). For a piece lying on the
floor, with the camera's mount known (robot-to-camera transform: height `h`, pitch, yaw, position):

1. Take the **bottom-centre** of the box (where the piece touches the floor), not the centre: the
   centre is half a piece higher and biases the distance. Undistort that pixel with the calibration
   and turn it into a ray in the camera frame (`x = (u - cx)/fx`, `y = (v - cy)/fy`, `z = 1`), or use
   PhotonLib's yaw/pitch of the target's bottom point.
2. Rotate the ray into the robot frame with the camera's mount rotation (pitch down is positive in
   WPILib's convention; check the sign once with a piece at a measured spot).
3. Intersect it with the floor plane `z = 0`: the ray from the camera at height `h` with downward
   component `d_z < 0` hits the floor at `t = h / -d_z`; the point is `camera + t * d`. Rays that
   don't point down (`d_z >= 0`) are above the horizon: reject them.
4. Add the camera's x/y offset, then transform by the robot's pose at the **object result's
   timestamp** (from the pose estimator's history) to get a field position.
5. For tall pieces, use the piece's known height: intersect with `z = piece_height / 2` using the box
   centre instead. Range error grows with distance squared: a 1 px error at 4 m on a 640-wide image is
   several cm; filter over frames.

`PhotonUtils.estimateCameraToTargetTranslation` / `calculateDistanceToTargetMeters` do step 3 for a
target height. This belongs in our robot library (ROBOT-LIBRARY-PLAN.md) as a `GamePieceTracker`.
