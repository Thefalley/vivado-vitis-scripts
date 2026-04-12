/*
 * counter_simple.c — Load 100, drain ALL 100, then read counters.
 * Same flow as simple_fifo_test (which PASSED) but with counter reads.
 */
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_io.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR
#define CTRL_BASE       XPAR_BRAM_CTRL_TOP_0_BASEADDR
#define NUM_WORDS       100
#define PATTERN(i)      (0xBEEF0000u + (i))
#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define MARKER_ADDR     0x01200000

static XAxiDma dma;
static void wait_us(int us) { volatile int i; for(i=0;i<us*100;i++){} }
static void mark(int idx, u32 val) {
    volatile u32 *m = (volatile u32*)(MARKER_ADDR + idx*4);
    *m = val; Xil_DCacheFlushRange((UINTPTR)m, 4);
}

int main(void) {
    volatile u32 *src = (volatile u32*)SRC_ADDR;
    volatile u32 *dst = (volatile u32*)DST_ADDR;
    int errors = 0;

    for (int i=0; i<16; i++) mark(i, 0);

    XAxiDma_Config *cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    XAxiDma_CfgInitialize(&dma, cfg);
    XAxiDma_IntrDisable(&dma, 0xFFFFFFFF, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, 0xFFFFFFFF, XAXIDMA_DEVICE_TO_DMA);

    for (u32 i=0; i<NUM_WORDS; i++) src[i] = PATTERN(i);
    memset((void*)dst, 0xAA, NUM_WORDS*4);
    Xil_DCacheFlushRange((UINTPTR)src, NUM_WORDS*4);
    Xil_DCacheFlushRange((UINTPTR)dst, NUM_WORDS*4);

    /* Reset counters */
    mark(0, 0x11110001);
    Xil_Out32(CTRL_BASE + 0x08, 0x01);
    wait_us(10);
    Xil_Out32(CTRL_BASE + 0x08, 0x00);
    wait_us(10);

    /* LOAD 100 */
    mark(0, 0x11110002);
    Xil_Out32(CTRL_BASE + 0x04, NUM_WORDS);
    wait_us(10);
    Xil_Out32(CTRL_BASE + 0x00, 0x01);
    wait_us(1);
    Xil_Out32(CTRL_BASE + 0x00, 0x00);
    Xil_DCacheFlushRange((UINTPTR)src, NUM_WORDS*4);
    XAxiDma_SimpleTransfer(&dma, (UINTPTR)src, NUM_WORDS*4, XAXIDMA_DMA_TO_DEVICE);
    while(XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));
    wait_us(200);

    /* DRAIN ALL 100 (single chunk, same as simple_fifo_test) */
    mark(0, 0x11110003);
    Xil_Out32(CTRL_BASE + 0x04, NUM_WORDS);
    wait_us(10);
    Xil_DCacheInvalidateRange((UINTPTR)dst, NUM_WORDS*4);
    XAxiDma_SimpleTransfer(&dma, (UINTPTR)dst, NUM_WORDS*4, XAXIDMA_DEVICE_TO_DMA);
    Xil_Out32(CTRL_BASE + 0x00, 0x02);
    wait_us(1);
    Xil_Out32(CTRL_BASE + 0x00, 0x00);
    while(XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));
    Xil_DCacheInvalidateRange((UINTPTR)dst, NUM_WORDS*4);

    /* Verify data first */
    mark(0, 0x11110004);
    for (u32 i=0; i<NUM_WORDS; i++) {
        if (dst[i] != PATTERN(i)) errors++;
    }
    mark(1, errors);

    /* NOW read counters */
    mark(0, 0x11110005);
    u32 occ = Xil_In32(CTRL_BASE + 0x10);
    mark(2, occ);

    mark(0, 0x11110006);
    u32 in_lo = Xil_In32(CTRL_BASE + 0x14);
    mark(3, in_lo);

    mark(0, 0x11110007);
    u32 out_lo = Xil_In32(CTRL_BASE + 0x24);
    mark(4, out_lo);

    /* Final result */
    if (errors == 0 && occ == 0 && in_lo == NUM_WORDS && out_lo == NUM_WORDS)
        mark(0, 0xCAFE0000);
    else
        mark(0, 0xDEAD0000);

    mark(5, 0xD00ED00E);

    while(1);
}
