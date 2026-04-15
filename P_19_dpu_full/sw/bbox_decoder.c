/* bbox_decoder.c -- bare-metal YOLOv4-416 post-processing.
 *
 * Target: Xilinx ARM Cortex-A9 (ZedBoard PS), Vitis bare-metal / standalone.
 * Dependencies: <stdint.h>, <math.h>, <string.h>. xil_printf() optional.
 *
 * Memory budget: only static arrays. MAX_DETECTIONS controls the cap.
 *   Largest temporary: index buffer for the candidate list (int).
 */

#include "bbox_decoder.h"
#include "anchors.h"

#include <math.h>
#include <string.h>
#include <stdint.h>

/* ---------- helpers --------------------------------------------------- */

static inline float sigmoidf(float x) {
    /* Standard sigmoid; ARM-A9 has hard FPU + libm expf. */
    return 1.0f / (1.0f + expf(-x));
}

static inline float dequant(int8_t q, float scale, int32_t zp) {
    return ((float)((int32_t)q - zp)) * scale;
}

static inline float fmaxf2(float a, float b) { return a > b ? a : b; }
static inline float fminf2(float a, float b) { return a < b ? a : b; }

/* ---------- per-head decode ------------------------------------------- */

/* Decode one head and append qualifying detections (conf > thresh) to out.
 * head     : INT8 NHWC buffer, gH * gW * 255 elements.
 * gH = gW  : grid side (52 / 26 / 13).
 * anchors  : 3 anchor pairs (w,h) in pixels @ 416.
 * scale,zp : dequant params for this head.
 * Returns number of detections written.
 */
static int decode_one(const int8_t *head, int gH, int gW,
                      const float anchors[YOLO_NUM_ANCHORS][2],
                      float scale, int32_t zp,
                      detection_t *out, int out_cap, int out_count)
{
    const int stride_a = 5 + YOLO_NUM_CLASSES;          /* 85 */
    const int stride_w = YOLO_NUM_ANCHORS * stride_a;   /* 255 */
    const int stride_h = gW * stride_w;
    const float inv_gW = 1.0f / (float)gW;
    const float inv_gH = 1.0f / (float)gH;
    const float inv_in = 1.0f / (float)YOLO_INPUT_SIZE;

    for (int h = 0; h < gH; ++h) {
        for (int w = 0; w < gW; ++w) {
            const int8_t *cell = head + h * stride_h + w * stride_w;
            for (int a = 0; a < YOLO_NUM_ANCHORS; ++a) {
                const int8_t *p = cell + a * stride_a;

                /* 1) Object confidence first -- early reject saves expf calls. */
                float obj = sigmoidf(dequant(p[4], scale, zp));
                if (obj < YOLO_CONF_THRESH * 0.5f) {
                    /* very loose pre-filter: even with cls=1.0 final score
                     * couldn't reach threshold if obj < 0.125; keep generous. */
                    /* (Keep the multiply-by-0.5 to avoid edge cases.) */
                    continue;
                }

                /* 2) Find best class. */
                int   best_c = 0;
                float best_logit = dequant(p[5], scale, zp);
                for (int c = 1; c < YOLO_NUM_CLASSES; ++c) {
                    float v = dequant(p[5 + c], scale, zp);
                    if (v > best_logit) { best_logit = v; best_c = c; }
                }
                float best_p = sigmoidf(best_logit);
                float conf   = obj * best_p;
                if (conf <= YOLO_CONF_THRESH) continue;

                /* 3) Decode box (only for surviving cells). */
                float tx = sigmoidf(dequant(p[0], scale, zp));
                float ty = sigmoidf(dequant(p[1], scale, zp));
                float tw = dequant(p[2], scale, zp);
                float th = dequant(p[3], scale, zp);

                float bx = (tx + (float)w) * inv_gW;
                float by = (ty + (float)h) * inv_gH;
                float bw = expf(tw) * anchors[a][0] * inv_in;
                float bh = expf(th) * anchors[a][1] * inv_in;

                if (out_count >= out_cap) return out_count;
                detection_t *d = &out[out_count++];
                d->x = bx - bw * 0.5f;     /* x1 */
                d->y = by - bh * 0.5f;     /* y1 */
                d->w = bx + bw * 0.5f;     /* x2 */
                d->h = by + bh * 0.5f;     /* y2 */
                d->confidence = conf;
                d->class_id   = best_c;
            }
        }
    }
    return out_count;
}

