/*
 * conv_dma_test.c -- Test conv_engine + DMA infrastructure on ZedBoard
 *
 * Phase 1: conv_engine via AXI-Lite (identical to P_13) + DMA loopback sanity.
 *
 * This test does TWO things:
 * 1. Runs the full P_13 conv_engine test (41 checks, layer_005) via AXI-Lite
 * 2. Runs a DMA loopback sanity test (MM2S -> S2MM, data round-trip through DDR)
 *
 * Both must pass for the infrastructure to be validated.
 *
 * BRAM layout (4KB = 0x000-0xFFF):
 *   0x000-0x01A: input  (27 bytes)
 *   0x400-0x75F: weights (864 bytes)
 *   0x800-0x87F: bias   (128 bytes)
 *   0xC00-0xD1F: output (288 bytes)
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

/* ========================================================================= */
/* Address definitions                                                       */
/* ========================================================================= */

/* conv_test_wrapper base (GP0 M01 -- assigned by Vivado, typically 0x43C00000) */
#ifndef XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR
#define XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR 0x43C00000
#endif
#define WRAPPER_BASE  XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR

/* DMA base address */
#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR

/* DDR buffers for DMA loopback test */
#define DMA_SRC_ADDR    0x01000000
#define DMA_DST_ADDR    0x01100000

/* Shared result area for XSCT polling */
#define RESULT_ADDR     0x01200000
#define MAGIC_DONE      0xDEAD1234

/* Register offsets (conv_test_wrapper) */
#define REG_CTRL           0x00
#define REG_C_IN           0x04
#define REG_C_OUT          0x08
#define REG_H_IN           0x0C
#define REG_W_IN           0x10
#define REG_KSP            0x14
#define REG_X_ZP           0x18
#define REG_W_ZP           0x1C
#define REG_M0             0x20
#define REG_N_SHIFT        0x24
#define REG_Y_ZP           0x28
#define REG_ADDR_INPUT     0x2C
#define REG_ADDR_WEIGHTS   0x30
#define REG_ADDR_BIAS      0x34
#define REG_ADDR_OUTPUT    0x38
#define REG_IC_TILE_SIZE   0x3C
#define REG_BRAM_BASE      0x1000

/* BRAM internal addresses */
#define BRAM_INPUT_ADDR    0x000
#define BRAM_WEIGHTS_ADDR  0x400
#define BRAM_BIAS_ADDR     0x800
#define BRAM_OUTPUT_ADDR   0xC00

/* Conv config */
#define C_IN    3
#define C_OUT   32
#define H_IN    3
#define W_IN    3
#define KSIZE   2    /* 3x3 */
#define STRIDE  0    /* stride 1 */
#define PAD     1
#define H_OUT   3
#define W_OUT   3

/* DMA loopback config */
#define DMA_TEST_LEN    256   /* bytes to loopback */

/* ========================================================================= */
/* Test data (identical to P_13 conv_test.c)                                 */
/* ========================================================================= */

static const s8 input_data[27] = {
     56,-106,  21,  50,-102,  17,   6, -97,  -6,
     62, -64,  39,  59, -57,  34,  29, -42,  23,
     65, -40,  44,  70, -31,  33,  39, -24,  31
};

