# fuelmodel: FUEL model export and comparison

Exports Project516's [rebuilt-fuel](https://github.com/Project516/rebuilt-fuel) YOLO26n (v1) to the
ONNX that `scripts/jetson/12-install-yolo-model.sh` takes, and scores it against Team 2826's
YOLO11n. Runs on the CPU of any Linux machine; not on the Jetson or a Pi (it installs PyTorch).

```bash
python3 -m venv ~/build/fuelmodel-venv
~/build/fuelmodel-venv/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision
~/build/fuelmodel-venv/bin/pip install -r tools/fuelmodel/requirements.txt
~/build/fuelmodel-venv/bin/python tools/fuelmodel/export.py
~/build/fuelmodel-venv/bin/python tools/fuelmodel/eval.py staging/fuel-models/project516_yolo26n_fuel_v1_raw.onnx --wave
```

- `export.py` writes `staging/fuel-models/project516_yolo26n_fuel_v1_raw.onnx` (about a minute).
  Copy it to `~/models` on the Jetson and install it:
  `12-install-yolo-model.sh ~/models/project516_yolo26n_fuel_v1_raw.onnx "Fuel (Project516 YOLO26n)" Fuel`.
- `eval.py` downloads the 53 rebuilt-fuel photos and prints a Markdown table (a few minutes).
  What the numbers mean, and the last results: [docs/GAME-PIECE-MODELS.md](../../docs/GAME-PIECE-MODELS.md#accuracy-on-the-rebuilt-fuel-photos).

Every download is pinned: the model and dataset to a Hugging Face revision, Team 2826's TFLite to a
PhotonVision commit and SHA-256.
