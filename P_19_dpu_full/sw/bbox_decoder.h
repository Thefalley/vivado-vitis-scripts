/* bbox_decoder.h -- YOLOv4-416 post-processing for ARM Cortex-A9 bare-metal.
 *
 * Decodes 3 INT8 DPU output heads (stride 8/16/32) into bounding boxes,
 * then runs per-class NMS. Box coordinates are normalised to [0..1] of the
 * 416x416 input (xyxy = x1, y1, x2, y2).
 *
 * Heads NHWC layout, channels-last, 255 ch per cell, ordered as:
 *   for a in 0..2:
 *     [tx, ty, tw, th, obj, cls0, cls1, ..., cls79]
 *
 * Dequantisation: float_val = (int8_val - x_zp) * x_scale
 * (matches ONNX QuantizeLinear / Vitis DPU INT8 output convention).
 */
#ifndef BBOX_DECODER_H
#define BBOX_DECODER_H

#include <stdint.h>

#ifndef MAX_DETECTIONS
#define MAX_DETECTIONS 256
#endif

#define YOLO_CONF_THRESH  0.25f
#define YOLO_IOU_THRESH   0.45f

typedef struct {
    float x;            /* x1 in [0..1] */
    float y;            /* y1 in [0..1] */
    float w;            /* x2 in [0..1] -- stored as second corner, NOT width */
    float h;            /* y2 in [0..1] */
    float confidence;   /* obj * max(cls_prob)                              */
    int   class_id;     /* 0..79                                            */
} detection_t;

/* Decode the 3 heads into out[].
 *   h52, h26, h13 : raw INT8 buffers in NHWC, channels-last, 255 ch/cell.
 *   x_scale_*     : output dequant scale per head.
 *   x_zp_*        : output dequant zero-point per head (often 0).
 *   out / max_out : caller-provided buffer.
 * Returns number of raw detections written (pre-NMS, post conf threshold).
 */
int decode_heads(const int8_t *h52, const int8_t *h26, const int8_t *h13,
                 float x_scale_52, float x_scale_26, float x_scale_13,
                 int32_t x_zp_52, int32_t x_zp_26, int32_t x_zp_13,
                 detection_t *out, int max_out);

/* In-place per-class greedy NMS. Returns new detection count.
 * dets is reordered (kept ones at the front, sorted desc by confidence).
 */
int nms(detection_t *dets, int n, float iou_thr);

#endif /* BBOX_DECODER_H */
