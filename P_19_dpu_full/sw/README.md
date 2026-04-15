# P_19 YOLOv4-416 bare-metal post-processing

Bare-metal C port of `P_17_dpu_multi/sw/runtime/draw_bboxes.py`. Runs on the
ARM Cortex-A9 (PS) of the ZedBoard, processing 3 INT8 output heads from the
DPU into COCO bounding boxes.

## Files

| File              | Purpose                                          |
| ----------------- | ------------------------------------------------ |
| `bbox_decoder.h`  | Public API + `detection_t` + thresholds.         |
| `bbox_decoder.c`  | Decoder + per-class greedy NMS, FP32, no malloc. |
| `anchors.h`       | YOLOv4-416 anchors (9, Darknet ordering).        |
| `coco_classes.h`  | 80 COCO class name strings.                      |
| `host/validate_bbox_decoder.py` | Host-side equivalence test vs Python. |
| `host/host_shim.c`              | `xil_printf` shim for host build.     |

## API

```c
#include "bbox_decoder.h"

static detection_t dets[MAX_DETECTIONS];   /* MAX_DETECTIONS = 256 */

int n = decode_heads(h52, h26, h13,
                     scale52, scale26, scale13,
                     zp52,    zp26,    zp13,
                     dets, MAX_DETECTIONS);
n = nms(dets, n, YOLO_IOU_THRESH);   /* 0.45 */

for (int i = 0; i < n; ++i) {
    xil_printf("%s  conf=%d/1000  box=[%d %d %d %d]\r\n",
               COCO_CLASSES[dets[i].class_id],
               (int)(dets[i].confidence * 1000.0f),
               (int)(dets[i].x * 416.0f), (int)(dets[i].y * 416.0f),
               (int)(dets[i].w * 416.0f), (int)(dets[i].h * 416.0f));
}
```

`detection_t` stores `xyxy` corners normalised to `[0..1]` of the 416 input
in fields `(x, y, w, h)` (second pair is the lower-right corner, not the
width/height -- chosen to keep IoU branch-free and to match the Python
reference's `xmin, ymin, xmax, ymax` layout).

## Tensor layout assumptions

Each head is `int8`, NHWC, channels-last, **255 channels per cell**, ordered
`[a0_tx, a0_ty, a0_tw, a0_th, a0_obj, a0_cls0..79, a1_tx, ...]`. This matches
the Python reshape `feat.reshape(1, gH, gW, 3, 85)`.

Dequant: `f = (q - zp) * scale`. For Vitis DPU outputs the typical scale is
`1/256` and `zp = 0`, but pass whatever the model exports.

## Memory & runtime

- All buffers static. Worst-case stack: ~1 KB. Heap: 0.
- `MAX_DETECTIONS = 256` cap on raw + post-NMS detections.
- Pre-filter on `obj < 0.125` cuts ~98 % of `expf`/inner loops on typical
  scenes -- enough to keep a single-frame post-process well under 50 ms on
  the A9 @ 667 MHz with hard FPU.
- No recursion, no malloc, no stdio (only `xil_printf` if you want logs).

## Validation (offline, host)

Build a host shared lib and run the diff script against the Python reference:

```bash
cd P_19_dpu_full/sw/host
gcc -O2 -shared -fPIC -o libbboxdec.so ../bbox_decoder.c host_shim.c -lm
python validate_bbox_decoder.py \
    --h52 head_52.i8 --h26 head_26.i8 --h13 head_13.i8 \
    --scales 0.00390625 0.00390625 0.00390625 \
    --zps    0 0 0
# expects: RESULT: PASS
```

The validator:
1. calls the C `decode_heads` + `nms` via ctypes,
2. dequantises the same `int8` blobs and runs `draw_bboxes.decode_heads` +
   `draw_bboxes.nms` in Python,
3. matches each C detection to a Python detection by class + |Δconf| < 1e-3
   + IoU > 0.99. Any mismatch -> `RESULT: FAIL`.

If you only have float32 head dumps, requantise first:
`q = round(f / scale + zp).clip(-128, 127).astype(int8)`.

## On-target build (Vitis)

Add `bbox_decoder.c` to the standalone application's source list. No BSP
flags required beyond the default `-lm`. `MAX_DETECTIONS` and the conf/IoU
thresholds can be overridden with `-D`.
