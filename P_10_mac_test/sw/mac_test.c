/*
 * mac_test.c — Test mac_array layer_005 pixel (200,200) via DMA
 *
 * Envia 32 bias + 27 pasos MAC (a_in + 32 pesos) empaquetados.
 * Lee 32 acumuladores de vuelta. Compara contra referencia ONNX.
 *
 * Formato entrada (275 words de 32 bits):
 *   Words  0..31: bias[0..31] como int32
 *   Steps  0..26: 9 words cada uno:
 *     Word 0: a_in (signed 9 bits en [8:0])
 *     Words 1-8: b_in[0..31] packed 4×int8 por word (little-endian)
 *
 * Formato salida (32 words): acc_out[0..31] como int32
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR
#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define RESULT_ADDR     0x01200000
#define MAGIC_DONE      0xDEAD1234

static XAxiDma dma_inst;

/* Pack 4 signed bytes into 1 u32 (little-endian) */
static u32 pack4(s8 a, s8 b, s8 c, s8 d) {
    return ((u32)(u8)a) | ((u32)(u8)b << 8) | ((u32)(u8)c << 16) | ((u32)(u8)d << 24);
}

/* 32 bias values */
static const s32 bias[32] = {
    1623, 1048, 1258, 232, 1845, 1748, 1300, 1221,
    1861, 123, -859, -1173, 4085, 2515, 659, 825,
    1526, 3951, 1526, 1647, 1409, -616, 1566, 984,
    -6950, 1229, -10249, 2056, -8582, 1821, 3756, 814
};

/* 27 steps: a_in (int16 for convenience) */
static const s16 a_in[27] = {
    184, 22, 149, 178, 26, 145, 134, 31, 122,
    190, 64, 167, 187, 71, 162, 157, 86, 151,
    193, 88, 172, 198, 97, 161, 167, 104, 159
};

/* 27 steps × 32 weights (int8) */
static const s8 weights[27][32] = {
    { -4,-13, -2,  3, -2,  2, -1, 10,  6,-28, -1,  2, -3,  2,-10,  1, -4, -2, -4, 29,  0,-10, -7,  6, -2, -1,  0,  1,  2,-21,  1,  4},
    { -3, -2, -6, -1,-12, -2,  0, 18, -3,  7, -1,  0, -2, 11,  1,  6, -3, -1, -4,  9,  2,-13,  6,  2, -1,  1,  4,-12,  4,-36, -5,  5},
    { 10,  4, -9,-14, -1,  2, -2, 12, -9,-27, -7,  0,  1, 11, 12,  2,  4,  3, -1,-21, -1,-14, -6,  3, -2, -2,  4,  2,  0,-31,  1,  8},
    { -8, -7, -2,  0,  2,  0,  1,  0,  9,  5,  3, -1, -4,  9,-13,  4, -6, -5,-11, 36,  2,  4,  0,  4,  0,  4,  2,-11,  6, -1,  0, -2},
    {-12,  3, -7, -9,-23, -4,  6,  0, -8,127, 10, -8, -3,-46,  2, 20, -2,-48,-15,  4,  2,  5,-14, -4,  5, 18, 11,-32, 17,  1,-48, -6},
    { 11,  6, -9, -6,  5, -2,  2,  0,-12,  5,-10, -4,  1,  1, 20, 10, -8, 46,  0,-36,  2,  4, -6, -4,  1, -8, 13,-13,  4, -7, -4,  2},
    { -4,  1,  0,  8,  6,  1, -2,-10, 10,-29,  6,  2,  0,  5,-14,  1, -2, -1, -2, 25,  2,  5, -1,  5, -4,  1,  0,  2,  0, 27, -2, -4},
    { -5,  5, -1, -2,  9, -3,  1,-18, -1,-13, -4, -6,  1, -2, -3, 10,-12, -4, -4, -3,  4, 10,  2, -2,  2,  0,  6,-18,  6, 44, 55, -5},
    {  7,  0, -4, -6,  8,  0, -1,-11, -3,-27, -8, -2,  4,  9, 11,  5, -9,  5, -4,-38,  3, 10, -5, -9, -1,-14,  5,  0,  1, 31,  5,  0},
    { -2,-10,  3,  0, -5, -7,  3,  9,  7, 14,  3, -4, -5,  5, -7, -3, -1,  7, -1,-11,  3, -7,  7,  0,  0,  3,  0,  4, -3,  4,  8, -1},
    { -4, -3, -3,  3, -9, -7,  5, 17, -1,-16,  1, -6,  0,  2, -1, -9,  4,  0,  0, -3,  0, -9, 10, -3, -2,  2, -3,  6,  1, 15,-13, -1},
    {  6,  6,  0,  2, -7, -8,  5, 10, -3, 14, -8, -6,  9,  8,  4, -5,  2,  0, 11,  8,  2, -9, 10, -1, -2,  5, -4,  4, -1, 11,  7, -1},
    { -6, -9,  3, -6, -2, -6,  4,  0,  6,-11,  7, -6,-10,  5, -8, -6,  4, -5,-12,-11, -2,  1,  3, -2,  0,  1, -2,  6,  0,  0,  1, -4},
    {-12, -1, -7, -7,-16, -7, 10,  0,-10,-18, 10, -9, -4,-30,  3, -9,  9,-60,-19,  2, -7,  3,-31, -8,  4,  4,  3, 24, 14, 10,-60, -7},
    {  6,  5, -2,  9, -5, -8,  7,  0, -9,-17,-13, -8,  8, -4, 13, -9, -8, 53,  6, 21, -1,  1, -1, -5,  0, -6, 10,  8, -2,  2,-10, -4},
    { -1,  4,  4, -3, -1, -7,  6, -9,  8, 16, 10, -3, -7,  8, -7, -4,  4,  9,  4,-10, -2,  5,  3,  0,  0,  4,  0,  5, -3, -9, -3, -3},
    { -4,  6,  2, -6,  4, -7,  9,-17, -2,-27, -5, -9, -2, -5,  0,-11, -8, -3,  2, -2, -5,  9, -9, -6,  3, -5, -1,  9,  2,-14, 65, -3},
    {  6,  5,  4,  3, -3, -8,  8,-11,  0, 10,-10, -6,  8,  3,  6, -8,-12,  4,  6, 10, -1,  7,  3, -7,  0, -7, -3,  4, -4,-15,  4, -3},
    {  0, -8,  2,  4,  0,  5, -2,  6,  3, 14,  3,  3, -5,-12, -2,  3, -6,  3, -7,-20,  0, -6,  4,  3, -2, -1, -2, -4, -4, 14,  2,  1},
    { -2, -7,  1,  7, -3,  8, -6, 12,  0, -6,  1,  9,  1, -1, -1,  0,  2,  0, -1, -7,  0, -7, 17,  2,  0, -4, -7,  0, -2, 28,  1,  1},
    {  0, -5,  4,  3, -1,  5, -4,  7, -1, 16, -8,  4,  9,-14, -1,  4, -2, -2, 10, 12,  2, -6,  9,  3, -4,  2,  2, -5, -5, 22,  3,  0},
    { -3, -8,  1, -1,  3,  7, -5,  0,  3, -4,  7,  6,-10, -4, -2, -1,  3,  3,-13,-26, -4, -2,  3,  1,  1, -6, -4,  0,  2, -1,  2,  2},
    { -5, -6, -1, -6, -7, 13,-12,  0, -6,-54, 14, 19, -2, 16,  2, -4, 13,-12,-14, -1, -5,  0,-18, -2, 13, -7,  2, 23, 17,  5,-21,  0},
    {  3, -3,  5,  9,  1, 10, -9,  0, -5, -5, -8, 12,  8, -6,  5, -2, -7, 12, 10, 31, -2,  0,  3,  0,  3, -8, 25,  3, -6,  4, -5,  0},
    { -1, -1, -1, -2,  3,  6, -4, -6,  3, 14, 10,  2, -9,-11, -2,  4,  7,  4,  2,-12, -4,  4, -4,  3,  1, -4, -4, -6, -2,-17, -3,  2},
    { -2, -2,  2,-11,  5, 10,-11,-12, -3,  2, -1, 12, -3,  2,  1, -1, -1, -3,  3,  5, -5,  8,-10, -1, 13,-12,-11,  6,  5,-32, 21,  3},
    {  5, -3,  5, -3,  3,  8, -8, -7, -2, 20, -7,  8,  7,-12,  2,  3,-11,  1, 10, 24, -3,  7,  2, -2,  5, -8, -1, -4, -8,-21,  1,  2},
};

