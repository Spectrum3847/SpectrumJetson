"""Compare FUEL models on Project516's rebuilt-fuel photos, in colour and in gray.

    tools/fuelmodel/eval.py staging/fuel-models/project516_yolo26n_fuel_v1_raw.onnx [--wave]

Downloads the rebuilt-fuel dataset (53 labelled phone photos, pinned revision) and scores each
model the same way: the photo letterboxed to 640x640 as PhotonVision does, NMS at IoU 0.45
(PhotonVision's default), then COCO-style AP. --wave adds Team 2826's YOLO11n as PhotonVision ships
it (int8 TFLite, pinned commit), so both models see the same pixels.

Two splits:
- val: the photos Project516's v1 did not train on. It rebuilds v1's split (train_test_split,
  80/20, random_state=42, over the train.txt entries that have a photo, as v1's training script
  did), so it's the only fair split for v1.
- all: all 53 photos. Team 2826 never trained on any of them.

Gray is each photo converted to one channel and back to three, which is what PhotonVision feeds
the model from a mono camera like the Thriftiest Cam.

Prints a Markdown table: AP at IoU 0.5 and 0.5-0.95, then precision and recall at confidence 0.5
and recall at 0.9 (PhotonVision's default threshold). Needs the packages in requirements.txt.
"""

from __future__ import annotations

import argparse
import hashlib
import urllib.request
from pathlib import Path

import cv2
import numpy as np

DATASET_REPO = "project516/rebuilt-fuel-dataset"
DATASET_REVISION = "4040182cc1e330c40d217d6ac7581bc6b2daabda"
# train.txt's order decides v1's train/val split.
TRAIN_TXT_URL = ("https://raw.githubusercontent.com/Project516/rebuilt-fuel/"
                 "acad6f1b3feb68cf05ee8e0bfdaf1637905eab68/dataset1/annotated/train.txt")
WAVE_URL = ("https://raw.githubusercontent.com/PhotonVision/photonvision/"
            "1f419c9de3a6a0787571648d18211537a83fdca9/"
            "photon-server/src/main/resources/models/fuelV1-yolo11n.tflite")
WAVE_SHA256 = "bd74b36f230df1e560ce92d0e06b7504dda169462882774fe6154b598a7b9bcb"
SIZE = 640
NMS_IOU = 0.45
MIN_CONF = 0.001


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url: str, dest: Path, digest: str | None = None) -> Path:
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(url, dest)
    if digest and sha256(dest) != digest:
        raise SystemExit(f"{dest} SHA-256 is {sha256(dest)}, expected {digest}")
    return dest


def v1_val_names(train_txt: Path, src: Path) -> set[str]:
    from sklearn.model_selection import train_test_split

    names = [Path(line.strip()).name for line in train_txt.read_text().splitlines() if line.strip()]
    names = [n for n in names if (src / n).exists()]
    _, val = train_test_split(names, train_size=0.8, random_state=42)
    return set(val)


def letterbox(bgr: np.ndarray) -> tuple[np.ndarray, float, int, int]:
    """640x640 RGB with grey (114) bars, plus the scale and padding used."""
    h, w = bgr.shape[:2]
    r = min(SIZE / w, SIZE / h)
    nw, nh = round(w * r), round(h * r)
    px, py = (SIZE - nw) // 2, (SIZE - nh) // 2
    out = np.full((SIZE, SIZE, 3), 114, np.uint8)
    out[py:py + nh, px:px + nw] = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_LINEAR)
    return cv2.cvtColor(out, cv2.COLOR_BGR2RGB), r, px, py


def labels_xyxy(label: Path, w: int, h: int, r: float, px: int, py: int) -> np.ndarray:
    rows = [list(map(float, line.split()[1:])) for line in label.read_text().splitlines() if line.strip()]
    if not rows:
        return np.zeros((0, 4))
    cx, cy, bw, bh = np.array(rows).T
    x1 = (cx - bw / 2) * w * r + px
    y1 = (cy - bh / 2) * h * r + py
    return np.stack([x1, y1, x1 + bw * w * r, y1 + bh * h * r], 1)


class OnnxRaw:
    """An Ultralytics raw export: float RGB [1, 3, 640, 640] in, [1, 5, N] cx cy w h score out."""

    def __init__(self, path: Path):
        import onnxruntime as ort

        self.s = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        self.input = self.s.get_inputs()[0].name

    def __call__(self, rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        x = rgb.transpose(2, 0, 1)[None].astype(np.float32) / 255
        out = self.s.run(None, {self.input: x})[0][0]
        cx, cy, w, h, score = out[:5]
        return np.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], 1), score


