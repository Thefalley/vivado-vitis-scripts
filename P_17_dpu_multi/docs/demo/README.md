# YOLOv4-INT8 DPU end-to-end demo assets

This directory documents the post-processing pipeline that turns a raw DPU
inference (3 head dumps) into an annotated bounding-box image, and explains
how the corresponding calibration image is generated and quantized.

## Files produced

| Path | What | Source |
| --- | --- | --- |
| `C:/project/vitis-ai/workspace/c_dpu/demo/input_image.png` | 416x416 RGB calibration image (display) | `prepare_demo.py` |
| `C:/project/vitis-ai/workspace/c_dpu/demo/input_int8.bin` | int8 HWC bytes the DPU ingests (519168 B = 416*416*3) | `prepare_demo.py` |
| `C:/project/vitis-ai/workspace/c_dpu/demo/head_52.bin` | ONNX reference head, stride 8  (1x52x52x255 fp32) | `prepare_demo.py` |
| `C:/project/vitis-ai/workspace/c_dpu/demo/head_26.bin` | ONNX reference head, stride 16 (1x26x26x255 fp32) | `prepare_demo.py` |
| `C:/project/vitis-ai/workspace/c_dpu/demo/head_13.bin` | ONNX reference head, stride 32 (1x13x13x255 fp32) | `prepare_demo.py` |
| `C:/project/vivado/P_17_dpu_multi/docs/reference_onnx_output.png` | ground-truth post-NMS overlay produced by ONNX Runtime | `prepare_demo.py` |

The runtime helper used by both the demo prepare step and the on-board flow:

* `C:/project/vivado/P_17_dpu_multi/sw/runtime/draw_bboxes.py`

## Quantization convention (must match the DPU)

The model's input tensor is `image_input:0` shape `[1,416,416,3]` float32 in
NHWC order. The first ops in the graph are `Transpose -> QuantizeLinear`
with:

```
x_scale       = 1/255  (~0.003921568...)
x_zero_point  = -128   (int8)
```

i.e. `int8(x) = clip(round(x_float / x_scale) + x_zp, -128, 127)`. For an
RGB pixel `r` in `[0,255]`, that simplifies to `int8 = r - 128`. The
letterbox padding value (128) therefore becomes `0` in int8.

`input_int8.bin` is a flat HWC byte stream: `H=416, W=416, C=3 (R,G,B)`.

## Image source

`prepare_demo.py` picks a non-trivial COCO scene from the workspace cache:

* preferred: `cache_personas_calle.jpg` (busy street, 4 people + accessories)
* fallbacks: `cache_trafico`, `cache_caballos`, `cache_autobus`, `cache_gatos_sofa`

Standard YOLOv4 letterboxing is applied (preserve aspect ratio, pad with
gray 128).

No image was downloaded from the internet for this run; the workspace
already shipped the required COCO samples.

## Reproducing

```
python C:/project/vitis-ai/workspace/c_dpu/demo/prepare_demo.py
```

(optional `--src path/to/image.jpg` to override).

## After the DPU runs on ZedBoard

The on-board firmware will dump three raw float32 NHWC head buffers (one per
output stride) named `head_52.bin`, `head_26.bin`, `head_13.bin`. To draw
boxes:

```
python C:/project/vivado/P_17_dpu_multi/sw/runtime/draw_bboxes.py \
       --heads head_52.bin head_26.bin head_13.bin \
       --input input_image.png \
       --out   dpu_output.png
```

A successful end-to-end DPU run is bit-exact with ONNX when
`dpu_output.png` matches `reference_onnx_output.png` (same boxes, same
labels, same confidences within fp32 noise from the per-grid sigmoid/exp).

## NMS / threshold defaults

* confidence threshold: `0.25`
* IoU threshold: `0.45`
* per-class greedy NMS (matches the convention used in
  `scripts/infer_yolov4_qop.py`)

Both thresholds are CLI-overridable via `--conf` / `--iou`.

## Anchors (COCO YOLOv4-416, Darknet ordering)

| Stride | Grid | Anchors (px @ 416) |
| --- | --- | --- |
|  8 | 52x52 | (10,13)  (16,30)  (33,23)  |
| 16 | 26x26 | (30,61)  (62,45)  (59,119) |
| 32 | 13x13 | (116,90) (156,198)(373,326)|

## Class labels

COCO 80, embedded as a list in `draw_bboxes.py`. No external label file
needed.

## Sanity check (current snapshot)

ONNX run on `cache_personas_calle.jpg` produced 20 detections after NMS:
4 persons (conf 0.99 / 0.98 / 0.96 / 0.96), suitcase (0.93), chair (0.77),
several cups, a wine glass, a tie, and a dining table. The annotated
result is `reference_onnx_output.png`.