static const s8 weight_data[864] = {
    /* filtro 0 */
     -4,  -3,  10,  -8, -12,  11,  -4,  -5,   7,  -2,  -4,   6,  -6, -12,   6,  -1,  -4,   6,   0,  -2,   0,  -3,  -5,   3,  -1,  -2,   5,
    /* filtro 1 */
    -13,  -2,   4,  -7,   3,   6,   1,   5,   0, -10,  -3,   6,  -9,  -1,   5,   4,   6,   5,  -8,  -7,  -5,  -8,  -6,  -3,  -1,  -2,  -3,
    /* filtro 2 */
     -2,  -6,  -9,  -2,  -7,  -9,   0,  -1,  -4,   3,  -3,   0,   3,  -7,  -2,   4,   2,   4,   2,   1,   4,   1,  -1,   5,  -1,   2,   5,
    /* filtro 3 */
      3,  -1, -14,   0,  -9,  -6,   8,  -2,  -6,   0,   3,   2,  -6,  -7,   9,  -3,  -6,   3,   4,   7,   3,  -1,  -6,   9,  -2, -11,  -3,
    /* filtro 4 */
     -2, -12,  -1,   2, -23,   5,   6,   9,   8,  -5,  -9,  -7,  -2, -16,  -5,  -1,   4,  -3,   0,  -3,  -1,   3,  -7,   1,   3,   5,   3,
    /* filtro 5 */
      2,  -2,   2,   0,  -4,  -2,   1,  -3,   0,  -7,  -7,  -8,  -6,  -7,  -8,  -7,  -7,  -8,   5,   8,   5,   7,  13,  10,   6,  10,   8,
    /* filtro 6 */
     -1,   0,  -2,   1,   6,   2,  -2,   1,  -1,   3,   5,   5,   4,  10,   7,   6,   9,   8,  -2,  -6,  -4,  -5, -12,  -9,  -4, -11,  -8,
    /* filtro 7 */
     10,  18,  12,   0,   0,   0, -10, -18, -11,   9,  17,  10,   0,   0,   0,  -9, -17, -11,   6,  12,   7,   0,   0,   0,  -6, -12,  -7,
    /* filtro 8 */
      6,  -3,  -9,   9,  -8, -12,  10,  -1,  -3,   7,  -1,  -3,   6, -10,  -9,   8,  -2,   0,   3,   0,  -1,   3,  -6,  -5,   3,  -3,  -2,
    /* filtro 9 */
    -28,   7, -27,   5, 127,   5, -29, -13, -27,  14, -16,  14, -11, -18, -17,  16, -27,  10,  14,  -6,  16,  -4, -54,  -5,  14,   2,  20,
    /* filtro 10 */
     -1,  -1,  -7,   3,  10, -10,   6,  -4,  -8,   3,   1,  -8,   7,  10, -13,  10,  -5, -10,   3,   1,  -8,   7,  14,  -8,  10,  -1,  -7,
    /* filtro 11 */
      2,   0,   0,  -1,  -8,  -4,   2,  -6,  -2,  -4,  -6,  -6,  -6,  -9,  -8,  -3,  -9,  -6,   3,   9,   4,   6,  19,  12,   2,  12,   8,
    /* filtro 12 */
     -3,  -2,   1,  -4,  -3,   1,   0,   1,   4,  -5,   0,   9, -10,  -4,   8,  -7,  -2,   8,  -5,   1,   9, -10,  -2,   8,  -9,  -3,   7,
    /* filtro 13 */
      2,  11,  11,   9, -46,   1,   5,  -2,   9,   5,   2,   8,   5, -30,  -4,   8,  -5,   3, -12,  -1, -14,  -4,  16,  -6, -11,   2, -12,
    /* filtro 14 */
    -10,   1,  12, -13,   2,  20, -14,  -3,  11,  -7,  -1,   4,  -8,   3,  13,  -7,   0,   6,  -2,  -1,  -1,  -2,   2,   5,  -2,   1,   2,
    /* filtro 15 */
      1,   6,   2,   4,  20,  10,   1,  10,   5,  -3,  -9,  -5,  -6,  -9,  -9,  -4, -11,  -8,   3,   0,   4,  -1,  -4,  -2,   4,  -1,   3,
    /* filtro 16 */
     -4,  -3,   4,  -6,  -2,  -8,  -2, -12,  -9,  -1,   4,   2,   4,   9,  -8,   4,  -8, -12,  -6,   2,  -2,   3,  13,  -7,   7,  -1, -11,
    /* filtro 17 */
     -2,  -1,   3,  -5, -48,  46,  -1,  -4,   5,   7,   0,   0,  -5, -60,  53,   9,  -3,   4,   3,   0,  -2,   3, -12,  12,   4,  -3,   1,
    /* filtro 18 */
     -4,  -4,  -1, -11, -15,   0,  -2,  -4,  -4,  -1,   0,  11, -12, -19,   6,   4,   2,   6,  -7,  -1,  10, -13, -14,  10,   2,   3,  10,
    /* filtro 19 */
     29,   9, -21,  36,   4, -36,  25,  -3, -38, -11,  -3,   8, -11,   2,  21, -10,  -2,  10, -20,  -7,  12, -26,  -1,  31, -12,   5,  24,
    /* filtro 20 */
      0,   2,  -1,   2,   2,   2,   2,   4,   3,   3,   0,   2,  -2,  -7,  -1,  -2,  -5,  -1,   0,   0,   2,  -4,  -5,  -2,  -4,  -5,  -3,
    /* filtro 21 */
    -10, -13, -14,   4,   5,   4,   5,  10,  10,  -7,  -9,  -9,   1,   3,   1,   5,   9,   7,  -6,  -7,  -6,  -2,   0,   0,   4,   8,   7,
    /* filtro 22 */
     -7,   6,  -6,   0, -14,  -6,  -1,   2,  -5,   7,  10,  10,   3, -31,  -1,   3,  -9,   3,   4,  17,   9,   3, -18,   3,  -4, -10,   2,
    /* filtro 23 */
      6,   2,   3,   4,  -4,  -4,   5,  -2,  -9,   0,  -3,  -1,  -2,  -8,  -5,   0,  -6,  -7,   3,   2,   3,   1,  -2,   0,   3,  -1,  -2,
    /* filtro 24 */
     -2,  -1,  -2,   0,   5,   1,  -4,   2,  -1,   0,  -2,  -2,   0,   4,   0,   0,   3,   0,  -2,   0,  -4,   1,  13,   3,   1,  13,   5,
    /* filtro 25 */
     -1,   1,  -2,   4,  18,  -8,   1,   0, -14,   3,   2,   5,   1,   4,  -6,   4,  -5,  -7,  -1,  -4,   2,  -6,  -7,  -8,  -4, -12,  -8,
    /* filtro 26 */
      0,   4,   4,   2,  11,  13,   0,   6,   5,   0,  -3,  -4,  -2,   3,  10,   0,  -1,  -3,  -2,  -7,   2,  -4,   2,  25,  -4, -11,  -1,
    /* filtro 27 */
      1, -12,   2, -11, -32, -13,   2, -18,   0,   4,   6,   4,   6,  24,   8,   5,   9,   4,  -4,   0,  -5,   0,  23,   3,  -6,   6,  -4,
    /* filtro 28 */
      2,   4,   0,   6,  17,   4,   0,   6,   1,  -3,   1,  -1,   0,  14,  -2,  -3,   2,  -4,  -4,  -2,  -5,   2,  17,  -6,  -2,   5,  -8,
    /* filtro 29 */
    -21, -36, -31,  -1,   1,  -7,  27,  44,  31,   4,  15,  11,   0,  10,   2,  -9, -14, -15,  14,  28,  22,  -1,   5,   4, -17, -32, -21,
    /* filtro 30 */
      1,  -5,   1,   0, -48,  -4,  -2,  55,   5,   8, -13,   7,   1, -60, -10,  -3,  65,   4,   2,   1,   3,   2, -21,  -5,  -3,  21,   1,
    /* filtro 31 */
      4,   5,   8,  -2,  -6,   2,  -4,  -5,   0,  -1,  -1,  -1,  -4,  -7,  -4,  -3,  -3,  -3,   1,   1,   0,   2,   0,   0,   2,   3,   2
};

