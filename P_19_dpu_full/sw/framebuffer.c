/*
 * framebuffer.c - 2D primitives, integer-only, no stdlib (besides stdint).
 */
#include "framebuffer.h"
#include "clip_helpers.h"
#include "font8x8.h"

/* ---- private helpers --------------------------------------------------- */

static inline void put_px_unsafe(fb_t *fb, int x, int y,
                                 uint8_t r, uint8_t g, uint8_t b)
{
    uint8_t *p = fb->base + (uint32_t)y * fb->stride + (uint32_t)x * FB_BPP;
    p[0] = r;
    p[1] = g;
    p[2] = b;
}

static inline int abs_i(int v) { return v < 0 ? -v : v; }

/* ---- public API -------------------------------------------------------- */

void fb_init(fb_t *fb, void *base, uint16_t w, uint16_t h)
{
    fb->base   = (uint8_t *)base;
    fb->w      = w;
    fb->h      = h;
    fb->stride = (uint32_t)w * FB_BPP;
}

void fb_clear(fb_t *fb, uint8_t r, uint8_t g, uint8_t b)
{
    /* Build one row, then duplicate. */
    uint8_t *row = fb->base;
    for (int x = 0; x < fb->w; x++) {
        row[x * FB_BPP + 0] = r;
        row[x * FB_BPP + 1] = g;
        row[x * FB_BPP + 2] = b;
    }
    for (int y = 1; y < fb->h; y++) {
        uint8_t *dst = fb->base + (uint32_t)y * fb->stride;
        for (uint32_t i = 0; i < fb->stride; i++) dst[i] = row[i];
    }
}

void fb_set_pixel(fb_t *fb, int x, int y, uint8_t r, uint8_t g, uint8_t b)
{
    if (!clip_in_bounds(x, y, fb->w, fb->h)) return;
    put_px_unsafe(fb, x, y, r, g, b);
}

void fb_draw_line(fb_t *fb, int x0, int y0, int x1, int y1,
                  uint8_t r, uint8_t g, uint8_t b)
{
    int dx =  abs_i(x1 - x0);
    int dy = -abs_i(y1 - y0);
    int sx = (x0 < x1) ? 1 : -1;
    int sy = (y0 < y1) ? 1 : -1;
    int err = dx + dy;

    for (;;) {
        if (clip_in_bounds(x0, y0, fb->w, fb->h))
            put_px_unsafe(fb, x0, y0, r, g, b);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

void fb_fill_rect(fb_t *fb, int x, int y, int w, int h,
                  uint8_t r, uint8_t g, uint8_t b)
{
    if (!clip_rect(&x, &y, &w, &h, fb->w, fb->h)) return;
    for (int j = 0; j < h; j++) {
        uint8_t *p = fb->base + (uint32_t)(y + j) * fb->stride
                              + (uint32_t)x * FB_BPP;
        for (int i = 0; i < w; i++) {
            p[0] = r; p[1] = g; p[2] = b;
            p += FB_BPP;
        }
    }
}

void fb_draw_rect(fb_t *fb, int x, int y, int w, int h,
                  uint8_t r, uint8_t g, uint8_t b, int thickness)
{
    if (thickness < 1) thickness = 1;
    if (w <= 0 || h <= 0) return;

    /* If border is thicker than half the rect, just fill it. */
    if (thickness * 2 >= w || thickness * 2 >= h) {
        fb_fill_rect(fb, x, y, w, h, r, g, b);
        return;
    }

    /* Top and bottom bands. */
    fb_fill_rect(fb, x, y,                 w, thickness, r, g, b);
    fb_fill_rect(fb, x, y + h - thickness, w, thickness, r, g, b);
    /* Left and right bands (excluding corners already drawn). */
    fb_fill_rect(fb, x,             y + thickness, thickness, h - 2*thickness, r, g, b);
    fb_fill_rect(fb, x + w - thickness, y + thickness, thickness, h - 2*thickness, r, g, b);
}

void fb_draw_text(fb_t *fb, int x, int y, const char *text,
                  uint8_t r, uint8_t g, uint8_t b)
{
    if (!text) return;
    int cx = x;
    for (const char *s = text; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '\n') { cx = x; y += 8; continue; }
        if (c < FONT8X8_FIRST || c > FONT8X8_LAST) c = '?';
        const uint8_t *glyph = font8x8[c - FONT8X8_FIRST];
        for (int row = 0; row < 8; row++) {
            uint8_t bits = glyph[row];
            for (int col = 0; col < 8; col++) {
                if (bits & (1u << col)) {
                    int px = cx + col;
                    int py = y  + row;
                    if (clip_in_bounds(px, py, fb->w, fb->h))
                        put_px_unsafe(fb, px, py, r, g, b);
                }
            }
        }
        cx += 8;
    }
}

void fb_draw_image_rgb(fb_t *fb, int dst_x, int dst_y,
                       const uint8_t *src, int sw, int sh)
{
    if (!src || sw <= 0 || sh <= 0) return;

    int src_x0 = 0, src_y0 = 0;
    int dx = dst_x, dy = dst_y, w = sw, h = sh;

    /* Clip destination, accumulating source-side offset. */
    if (dx < 0)        { src_x0 = -dx; w += dx; dx = 0; }
    if (dy < 0)        { src_y0 = -dy; h += dy; dy = 0; }
    if (dx >= fb->w || dy >= fb->h) return;
    if (dx + w > fb->w) w = fb->w - dx;
    if (dy + h > fb->h) h = fb->h - dy;
    if (w <= 0 || h <= 0) return;

    for (int j = 0; j < h; j++) {
        const uint8_t *sp = src + (uint32_t)(src_y0 + j) * (uint32_t)sw * FB_BPP
                                + (uint32_t)src_x0 * FB_BPP;
        uint8_t *dp = fb->base + (uint32_t)(dy + j) * fb->stride
                               + (uint32_t)dx * FB_BPP;
        for (int i = 0; i < w * FB_BPP; i++) dp[i] = sp[i];
    }
}