/* Expected accumulator outputs (validated against ONNX) */
static const s32 expected_acc[32] = {
    1750, -7457, 1481, -1701, -537, 3179, 35, 1992,
    2443, -8162, -3019, 589, 2227, 316, 589, -1407,
    -5361, 17484, -1748, 3940, -1184, -2026, 1345, -213,
    -4697, -7156, -5384, 5474, -8449, 227, 6471, 84
};

int main(void)
{
    XAxiDma_Config *cfg;
    volatile u32 *src = (volatile u32 *)SRC_ADDR;
    volatile u32 *dst = (volatile u32 *)DST_ADDR;
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    int errors = 0;
    int idx = 0;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  MAC Array Test — Layer 005 pixel(200,200)\r\n");
    xil_printf("  32 filtros, 27 MAC steps\r\n");
    xil_printf("==========================================\r\n\r\n");

    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    XAxiDma_CfgInitialize(&dma_inst, cfg);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Pack input data */
    /* 32 bias words */
    for (int i = 0; i < 32; i++)
        src[idx++] = (u32)bias[i];

    /* 27 MAC steps: 9 words each */
    for (int s = 0; s < 27; s++) {
        src[idx++] = (u32)(u16)a_in[s];  /* a_in in bits [8:0] */
        for (int w = 0; w < 8; w++) {
            int base = w * 4;
            src[idx++] = pack4(weights[s][base], weights[s][base+1],
                               weights[s][base+2], weights[s][base+3]);
        }
    }

    u32 src_bytes = idx * 4;     /* 275 words = 1100 bytes */
    u32 dst_bytes = 32 * 4;     /* 32 words = 128 bytes */

    xil_printf("Input: %d words (%d bytes)\r\n", idx, src_bytes);
    xil_printf("Output: 32 words (128 bytes)\r\n\r\n");

    memset((void *)dst, 0xDE, dst_bytes);
    Xil_DCacheFlushRange((UINTPTR)src, src_bytes);
    Xil_DCacheInvalidateRange((UINTPTR)dst, dst_bytes);

    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, dst_bytes, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, src_bytes, XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, dst_bytes);

    /* Verify */
    xil_printf("  ch | got        | expected   | OK?\r\n");
    xil_printf("  ---+------------+------------+----\r\n");

    for (int i = 0; i < 32; i++) {
        s32 got = (s32)dst[i];
        s32 exp = expected_acc[i];
        int ok = (got == exp);
        if (!ok) errors++;
        xil_printf("  %2d | %10d | %10d | %s\r\n", i, got, exp, ok ? "OK" : "FAIL");
    }

    res[0] = MAGIC_DONE;
    res[1] = 32;
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS: 32/32 canales OK — BIT-EXACTO\r\n");
    } else {
        xil_printf("  FAIL: %d/32 errores\r\n", errors);
    }
    xil_printf("==========================================\r\n");

    while(1);
    return 0;
}
