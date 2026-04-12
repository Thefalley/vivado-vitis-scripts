/*
 * bram_stream_test.c - Round-trip test for bram_stream via DMA on ZedBoard.
 *
 * Flow: fill SRC buffer with a recognisable pattern, launch DMA to send
 * it through bram_stream, DMA back to DST, compare SRC vs DST beat-for-beat.
 *
 * bram_stream is a store-and-replay module: every beat written is read
 * back in the same order after tlast, so the output must match the
 * input exactly (identity transform).
 *
 * The design's internal BRAM is 1024 words deep; we transfer 256 words
 * here, which comfortably fits in a single pass through the FSM.
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xstatus.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR

#define TRANSFER_BYTES  1024             /* 256 words x 4 bytes */
#define NUM_WORDS       (TRANSFER_BYTES / 4)

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000

/* Reference pattern used by the host and by run.tcl for JTAG verification. */
#define PATTERN(i)      (0xDEAD0000u + (i))

static XAxiDma dma_inst;

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    u32 *src = (u32 *)SRC_ADDR;
    u32 *dst = (u32 *)DST_ADDR;
    int errors = 0;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  bram_stream Test (%d words round-trip)\r\n", NUM_WORDS);
    xil_printf("==========================================\r\n\r\n");

    /* Init DMA */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    if (!cfg) {
        xil_printf("ERROR: DMA config not found\r\n");
        return XST_FAILURE;
    }
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed (%d)\r\n", status);
        return XST_FAILURE;
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Fill source with the recognisable pattern */
    for (u32 i = 0; i < NUM_WORDS; i++) {
        src[i] = PATTERN(i);
    }
    memset(dst, 0xAA, TRANSFER_BYTES);

    /* Push src, invalidate dst */
    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_BYTES);
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    /* S2MM (receive) first, then MM2S (send) - canonical order */
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, TRANSFER_BYTES,
                           XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, TRANSFER_BYTES,
                           XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    /* Compare: dst[i] == PATTERN(i) */
    xil_printf("  Word | Source     | Dest       | OK?\r\n");
    xil_printf("  -----|------------|------------|----\r\n");

    for (u32 i = 0; i < NUM_WORDS; i++) {
        u32 expected = PATTERN(i);
        if (dst[i] != expected) errors++;

        if (i < 8 || i >= NUM_WORDS - 4) {
            xil_printf("  %4d | 0x%08X | 0x%08X | %s\r\n",
                       i, src[i], dst[i],
                       (dst[i] == expected) ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS (%d/%d words OK)\r\n", NUM_WORDS, NUM_WORDS);
        xil_printf("  bram_stream + BRAM + DMA OK\r\n");
    } else {
        xil_printf("  FAIL (%d errors)\r\n", errors);
    }
    xil_printf("==========================================\r\n");

    /* Halt so JTAG can re-read the buffers */
    while (1) {}

    return 0;
}