static const s32 bias_data[32] = {
    1623, 1048, 1258, 232, 1845, 1748, 1300, 1221,
    1861, 123, -859, -1173, 4085, 2515, 659, 825,
    1526, 3951, 1526, 1647, 1409, -616, 1566, 984,
    -6950, 1229, -10249, 2056, -8582, 1821, 3756, 814
};

static const s8 expected_center[32] = {
     -9, -53, -10, -25, -20,  -2, -17,  -7,
     -5, -56, -31, -14,  -6, -15, -14, -24,
    -43,  67, -25,   2, -23, -27, -11, -18,
    -39, -51, -43,   9, -57, -16,  14, -17
};

static const s8 expected_ch0_all[9] = {
    -36, -11, -45,
    -37,  -9, -52,
    -29, -14, -42
};

/* ========================================================================= */
/* Helper functions                                                          */
/* ========================================================================= */

static void write_reg(u32 offset, u32 val)
{
    Xil_Out32(WRAPPER_BASE + offset, val);
}

static u32 read_reg(u32 offset)
{
    return Xil_In32(WRAPPER_BASE + offset);
}

static void write_bram_word(u32 bram_addr, u32 val)
{
    Xil_Out32(WRAPPER_BASE + REG_BRAM_BASE + bram_addr, val);
}

