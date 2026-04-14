#!/usr/bin/env python3
"""
draw_bboxes.py -- YOLOv4 INT8 DPU post-processing.

Decodes 3 raw YOLOv4 head dumps (binary float32 NHWC tensors as emitted by
the DequantizeLinear at the tail of `yolov4_int8_qop.onnx`) and draws COCO
bounding boxes on top of the original 416x416 input image.

Heads expected (any order, sorted internally by spatial size):
  stride 8   -> [1, 52, 52, 255]   float32  (small objects)
  stride 16  -> [1, 26, 26, 255]   float32
  stride 32  -> [1, 13, 13, 255]   float32  (large objects)

The 255 channels = 3 anchors x (4 box + 1 obj + 80 class) per cell.

Usable both as a CLI and as a library:

    from draw_bboxes import decode_heads, draw_detections

CLI:
    python draw_bboxes.py \
        --heads head_52.bin head_26.bin head_13.bin \
        --input input_image.png \
        --out   output.png
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import List, Tuple

import numpy as np
from PIL import Image, ImageDraw, ImageFont


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INPUT_SIZE = 416
NUM_CLASSES = 80

COCO_CLASSES = [
    "person", "bicycle", "car", "motorbike", "aeroplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
    "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag",
    "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite",
    "baseball bat", "baseball glove", "skateboard", "surfboard",
    "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon",
    "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
    "hot dog", "pizza", "donut", "cake", "chair", "sofa", "pottedplant",
    "bed", "diningtable", "toilet", "tvmonitor", "laptop", "mouse", "remote",
    "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
    "hair drier", "toothbrush",
]

# Standard YOLOv4-416 anchors (Darknet ordering: small -> large).
ANCHORS = np.array([
    [10, 13],  [16, 30],  [33, 23],     # stride 8  / 52x52
    [30, 61],  [62, 45],  [59, 119],    # stride 16 / 26x26
    [116, 90], [156, 198], [373, 326],  # stride 32 / 13x13
], dtype=np.float32)

ANCHOR_MASK = [[0, 1, 2], [3, 4, 5], [6, 7, 8]]


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def _infer_grid(nbytes: int) -> int:
    """Given a head dump size in bytes (float32), find the spatial side."""
    floats = nbytes // 4
    if floats % 255 != 0:
        raise ValueError(f"Head size {nbytes} bytes is not a multiple of 255 floats")
    cells = floats // 255
    side = int(round(cells ** 0.5))
    if side * side != cells:
        raise ValueError(f"Head with {cells} cells is not square (got side={side})")
    return side


def load_head(path: str) -> np.ndarray:
    """Load a raw float32 head dump and reshape to NHWC (1, S, S, 255)."""
    raw = np.fromfile(path, dtype=np.float32)
    side = _infer_grid(raw.nbytes)
    return raw.reshape(1, side, side, 255)


# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

def _sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def decode_scale(feat: np.ndarray, anchors: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """One YOLO head -> (boxes [N,4] xyxy in [0..1], scores [N, NUM_CLASSES]).

    feat: (1, gH, gW, 255) raw logits (pre-sigmoid).
    anchors: (3, 2) in pixels at the 416 input scale.
    """
    _, gH, gW, _ = feat.shape
    na = anchors.shape[0]

    feat = feat.reshape(1, gH, gW, na, 5 + NUM_CLASSES)

    box_xy   = _sigmoid(feat[..., 0:2])
    box_wh   = feat[..., 2:4]
    box_conf = _sigmoid(feat[..., 4:5])
    box_prob = _sigmoid(feat[..., 5:])

    gy, gx = np.meshgrid(np.arange(gH), np.arange(gW), indexing="ij")
    grid_xy = np.stack([gx, gy], axis=-1).reshape(1, gH, gW, 1, 2).astype(np.float32)

    box_xy = (box_xy + grid_xy) / np.array([gW, gH], dtype=np.float32)
    box_wh = np.exp(box_wh) * anchors.reshape(1, 1, 1, na, 2) / float(INPUT_SIZE)

    xmin = (box_xy[..., 0:1] - box_wh[..., 0:1] / 2)
    ymin = (box_xy[..., 1:2] - box_wh[..., 1:2] / 2)
    xmax = (box_xy[..., 0:1] + box_wh[..., 0:1] / 2)
    ymax = (box_xy[..., 1:2] + box_wh[..., 1:2] / 2)

    boxes = np.concatenate([xmin, ymin, xmax, ymax], axis=-1).reshape(-1, 4)
    scores = (box_conf * box_prob).reshape(-1, NUM_CLASSES)
    return boxes, scores


def decode_heads(heads: List[np.ndarray]) -> Tuple[np.ndarray, np.ndarray]:
    """Sort 3 heads by grid (large->small => mask 0->2) and decode all."""
    heads_sorted = sorted(heads, key=lambda h: -h.shape[1])  # 52, 26, 13
    all_boxes, all_scores = [], []
    for i, feat in enumerate(heads_sorted):
        anch = ANCHORS[ANCHOR_MASK[i]]
        b, s = decode_scale(feat, anch)
        all_boxes.append(b)
        all_scores.append(s)
    return np.vstack(all_boxes), np.vstack(all_scores)


# ---------------------------------------------------------------------------
# NMS (per-class)
# ---------------------------------------------------------------------------

def _iou_xyxy(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    inter_x1 = np.maximum(a[:, 0:1], b[None, :, 0])
    inter_y1 = np.maximum(a[:, 1:2], b[None, :, 1])
    inter_x2 = np.minimum(a[:, 2:3], b[None, :, 2])
    inter_y2 = np.minimum(a[:, 3:4], b[None, :, 3])
    iw = np.clip(inter_x2 - inter_x1, 0, None)
    ih = np.clip(inter_y2 - inter_y1, 0, None)
    inter = iw * ih
    area_a = ((a[:, 2] - a[:, 0]) * (a[:, 3] - a[:, 1]))[:, None]
    area_b = ((b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1]))[None, :]
    union = area_a + area_b - inter + 1e-9
    return inter / union


def nms(boxes: np.ndarray, scores: np.ndarray,
        conf_thresh: float = 0.25, iou_thresh: float = 0.45,
        max_det: int = 100) -> List[dict]:
    """Per-class NMS. Returns list of {class_id, class, conf, box=[x1,y1,x2,y2]}."""
    cls_ids = scores.argmax(axis=1)
    confs   = scores.max(axis=1)
    keep_mask = confs > conf_thresh
    boxes = boxes[keep_mask]
    confs = confs[keep_mask]
    cls_ids = cls_ids[keep_mask]
    if boxes.shape[0] == 0:
        return []

    detections = []
    for cls in np.unique(cls_ids):
        idx = np.where(cls_ids == cls)[0]
        b = boxes[idx]
        c = confs[idx]
        order = c.argsort()[::-1]
        b = b[order]; c = c[order]
        keep = []
        while b.shape[0] > 0:
            keep.append(0)
            if b.shape[0] == 1:
                break
            ious = _iou_xyxy(b[0:1], b[1:])[0]
            survivors = np.where(ious < iou_thresh)[0] + 1
            b = b[survivors]; c = c[survivors]
            # rebuild relative-index keep list
        # Above approach loses absolute indices: redo cleanly.
        # (simpler) standard greedy NMS:
        b = boxes[idx][order]; c = confs[idx][order]
        kept_boxes, kept_confs = [], []
        alive = np.ones(len(b), dtype=bool)
        for i in range(len(b)):
            if not alive[i]:
                continue
            kept_boxes.append(b[i])
            kept_confs.append(c[i])
            if i + 1 < len(b):
                ious = _iou_xyxy(b[i:i+1], b[i+1:])[0]
                kill = np.where(ious >= iou_thresh)[0] + (i + 1)
                alive[kill] = False
        for kb, kc in zip(kept_boxes, kept_confs):
            detections.append({
                "class_id": int(cls),
                "class":    COCO_CLASSES[int(cls)],
                "conf":     float(kc),
                "box":      [float(kb[0]), float(kb[1]),
                             float(kb[2]), float(kb[3])],
            })
    detections.sort(key=lambda d: -d["conf"])
    return detections[:max_det]


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

def _color_for(cid: int) -> Tuple[int, int, int]:
    rng = np.random.default_rng(cid * 9973 + 17)
    return tuple(int(v) for v in (rng.integers(60, 240, size=3)))


def draw_detections(img: Image.Image, dets: List[dict]) -> Image.Image:
    """Draw boxes on a copy of img. Coordinates are in [0..1] of the input."""
    out = img.convert("RGB").copy()
    drw = ImageDraw.Draw(out)
    W, H = out.size
    try:
        font = ImageFont.truetype("arial.ttf", 12)
    except Exception:
        font = ImageFont.load_default()
    for d in dets:
        x1, y1, x2, y2 = d["box"]
        x1 = max(0, min(W - 1, int(x1 * W)))
        y1 = max(0, min(H - 1, int(y1 * H)))
        x2 = max(0, min(W - 1, int(x2 * W)))
        y2 = max(0, min(H - 1, int(y2 * H)))
        if x2 <= x1 or y2 <= y1:
            continue
        color = _color_for(d["class_id"])
        drw.rectangle([x1, y1, x2, y2], outline=color, width=2)
        label = f"{d['class']} {d['conf']:.2f}"
        try:
            tb = drw.textbbox((0, 0), label, font=font)
            tw, th = tb[2] - tb[0], tb[3] - tb[1]
        except Exception:
            tw, th = 8 * len(label), 12
        ty = max(0, y1 - th - 2)
        drw.rectangle([x1, ty, x1 + tw + 4, ty + th + 2], fill=color)
        drw.text((x1 + 2, ty), label, fill=(255, 255, 255), font=font)
    return out


# ---------------------------------------------------------------------------
# Convenience: full pipeline
# ---------------------------------------------------------------------------

def run(head_paths: List[str], input_image_path: str, out_path: str,
        conf_thresh: float = 0.25, iou_thresh: float = 0.45) -> List[dict]:
    heads = [load_head(p) for p in head_paths]
    boxes, scores = decode_heads(heads)
    dets = nms(boxes, scores, conf_thresh=conf_thresh, iou_thresh=iou_thresh)
    img = Image.open(input_image_path)
    if img.size != (INPUT_SIZE, INPUT_SIZE):
        img = img.resize((INPUT_SIZE, INPUT_SIZE), Image.BILINEAR)
    out = draw_detections(img, dets)
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    out.save(out_path, optimize=True)
    return dets


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--heads", nargs=3, required=True,
                    metavar=("H1", "H2", "H3"),
                    help="3 raw float32 head .bin files (any order).")
    ap.add_argument("--input", required=True,
                    help="416x416 PNG/JPG used as DPU input (for overlay).")
    ap.add_argument("--out", required=True, help="Output PNG path.")
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou",  type=float, default=0.45)
    args = ap.parse_args()

    for h in args.heads:
        if not os.path.isfile(h):
            print(f"ERROR: missing head file: {h}", file=sys.stderr)
            sys.exit(2)
    if not os.path.isfile(args.input):
        print(f"ERROR: missing input image: {args.input}", file=sys.stderr)
        sys.exit(2)

    dets = run(args.heads, args.input, args.out,
               conf_thresh=args.conf, iou_thresh=args.iou)
    print(f"[draw_bboxes] {len(dets)} detection(s):")
    for d in dets:
        print(f"  {d['class']:<18} conf={d['conf']:.3f}  box={d['box']}")
    print(f"[draw_bboxes] wrote {args.out}")


if __name__ == "__main__":
    _main()
