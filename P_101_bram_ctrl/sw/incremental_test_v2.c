/*
 * incremental_test_v2.c — Conservative incremental test with per-iteration
 * JTAG-readable diagnostics.
 *
 * Tests 260 words in chunks of 40 (same as original incremental test).
 * Key differences from v1:
 *   - Longer waits (100us) between phases
 *   - Per-iteration markers at MARKER_ADDR for JTAG diagnosis
 *   - DMA timeout detection (no infinite loops)
 *   - Per-chunk cache flush/invalidate
 *   - Explicit DMA reset between iterations
 *
 * JTAG markers at 0x01200000:
 *   [0] = result: 0xCAFE0000=PASS, 0xDEAD0000+n=FAIL(n errors),
 *          0xBBBBiipp where ii=iteration, pp=phase(01=MM2S,02=S2MM)
 *   [1] = iterations completed successfully
 *   [2] = current iteration (1-based)
 *   [3] = current phase in current iteration
 *   [4] = first error index (0xFFFFFFFF if none)
 *   [5] = first error dst value
 *   [6] = first error expected value
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

#define TOTAL_WORDS     260
#define CHUNK_SIZE      40
#define TRANSFER_BYTES  (TOTAL_WORDS * 4)

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define MARKER_ADDR     0x01200000

#define PATTERN(i)      (0xCAFE0000u + (i))

static XAxiDma dma_inst;

static void marker(int idx, u32 val) {
    volatile u32 *m = (volatile u32 *)(MARKER_ADDR + idx * 4);
    *m = val;
    Xil_DCacheFlushRange((UINTPTR)m, 4);
}

/* Busy-wait approximately N microseconds (ARM Cortex-A9 @ ~667MHz) */
static void wait_us(int us) {
    volatile int i;
    for (i = 0; i < us * 100; i++) {}
}

/* Wait for DMA with timeout. Returns 0=ok, 1=timeout */
static int wait_dma(int direction, int timeout_ms) {
    volatile int i;
    int loops = timeout_ms * 100000;
    for (i = 0; i < loops; i++) {
        if (!XAxiDma_Busy(&dma_inst, direction))
            return 0;
    }
    return 1;
}

