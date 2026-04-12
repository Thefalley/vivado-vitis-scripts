/*
 * counter_test.c - Test bram_ctrl_top v2 counters + FIFO via DMA
 *
 * Tests:
 *   1. Reset counters, verify all zero
 *   2. Load 100 words, verify occupancy=100, total_in=100, total_out=0
 *   3. Drain 40 words, verify occupancy=60, total_in=100, total_out=40
 *   4. Drain remaining 60, verify occupancy=0, total_in=100, total_out=100
 *   5. Verify data integrity
 *   6. Reset counters again, verify all zero
 *
 * JTAG markers at 0x01200000:
 *   [0] = result: 0xCAFE0000=PASS, 0xDEAD0000+n=FAIL(n errors)
 *   [1] = data errors
 *   [2] = counter errors
 *   [3] = last phase completed
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
#define REG_CMD           0x00
#define REG_NWORDS        0x04
#define REG_COUNTER_RST   0x08
#define REG_CTRL_STATE    0x0C
#define REG_OCCUPANCY     0x10
#define REG_TOTAL_IN_LO   0x14
#define REG_TOTAL_IN_HI   0x18
#define REG_TOTAL_IN_HH   0x1C
#define REG_TOTAL_IN_HHH  0x20
#define REG_TOTAL_OUT_LO  0x24
#define REG_TOTAL_OUT_HI  0x28
#define REG_TOTAL_OUT_HH  0x2C
#define REG_TOTAL_OUT_HHH 0x30

/* Commands */
#define CMD_NOP         0x00
#define CMD_LOAD        0x01
#define CMD_DRAIN       0x02
#define CMD_STOP        0x03

#define TOTAL_WORDS     100
#define DRAIN_CHUNK1    40
#define DRAIN_CHUNK2    60
#define PATTERN(i)      (0xBEEF0000u + (i))

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define MARKER_ADDR     0x01200000

static XAxiDma dma_inst;

static void marker(int idx, u32 val) {
    volatile u32 *m = (volatile u32 *)(MARKER_ADDR + idx * 4);
    *m = val;
    Xil_DCacheFlushRange((UINTPTR)m, 4);
}

