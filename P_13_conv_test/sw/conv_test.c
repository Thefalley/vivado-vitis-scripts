/*
 * conv_test.c -- Test conv_engine via AXI-Lite wrapper on ZedBoard
 *
 * Uses a dual-port BRAM (4KB) as DDR model.
 * ARM writes input/weights/bias into BRAM via AXI-Lite (offset 0x1000),
 * configures conv_engine registers, starts it, waits for done,
 * then reads the output from BRAM and compares with expected values.
 *
 * Test case: layer_005, 3x3 input, 3 channels in, 32 channels out,
 *            3x3 kernel, stride=1, pad=1.
 *
 * BRAM layout (4KB = 0x000-0xFFF):
 *   0x000-0x01A: input  (27 bytes)
 *   0x400-0x75F: weights (864 bytes)
 *   0x800-0x87F: bias   (128 bytes)
 *   0xC00-0xD1F: output (288 bytes)
 */

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

/* Base address of conv_test_wrapper (from xparameters.h) */
#ifndef XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR
#define XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR 0x43C00000
#endif
#define WRAPPER_BASE  XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR

/* Register offsets */
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
#define REG_BRAM_BASE      0x1000

/* BRAM internal addresses (what conv_engine sees) */
#define BRAM_INPUT_ADDR    0x000
#define BRAM_WEIGHTS_ADDR  0x400
#define BRAM_BIAS_ADDR     0x800
#define BRAM_OUTPUT_ADDR   0xC00

/* Config */
#define C_IN    3
#define C_OUT   32
#define H_IN    3
#define W_IN    3
#define KSIZE   2    /* 3x3 */
#define STRIDE  0    /* stride 1 */
#define PAD     1
#define H_OUT   3
#define W_OUT   3

/* Shared result area for XSCT polling */
#define RESULT_ADDR   0x01200000
#define MAGIC_DONE    0xDEAD1234

/* ========================================================================= */
/* Test data from conv_engine_test_vectors.txt (layer_005, pixel 200,200)    */
/* ========================================================================= */

/* Input image: 3x3, 3 channels, NCHW order = 27 bytes */
static const s8 input_data[27] = {
     56,-106,  21,  50,-102,  17,   6, -97,  -6,
     62, -64,  39,  59, -57,  34,  29, -42,  23,
     65, -40,  44,  70, -31,  33,  39, -24,  31
};

/* Weights: 32 filters x 27 values = 864 bytes */
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

/* Bias: 32 values as int32 */
static const s32 bias_data[32] = {
    1623, 1048, 1258, 232, 1845, 1748, 1300, 1221,
    1861, 123, -859, -1173, 4085, 2515, 659, 825,
    1526, 3951, 1526, 1647, 1409, -616, 1566, 984,
    -6950, 1229, -10249, 2056, -8582, 1821, 3756, 814
};

/* Expected output: pixel(1,1) for all 32 channels */
static const s8 expected_center[32] = {
     -9, -53, -10, -25, -20,  -2, -17,  -7,
     -5, -56, -31, -14,  -6, -15, -14, -24,
    -43,  67, -25,   2, -23, -27, -11, -18,
    -39, -51, -43,   9, -57, -16,  14, -17
};

/* Expected output: all 9 pixels for channel 0 */
static const s8 expected_ch0_all[9] = {
    -36, -11, -45,
    -37,  -9, -52,
    -29, -14, -42
};


/* ========================================================================= */

static void write_reg(u32 offset, u32 val)
{
    Xil_Out32(WRAPPER_BASE + offset, val);
}

static u32 read_reg(u32 offset)
{
    return Xil_In32(WRAPPER_BASE + offset);
}

/* Write 4 bytes to BRAM at word-aligned address */
static void write_bram_word(u32 bram_addr, u32 val)
{
    Xil_Out32(WRAPPER_BASE + REG_BRAM_BASE + bram_addr, val);
}

/* Write a byte array to BRAM, packing into 32-bit words.
 * bram_addr must be word-aligned (multiple of 4).
 * Handles partial last word. */
static void write_bram_bytes(u32 bram_addr, const s8 *data, int len)
{
    int i = 0;
    /* Full words */
    for (; i + 3 < len; i += 4) {
        u32 word = ((u32)(u8)data[i])
                 | ((u32)(u8)data[i+1] << 8)
                 | ((u32)(u8)data[i+2] << 16)
                 | ((u32)(u8)data[i+3] << 24);
        write_bram_word(bram_addr + i, word);
    }
    /* Remaining bytes (partial word) */
    if (i < len) {
        u32 word = 0;
        for (int j = 0; j < len - i; j++) {
            word |= ((u32)(u8)data[i+j]) << (j * 8);
        }
        /* Fill unused bytes with 0 */
        write_bram_word(bram_addr + i, word);
    }
}

/* Read a byte from BRAM */
static s8 read_bram_byte(u32 bram_addr)
{
    u32 word_addr = bram_addr & ~0x3u;
    u32 byte_pos  = bram_addr & 0x3u;
    u32 word = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + word_addr);
    return (s8)((word >> (byte_pos * 8)) & 0xFF);
}