static void write_bram_bytes(u32 bram_addr, const s8 *data, int len)
{
    int i = 0;
    for (; i + 3 < len; i += 4) {
        u32 word = ((u32)(u8)data[i])
                 | ((u32)(u8)data[i+1] << 8)
                 | ((u32)(u8)data[i+2] << 16)
                 | ((u32)(u8)data[i+3] << 24);
        write_bram_word(bram_addr + i, word);
    }
    if (i < len) {
        u32 word = 0;
        for (int j = 0; j < len - i; j++) {
            word |= ((u32)(u8)data[i+j]) << (j * 8);
        }
        write_bram_word(bram_addr + i, word);
    }
}

static s8 read_bram_byte(u32 bram_addr)
{
    u32 word_addr = bram_addr & ~0x3u;
    u32 byte_pos  = bram_addr & 0x3u;
    u32 word = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + word_addr);
    return (s8)((word >> (byte_pos * 8)) & 0xFF);
}

/* ========================================================================= */
/* DMA loopback test                                                         */
/* ========================================================================= */

static XAxiDma dma_inst;

static int dma_loopback_test(void)
{
    int status;
    XAxiDma_Config *cfg;
    volatile u8 *src = (volatile u8 *)DMA_SRC_ADDR;
    volatile u8 *dst = (volatile u8 *)DMA_DST_ADDR;
    int errors = 0;

    xil_printf("\r\n--- DMA Loopback Test (%d bytes) ---\r\n", DMA_TEST_LEN);

    /* Initialize DMA */
    cfg = XAxiDma_LookupConfig(XPAR_XAXIDMA_0_DEVICE_ID);
    if (!cfg) {
        xil_printf("ERROR: DMA LookupConfig failed\r\n");
        return -1;
    }
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA CfgInitialize failed (%d)\r\n", status);
        return -1;
    }

    /* Disable interrupts (polling mode) */
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Fill source buffer with pattern */
    for (int i = 0; i < DMA_TEST_LEN; i++) {
        src[i] = (u8)(i & 0xFF);
    }
    /* Clear destination */
    memset((void *)dst, 0xDE, DMA_TEST_LEN);

    /* Flush source, invalidate destination */
    Xil_DCacheFlushRange((UINTPTR)src, DMA_TEST_LEN);
    Xil_DCacheFlushRange((UINTPTR)dst, DMA_TEST_LEN);

    /* Start S2MM (receive) first, then MM2S (send) */
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, DMA_TEST_LEN,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM transfer start failed (%d)\r\n", status);
        return -1;
    }

    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, DMA_TEST_LEN,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S transfer start failed (%d)\r\n", status);
        return -1;
    }

    /* Poll for completion */
    int timeout = 0;
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA) ||
           XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE)) {
        timeout++;
        if (timeout > 10000000) {
            xil_printf("ERROR: DMA timeout! MM2S_busy=%d S2MM_busy=%d\r\n",
                       XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE),
                       XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));
            return -1;
        }
    }

    /* Invalidate destination cache and verify */
    Xil_DCacheInvalidateRange((UINTPTR)dst, DMA_TEST_LEN);

    for (int i = 0; i < DMA_TEST_LEN; i++) {
        if (dst[i] != (u8)(i & 0xFF)) {
            if (errors < 8) {
                xil_printf("  DMA mismatch [%d]: got 0x%02X exp 0x%02X\r\n",
                           i, dst[i], (u8)(i & 0xFF));
            }
            errors++;
        }
    }

    if (errors == 0) {
        xil_printf("  DMA loopback: %d/%d PASS\r\n", DMA_TEST_LEN, DMA_TEST_LEN);
    } else {
        xil_printf("  DMA loopback: %d errors of %d\r\n", errors, DMA_TEST_LEN);
    }

    return errors;
}

