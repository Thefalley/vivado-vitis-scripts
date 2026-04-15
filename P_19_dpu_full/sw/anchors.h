/* anchors.h -- YOLOv4-416 anchors (Darknet ordering, small -> large).
 *
 * Three scales x three anchors each = 9 anchors total, in pixels at the
 * 416x416 input resolution. Order MUST match draw_bboxes.py ANCHOR_MASK:
 *   mask[0] = {0,1,2}  -> stride  8 (52x52)
 *   mask[1] = {3,4,5}  -> stride 16 (26x26)
 *   mask[2] = {6,7,8}  -> stride 32 (13x13)
 */
#ifndef ANCHORS_H
#define ANCHORS_H

#include <stdint.h>

#define YOLO_INPUT_SIZE   416
#define YOLO_NUM_CLASSES   80
#define YOLO_NUM_ANCHORS    3   /* per scale */
#define YOLO_CH_PER_CELL  255   /* 3 * (5 + 80) */

/* anchors_xx[YOLO_NUM_ANCHORS][2] = { {w_px, h_px}, ... } */
static const float ANCHORS_S8[YOLO_NUM_ANCHORS][2]  = {
    { 10.0f,  13.0f}, { 16.0f,  30.0f}, { 33.0f,  23.0f}
};
static const float ANCHORS_S16[YOLO_NUM_ANCHORS][2] = {
    { 30.0f,  61.0f}, { 62.0f,  45.0f}, { 59.0f, 119.0f}
};
static const float ANCHORS_S32[YOLO_NUM_ANCHORS][2] = {
    {116.0f,  90.0f}, {156.0f, 198.0f}, {373.0f, 326.0f}
};

#endif /* ANCHORS_H */
