/* host_shim.c -- empty stubs so bbox_decoder.c links on a host (gcc).
 *
 * bbox_decoder.c only uses libm + <stdint.h> + <string.h>, so nothing else
 * is needed. This TU exists just to give the build something to point at if
 * future code adds xil_printf() guards. Keeping it for forward compat.
 */
#include <stdarg.h>
#include <stdio.h>

int xil_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}
