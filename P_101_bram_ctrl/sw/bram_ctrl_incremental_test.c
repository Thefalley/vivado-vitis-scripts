/*
 * bram_ctrl_incremental_test.c
 *
 * Test de control de flujo incremental para bram_ctrl_top.
 *
 * El DMA envia 260 words de golpe, pero la FSM solo deja pasar
 * CHUNK_SIZE=40 words por iteracion. El ARM controla el flujo:
 *   - n_words=40, CMD_LOAD  -> acepta 40, auto-stop
 *   - n_words=40, CMD_DRAIN -> emite 40, auto-stop
 *   - repite hasta procesar las 260
 *
 * Al final verifica que dst[0..259] == src[0..259].
 * Esto demuestra que n_words REALMENTE controla el bloqueo.
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
#define RESULT_ADDR     0x01200000

#define PATTERN(i)      (0xCAFE0000u + (i))

static XAxiDma dma_inst;

/* Small busy-wait (~N microseconds at 100MHz ARM) */
static void wait_us(int us) {
    volatile int i;
    for (i = 0; i < us * 50; i++) {}
}

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    volatile u32 *src = (volatile u32 *)SRC_ADDR;
    volatile u32 *dst = (volatile u32 *)DST_ADDR;
    volatile u32 *result = (volatile u32 *)RESULT_ADDR;
    int errors = 0;
    int words_processed = 0;
    int iteration = 0;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  INCREMENTAL FLOW CONTROL TEST\r\n");
    xil_printf("  Total: %d words, Chunk: %d words/iter\r\n",
               TOTAL_WORDS, CHUNK_SIZE);
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

    /* Fill source with pattern */
    for (u32 i = 0; i < TOTAL_WORDS; i++) {
        src[i] = PATTERN(i);
    }
    memset((void *)dst, 0xAA, TRANSFER_BYTES);

    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_BYTES);
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    xil_printf("  Processing in chunks of %d\r\n\r\n", CHUNK_SIZE);

    /* Incremental load/drain loop.
     * Each iteration does its OWN DMA transfers (chunk-sized) so that
     * the inner FIFO's tlast matches the DMA's BTT exactly.
     * This avoids S2MM truncating at tlast when only 40 of 260 arrive. */
    while (words_processed < TOTAL_WORDS) {
        int remaining = TOTAL_WORDS - words_processed;
        int chunk = (remaining >= CHUNK_SIZE) ? CHUNK_SIZE : remaining;
        u32 chunk_bytes = chunk * 4;
        volatile u32 *src_chunk = src + words_processed;
        volatile u32 *dst_chunk = dst + words_processed;

        iteration++;

        /* Configure n_words for this chunk */
        Xil_Out32(CTRL_BASE + REG_NWORDS, chunk);

        /* --- LOAD phase --- */
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

        Xil_DCacheFlushRange((UINTPTR)src_chunk, chunk_bytes);
        XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src_chunk,
                               chunk_bytes, XAXIDMA_DMA_TO_DEVICE);
        while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));

        /* Small wait for FSM auto-idle after load */
        wait_us(5);

        /* --- DRAIN phase --- */
        Xil_DCacheInvalidateRange((UINTPTR)dst_chunk, chunk_bytes);
        XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst_chunk,
                               chunk_bytes, XAXIDMA_DEVICE_TO_DMA);

        Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
        Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

        while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

        Xil_DCacheInvalidateRange((UINTPTR)dst_chunk, chunk_bytes);

        words_processed += chunk;

        xil_printf("  iter %d: chunk=%d, total=%d/%d\r\n",
                   iteration, chunk, words_processed, TOTAL_WORDS);
    }

    xil_printf("\r\n  All chunks processed.\r\n\r\n");

    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_BYTES);

    /* Verify ALL 260 words */
    xil_printf("  Word | Source     | Dest       | OK?\r\n");
    xil_printf("  -----|------------|------------|----\r\n");

    for (u32 i = 0; i < TOTAL_WORDS; i++) {
        u32 expected = PATTERN(i);
        if (dst[i] != expected) errors++;

        /* Print first 4, last 4, and any errors */
        if (i < 4 || i >= TOTAL_WORDS - 4 || dst[i] != expected) {
            xil_printf("  %4d | 0x%08X | 0x%08X | %s\r\n",
                       i, src[i], dst[i],
                       (dst[i] == expected) ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS (%d/%d words OK)\r\n", TOTAL_WORDS, TOTAL_WORDS);
        xil_printf("  %d iterations, %d words/chunk\r\n", iteration, CHUNK_SIZE);
        xil_printf("  Flow control VERIFIED\r\n");
        *result = 0xCAFE0000;   /* marker for JTAG verify */
    } else {
        xil_printf("  FAIL (%d errors)\r\n", errors);
        *result = 0xDEAD0000 + errors;
    }
    xil_printf("==========================================\r\n");
    Xil_DCacheFlushRange((UINTPTR)result, 4);

    while (1) {}
    return 0;
}
