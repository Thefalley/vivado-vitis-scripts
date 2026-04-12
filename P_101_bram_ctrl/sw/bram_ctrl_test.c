/*
 * bram_ctrl_test.c - Test bram_ctrl_top FIFO via DMA en ZedBoard
 *
 * Flow:
 *   1. Write n_words and CMD_LOAD via AXI-Lite
 *   2. DMA MM2S pushes data into FIFO (LOAD phase)
 *   3. Wait MM2S done
 *   4. Start DMA S2MM (prepare receive buffer)
 *   5. Write CMD_DRAIN via AXI-Lite (FIFO emits data)
 *   6. Wait S2MM done
 *   7. Verify: dst[i] == PATTERN(i)
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

/* AXI-Lite register offsets */
#define REG_CMD         0x00
#define REG_NWORDS      0x04

/* Commands */
#define CMD_NOP         0x00
#define CMD_LOAD        0x01
#define CMD_DRAIN       0x02
#define CMD_STOP        0x03

#define NUM_WORDS       256
#define TRANSFER_SIZE   (NUM_WORDS * 4)
#define PATTERN(i)      (0xBEEF0000u + (i))

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000

static XAxiDma dma_inst;

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    u32 *src = (u32 *)SRC_ADDR;
    u32 *dst = (u32 *)DST_ADDR;
    int errors = 0;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  bram_ctrl_top FIFO Test (%d words)\r\n", NUM_WORDS);
    xil_printf("==========================================\r\n\r\n");

    /* ---- Init DMA ---- */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed\r\n");
        return XST_FAILURE;
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* ---- Fill source buffer ---- */
    for (u32 i = 0; i < NUM_WORDS; i++) {
        src[i] = PATTERN(i);
    }
    memset(dst, 0xAA, TRANSFER_SIZE);

    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_SIZE);
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_SIZE);

    /* ---- PHASE 1: LOAD (push data into FIFO) ---- */
    xil_printf("[1] LOAD: writing %d words into FIFO ...\r\n", NUM_WORDS);

    /* Configure n_words */
    Xil_Out32(CTRL_BASE + REG_NWORDS, NUM_WORDS);

    /* Start LOAD command (edge-sensitive: write CMD then NOP) */
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    /* DMA MM2S: push data from DDR to FIFO */
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, TRANSFER_SIZE,
                           XAXIDMA_DMA_TO_DEVICE);

    /* Wait for MM2S to complete */
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    xil_printf("    MM2S done (FIFO loaded)\r\n");

    /* ---- PHASE 2: DRAIN (read data from FIFO) ---- */
    xil_printf("[2] DRAIN: reading %d words from FIFO ...\r\n", NUM_WORDS);

    /* Start DMA S2MM FIRST (so receiver is ready before data arrives) */
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, TRANSFER_SIZE,
                           XAXIDMA_DEVICE_TO_DMA);

    /* Start DRAIN command */
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    /* Wait for S2MM to complete */
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));
    xil_printf("    S2MM done (FIFO drained)\r\n\r\n");

    /* ---- VERIFY ---- */
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_SIZE);

    xil_printf("  Word | Source     | Dest       | Expected   | OK?\r\n");
    xil_printf("  -----|------------|------------|------------|----\r\n");

    for (u32 i = 0; i < NUM_WORDS; i++) {
        u32 expected = PATTERN(i);
        if (dst[i] != expected) errors++;

        if (i < 16) {
            xil_printf("  %4d | 0x%08X | 0x%08X | 0x%08X | %s\r\n",
                       i, src[i], dst[i], expected,
                       (dst[i] == expected) ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS (%d/%d words OK)\r\n", NUM_WORDS, NUM_WORDS);
    } else {
        xil_printf("  FAIL (%d errores de %d)\r\n", errors, NUM_WORDS);
    }
    xil_printf("==========================================\r\n");

    /* STOP HERE - so JTAG can read the buffers */
    while(1);

    return 0;
}
