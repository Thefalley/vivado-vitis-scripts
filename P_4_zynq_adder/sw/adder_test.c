/*
 * adder_test.c - Test stream_adder via DMA en ZedBoard
 * Test simple: escribe 0,1,2,3... en source, suma 5, verifica dest = 5,6,7,8...
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xstatus.h"
#include <string.h>

#define DMA_BASEADDR        XPAR_XAXIDMA_0_BASEADDR
#define STREAM_ADDER_BASE   XPAR_STREAM_ADDER_0_BASEADDR
#define ADDER_REG_ADD_VALUE 0x00

#define TRANSFER_SIZE   256     /* 64 words x 4 bytes */
#define NUM_WORDS       (TRANSFER_SIZE / 4)

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000

/* Valor a sumar - facil de verificar */
#define ADD_VALUE       0x00000005

static XAxiDma dma_inst;

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    u32 *src = (u32 *)SRC_ADDR;
    u32 *dst = (u32 *)DST_ADDR;
    int errors = 0;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  stream_adder Test (add_value = %d)\r\n", ADD_VALUE);
    xil_printf("==========================================\r\n\r\n");

    /* Init DMA */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed\r\n");
        return XST_FAILURE;
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Set add_value = 5 via AXI-Lite */
    Xil_Out32(STREAM_ADDER_BASE + ADDER_REG_ADD_VALUE, ADD_VALUE);
    u32 readback = Xil_In32(STREAM_ADDER_BASE + ADDER_REG_ADD_VALUE);
    xil_printf("AXI-Lite: add_value escrito=%d, leido=%d\r\n\r\n", ADD_VALUE, readback);

    /* Fill source: 0, 1, 2, 3, 4, ... */
    for (u32 i = 0; i < NUM_WORDS; i++) {
        src[i] = i;
    }
    memset(dst, 0xAA, TRANSFER_SIZE);  /* fill dest with 0xAA pattern to see changes */

    /* Cache */
    Xil_DCacheFlushRange((UINTPTR)src, TRANSFER_SIZE);
    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_SIZE);

    /* DMA: S2MM first, then MM2S */
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, TRANSFER_SIZE, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, TRANSFER_SIZE, XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, TRANSFER_SIZE);

    /* Verify: dest[i] should be i + 5 */
    xil_printf("  Word | Source | Dest   | Expected | OK?\r\n");
    xil_printf("  -----|--------|--------|----------|----\r\n");

    for (u32 i = 0; i < NUM_WORDS; i++) {
        u32 expected = i + ADD_VALUE;
        if (dst[i] != expected) errors++;

        if (i < 16) {
            xil_printf("  %4d | %6d | %6d | %8d | %s\r\n",
                       i, src[i], dst[i], expected,
                       (dst[i] == expected) ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS (%d/%d words OK)\r\n", NUM_WORDS, NUM_WORDS);
    } else {
        xil_printf("  FAIL (%d errores)\r\n", errors);
    }
    xil_printf("==========================================\r\n");

    /* STOP HERE - so JTAG can read the buffers */
    while(1);

    return 0;
}