/* ---------- public: decode_heads -------------------------------------- */

int decode_heads(const int8_t *h52, const int8_t *h26, const int8_t *h13,
                 float x_scale_52, float x_scale_26, float x_scale_13,
                 int32_t x_zp_52, int32_t x_zp_26, int32_t x_zp_13,
                 detection_t *out, int max_out)
{
    int n = 0;
    /* mask 0 (small obj) -> 52x52 / stride 8  / ANCHORS_S8  */
    n = decode_one(h52, 52, 52, ANCHORS_S8,  x_scale_52, x_zp_52, out, max_out, n);
    /* mask 1 -> 26x26 / stride 16 / ANCHORS_S16 */
    n = decode_one(h26, 26, 26, ANCHORS_S16, x_scale_26, x_zp_26, out, max_out, n);
    /* mask 2 (large obj) -> 13x13 / stride 32 / ANCHORS_S32 */
    n = decode_one(h13, 13, 13, ANCHORS_S32, x_scale_13, x_zp_13, out, max_out, n);
    return n;
}

/* ---------- NMS ------------------------------------------------------- */

static inline float iou_xyxy(const detection_t *a, const detection_t *b) {
    float ix1 = fmaxf2(a->x, b->x);
    float iy1 = fmaxf2(a->y, b->y);
    float ix2 = fminf2(a->w, b->w);
    float iy2 = fminf2(a->h, b->h);
    float iw  = ix2 - ix1; if (iw < 0.0f) iw = 0.0f;
    float ih  = iy2 - iy1; if (ih < 0.0f) ih = 0.0f;
    float inter = iw * ih;
    float aa = (a->w - a->x) * (a->h - a->y);
    float bb = (b->w - b->x) * (b->h - b->y);
    float u  = aa + bb - inter + 1e-9f;
    return inter / u;
}

/* In-place insertion sort by confidence descending.
 * O(n^2) but n <= MAX_DETECTIONS=256 and typical post-conf survivors << 100.
 * No recursion, no heap. */
static void sort_by_conf_desc(detection_t *d, int n)
{
    for (int i = 1; i < n; ++i) {
        detection_t key = d[i];
        int j = i - 1;
        while (j >= 0 && d[j].confidence < key.confidence) {
            d[j + 1] = d[j];
            --j;
        }
        d[j + 1] = key;
    }
}

int nms(detection_t *dets, int n, float iou_thr)
{
    if (n <= 0) return 0;
    if (n > MAX_DETECTIONS) n = MAX_DETECTIONS;

    /* Sort descending by confidence (global, not per-class -- cheaper and
     * equivalent to per-class because the inner test gates on class_id). */
    sort_by_conf_desc(dets, n);

    static uint8_t alive[MAX_DETECTIONS];
    for (int i = 0; i < n; ++i) alive[i] = 1;

    /* Greedy per-class suppression. */
    for (int i = 0; i < n; ++i) {
        if (!alive[i]) continue;
        for (int j = i + 1; j < n; ++j) {
            if (!alive[j]) continue;
            if (dets[j].class_id != dets[i].class_id) continue;
            if (iou_xyxy(&dets[i], &dets[j]) >= iou_thr) {
                alive[j] = 0;
            }
        }
    }

    /* Compact survivors in-place, preserving order (already conf-desc). */
    int k = 0;
    for (int i = 0; i < n; ++i) {
        if (alive[i]) {
            if (k != i) dets[k] = dets[i];
            ++k;
        }
    }
    return k;
}
