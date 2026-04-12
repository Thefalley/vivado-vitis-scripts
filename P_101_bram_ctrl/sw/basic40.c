/*
 * basic40.c — Minimal test: single load/drain of 40 words via DMA
 *
 * This isolates the core FIFO+DMA path without any incremental logic.
 * Uses n_words=40 so the FSM auto-injects tlast and auto-stops.
 *
 * Flow:
 *   1. Fill src[0..39] with CAFE pattern
 *   2. n_words=40, CMD_LOAD, DMA MM2S 40 words, wait
 *   3. DMA S2MM 40 words, CMD_DRAIN, wait
 *   4. Compare src vs dst
 *   5. Write diagnostic markers to 0x01200000..0x0120000F
 *
 * JTAG-readable markers at 0x01200000:
 *   [0] = 0xCAFE0000 if PASS, 0xDEAD0000+errors if FAIL,
 *         0xBBBB0001 if stuck at MM2S, 0xBBBB0002 if stuck at S2MM
 *   [1] = phase marker (increments as app progresses)
 *   [2] = first mismatched index (or 0xFFFFFFFF if all match)
 *   [3] = first mismatched dst value
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xstatus.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR
#define CTRL_BASE       XPAR_BRAM_CTRL_TOP_0_BASEADDR

#define REG_CMD         0x00
#define REG_NWORDS      0x04

#define CMD_NOP         0x00
#define CMD_LOAD        0x01
#define CMD_DRAIN       0x02

#define NUM_WORDS       40
#define TRANSFER_BYTES  (NUM_WORDS * 4)

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define MARKER_ADDR     0x01200000

#define PATTERN(i)      (0xCAFE0000u + (i))

static XAxiDma dma_inst;

/* Write a diagnostic marker visible via JTAG */
static void marker(int idx, u32 val) {
    volatile u32 *m = (volatile u32 *)(MARKER_ADDR + idx * 4);
    *m = val;
    Xil_DCacheFlushRange((UINTPTR)m, 4);
}

/* Busy-wait with timeout. Returns 0 if completed, 1 if timeout. */
static int wait_dma(int direction, int timeout_ms) {
    volatile int i;
    int loops = timeout_ms * 50000; /* ~1ms at 100MHz */
    for (i = 0; i < loops; i++) {
        if (!XAxiDma_Busy(&dma_inst, direction))
            return 0;
    }
    return 1; /* timeout */
}

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    volatile u32 *src = (volatile u32 *)SRC_ADDR;
    volatile u32 *dst = (volatile u32 *)DST_ADDR;
    int errors = 0;

    /* Phase 0: Init */
    marker(0, 0xAAAA0000); /* "I started" */
    marker(1, 0);          /* phase counter */
    marker(2, 0xFFFFFFFF); /* first bad index */
    marker(3, 0);          /* first bad value */

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  BASIC 40-WORD TEST\r\n");
    xil_printf("==========================================\r\n\r\n");

    /* Phase 1: Init DMA */
    marker(1, 1);
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    if (!cfg) {
        xil_printf("ERROR: DMA config not found\r\n");
        marker(0, 0xEEEE0001);
        while(1);
    }
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed (%d)\r\n", status);
        marker(0, 0xEEEE0002);
        while(1);
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Phase 2: Fill source, clear dest */
    marker(1, 2);
    for (u32 i = 0; i < NUM_WORDS; i++) {
        src[i] = PATTERN(i);
    }
    memset((void *)dst, 0x00, TRANSFER_BYTES);  /* Use 0x00 not 0xAA */
    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, TRANSFER_BYTES);  /* Flush 0x00s to DDR */

    xil_printf("  src filled: src[0]=0x%08X, src[39]=0x%08X\r\n",
               src[0], src[39]);

    /* Phase 3: Configure n_words */
    marker(1, 3);
    Xil_Out32(CTRL_BASE + REG_NWORDS, NUM_WORDS);
    xil_printf("  n_words = %d\r\n", NUM_WORDS);

    /* Phase 4: LOAD — CMD first, then DMA */
    marker(1, 4);
    xil_printf("  CMD_LOAD...\r\n");
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    /* Start MM2S DMA */
    xil_printf("  MM2S starting (%d bytes)...\r\n", TRANSFER_BYTES);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src,
                                    TRANSFER_BYTES, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S transfer start failed (%d)\r\n", status);
        marker(0, 0xEEEE0003);
        while(1);
    }

    /* Wait for MM2S with timeout */
    marker(1, 5);
    if (wait_dma(XAXIDMA_DMA_TO_DEVICE, 1000)) {
        xil_printf("ERROR: MM2S timeout!\r\n");
        marker(0, 0xBBBB0001);
        while(1);
    }
    xil_printf("  MM2S done.\r\n");

    /* Phase 6: DRAIN — S2MM first, then CMD */
    marker(1, 6);

    /* Invalidate dst cache before S2MM writes to it */
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    /* Start S2MM DMA first (receiver ready before data arrives) */
    xil_printf("  S2MM starting (%d bytes)...\r\n", TRANSFER_BYTES);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst,
                                    TRANSFER_BYTES, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM transfer start failed (%d)\r\n", status);
        marker(0, 0xEEEE0004);
        while(1);
    }

    /* Now issue DRAIN command */
    xil_printf("  CMD_DRAIN...\r\n");
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    /* Wait for S2MM with timeout */
    marker(1, 7);
    if (wait_dma(XAXIDMA_DEVICE_TO_DMA, 1000)) {
        xil_printf("ERROR: S2MM timeout!\r\n");
        marker(0, 0xBBBB0002);
        while(1);
    }
    xil_printf("  S2MM done.\r\n");

    /* Phase 8: Verify */
    marker(1, 8);
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    xil_printf("\r\n  Word | Source     | Dest       | OK?\r\n");
    xil_printf("  -----|------------|------------|----\r\n");

    for (u32 i = 0; i < NUM_WORDS; i++) {
        u32 expected = PATTERN(i);
        if (dst[i] != expected) {
            errors++;
            if (errors == 1) {
                marker(2, i);           /* first bad index */
                marker(3, dst[i]);      /* first bad value */
            }
        }
        /* Print all 40 words (it's small enough) */
        xil_printf("  %4d | 0x%08X | 0x%08X | %s\r\n",
                   i, src[i], dst[i],
                   (dst[i] == expected) ? "OK" : "FAIL");
    }

    /* Phase 9: Result */
    marker(1, 9);
    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS (40/40 words OK)\r\n");
        marker(0, 0xCAFE0000);
    } else {
        xil_printf("  FAIL (%d errors)\r\n", errors);
        marker(0, 0xDEAD0000 + errors);
    }
    xil_printf("==========================================\r\n");

    while (1);
    return 0;
}
