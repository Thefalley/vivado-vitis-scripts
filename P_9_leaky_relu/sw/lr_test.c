/*
 * lr_test.c — Test LeakyRelu layer_006 via DMA en ZedBoard
 *
 * Envia los 256 valores posibles de INT8 (-128..127) por DMA,
 * leaky_relu_stream procesa, DMA devuelve resultado.
 * Compara contra tabla de referencia validada con ONNX Runtime.
 *
 * Parametros layer_006 (hardcoded en leaky_relu_stream generics):
 *   x_zp=-17, y_zp=-110, M0_pos=881676063, M0_neg=705340861, n_pos=29, n_neg=32
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR

#define NUM_TESTS       256
#define TRANSFER_SIZE   (NUM_TESTS * 4)  /* 32-bit words */

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define RESULT_ADDR     0x01200000

#define MAGIC_RUNNING   0xAAAA0001
#define MAGIC_DONE      0xDEAD1234

static XAxiDma dma_inst;

/* Tabla de referencia: expected[x+128] = y para x = -128..127 */
/* Validada contra ONNX Runtime: 5,537,792 valores, 0 errores */
static const s8 expected[256] = {
    /* x = -128 .. -1 */
    -128, -128, -128, -128, -128, -127, -127, -127, -127, -127,  /*  -128..-119 */
    -127, -126, -126, -126, -126, -126, -126, -125, -125, -125,  /*  -118..-109 */
    -125, -125, -125, -124, -124, -124, -124, -124, -124, -123,  /*  -108..-99  */
    -123, -123, -123, -123, -123, -122, -122, -122, -122, -122,  /*   -98..-89  */
    -122, -121, -121, -121, -121, -121, -121, -121, -120, -120,  /*   -88..-79  */
    -120, -120, -120, -120, -119, -119, -119, -119, -119, -119,  /*   -78..-69  */
    -118, -118, -118, -118, -118, -118, -117, -117, -117, -117,  /*   -68..-59  */
    -117, -117, -116, -116, -116, -116, -116, -116, -115, -115,  /*   -58..-49  */
    -115, -115, -115, -115, -114, -114, -114, -114, -114, -114,  /*   -48..-39  */
    -113, -113, -113, -113, -113, -113, -112, -112, -112, -112,  /*   -38..-29  */
    -112, -112, -111, -111, -111, -111, -111, -111, -110, -110,  /*   -28..-19  */
    -110, -110,                                                    /*   -18..-17  */
    /* x = -16 (shifted=+1, rama POS) .. -1 */
    -108, -107, -105, -103, -102, -100,  -99,  -97,  -95,  -94,  /*   -16..-7   */
     -92,  -90,  -89,  -87,  -85,  -84,                           /*    -6..-1   */
    /* x = 0 .. 127 */
     -82,  -80,  -79,  -77,  -76,  -74,  -72,  -71,  -69,  -67,  /*     0..9    */
     -66,  -64,  -62,  -61,  -59,  -57,  -56,  -54,  -53,  -51,  /*    10..19   */
     -49,  -48,  -46,  -44,  -43,  -41,  -39,  -38,  -36,  -34,  /*    20..29   */
     -33,  -31,  -30,  -28,  -26,  -25,  -23,  -21,  -20,  -18,  /*    30..39   */
     -16,  -15,  -13,  -11,  -10,   -8,   -7,   -5,   -3,   -2,  /*    40..49   */
       0,    2,    3,    5,    7,    8,   10,   12,   13,   15,    /*    50..59   */
      16,   18,   20,   21,   23,   25,   26,   28,   30,   31,   /*    60..69   */
      33,   35,   36,   38,   39,   41,   43,   44,   46,   48,   /*    70..79   */
      49,   51,   53,   54,   56,   58,   59,   61,   62,   64,   /*    80..89   */
      66,   67,   69,   71,   72,   74,   76,   77,   79,   81,   /*    90..99   */
      82,   84,   85,   87,   89,   90,   92,   94,   95,   97,   /*   100..109  */
      99,  100,  102,  103,  105,  107,  108,  110,  112,  113,   /*   110..119  */
     115,  117,  118,  120,  122,  123,  125,  126                 /*   120..127  */
};

int main(void)
{
    XAxiDma_Config *cfg;
    volatile u32 *src = (volatile u32 *)SRC_ADDR;
    volatile u32 *dst = (volatile u32 *)DST_ADDR;
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    int errors = 0;

    /* Marcar como running */
    res[0] = MAGIC_RUNNING;
    res[1] = 0;  /* total_tests */
    res[2] = 0;  /* total_errors */
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  LeakyRelu Layer_006 — Full INT8 Sweep\r\n");
    xil_printf("  256 test vectors via DMA\r\n");
    xil_printf("==========================================\r\n\r\n");

    /* Init DMA */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    XAxiDma_CfgInitialize(&dma_inst, cfg);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Fill source: x = -128..127, packed as 32-bit (sign-extended lower 8 bits) */
    for (int i = 0; i < NUM_TESTS; i++) {
        s8 x = (s8)(i - 128);
        src[i] = (u32)(u8)x;  /* lower 8 bits = signed byte as unsigned */
    }
    memset((void *)dst, 0xDE, TRANSFER_SIZE);

    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_SIZE);
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_SIZE);

    /* DMA transfer */
    xil_printf("Enviando %d tests por DMA...\r\n\r\n", NUM_TESTS);

    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, TRANSFER_SIZE, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, TRANSFER_SIZE, XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_SIZE);

    /* Verify */
    xil_printf("  x_in | got | exp | OK?\r\n");
    xil_printf("  -----+-----+-----+----\r\n");

    for (int i = 0; i < NUM_TESTS; i++) {
        s8 x = (s8)(i - 128);
        s8 got = (s8)(dst[i] & 0xFF);
        s8 exp = expected[i];
        int ok = (got == exp);

        if (!ok) errors++;

        /* Print first 20, last 10, transitions, and failures */
        if (i < 20 || i >= 246 || !ok ||
            i == 111 || i == 112 || i == 113 ||  /* around x_zp=-17 */
            i == 128) {                            /* x=0 */
            xil_printf("  %4d | %4d | %4d | %s\r\n",
                       (int)x, (int)got, (int)exp,
                       ok ? "OK" : "FAIL");
        }
    }

    /* Write result to DDR for JTAG reading */
    res[0] = MAGIC_DONE;
    res[1] = NUM_TESTS;
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS: %d/%d tests OK (full INT8 sweep)\r\n", NUM_TESTS, NUM_TESTS);
        xil_printf("  LeakyRelu layer_006 BIT-EXACTO\r\n");
    } else {
        xil_printf("  FAIL: %d/%d errores\r\n", errors, NUM_TESTS);
    }
    xil_printf("==========================================\r\n");

    while(1);
    return 0;
}
