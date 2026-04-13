/*
 * test_ic_tiling.c -- IC tiling test with REAL ONNX weights
 *
 * Layer 002 from yolov4_int8_qop.onnx: conv2d_3/Conv2D_quant
 * Original: 1x1 conv, c_in=64, c_out=64
 * Test subset: c_in=32, c_out=32, h_in=3, w_in=3
 *
 * KEY: ic_tile_size=8 (NOT c_in!)
 *   => 4 tiles of 8 channels each
 *   => Exercises IC_TILE_ADV state machine path
 *   => MAC accumulators must be preserved across tiles
 *
 * ALL 32 output channels have REAL nonzero weights from the ONNX model.
 * Input: deterministic synthetic (gen_layer_tests.py formula)
 * Expected: Python-computed with HW-exact integer arithmetic
 *
 * Quant params (from ONNX):
 *   x_scale=0.11783, w_scale=0.006049, y_scale=0.15697
 *   x_zp=-97, w_zp=0, y_zp=7
 *   M0=1248165501, n_shift=38
 *
 * BRAM layout (1728 bytes, well within 4096):
 *   Input:   0x000-0x11F (288 B) -- 32ch x 3x3, NCHW
 *   Weights: 0x120-0x51F (1024 B) -- 32x1x1x32, OHWI
 *   Bias:    0x520-0x59F (128 B)  -- 32 x int32
 *   Output:  0x5A0-0x6BF (288 B) -- 32ch x 3x3, NCHW
 *
 * Verified in RTL simulation: 288/288 bit-exact with ic_tile_size=8
 */

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

/* Base address of conv_test_wrapper */
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
#define REG_IC_TILE_SIZE   0x3C
#define REG_BRAM_BASE      0x1000

/* BRAM addresses (what conv_engine sees) */
#define BRAM_INPUT_ADDR    0x000
#define BRAM_WEIGHTS_ADDR  0x120
#define BRAM_BIAS_ADDR     0x520
#define BRAM_OUTPUT_ADDR   0x5A0

/* Layer config */
#define C_IN    32
#define C_OUT   32
#define H_IN    3
#define W_IN    3
#define KH      1
#define KW      1
#define H_OUT   3
#define W_OUT   3
#define IC_TILE_SIZE  8   /* <<< KEY: 4 tiles of 8, NOT c_in */

#define KSP     0         /* ksize=0 (1x1), stride=0 (1), pad=0 */

#define TOTAL_INPUT    (C_IN * H_IN * W_IN)     /* 288 */
#define TOTAL_WEIGHTS  (C_OUT * C_IN * KH * KW) /* 1024 */
#define TOTAL_OUTPUT   (C_OUT * H_OUT * W_OUT)   /* 288 */

/* Shared result area for XSCT polling */
#define RESULT_ADDR   0x01200000
#define MAGIC_DONE    0xDEAD1234

/* ========================================================================= */
/* REAL data from ONNX layer_002 (conv2d_3/Conv2D_quant)                     */
/* ========================================================================= */

