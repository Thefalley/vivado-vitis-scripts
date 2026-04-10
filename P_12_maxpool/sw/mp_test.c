/*
 * mp_test.c -- Test maxpool_unit via DMA on ZedBoard
 *
 * Protocol: for each pixel send via AXI-Stream:
 *   1 word: 0x100 (clear, bit 8 set)
 *   25 words: int8 window values in bits [7:0] (sign-extended to u32)
 *   1 word: 0x200 (read, bit 9 set) -- TLAST on last pixel's read word
 * Total: 27 words per pixel, 13 pixels = 351 words input
 * Output: 13 words (1 per pixel)
 *
 * Test data: first 13 pixels from maxpool layer, kernel 5x5
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

#define N_PIXELS        13
#define N_VALUES        25  /* 5x5 kernel */
#define WORDS_PER_PIXEL 27  /* 1 clear + 25 values + 1 read */

#define CMD_CLEAR       0x100
#define CMD_READ        0x200

static XAxiDma dma_inst;

/* 13 pixels: 25 window values each */
static const s8 window[N_PIXELS][N_VALUES] = {
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-89,-80,-93,-128,-128,-109,-119,-117,-128,-128,-115,-118,-119},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-89,-80,-93,-106,-128,-109,-119,-117,-118,-128,-115,-118,-119,-119},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-89,-80,-93,-106,-115,-109,-119,-117,-118,-119,-115,-118,-119,-119,-119},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-80,-93,-106,-115,-113,-119,-117,-118,-119,-118,-118,-119,-119,-119,-118},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-93,-106,-115,-113,-112,-117,-118,-119,-118,-118,-119,-119,-119,-118,-117},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-106,-115,-113,-112,-109,-118,-119,-118,-118,-117,-119,-119,-118,-117,-116},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-115,-113,-112,-109,-99,-119,-118,-118,-117,-107,-119,-118,-117,-116,-110},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-113,-112,-109,-99,-89,-118,-118,-117,-107,-90,-118,-117,-116,-110,-96},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-112,-109,-99,-89,-77,-118,-117,-107,-90,-75,-117,-116,-110,-96,-83},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-109,-99,-89,-77,-72,-117,-107,-90,-75,-97,-116,-110,-96,-83,-96},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-99,-89,-77,-72,-102,-107,-90,-75,-97,-117,-110,-96,-83,-96,-102},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-89,-77,-72,-102,-128,-90,-75,-97,-117,-128,-96,-83,-96,-102,-128},
    {-128,-128,-128,-128,-128,-128,-128,-128,-128,-128,-77,-72,-102,-128,-128,-75,-97,-117,-128,-128,-83,-96,-102,-128,-128},
};

/* Expected max for each pixel */
static const s8 expected_max[N_PIXELS] = {
    -80, -80, -80, -80, -93, -106, -99, -89, -75, -72, -72, -72, -72
};

/* Encode signed int8 as u32, preserving sign in bits [7:0] */
static u32 encode_val(s8 v) {
    return (u32)((u8)v);
}

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
    xil_printf("  MaxPool Unit Test -- 13 pixels, 5x5 kernel\r\n");
    xil_printf("==========================================\r\n\r\n");

    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    XAxiDma_CfgInitialize(&dma_inst, cfg);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Pack input data: for each pixel: clear + 25 values + read */
    for (int p = 0; p < N_PIXELS; p++) {
        /* Clear command */
        src[idx++] = CMD_CLEAR;
        /* 25 window values */
        for (int v = 0; v < N_VALUES; v++) {
            src[idx++] = encode_val(window[p][v]);
        }
        /* Read command (with TLAST on last pixel handled by DMA length) */
        src[idx++] = CMD_READ;
    }

    u32 src_bytes = idx * 4;
    u32 dst_bytes = N_PIXELS * 4;

    xil_printf("Input: %d words (%d bytes)\r\n", idx, src_bytes);
    xil_printf("Output: %d words (%d bytes)\r\n\r\n", N_PIXELS, dst_bytes);

    memset((void *)dst, 0xDE, dst_bytes);
    Xil_DCacheFlushRange((UINTPTR)src, src_bytes);
    Xil_DCacheInvalidateRange((UINTPTR)dst, dst_bytes);

    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, dst_bytes, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, src_bytes, XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, dst_bytes);

    /* Verify */
    xil_printf("  px | got  | expected | OK?\r\n");
    xil_printf("  ---+------+----------+----\r\n");

    for (int i = 0; i < N_PIXELS; i++) {
        s8 got = (s8)(dst[i] & 0xFF);
        s8 exp = expected_max[i];
        int ok = (got == exp);
        if (!ok) errors++;
        xil_printf("  %2d | %4d | %4d     | %s\r\n", i, (int)got, (int)exp, ok ? "OK" : "FAIL");
    }

    res[0] = MAGIC_DONE;
    res[1] = (u32)N_PIXELS;
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS: %d/%d pixels OK -- BIT-EXACTO\r\n", N_PIXELS, N_PIXELS);
    } else {
        xil_printf("  FAIL: %d/%d errores\r\n", errors, N_PIXELS);
    }
    xil_printf("==========================================\r\n");

    while(1);
    return 0;
}