/* ========================================================================= */
/* Conv engine test (identical logic to P_13)                                */
/* ========================================================================= */

static int conv_engine_test(void)
{
    int errors = 0;
    u32 ctrl;

    xil_printf("\r\n--- Conv Engine Test (layer_005, 3x3, 32 filters) ---\r\n");

    /* Write input to BRAM */
    xil_printf("Writing input (27 bytes) to BRAM @ 0x%03X...\r\n", BRAM_INPUT_ADDR);
    write_bram_bytes(BRAM_INPUT_ADDR, input_data, 27);

    /* Write weights (OIHW -> OHWI transpose) */
    xil_printf("Writing weights (864 bytes, OIHW->OHWI) to BRAM @ 0x%03X...\r\n",
               BRAM_WEIGHTS_ADDR);
    {
        s8 w_ohwi[864];
        int kh_sz = 3, kw_sz = 3;
        for (int oc = 0; oc < C_OUT; oc++) {
            const s8 *filt = &weight_data[oc * C_IN * kh_sz * kw_sz];
            s8 *dst = &w_ohwi[oc * C_IN * kh_sz * kw_sz];
            for (int kh = 0; kh < kh_sz; kh++) {
                for (int kw = 0; kw < kw_sz; kw++) {
                    for (int ic = 0; ic < C_IN; ic++) {
                        dst[kh * kw_sz * C_IN + kw * C_IN + ic] =
                            filt[ic * kh_sz * kw_sz + kh * kw_sz + kw];
                    }
                }
            }
        }
        write_bram_bytes(BRAM_WEIGHTS_ADDR, w_ohwi, 864);
    }

    /* Write bias */
    xil_printf("Writing bias (32 x int32) to BRAM @ 0x%03X...\r\n", BRAM_BIAS_ADDR);
    for (int i = 0; i < 32; i++) {
        write_bram_word(BRAM_BIAS_ADDR + i * 4, (u32)bias_data[i]);
    }

    /* Clear output area */
    for (int i = 0; i < 288; i += 4) {
        write_bram_word(BRAM_OUTPUT_ADDR + i, 0xDEDEDEDE);
    }

    /* Configure registers */
    xil_printf("Configuring conv_engine registers...\r\n");
    write_reg(REG_CTRL, 0);
    write_reg(REG_C_IN,  C_IN);
    write_reg(REG_C_OUT, C_OUT);
    write_reg(REG_H_IN,  H_IN);
    write_reg(REG_W_IN,  W_IN);
    write_reg(REG_KSP, (PAD << 3) | (STRIDE << 2) | KSIZE);
    write_reg(REG_X_ZP, (u32)(s32)(-128) & 0x1FF);
    write_reg(REG_W_ZP, 0);
    write_reg(REG_M0, 656954014u);
    write_reg(REG_N_SHIFT, 37);
    write_reg(REG_Y_ZP, (u32)(s32)(-17) & 0xFF);
    write_reg(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);
    write_reg(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);
    write_reg(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);
    write_reg(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);
    write_reg(REG_IC_TILE_SIZE, C_IN);

    /* Start */
    xil_printf("Starting conv_engine...\r\n");
    write_reg(REG_CTRL, 1);

    /* Poll for done */
    int timeout = 0;
    do {
        ctrl = read_reg(REG_CTRL);
        timeout++;
        if (timeout > 10000000) {
            xil_printf("ERROR: Timeout! ctrl=0x%08X\r\n", ctrl);
            return 99;
        }
    } while ((ctrl & 0x02) == 0);

    xil_printf("Conv DONE (polls=%d, ctrl=0x%08X)\r\n\r\n", timeout, ctrl);
    write_reg(REG_CTRL, 0);

    /* Verify pixel(1,1) for all 32 channels */
    xil_printf("=== Pixel (1,1) - all 32 output channels ===\r\n");
    for (int oc = 0; oc < 32; oc++) {
        u32 addr = BRAM_OUTPUT_ADDR + oc * (H_OUT * W_OUT) + 1 * W_OUT + 1;
        s8 got = read_bram_byte(addr);
        s8 exp = expected_center[oc];
        int ok = (got == exp);
        if (!ok) errors++;
        xil_printf("  oc %2d: got %4d  exp %4d  %s\r\n", oc, (int)got, (int)exp,
                   ok ? "OK" : "FAIL");
    }

    /* Verify all 9 pixels for channel 0 */
    xil_printf("\r\n=== Channel 0 - all 9 pixels ===\r\n");
    for (int oh = 0; oh < 3; oh++) {
        for (int ow = 0; ow < 3; ow++) {
            u32 addr = BRAM_OUTPUT_ADDR + 0 * 9 + oh * W_OUT + ow;
            s8 got = read_bram_byte(addr);
            s8 exp = expected_ch0_all[oh * 3 + ow];
            int ok = (got == exp);
            if (!ok) errors++;
            xil_printf("  (%d,%d): got %4d  exp %4d  %s\r\n", oh, ow,
                       (int)got, (int)exp, ok ? "OK" : "FAIL");
        }
    }

    return errors;
}

