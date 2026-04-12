/*
 * read_probe.c — Prueba registro por registro cuál cuelga.
 * Escribe un marker antes de cada lectura. Si la app se cuelga,
 * el marker dice en qué registro se paró.
 */
#include "xil_io.h"
#include "xil_cache.h"
#include "xparameters.h"

#define CTRL_BASE   XPAR_BRAM_CTRL_TOP_0_BASEADDR
#define MARKER_ADDR 0x01200000

static void mark(int idx, u32 val) {
    volatile u32 *m = (volatile u32*)(MARKER_ADDR + idx*4);
    *m = val;
    Xil_DCacheFlushRange((UINTPTR)m, 4);
}

static void wait_us(int us) { volatile int i; for(i=0;i<us*100;i++){} }

int main(void) {
    volatile u32 val;

    /* Clear markers */
    for (int i=0; i<16; i++) mark(i, 0);

    /* Write something to reg0 and reg1 first */
    Xil_Out32(CTRL_BASE + 0x00, 0x00);  /* NOP */
    Xil_Out32(CTRL_BASE + 0x04, 42);    /* n_words=42 */
    wait_us(10);

    /* Try reading each register one by one */
    /* reg0 (0x00) ctrl_cmd — writable, read should return last written */
    mark(0, 0xAA000000);
    val = Xil_In32(CTRL_BASE + 0x00);
    mark(0, 0xBB000000 | val);

    /* reg1 (0x04) n_words */
    mark(1, 0xAA010000);
    val = Xil_In32(CTRL_BASE + 0x04);
    mark(1, 0xBB010000 | val);

    /* reg2 (0x08) counter_reset */
    mark(2, 0xAA020000);
    val = Xil_In32(CTRL_BASE + 0x08);
    mark(2, 0xBB020000 | val);

    /* reg3 (0x0C) ctrl_state — HW readback */
    mark(3, 0xAA030000);
    val = Xil_In32(CTRL_BASE + 0x0C);
    mark(3, 0xBB030000 | val);

    /* reg4 (0x10) occupancy — HW readback */
    mark(4, 0xAA040000);
    val = Xil_In32(CTRL_BASE + 0x10);
    mark(4, 0xBB040000 | val);

    /* reg5 (0x14) total_in_lo — HW readback */
    mark(5, 0xAA050000);
    val = Xil_In32(CTRL_BASE + 0x14);
    mark(5, 0xBB050000 | val);

    /* reg6 (0x18) total_in_hi */
    mark(6, 0xAA060000);
    val = Xil_In32(CTRL_BASE + 0x18);
    mark(6, 0xBB060000 | val);

    /* reg7 (0x1C) total_in_hh */
    mark(7, 0xAA070000);
    val = Xil_In32(CTRL_BASE + 0x1C);
    mark(7, 0xBB070000 | val);

    /* reg8 (0x20) total_in_hhh */
    mark(8, 0xAA080000);
    val = Xil_In32(CTRL_BASE + 0x20);
    mark(8, 0xBB080000 | val);

    /* reg9 (0x24) total_out_lo */
    mark(9, 0xAA090000);
    val = Xil_In32(CTRL_BASE + 0x24);
    mark(9, 0xBB090000 | val);

    /* Done! */
    mark(15, 0xCAFECAFE);

    while(1);
}
