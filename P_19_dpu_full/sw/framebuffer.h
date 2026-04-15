/*
 * framebuffer.h - 2D drawing primitives for RGB888 framebuffer in DDR.
 *
 * Target: ARM Cortex-A9 bare-metal (ZedBoard) + PC test (gcc).
 * Pixel format: RGB888, 3 bytes/pixel (R, G, B), little-endian byte order.
 * Default resolution: 1280 x 720, stride = 1280 * 3 = 3840 bytes.
 */
#ifndef FRAMEBUFFER_H
#define FRAMEBUFFER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FB_DEFAULT_W      1280
#define FB_DEFAULT_H      720
#define FB_BPP            3
#define FB_DEFAULT_STRIDE (FB_DEFAULT_W * FB_BPP)
#define FB_DEFAULT_SIZE   (FB_DEFAULT_STRIDE * FB_DEFAULT_H)
/* Default DDR address (clear of DPU regions). */
#define FB_DEFAULT_ADDR   0x1A000000u

typedef struct {
    uint8_t  *base;     /* pointer to pixel 0,0  */
    uint16_t  w;        /* width  in pixels      */
    uint16_t  h;        /* height in pixels      */
    uint32_t  stride;   /* bytes per row         */
} fb_t;

/* Initialise an fb_t struct (does NOT clear memory). */
void fb_init(fb_t *fb, void *base, uint16_t w, uint16_t h);

/* Solid fill of the whole framebuffer. */
void fb_clear(fb_t *fb, uint8_t r, uint8_t g, uint8_t b);

/* Write a single pixel; safe (clipped). */
void fb_set_pixel(fb_t *fb, int x, int y, uint8_t r, uint8_t g, uint8_t b);

/* Bresenham line, integer-only, clipped per-pixel. */
void fb_draw_line(fb_t *fb, int x0, int y0, int x1, int y1,
                  uint8_t r, uint8_t g, uint8_t b);

/* Hollow rectangle of given border thickness (>=1). */
void fb_draw_rect(fb_t *fb, int x, int y, int w, int h,
                  uint8_t r, uint8_t g, uint8_t b, int thickness);

/* Solid rectangle. */
void fb_fill_rect(fb_t *fb, int x, int y, int w, int h,
                  uint8_t r, uint8_t g, uint8_t b);

/* 8x8 ASCII text, 1x scale, no kerning, no wrap. */
void fb_draw_text(fb_t *fb, int x, int y, const char *text,
                  uint8_t r, uint8_t g, uint8_t b);

/* Blit RGB888 source rectangle (sw x sh) into fb at (dst_x, dst_y). */
void fb_draw_image_rgb(fb_t *fb, int dst_x, int dst_y,
                       const uint8_t *src, int sw, int sh);

#ifdef __cplusplus
}
#endif

#endif /* FRAMEBUFFER_H */
