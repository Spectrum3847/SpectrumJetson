"""Export Project516's rebuilt-fuel YOLO26n model to the ONNX that 12-install-yolo-model.sh takes.

    tools/fuelmodel/export.py [--out staging/fuel-models]

Downloads rebuilt-fuel-model-v1.pt from Hugging Face at a pinned revision, checks its SHA-256, and
exports the raw head: output [1, 5, 8400] (cx, cy, w, h, score), no NMS inside the model. Our
TensorRT runner does the NMS, so its thresholds stay tunable. The script fails if the ONNX has any
other output shape.

Needs the packages in requirements.txt. Runs on the CPU in about a minute.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path

MODEL_REPO = "project516/rebuilt-fuel-model"
MODEL_REVISION = "7661f55574604588bee7dfbf889c01828558886b"
MODEL_FILE = "rebuilt-fuel-model-v1.pt"
MODEL_SHA256 = "94954a468c210c703929eff18a19c380a03865a1194f1584027ae2847263f0c6"
ONNX_NAME = "project516_yolo26n_fuel_v1_raw.onnx"
RAW_SHAPE = [1, 5, 8400]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download_checkpoint() -> Path:
    from huggingface_hub import hf_hub_download

    pt = Path(hf_hub_download(MODEL_REPO, MODEL_FILE, revision=MODEL_REVISION))
    got = sha256(pt)
    if got != MODEL_SHA256:
        raise SystemExit(f"{MODEL_FILE} SHA-256 is {got}, expected {MODEL_SHA256}")
    return pt


def export(pt: Path, out_dir: Path) -> Path:
    import onnx
    from ultralytics import YOLO

    work = out_dir / "work"
    work.mkdir(parents=True, exist_ok=True)
    local_pt = work / MODEL_FILE
    shutil.copyfile(pt, local_pt)
    # end2end=False keeps YOLO26's one-to-many head, the same layout as a YOLO11 raw export.
    exported = YOLO(str(local_pt)).export(
        format="onnx", imgsz=640, batch=1, dynamic=False, opset=17, simplify=True,
        end2end=False, nms=False)
    onnx_path = out_dir / ONNX_NAME
    shutil.move(exported, onnx_path)
    shutil.rmtree(work)

    model = onnx.load(str(onnx_path))
    shapes = [[d.dim_value for d in o.type.tensor_type.shape.dim] for o in model.graph.output]
    if shapes != [RAW_SHAPE]:
        raise SystemExit(f"{onnx_path} outputs {shapes}, expected [{RAW_SHAPE}]")
    return onnx_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=Path("staging/fuel-models"))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    onnx_path = export(download_checkpoint(), args.out)
    print(f"{onnx_path}  sha256 {sha256(onnx_path)}  output {RAW_SHAPE}")


if __name__ == "__main__":
    main()
