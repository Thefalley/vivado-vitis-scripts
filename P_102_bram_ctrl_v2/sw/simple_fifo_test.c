/*
 * simple_fifo_test.c — Minimal FIFO test for P_102 bitstream.
 * NO counter reads (to isolate if AXI-Lite readback hangs the bus).
 * Just: load 100, drain 100, verify data.
 */
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
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

int main(void) {
    volatile u32 *src = (volatile u32*)SRC_ADDR;
    volatile u32 *dst = (volatile u32*)DST_ADDR;
    volatile u32 *mark = (volatile u32*)MARKER_ADDR;
    int errors = 0;

    mark[0] = 0x11110000; Xil_DCacheFlushRange((UINTPTR)mark, 32);

    XAxiDma_Config *cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    XAxiDma_CfgInitialize(&dma, cfg);
    XAxiDma_IntrDisable(&dma, 0xFFFFFFFF, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, 0xFFFFFFFF, XAXIDMA_DEVICE_TO_DMA);

    for (u32 i=0; i<NUM_WORDS; i++) src[i] = PATTERN(i);
    memset((void*)dst, 0xAA, NUM_WORDS*4);
    Xil_DCacheFlushRange((UINTPTR)src, NUM_WORDS*4);
    Xil_DCacheFlushRange((UINTPTR)dst, NUM_WORDS*4);

    mark[0] = 0x22220000; Xil_DCacheFlushRange((UINTPTR)mark, 4);

    /* LOAD 100 */
    Xil_Out32(CTRL_BASE + 0x04, NUM_WORDS);  /* n_words */
    wait_us(10);
    Xil_Out32(CTRL_BASE + 0x00, 0x01);       /* CMD_LOAD */
    wait_us(1);
    Xil_Out32(CTRL_BASE + 0x00, 0x00);       /* NOP */

    Xil_DCacheFlushRange((UINTPTR)src, NUM_WORDS*4);
    XAxiDma_SimpleTransfer(&dma, (UINTPTR)src, NUM_WORDS*4, XAXIDMA_DMA_TO_DEVICE);
    while(XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));

    mark[0] = 0x33330000; Xil_DCacheFlushRange((UINTPTR)mark, 4);
    wait_us(200);

    /* DRAIN 100 */
    Xil_Out32(CTRL_BASE + 0x04, NUM_WORDS);  /* n_words */
    wait_us(10);

    Xil_DCacheInvalidateRange((UINTPTR)dst, NUM_WORDS*4);
    XAxiDma_SimpleTransfer(&dma, (UINTPTR)dst, NUM_WORDS*4, XAXIDMA_DEVICE_TO_DMA);

    Xil_Out32(CTRL_BASE + 0x00, 0x02);       /* CMD_DRAIN */
    wait_us(1);
    Xil_Out32(CTRL_BASE + 0x00, 0x00);

    while(XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));
    Xil_DCacheInvalidateRange((UINTPTR)dst, NUM_WORDS*4);

    mark[0] = 0x44440000; Xil_DCacheFlushRange((UINTPTR)mark, 4);

    /* Verify */
    for (u32 i=0; i<NUM_WORDS; i++) {
        if (dst[i] != PATTERN(i)) errors++;
    }

    if (errors == 0)
        mark[0] = 0xCAFE0000;
    else
        mark[0] = 0xDEAD0000 + errors;
    mark[1] = errors;
    Xil_DCacheFlushRange((UINTPTR)mark, 8);

    while(1);
}
