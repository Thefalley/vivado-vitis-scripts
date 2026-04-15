/*
 * demo_test.c - PC-side smoke test for framebuffer primitives.
 *
 * Build:   gcc -O2 -Wall -Wextra demo_test.c framebuffer.c clip_helpers.c -o demo_test
 * Run:     ./demo_test
 * Output:  demo_test.ppm   (1280x720 RGB888, viewable in IrfanView/GIMP/feh)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "framebuffer.h"

int main(void)
{
    fb_t fb;
    uint8_t *mem = (uint8_t *)malloc(FB_DEFAULT_SIZE);
    if (!mem) {
        fprintf(stderr, "malloc %u bytes failed\n", (unsigned)FB_DEFAULT_SIZE);
        return 1;
    }
    fb_init(&fb, mem, FB_DEFAULT_W, FB_DEFAULT_H);

    /* 1. clear to mid-gray */
    fb_clear(&fb, 0x40, 0x40, 0x40);

    /* 2. red hollow rectangle (3-px border) */
    fb_draw_rect(&fb, 100, 80, 400, 300,  0xFF, 0x00, 0x00, 3);

    /* 3. solid green rectangle */
    fb_fill_rect(&fb, 600, 100, 200, 150, 0x00, 0xC0, 0x00);

    /* 4. blue diagonal line + cross */
    fb_draw_line(&fb,  50,  50, 1230, 670, 0x00, 0x80, 0xFF);
    fb_draw_line(&fb,  50, 670, 1230,  50, 0x00, 0x80, 0xFF);

    /* 5. text label "hello dpu" + a YOLO-style label */
    fb_draw_text(&fb, 120, 100, "hello dpu", 0xFF, 0xFF, 0xFF);
    fb_draw_text(&fb, 610, 110, "person 0.95", 0x00, 0x00, 0x00);

    /* 6. clipped pixel writes around screen corners (smoke test) */
    for (int i = -5; i < 5; i++)
        fb_set_pixel(&fb, i, i, 0xFF, 0xFF, 0x00);
    for (int i = -5; i < 5; i++)
        fb_set_pixel(&fb, FB_DEFAULT_W - 1 + i, FB_DEFAULT_H - 1 + i,
                     0xFF, 0xFF, 0x00);

    /* 7. tiny 32x32 fake "DPU image" pasted with clipping at edge */
    uint8_t tile[32 * 32 * 3];
    for (int j = 0; j < 32; j++)
        for (int i = 0; i < 32; i++) {
            tile[(j*32 + i)*3 + 0] = (uint8_t)(i * 8);
            tile[(j*32 + i)*3 + 1] = (uint8_t)(j * 8);
            tile[(j*32 + i)*3 + 2] = 0x80;
        }
    fb_draw_image_rgb(&fb, 900, 400, tile, 32, 32);
    fb_draw_image_rgb(&fb, FB_DEFAULT_W - 16, 500, tile, 32, 32); /* right-clip */
    fb_draw_image_rgb(&fb, -16, 600, tile, 32, 32);               /* left-clip  */

    /* Save as PPM (P6 binary). */
    const char *fname = "demo_test.ppm";
    FILE *fp = fopen(fname, "wb");
    if (!fp) { fprintf(stderr, "cannot open %s\n", fname); free(mem); return 2; }
    fprintf(fp, "P6\n%u %u\n255\n", FB_DEFAULT_W, FB_DEFAULT_H);
    fwrite(mem, 1, FB_DEFAULT_SIZE, fp);
    fclose(fp);

    /* Quick integrity check: count non-gray pixels. */
    uint32_t painted = 0;
    for (uint32_t i = 0; i < FB_DEFAULT_SIZE; i += 3) {
        if (mem[i] != 0x40 || mem[i+1] != 0x40 || mem[i+2] != 0x40) painted++;
    }
    printf("OK  framebuffer=%ux%u  bytes=%u  painted_px=%u  out=%s\n",
           FB_DEFAULT_W, FB_DEFAULT_H, (unsigned)FB_DEFAULT_SIZE,
           painted, fname);

    free(mem);
    return 0;
}