/* Input: NCHW, 32 channels x 3x3 = 288 bytes */
/* Formula: ((c*37 + r*17 + col*7 + c*r*3) % 256) - 128 */
static const s8 input_data[288] = {
    -128,-121,-114,-111,-104, -97, -94, -87, -80, -91, -84, -77, -71, -64, -57, -51,
     -44, -37, -54, -47, -40, -31, -24, -17,  -8,  -1,   6, -17, -10,  -3,   9,  16,
      23,  35,  42,  49,  20,  27,  34,  49,  56,  63,  78,  85,  92,  57,  64,  71,
      89,  96, 103, 121,-128,-121,  94, 101, 108,-127,-120,-113, -92, -85, -78,-125,
    -118,-111, -87, -80, -73, -49, -42, -35, -88, -81, -74, -47, -40, -33,  -6,   1,
       8, -51, -44, -37,  -7,   0,   7,  37,  44,  51, -14,  -7,   0,  33,  40,  47,
      80,  87,  94,  23,  30,  37,  73,  80,  87, 123,-126,-119,  60,  67,  74, 113,
     120, 127, -90, -83, -76,  97, 104, 111,-103, -96, -89, -47, -40, -33,-122,-115,
    -108, -63, -56, -49,  -4,   3,  10, -85, -78, -71, -23, -16,  -9,  39,  46,  53,
     -48, -41, -34,  17,  24,  31,  82,  89,  96, -11,  -4,   3,  57,  64,  71, 125,
    -124,-117,  26,  33,  40,  97, 104, 111, -88, -81, -74,  63,  70,  77,-119,-112,
    -105, -45, -38, -31, 100, 107, 114, -79, -72, -65,  -2,   5,  12,-119,-112,-105,
     -39, -32, -25,  41,  48,  55, -82, -75, -68,   1,   8,  15,  84,  91,  98, -45,
     -38, -31,  41,  48,  55, 127,-122,-115,  -8,  -1,   6,  81,  88,  95, -86, -79,
     -72,  29,  36,  43, 121,-128,-121, -43, -36, -29,  66,  73,  80, -95, -88, -81,
       0,   7,  14, 103, 110, 117, -55, -48, -41,  43,  50,  57,-116,-109,-102, -15,
      -8,  -1,  86,  93, 100, -79, -72, -65,  25,  32,  39,-127,-120,-113, -42, -35,
     -28,  65,  72,  79, -84, -77, -70,  -5,   2,   9, 105, 112, 119, -41, -34, -27
};

