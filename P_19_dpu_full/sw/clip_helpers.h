/*
 * clip_helpers.h - integer clipping helpers for framebuffer primitives.
 */
#ifndef CLIP_HELPERS_H
#define CLIP_HELPERS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int clip_min(int a, int b) { return a < b ? a : b; }
static inline int clip_max(int a, int b) { return a > b ? a : b; }

/* Clamp v into [lo, hi]. */
int  clip_clamp(int v, int lo, int hi);

/* Returns 1 if (x,y) is inside [0,w-1] x [0,h-1], else 0. */
int  clip_in_bounds(int x, int y, int w, int h);

/*
 * Clip an axis-aligned rectangle (x,y,w,h) against framebuffer (fbw,fbh).
 * Returns 1 if any part is visible (and updates *x,*y,*w,*h to the visible
 * portion); returns 0 if fully outside (rect fields untouched).
 */
int  clip_rect(int *x, int *y, int *w, int *h, int fbw, int fbh);

#ifdef __cplusplus
}
#endif

#endif /* CLIP_HELPERS_H */