class PhotonTflite:
    """PhotonVision's int8 TFLite: uint8 RGB in; boxes (x1 y1 x2 y2), scores, class_idx out."""

    def __init__(self, path: Path):
        from ai_edge_litert.interpreter import Interpreter

        self.i = Interpreter(str(path))
        self.i.allocate_tensors()
        self.input = self.i.get_input_details()[0]["index"]
        self.out = {d["name"]: d for d in self.i.get_output_details()}

    def _get(self, name: str) -> np.ndarray:
        d = self.out[name]
        scale, zero = d["quantization"]
        return (self.i.get_tensor(d["index"]).astype(np.float32) - zero) * scale

    def __call__(self, rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        self.i.set_tensor(self.input, rgb[None])
        self.i.invoke()
        return self._get("boxes")[0], self._get("scores")[0]


def iou(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """IoU of every box in a against every box in b, both x1 y1 x2 y2."""
    lt = np.maximum(a[:, None, :2], b[None, :, :2])
    rb = np.minimum(a[:, None, 2:], b[None, :, 2:])
    inter = np.clip(rb - lt, 0, None).prod(2)
    area = lambda x: (x[:, 2] - x[:, 0]) * (x[:, 3] - x[:, 1])
    return inter / (area(a)[:, None] + area(b)[None] - inter + 1e-9)


def nms(boxes: np.ndarray, scores: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    keep_mask = scores >= MIN_CONF
    boxes, scores = boxes[keep_mask], scores[keep_mask]
    order = np.argsort(-scores)
    keep = []
    while order.size:
        i = order[0]
        keep.append(i)
        order = order[1:][iou(boxes[i:i + 1], boxes[order[1:]])[0] <= NMS_IOU]
    return boxes[keep], scores[keep]


def match(pred: np.ndarray, truth: np.ndarray, thresholds: np.ndarray) -> np.ndarray:
    """Per prediction (best first), whether it is a true positive at each IoU threshold."""
    tp = np.zeros((len(pred), len(thresholds)), bool)
    if not len(pred) or not len(truth):
        return tp
    overlaps = iou(pred, truth)
    for t, thr in enumerate(thresholds):
        used = np.zeros(len(truth), bool)
        for p in range(len(pred)):
            cand = np.where((overlaps[p] >= thr) & ~used)[0]
            if cand.size:
                used[cand[np.argmax(overlaps[p, cand])]] = True
                tp[p, t] = True
    return tp


def average_precision(tp: np.ndarray, conf: np.ndarray, n_truth: int) -> np.ndarray:
    """COCO 101-point AP per IoU threshold."""
    order = np.argsort(-conf)
    tp = tp[order]
    ctp = np.cumsum(tp, 0)
    recall = ctp / max(n_truth, 1)
    precision = ctp / np.arange(1, len(tp) + 1)[:, None]
    aps = []
    for t in range(tp.shape[1]):
        p = np.concatenate([[1.0], precision[:, t], [0.0]])
        r = np.concatenate([[0.0], recall[:, t], [1.0]])
        p = np.flip(np.maximum.accumulate(np.flip(p)))
        grid = np.linspace(0, 1, 101)
        aps.append(np.interp(grid, r, p, right=0).mean())
    return np.array(aps)


def score(model, photos: list[tuple[np.ndarray, Path]]) -> dict[str, float]:
    thresholds = np.linspace(0.5, 0.95, 10)
    tps, confs, n_truth = [], [], 0
    for bgr, label in photos:
        rgb, r, px, py = letterbox(bgr)
        truth = labels_xyxy(label, bgr.shape[1], bgr.shape[0], r, px, py)
        boxes, scores = nms(*model(rgb))
        tps.append(match(boxes, truth, thresholds))
        confs.append(scores)
        n_truth += len(truth)
    tp, conf = np.concatenate(tps), np.concatenate(confs)
    ap = average_precision(tp, conf, n_truth)

    def at(c: float) -> tuple[float, float]:
        hit = conf >= c
        found = int(tp[hit, 0].sum())
        return found / max(int(hit.sum()), 1), found / max(n_truth, 1)

    p50, r50 = at(0.5)
    _, r90 = at(0.9)
    return {"balls": n_truth, "ap50": ap[0], "ap": ap.mean(), "p50": p50, "r50": r50, "r90": r90}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("models", nargs="*", type=Path, help="Ultralytics raw ONNX exports")
    parser.add_argument("--wave", action="store_true", help="also score Team 2826's model")
    parser.add_argument("--work", type=Path, default=Path.home() / "build" / "fuel-eval")
    args = parser.parse_args()

    from huggingface_hub import snapshot_download

    src = Path(snapshot_download(DATASET_REPO, repo_type="dataset", revision=DATASET_REVISION))
    images = sorted(src.glob("*.png"), key=lambda p: int(p.stem))
    if len(images) != 53:
        raise SystemExit(f"expected 53 photos in {src}, found {len(images)}")
    val = v1_val_names(download(TRAIN_TXT_URL, args.work / "train.txt"), src)

    models = [(m.stem, OnnxRaw(m)) for m in args.models]
    if args.wave:
        tflite = download(WAVE_URL, args.work / "fuelV1-yolo11n.tflite", WAVE_SHA256)
        models.append(("wave2826_yolo11n_fuel_int8", PhotonTflite(tflite)))
    if not models:
        raise SystemExit("nothing to score: pass a model or --wave")

    colour = [(cv2.imread(str(p)), p.with_suffix(".txt")) for p in images]
    gray = [(cv2.cvtColor(cv2.cvtColor(b, cv2.COLOR_BGR2GRAY), cv2.COLOR_GRAY2BGR), l)
            for b, l in colour]
    in_val = [p.name in val for p in images]
    sets = {}
    for mode, photos in (("colour", colour), ("gray", gray)):
        sets[("val", mode)] = [x for x, v in zip(photos, in_val) if v]
        sets[("all", mode)] = photos

    print("| Model | Split | Photos | Balls | Image | AP50 | AP50-95 | P @0.5 | R @0.5 | R @0.9 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for name, model in models:
        for (split, mode), photos in sets.items():
            s = score(model, photos)
            print(f"| {name} | {split} | {len(photos)} | {s['balls']} | {mode} | {s['ap50']:.3f}"
                  f" | {s['ap']:.3f} | {s['p50']:.3f} | {s['r50']:.3f} | {s['r90']:.3f} |", flush=True)


if __name__ == "__main__":
    main()