/* Weights: OHWI, 32 filters x 1x1 x 32ch = 1024 bytes */
/* Real weights from ONNX layer_002 first 32 oc x first 32 ic */
static const s8 weight_data[1024] = {
      -7,   8,  16,  -5,  -6,   1,   1,   3,  -6,   6,  10,   0,  -6,  35,   8,   3,
      -4,  35,  -5,  -4, -69,  15,  -4,   3,   7,  -7,  -5,   5,   6,   4,  -6,  -2,
      15, -47,  10,   4, -24,  -9, -47,   1,   4, -12,  -9, -23, -14, -23,  -4, -21,
     -12,   1,   0, -15, -16,  -4,  -8,  -9, -16,   8, -34,  14,   2, -23, -23,  -4,
      -4, -20,  -4,  -1,   2, -19,  35,   2,   0,   4,  -8, -12,  -1,   3,  10,  -9,
      -3, -17,  -8,   0,  -5,  -1,  29, -17,  -2,  -1, -36,   3, -15, -12, -10, -13,
      60,   9,  -5, -20,   4,   0,   2, -26,  -8,  -5,   6,  -1,  -1, -11,   4,  -5,
     -11,   2,  -2,  -1,  10, -50,  -3,   5, -10,  -3,   0,  11,   4,  -4,  -9,   3,
      19, -10,   3,  -6,  -5,  -3,   3,  -1,  -6,  14,  -2,  11,  -3, -85,  11,   1,
       7,  16,   1,   3,  45, -19,  -4,  14,  -6,  -1,   0,   2,   7,   2,   5, -12,
      -7, -10, -31, -30,   2,  -2,  -2,   6,  31,   7,  -7,   8,  10,   6,  -2,   1,
      11,  11,   0,   8,   7,   4,   0,  13,   7,   2,   2,   0,   5, -18,   4, -26,
      -7,  -1,   8, -24,   2,   5,   0, -11,  -2,   7,   1,   0, -11,  15,  -6,  -2,
      13,  -5,   4,   5, -19,  -2,   0,  -1, -72,  15,   3,   4,   9,   3,   5,  11,
       9,   9,  17,  87,  -2,   7,   0,  16, -10, -12,  -2,   8,   5,   1,   3,   3,
       8,   6,  -7,  14, -33,   6,   2,  -4, -75,  16,   1,  -1,   4,  -3,  -5,  12,
     -16, -18,  -7,  -4,  -3, -26,  -5,  -1,  -5, -11, -20, -29,  -7,  -1,  13, -17,
      -5,  -1,  57, -10,   5,  -4,   8,  -2,  -4,   0,  -1,   5, -33, -14,  -3,   3,
       3,   4,   9,   0,  -3,   8,  18,   0,  20,   7,   3,  26,  10,   1, -13, -16,
       7,  -1,   0,  -3,  -1,   0, -45,  23,   0,  -6,  13,   2,  -8,  42,  -1,  34,
      -4,   3,  -7,  -4,   0,  -4,   0,  -1, -17,   4, -11,  -3,   2,   0,  -5,  -7,
       1, -11,  -2,   3,   2,   3,  -7,  -4,   2,   1,  -7,   5,  -4,  -5,   2,  -2,
      -6,  -2, -10,   6,  -2,  -5,   3,  13,  19,  12,  -6, -10,   3,  20,   5,  -4,
       1,  -6,   8,  10, -26,   8,  -6,  15,  25,   1,   1,  -1,  -1,  -6,   2, -13,
       6,  23,  -7,   2,   7, -27,  -4, -18,   3,  -5,   3,  -3,  -3,   7, -16,   0,
      -2,  -1, -25, -16,  -4, -18,   3,  -5,  -2, -11,  -3,  -4, -13,  -6,  59,   0,
      -9,   1,  -6,  -1, -11, -15,  -6, -17,   5,  13,   1,  -1,   4, -10,  -9,  12,
      82,  -8, -11,  18,  -2, -14,  -7, -14,   1,  55,  -7,  39, -16,  10, -10,   3,
     -13,   5,   6,  21,  -2,  -7,   3,  15,  -7,   0,   0,  -4,   3,  41,  -5,  -2,
      -6,   3,   2,  -1, -23,  -1,  -3,  -8, -27,  14,  -1,  -2,   2,   4,  -5,  -4,
      -6,  -8,  -3,-108,  -8,   2,  -2,   0,  11,  -6,   1,  -4, -18, -16,   2,   6,
       4,  -1,   8,   6,  16, -13,  -7,   8,  92, -17,  -5,  18,  12,   0,   4,  -2,
      -7,   9, -11,  11,  12,   1,  -2,   1, -34,  -7,  -4,   6,  10,  -6,   9,   3,
      -9,  30,   3,   7,  -5,  11,  10,  25,   4,  14,   6,  -3,   3,  -8,  -4,  -5,
     -28,  -2, -18,  11, -14, -17,  -1,   1,   4,  -3,  -9, -11,  -6, -10,   8,  -2,
      20,   2,  -6,   0,   8,  25,   0,  -3,   4, -17,  -4, -16, -19,  -5,  10,   6,
     -18,  -4,   5,  33, -13,  -4,   4,  -3, -15,   6,   9,   9,   2,  -8,  -5,  -9,
       5,  12,  -9,  -2,  17,   1,  14,   7,   2,   4,   9,  -1,  -3,  -3,   0,   7,
     -54, -10,  -1, -11, -11,   4,   4,  11,   5,   2,  -1,  -6,   9,  19,   5,   3,
      18,   4,   6,   8, -46,  44,  -1,  -5, -21,   1,   2, -14,   5,   3,  15, -13,
     -18, -29,  19, -12, -22, -65,   6, -17,  31,  24, -41, -15,  -8,  13,  18,  52,
       3,  -7, -11,  -6,  -9,   2,  -9,   1,  -9,  -1,   8, -22, -69, -38,  -1, -42,
      -7,   9,  22,  -2, -15,  -3,   7,  14, -65,   1,   1,   7, -11,   1,  -2,   7,
      -6,   0,   0,   0,  10,  11,  -8,  -6,   9,   6,  10,  -2,  11,   2,   1,  12,
       1,  -3, -10,  11,  22,  -7,   3,  -4,   3,   4,   6,  -4,  -3, -31,   1,   4,
     -10,   5,  -3,  -4,  21, -21,   8,  11,   7,  -7,   2,  -2,  -5,   3,  -4,  -7,
       5,   4,  14, -45, -25,  -8,   8,  13, -11,   5,  -2,  -8,  -3,  -9,  -6,  20,
     -10,  10,   5,  -9,  -8,  -1,  -3,  12, -19,  25,   6,   5,   6,   7,   6,  23,
      12, -18,   2,  28,   3,   5,  -3,  -1,   3,   5,   0,   0,   3,  -4,   5,   1,
      -2,   5,  -4,  -6,  -4, -24,   9, -16,  96,   1,  -3, -12,   5,   4,  -2,   5,
     -17,  -2,  -9,  37,   5, -13,   5,   8,   8,   4,   8,   5,  -6, -32, -11,  -5,
      -9,  -3,   4,  -4,  16,  10,  -4,  -5,  16,  -5,  -1,  -3,  -2,  -3,  -2, -11,
     -32, -21, -24,   6,  13, -16, -12,  -3,  -9,  30,  13,   2,   0,   7,  22,  -3,
      29,   5,  -3,  -8,   2, -15, -20,  11,  -3, -44, -15,   0, -11,   3,  -1,   0,
       9,  28,  -1,   3,   9,   9,   1,   4,  -3,   2, -10,  13,  -1,   0, -12,   5,
       9,   0,  -9,   5,  10,  -1,  -8,   3,   0,  -7,  -1, -21,  -7,  -1,   1,   0,
      30,  -8,   6, -21,  -3,   2,   2,   4,  -5,  -2,  -3,  -9,  -1,  50,   1,   5,
      13, -10,  13,   6,  -7, -13,  -1,   1,  10,   8,   4,  -5,   0,  -2,   0,   8,
     -11,   3,  -9,   5, -11, -19, -21, -18,  -4, -10, -19, -22,  -9,  13,  -8, -43,
      -2,  -2,  -5, -19, -28, -19, -10, -23,  -2,  12, -36,  -3,  -2, -41, -16, -14,
      36,   0, -24,  -1,  10,   1, -15,  -6,  17,  -5,  16, -23,  -4,  -8,   5,  -2,
      -2, -32,  -3,  -9,   3,   5, -19, -48,   5,  25,   8,   5, -28,  -4,   7,  -7,
     -10,  -7,  25,  -6,   8,  -2,   1,  -6, -19, -11,   5,  15, -20, -26,   1,   0,
      22,  16,  -4,  14,  36,  13, -11, -10, -10,   8,   1,  10,  13,  -2,   2,  20
};