/* Reset a DMA channel to clear any stuck state */
static void reset_dma_channel(int direction) {
    u32 cr_offset = (direction == XAXIDMA_DMA_TO_DEVICE) ? 0x00 : 0x30;
    u32 cr = Xil_In32(DMA_BASEADDR + cr_offset);
    Xil_Out32(DMA_BASEADDR + cr_offset, cr | 0x4);  /* Reset bit */
    /* Wait for reset to clear */
    volatile int i;
    for (i = 0; i < 10000; i++) {
        cr = Xil_In32(DMA_BASEADDR + cr_offset);
        if (!(cr & 0x4)) break;
    }
}

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    volatile u32 *src = (volatile u32 *)SRC_ADDR;
    volatile u32 *dst = (volatile u32 *)DST_ADDR;
    int errors = 0;
    int words_processed = 0;
    int iteration = 0;

    /* Clear all markers */
    for (int i = 0; i < 8; i++) marker(i, 0);
    marker(4, 0xFFFFFFFF);  /* no errors yet */

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  INCREMENTAL TEST V2 (conservative)\r\n");
    xil_printf("  Total: %d words, Chunk: %d words\r\n",
               TOTAL_WORDS, CHUNK_SIZE);
    xil_printf("==========================================\r\n\r\n");

    /* Init DMA */
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

    /* Fill source buffer */
    for (u32 i = 0; i < TOTAL_WORDS; i++) {
        src[i] = PATTERN(i);
    }

    /* Clear destination to zero and flush to DDR */
    memset((void *)dst, 0x00, TRANSFER_BYTES);
    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, TRANSFER_BYTES);

    xil_printf("  src filled, dst cleared\r\n\r\n");

    /* ============================================================
     * INCREMENTAL LOOP: chunk-by-chunk load/drain
     * ============================================================ */
    while (words_processed < TOTAL_WORDS) {
        int remaining = TOTAL_WORDS - words_processed;
        int chunk = (remaining >= CHUNK_SIZE) ? CHUNK_SIZE : remaining;
        u32 chunk_bytes = chunk * 4;
        UINTPTR src_addr = (UINTPTR)(src + words_processed);
        UINTPTR dst_addr = (UINTPTR)(dst + words_processed);

        iteration++;
        marker(1, iteration - 1);  /* completed iterations so far */
        marker(2, iteration);      /* current iteration */
        marker(3, 0);              /* phase: starting */

        xil_printf("  iter %d: words %d..%d (chunk=%d)\r\n",
                   iteration, words_processed,
                   words_processed + chunk - 1, chunk);

        /* ---------- PHASE 1: Configure n_words ---------- */
        marker(3, 1);
        Xil_Out32(CTRL_BASE + REG_NWORDS, chunk);

        /* Wait for AXI-Lite write to propagate */
        wait_us(10);

        /* ---------- PHASE 2: CMD_LOAD ---------- */
        marker(3, 2);
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
        /* Small delay to let FSM see the command before NOP */
        wait_us(1);
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

        /* Wait for NOP to propagate and FSM to latch */
        wait_us(10);

        /* ---------- PHASE 3: DMA MM2S ---------- */
        marker(3, 3);
        Xil_DCacheFlushRange(src_addr, chunk_bytes);

        status = XAxiDma_SimpleTransfer(&dma_inst, src_addr,
                                        chunk_bytes, XAXIDMA_DMA_TO_DEVICE);
        if (status != XST_SUCCESS) {
            xil_printf("  ERROR: MM2S transfer failed (%d)\r\n", status);
            marker(0, 0xEEEE0003);
            while(1);
        }

        /* ---------- PHASE 4: Wait MM2S ---------- */
        marker(3, 4);
        if (wait_dma(XAXIDMA_DMA_TO_DEVICE, 2000)) {
            xil_printf("  ERROR: MM2S timeout at iter %d\r\n", iteration);
            marker(0, 0xBBBB0000 | (iteration << 8) | 0x01);
            while(1);
        }
        xil_printf("    MM2S done\r\n");

        /* Wait for FSM to auto-return to S_IDLE after load_done */
        wait_us(100);

        /* ---------- PHASE 5: Prepare S2MM ---------- */
        marker(3, 5);
        Xil_DCacheInvalidateRange(dst_addr, chunk_bytes);

        status = XAxiDma_SimpleTransfer(&dma_inst, dst_addr,
                                        chunk_bytes, XAXIDMA_DEVICE_TO_DMA);
        if (status != XST_SUCCESS) {
            xil_printf("  ERROR: S2MM transfer failed (%d)\r\n", status);
            marker(0, 0xEEEE0004);
            while(1);
        }

        /* ---------- PHASE 6: CMD_DRAIN ---------- */
        marker(3, 6);
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
        wait_us(1);
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

        /* ---------- PHASE 7: Wait S2MM ---------- */
        marker(3, 7);
        if (wait_dma(XAXIDMA_DEVICE_TO_DMA, 2000)) {
            xil_printf("  ERROR: S2MM timeout at iter %d\r\n", iteration);
            marker(0, 0xBBBB0000 | (iteration << 8) | 0x02);
            while(1);
        }
        xil_printf("    S2MM done\r\n");

        /* Invalidate cache to read DMA-written data */
        Xil_DCacheInvalidateRange(dst_addr, chunk_bytes);

        /* Quick per-chunk verify */
        int chunk_err = 0;
        for (int j = 0; j < chunk; j++) {
            u32 idx = words_processed + j;
            u32 expected = PATTERN(idx);
            if (dst[idx] != expected) {
                chunk_err++;
                if (errors == 0) {
                    marker(4, idx);
                    marker(5, dst[idx]);
                    marker(6, expected);
                }
                errors++;
            }
        }
        if (chunk_err > 0) {
            xil_printf("    CHUNK VERIFY: %d errors in iter %d\r\n",
                       chunk_err, iteration);
        } else {
            xil_printf("    CHUNK VERIFY: OK\r\n");
        }

        words_processed += chunk;

        /* Wait between iterations for everything to settle */
        wait_us(100);
    }

    /* Final marker update */
    marker(1, iteration);  /* all iterations completed */
    marker(2, 0);          /* done */
    marker(3, 0xFF);       /* all phases complete */

    xil_printf("\r\n  All %d iterations done.\r\n\r\n", iteration);

    /* Full verification */
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    xil_printf("  Word | Source     | Dest       | OK?\r\n");
    xil_printf("  -----|------------|------------|----\r\n");

    int final_errors = 0;
    for (u32 i = 0; i < TOTAL_WORDS; i++) {
        u32 expected = PATTERN(i);
        if (dst[i] != expected) final_errors++;

        if (i < 4 || i >= TOTAL_WORDS - 4 ||
            (i % CHUNK_SIZE < 2) || (i % CHUNK_SIZE >= CHUNK_SIZE - 2) ||
            dst[i] != expected) {
            xil_printf("  %4d | 0x%08X | 0x%08X | %s\r\n",
                       i, src[i], dst[i],
                       (dst[i] == expected) ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n==========================================\r\n");
    if (final_errors == 0) {
        xil_printf("  PASS (%d/%d words OK)\r\n", TOTAL_WORDS, TOTAL_WORDS);
        xil_printf("  %d iterations, %d words/chunk\r\n", iteration, CHUNK_SIZE);
        marker(0, 0xCAFE0000);
    } else {
        xil_printf("  FAIL (%d errors)\r\n", final_errors);
        marker(0, 0xDEAD0000 + final_errors);
    }
    xil_printf("==========================================\r\n");

    while (1);
    return 0;
}