/* Busy-wait approximately N microseconds */
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

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    volatile u32 *src = (volatile u32 *)SRC_ADDR;
    volatile u32 *dst = (volatile u32 *)DST_ADDR;
    int data_errors = 0;
    int counter_errors = 0;
    u32 occ, in_lo, out_lo, st;

    /* Clear markers */
    for (int i = 0; i < 8; i++) marker(i, 0);

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  P_102 bram_ctrl_v2 Counter Test\r\n");
    xil_printf("  Load %d, Drain %d+%d\r\n", TOTAL_WORDS, DRAIN_CHUNK1, DRAIN_CHUNK2);
    xil_printf("==========================================\r\n\r\n");

    /* ---- Init DMA ---- */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed\r\n");
        marker(0, 0xEEEE0001);
        while(1);
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* ---- Fill source, clear dest ---- */
    for (u32 i = 0; i < TOTAL_WORDS; i++) {
        src[i] = PATTERN(i);
    }
    memset((void *)dst, 0xAA, TOTAL_WORDS * 4);
    Xil_DCacheFlushRange((UINTPTR)src, TOTAL_WORDS * 4);
    Xil_DCacheFlushRange((UINTPTR)dst, TOTAL_WORDS * 4);

    /* ============================================================
     * STEP 1: Reset counters
     * ============================================================ */
    marker(3, 1);
    xil_printf("[1] Reset counters ...\r\n");
    Xil_Out32(CTRL_BASE + REG_COUNTER_RST, 0x01);
    wait_us(10);
    Xil_Out32(CTRL_BASE + REG_COUNTER_RST, 0x00);
    wait_us(10);

    occ    = Xil_In32(CTRL_BASE + REG_OCCUPANCY);
    in_lo  = Xil_In32(CTRL_BASE + REG_TOTAL_IN_LO);
    out_lo = Xil_In32(CTRL_BASE + REG_TOTAL_OUT_LO);
    st     = Xil_In32(CTRL_BASE + REG_CTRL_STATE);
    xil_printf("    state=%d occ=%d in=%d out=%d\r\n", st, occ, in_lo, out_lo);

    if (occ != 0) { counter_errors++; xil_printf("    FAIL: occ!=0\r\n"); }
    if (in_lo != 0) { counter_errors++; xil_printf("    FAIL: in!=0\r\n"); }
    if (out_lo != 0) { counter_errors++; xil_printf("    FAIL: out!=0\r\n"); }

    /* ============================================================
     * STEP 2: Load 100 words
     * ============================================================ */
    marker(3, 2);
    xil_printf("[2] LOAD %d words ...\r\n", TOTAL_WORDS);

    Xil_Out32(CTRL_BASE + REG_NWORDS, TOTAL_WORDS);
    wait_us(10);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_LOAD);
    wait_us(1);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    wait_us(10);

    /* DMA MM2S */
    Xil_DCacheFlushRange((UINTPTR)src, TOTAL_WORDS * 4);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src,
                                     TOTAL_WORDS * 4, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S failed\r\n");
        marker(0, 0xEEEE0002);
        while(1);
    }

    if (wait_dma(XAXIDMA_DMA_TO_DEVICE, 2000)) {
        xil_printf("ERROR: MM2S timeout\r\n");
        marker(0, 0xEEEE0003);
        while(1);
    }
    xil_printf("    MM2S done\r\n");

    wait_us(100);

    /* Read counters after LOAD */
    occ    = Xil_In32(CTRL_BASE + REG_OCCUPANCY);
    in_lo  = Xil_In32(CTRL_BASE + REG_TOTAL_IN_LO);
    out_lo = Xil_In32(CTRL_BASE + REG_TOTAL_OUT_LO);
    st     = Xil_In32(CTRL_BASE + REG_CTRL_STATE);
    xil_printf("    state=%d occ=%d in=%d out=%d\r\n", st, occ, in_lo, out_lo);

    if (occ != TOTAL_WORDS) { counter_errors++; xil_printf("    FAIL: occ!=%d\r\n", TOTAL_WORDS); }
    if (in_lo != TOTAL_WORDS) { counter_errors++; xil_printf("    FAIL: in!=%d\r\n", TOTAL_WORDS); }
    if (out_lo != 0) { counter_errors++; xil_printf("    FAIL: out!=0\r\n"); }

    /* ============================================================
     * STEP 3: Drain first 40 words
     * ============================================================ */
    marker(3, 3);
    xil_printf("[3] DRAIN %d words ...\r\n", DRAIN_CHUNK1);

    Xil_Out32(CTRL_BASE + REG_NWORDS, DRAIN_CHUNK1);
    wait_us(10);

    /* Start S2MM first */
    Xil_DCacheInvalidateRange((UINTPTR)dst, DRAIN_CHUNK1 * 4);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst,
                                     DRAIN_CHUNK1 * 4, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM failed\r\n");
        marker(0, 0xEEEE0004);
        while(1);
    }

    Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
    wait_us(1);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    if (wait_dma(XAXIDMA_DEVICE_TO_DMA, 2000)) {
        xil_printf("ERROR: S2MM timeout\r\n");
        marker(0, 0xEEEE0005);
        while(1);
    }
    xil_printf("    S2MM done\r\n");

    wait_us(100);

    /* Read counters after DRAIN 40 */
    occ    = Xil_In32(CTRL_BASE + REG_OCCUPANCY);
    in_lo  = Xil_In32(CTRL_BASE + REG_TOTAL_IN_LO);
    out_lo = Xil_In32(CTRL_BASE + REG_TOTAL_OUT_LO);
    xil_printf("    occ=%d in=%d out=%d\r\n", occ, in_lo, out_lo);

    if (occ != (TOTAL_WORDS - DRAIN_CHUNK1)) {
        counter_errors++;
        xil_printf("    FAIL: occ!=%d\r\n", TOTAL_WORDS - DRAIN_CHUNK1);
    }
    if (in_lo != TOTAL_WORDS) { counter_errors++; xil_printf("    FAIL: in!=%d\r\n", TOTAL_WORDS); }
    if (out_lo != DRAIN_CHUNK1) { counter_errors++; xil_printf("    FAIL: out!=%d\r\n", DRAIN_CHUNK1); }

    /* ============================================================
     * STEP 4: Drain remaining 60 words
     * ============================================================ */
    marker(3, 4);
    xil_printf("[4] DRAIN %d words ...\r\n", DRAIN_CHUNK2);

    Xil_Out32(CTRL_BASE + REG_NWORDS, DRAIN_CHUNK2);
    wait_us(10);

    /* S2MM for remaining words */
    Xil_DCacheInvalidateRange((UINTPTR)(dst + DRAIN_CHUNK1), DRAIN_CHUNK2 * 4);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)(dst + DRAIN_CHUNK1),
                                     DRAIN_CHUNK2 * 4, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM failed\r\n");
        marker(0, 0xEEEE0006);
        while(1);
    }

    Xil_Out32(CTRL_BASE + REG_CMD, CMD_DRAIN);
    wait_us(1);
    Xil_Out32(CTRL_BASE + REG_CMD, CMD_NOP);

    if (wait_dma(XAXIDMA_DEVICE_TO_DMA, 2000)) {
        xil_printf("ERROR: S2MM timeout\r\n");
        marker(0, 0xEEEE0007);
        while(1);
    }
    xil_printf("    S2MM done\r\n");

    wait_us(100);

    /* Read counters after full drain */
    occ    = Xil_In32(CTRL_BASE + REG_OCCUPANCY);
    in_lo  = Xil_In32(CTRL_BASE + REG_TOTAL_IN_LO);
    out_lo = Xil_In32(CTRL_BASE + REG_TOTAL_OUT_LO);
    xil_printf("    occ=%d in=%d out=%d\r\n", occ, in_lo, out_lo);

    if (occ != 0) { counter_errors++; xil_printf("    FAIL: occ!=0\r\n"); }
    if (in_lo != TOTAL_WORDS) { counter_errors++; xil_printf("    FAIL: in!=%d\r\n", TOTAL_WORDS); }
    if (out_lo != TOTAL_WORDS) { counter_errors++; xil_printf("    FAIL: out!=%d\r\n", TOTAL_WORDS); }

    /* ============================================================
     * STEP 5: Verify data integrity
     * ============================================================ */
    marker(3, 5);
    xil_printf("[5] Verify data ...\r\n");

    Xil_DCacheInvalidateRange((UINTPTR)dst, TOTAL_WORDS * 4);

    xil_printf("  Word | Source     | Dest       | OK?\r\n");
    xil_printf("  -----|------------|------------|----\r\n");

    for (u32 i = 0; i < TOTAL_WORDS; i++) {
        u32 expected = PATTERN(i);
        if (dst[i] != expected) data_errors++;

        if (i < 4 || i >= TOTAL_WORDS - 4 || dst[i] != expected) {
            xil_printf("  %4d | 0x%08X | 0x%08X | %s\r\n",
                       i, src[i], dst[i],
                       (dst[i] == expected) ? "OK" : "FAIL");
        }
    }

    /* ============================================================
     * STEP 6: Reset counters and verify
     * ============================================================ */
    marker(3, 6);
    xil_printf("[6] Reset counters again ...\r\n");
    Xil_Out32(CTRL_BASE + REG_COUNTER_RST, 0x01);
    wait_us(10);
    Xil_Out32(CTRL_BASE + REG_COUNTER_RST, 0x00);
    wait_us(10);

    occ    = Xil_In32(CTRL_BASE + REG_OCCUPANCY);
    in_lo  = Xil_In32(CTRL_BASE + REG_TOTAL_IN_LO);
    out_lo = Xil_In32(CTRL_BASE + REG_TOTAL_OUT_LO);
    xil_printf("    occ=%d in=%d out=%d\r\n", occ, in_lo, out_lo);

    if (occ != 0) { counter_errors++; xil_printf("    FAIL: occ!=0\r\n"); }
    if (in_lo != 0) { counter_errors++; xil_printf("    FAIL: in!=0\r\n"); }
    if (out_lo != 0) { counter_errors++; xil_printf("    FAIL: out!=0\r\n"); }

    /* ============================================================
     * RESULTS
     * ============================================================ */
    marker(1, data_errors);
    marker(2, counter_errors);
    marker(3, 0xFF);

    xil_printf("\r\n==========================================\r\n");
    if (data_errors == 0 && counter_errors == 0) {
        xil_printf("  PASS (data: %d/%d OK, counters: 0 errors)\r\n",
                   TOTAL_WORDS, TOTAL_WORDS);
        marker(0, 0xCAFE0000);
    } else {
        xil_printf("  FAIL (data: %d errors, counters: %d errors)\r\n",
                   data_errors, counter_errors);
        marker(0, 0xDEAD0000 + data_errors + counter_errors);
    }
    xil_printf("==========================================\r\n");

    while (1);
    return 0;
}