/* ========================================================================= */
/* Main                                                                      */
/* ========================================================================= */

int main(void)
{
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    int conv_errors, dma_errors;
    int total_tests;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n###################################################\r\n");
    xil_printf("  P_14 Conv+DMA Test -- ZedBoard\r\n");
    xil_printf("###################################################\r\n");

    /* Part 1: Conv engine test (41 checks) */
    conv_errors = conv_engine_test();

    /* Part 2: DMA loopback sanity (256 checks) */
    dma_errors = dma_loopback_test();

    /* Summary */
    total_tests = 41 + DMA_TEST_LEN;  /* 41 conv + 256 DMA */

    xil_printf("\r\n###################################################\r\n");
    xil_printf("  RESULTADOS P_14\r\n");
    xil_printf("###################################################\r\n");
    xil_printf("  Conv engine: %s (%d/41)\r\n",
               conv_errors == 0 ? "PASS" : "FAIL", 41 - conv_errors);
    xil_printf("  DMA loopback: %s (%d/%d)\r\n",
               dma_errors <= 0 ? (dma_errors == 0 ? "PASS" : "INIT_FAIL") : "FAIL",
               dma_errors <= 0 ? DMA_TEST_LEN : DMA_TEST_LEN - dma_errors,
               DMA_TEST_LEN);

    if (conv_errors == 0 && dma_errors == 0) {
        xil_printf("\r\n  >>> ALL PASSED -- Conv + DMA infrastructure OK <<<\r\n");
    } else {
        xil_printf("\r\n  >>> FAILED: %d conv errors, %d DMA errors <<<\r\n",
                   conv_errors, dma_errors < 0 ? -1 : dma_errors);
    }
    xil_printf("###################################################\r\n");

    /* Signal to XSCT */
    res[0] = MAGIC_DONE;
    res[1] = (u32)total_tests;
    res[2] = (u32)(conv_errors + (dma_errors < 0 ? 1 : dma_errors));
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    while(1);
    return 0;
}
