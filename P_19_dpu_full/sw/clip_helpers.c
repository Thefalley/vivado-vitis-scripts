#include "clip_helpers.h"

int clip_clamp(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

int clip_in_bounds(int x, int y, int w, int h)
{
    return (x >= 0) && (y >= 0) && (x < w) && (y < h);
}

int clip_rect(int *x, int *y, int *w, int *h, int fbw, int fbh)
{
    int rx = *x, ry = *y, rw = *w, rh = *h;

    if (rw <= 0 || rh <= 0)            return 0;
    if (rx >= fbw || ry >= fbh)        return 0;
    if (rx + rw <= 0 || ry + rh <= 0)  return 0;

    if (rx < 0)        { rw += rx; rx = 0; }
    if (ry < 0)        { rh += ry; ry = 0; }
    if (rx + rw > fbw) { rw = fbw - rx; }
    if (ry + rh > fbh) { rh = fbh - ry; }

    if (rw <= 0 || rh <= 0) return 0;

    *x = rx; *y = ry; *w = rw; *h = rh;
    return 1;
}