int main(void)
{
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    int errors = 0;
    u32 ctrl;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n===================================================\r\n");
    xil_printf("  Conv Engine Test -- layer_005, 3x3, 32 filters\r\n");
    xil_printf("===================================================\r\n\r\n");

    /* ---- Step 1: Write input to BRAM ---- */
    xil_printf("Writing input (27 bytes) to BRAM @ 0x%03X...\r\n", BRAM_INPUT_ADDR);
    write_bram_bytes(BRAM_INPUT_ADDR, input_data, 27);

    /* ---- Step 2: Write weights to BRAM (OIHW → OHWI transpose) ---- */
    /* weight_data is in OIHW format (from ONNX), but conv_engine expects OHWI.
     * Conv loop order: kh → kw → ic (inner), so weight_buf layout is OHWI:
     *   OHWI[oc][kh][kw][ic] = OIHW[oc][ic][kh][kw]
     * Transpose formula per filter:
     *   ohwi[kh * kw_sz * c_in + kw * c_in + ic] = oihw[ic * kh_sz * kw_sz + kh * kw_sz + kw]
     */
    xil_printf("Writing weights (864 bytes, OIHW->OHWI) to BRAM @ 0x%03X...\r\n", BRAM_WEIGHTS_ADDR);
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

    /* ---- Step 3: Write bias to BRAM (little-endian int32) ---- */
    xil_printf("Writing bias (32 x int32) to BRAM @ 0x%03X...\r\n", BRAM_BIAS_ADDR);
    for (int i = 0; i < 32; i++) {
        write_bram_word(BRAM_BIAS_ADDR + i * 4, (u32)bias_data[i]);
    }

    /* ---- Step 4: Clear output area ---- */
    for (int i = 0; i < 288; i += 4) {
        write_bram_word(BRAM_OUTPUT_ADDR + i, 0xDEDEDEDE);
    }

    /* ---- Step 5: Configure conv_engine registers ---- */
    xil_printf("Configuring conv_engine registers...\r\n");
    write_reg(REG_CTRL, 0);   /* Ensure start is 0 */
    write_reg(REG_C_IN,  C_IN);
    write_reg(REG_C_OUT, C_OUT);
    write_reg(REG_H_IN,  H_IN);
    write_reg(REG_W_IN,  W_IN);
    /* ksize in bits [1:0], stride in bit [2], pad in bit [3] */
    write_reg(REG_KSP, (PAD << 3) | (STRIDE << 2) | KSIZE);
    /* x_zp = -128 -> 9-bit signed: 0x180 */
    write_reg(REG_X_ZP, (u32)(s32)(-128) & 0x1FF);
    write_reg(REG_W_ZP, 0);
    write_reg(REG_M0, 656954014u);
    write_reg(REG_N_SHIFT, 37);
    /* y_zp = -17 -> 8-bit signed: 0xEF */
    write_reg(REG_Y_ZP, (u32)(s32)(-17) & 0xFF);
    write_reg(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);
    write_reg(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);
    write_reg(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);
    write_reg(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);

    /* ---- Step 6: Start conv_engine ---- */
    xil_printf("Starting conv_engine...\r\n");
    write_reg(REG_CTRL, 1);  /* Set start bit */

    /* ---- Step 7: Poll for done ---- */
    int timeout = 0;
    do {
        ctrl = read_reg(REG_CTRL);
        timeout++;
        if (timeout > 10000000) {
            xil_printf("ERROR: Timeout waiting for done! ctrl=0x%08X\r\n", ctrl);
            res[0] = MAGIC_DONE;
            res[1] = 0;
            res[2] = 99;
            Xil_DCacheFlushRange((UINTPTR)res, 64);
            while(1);
        }
    } while ((ctrl & 0x02) == 0);  /* bit 1 = done */

    xil_printf("Conv_engine DONE (polls=%d, ctrl=0x%08X)\r\n\r\n", timeout, ctrl);

    /* Clear start */
    write_reg(REG_CTRL, 0);

    /* ---- Step 8: Read and verify pixel(1,1) for all 32 channels ---- */
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

    /* ---- Step 9: Verify all 9 pixels for channel 0 ---- */
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

    xil_printf("\r\n===================================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS: 41/41 -- BIT-EXACTO\r\n");
    } else {
        xil_printf("  FAIL: %d errores de 41\r\n", errors);
    }
    xil_printf("===================================================\r\n");

    /* Dump all 288 raw output bytes to DDR so XSCT can read them */
    volatile u8 *dump = (volatile u8 *)(RESULT_ADDR + 0x100);
    for (int i = 0; i < 288; i++) {
        dump[i] = (u8)read_bram_byte(BRAM_OUTPUT_ADDR + i);
    }
    Xil_DCacheFlushRange((UINTPTR)dump, 288);

    /* Also dump the 3 bias words we wrote (sanity check) */
    volatile u32 *dumpb = (volatile u32 *)(RESULT_ADDR + 0x300);
    for (int i = 0; i < 32; i++) {
        /* Read back BRAM to verify the write actually stuck */
        u32 word_addr = BRAM_BIAS_ADDR + i * 4;
        dumpb[i] = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + word_addr);
    }
    Xil_DCacheFlushRange((UINTPTR)dumpb, 128);

    /* Also read back a few input bytes */
    volatile u32 *dumpi = (volatile u32 *)(RESULT_ADDR + 0x400);
    for (int i = 0; i < 8; i++) {
        dumpi[i] = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + i * 4);
    }
    Xil_DCacheFlushRange((UINTPTR)dumpi, 32);

    /* Weight readback: first 32 bytes of each of the first 4 filters */
    volatile u32 *dumpw = (volatile u32 *)(RESULT_ADDR + 0x500);
    for (int i = 0; i < 32; i++) {
        u32 word_addr = BRAM_WEIGHTS_ADDR + i * 4;
        dumpw[i] = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + word_addr);
    }
    Xil_DCacheFlushRange((UINTPTR)dumpw, 128);

    /* Signal to XSCT */
    res[0] = MAGIC_DONE;
    res[1] = 32 + 9;  /* total tests */
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    while(1);
    return 0;
}