/* Bias: 32 x int32 (from ONNX) */
static const s32 bias_data[32] = {
    3834, 5385, 623, -458, 773, 3576, 1395, 1504,
    571, -833, -1907, -386, -50, -825, 1551, 1404,
    6400, 2318, -50, 4258, 1251, 950, 870, -2168,
    1505, -617, 2808, 176, 308, 4195, -1656, 1584
};

/* Expected output: 32ch x 3x3 = 288 bytes, NCHW
 * Python-computed with HW-exact integer arithmetic:
 *   acc = bias[oc]
 *   for ic in 0..31: acc += (x[ic,oh,ow] - x_zp) * (w[oc,0,0,ic] - w_zp)
 *   result = clamp( ((acc * M0) + 2^(n-1)) >> n + y_zp, -128, 127 )
 * Verified in RTL sim: 288/288 bit-exact with ic_tile_size=8
 */
static const s8 expected_output[288] = {
      -3,  -2,  -1,  42,  51,  52,  62,  18,  19,-128,-128,-128, -85,-106,-116, -97,
     -61, -72, -33, -37, -41, -81, -84, -88, -74,  -3,  -7,  -1,  -3,  -5, -41, -39,
     -41, -37, -46, -48, -16, -16, -16,  25,  26,  26,  45,   1,   1,  36,  37,  37,
      21,  19,  20,  55,  20,  21,   1,   0,  -2, -20, -39, -41,  20,  20,  18,  16,
      18,  21,  31,  15,  17,  91,  74,  77, -17, -22, -27, -41, -46, -51,-111, -48,
     -53,  77,  81,  85,  83,  94,  98,  31, -29, -25, -13, -16, -18, -36, -39, -42,
     -53, -29, -32,  11,  13,  14,  16,  16,  17,   5,  13,  15, -33, -35, -38, -25,
     -15, -17, -59, -20, -22,  63,  65,  68,  62,   0,   2,  38,  84,  86,  25,  25,
      25,  -4, -21, -21,   1,  19,  19,   6,   5,   4,  14,  33,  31, -36, -43, -44,
      69,  71,  74,  99,  85,  87, 109,  39,  42, -36, -39, -42, -25,  -9, -11, -25,
       6,   3,  49,  50,  52,  46,  43,  45,  63,  37,  38,  -5,  -6,  -7,  30,  28,
      28,  34,  37,  36,-101,-110,-119,-128,-128,-128,-128, -55, -64,  27,  28,  28,
      12,   5,   6,   5,   7,   8,   9,   8,   8,  15,  22,  22,  24,  18,  17, -23,
     -23, -23,   6, -23, -23, -25, -31, -31,  42,  45,  48, 109, 111, 113,  18,  28,
      31,  -6,  -7,  -8,   6,  11,  10,   4,  22,  21,  -9, -12, -15,  -5,  43,  40,
      24,  19,  16,  11,  12,  13,  10,  19,  20,  22,  -6,  -5,  51,  54,  56,  14,
       7,   9,  -8,  13,  16,-109,-121,-128,-122,-128,-128,-128, -94,-106, -38, -41,
     -44, -57, -90, -93,-117,  -2,  -5,  57,  59,  61,  47,  40,  42,  87,  67,  69
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

int main(void)
{
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    int errors = 0;
    u32 ctrl;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n===================================================\r\n");
    xil_printf("  IC Tiling Test -- REAL ONNX weights (layer_002)\r\n");
    xil_printf("  1x1 conv, c_in=32, c_out=32, ic_tile_size=8\r\n");
    xil_printf("  4 tiles of 8 channels each\r\n");
    xil_printf("===================================================\r\n\r\n");

    /* ---- Step 1: Write input to BRAM ---- */
    xil_printf("Writing input (%d bytes) to BRAM @ 0x%03X...\r\n",
               TOTAL_INPUT, BRAM_INPUT_ADDR);
    write_bram_bytes(BRAM_INPUT_ADDR, input_data, TOTAL_INPUT);

    /* ---- Step 2: Write weights to BRAM (already OHWI) ---- */
    /* For 1x1 conv: OIHW and OHWI are the same layout (no kh/kw reorder) */
    xil_printf("Writing weights (%d bytes, OHWI) to BRAM @ 0x%03X...\r\n",
               TOTAL_WEIGHTS, BRAM_WEIGHTS_ADDR);
    write_bram_bytes(BRAM_WEIGHTS_ADDR, weight_data, TOTAL_WEIGHTS);

    /* ---- Step 3: Write bias to BRAM ---- */
    xil_printf("Writing bias (%d x int32) to BRAM @ 0x%03X...\r\n",
               C_OUT, BRAM_BIAS_ADDR);
    for (int i = 0; i < C_OUT; i++) {
        write_bram_word(BRAM_BIAS_ADDR + i * 4, (u32)bias_data[i]);
    }

    /* ---- Step 4: Clear output area ---- */
    for (int i = 0; i < TOTAL_OUTPUT; i += 4) {
        write_bram_word(BRAM_OUTPUT_ADDR + i, 0xDEDEDEDE);
    }

    /* ---- Step 5: Configure conv_engine registers ---- */
    xil_printf("Configuring conv_engine registers...\r\n");
    write_reg(REG_CTRL, 0);
    write_reg(REG_C_IN,  C_IN);
    write_reg(REG_C_OUT, C_OUT);
    write_reg(REG_H_IN,  H_IN);
    write_reg(REG_W_IN,  W_IN);
    write_reg(REG_KSP,   KSP);    /* ksize=0 (1x1), stride=0, pad=0 */
    /* x_zp = -97 -> 9-bit signed: 0x19F */
    write_reg(REG_X_ZP, (u32)(s32)(-97) & 0x1FF);
    write_reg(REG_W_ZP, 0);
    write_reg(REG_M0, 1248165501u);
    write_reg(REG_N_SHIFT, 38);
    /* y_zp = 7 */
    write_reg(REG_Y_ZP, (u32)(s32)(7) & 0xFF);
    write_reg(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);
    write_reg(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);
    write_reg(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);
    write_reg(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);
    write_reg(REG_IC_TILE_SIZE, IC_TILE_SIZE);  /* <<< KEY: 8, NOT 32 */

    xil_printf("  ic_tile_size = %d (4 tiles of 8 channels)\r\n", IC_TILE_SIZE);

    /* ---- Step 6: Start conv_engine ---- */
    xil_printf("Starting conv_engine...\r\n");
    write_reg(REG_CTRL, 1);

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
    } while ((ctrl & 0x02) == 0);

    xil_printf("Conv_engine DONE (polls=%d, ctrl=0x%08X)\r\n\r\n", timeout, ctrl);
    write_reg(REG_CTRL, 0);

    /* ---- Step 8: Verify ALL 288 output bytes ---- */
    xil_printf("=== Verifying 288 output bytes (32ch x 9px) ===\r\n");

    for (int oc = 0; oc < C_OUT; oc++) {
        int ch_errors = 0;
        for (int px = 0; px < H_OUT * W_OUT; px++) {
            u32 addr = BRAM_OUTPUT_ADDR + oc * (H_OUT * W_OUT) + px;
            s8 got = read_bram_byte(addr);
            s8 exp = expected_output[oc * (H_OUT * W_OUT) + px];
            if (got != exp) {
                errors++;
                ch_errors++;
                if (ch_errors <= 2) {  /* Limit output per channel */
                    xil_printf("  FAIL oc=%d px=%d: got=%d exp=%d\r\n",
                               oc, px, (int)got, (int)exp);
                }
            }
        }
        if (ch_errors == 0) {
            /* Print first pixel as confirmation */
            u32 addr = BRAM_OUTPUT_ADDR + oc * (H_OUT * W_OUT);
            s8 got = read_bram_byte(addr);
            xil_printf("  oc %2d: 9/9 OK (y[0]=%d)\r\n", oc, (int)got);
        } else {
            xil_printf("  oc %2d: %d/9 FAIL\r\n", oc, ch_errors);
        }
    }

    /* ---- Summary ---- */
    xil_printf("\r\n===================================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS: 288/288 BIT-EXACT -- IC TILING VERIFIED\r\n");
        xil_printf("  ic_tile_size=8, 4 tiles, real ONNX weights\r\n");
    } else {
        xil_printf("  FAIL: %d errors of 288\r\n", errors);
    }
    xil_printf("===================================================\r\n");

    /* Dump all 288 raw output bytes to DDR for XSCT */
    volatile u8 *dump = (volatile u8 *)(RESULT_ADDR + 0x100);
    for (int i = 0; i < TOTAL_OUTPUT; i++) {
        dump[i] = (u8)read_bram_byte(BRAM_OUTPUT_ADDR + i);
    }
    Xil_DCacheFlushRange((UINTPTR)dump, TOTAL_OUTPUT);

    /* Signal to XSCT */
    res[0] = MAGIC_DONE;
    res[1] = TOTAL_OUTPUT;  /* total tests = 288 */
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    while(1);
    return 0;
}
