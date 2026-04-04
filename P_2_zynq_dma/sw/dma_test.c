/*
 * dma_test.c - DMA Loopback Test for ZedBoard
 *
 * Verifica escritura/lectura DDR via AXI DMA:
 *   1. Escribe patron en buffer source (DDR)
 *   2. DMA MM2S lee de source
 *   3. Loopback en PL
 *   4. DMA S2MM escribe en buffer dest (DDR)
 *   5. Compara source vs dest
 *   6. Repite en diferentes regiones de DDR
 *
 * Hardware: Zynq PS + AXI DMA con loopback (M_AXIS_MM2S -> S_AXIS_S2MM)
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xstatus.h"
#include <string.h>

/* ---- Configuracion ---- */
#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR
#define TRANSFER_SIZE   1024        /* bytes por transferencia */
#define NUM_TESTS       8           /* numero de regiones DDR a probar */

/*
 * Regiones de test en DDR (0x0010_0000 - 0x1F00_0000)
 * Evitamos la zona baja donde esta el codigo del programa
 */
#define DDR_BASE        0x00100000
#define DDR_END         0x1F000000
#define REGION_STEP     ((DDR_END - DDR_BASE) / NUM_TESTS)

/* Buffers: source y dest separados por 64KB */
#define SRC_OFFSET      0x00000000
#define DST_OFFSET      0x00010000

static XAxiDma dma_inst;

/* ---- Patrones de test ---- */
static void fill_pattern(u8 *buf, u32 size, u32 seed)
{
    for (u32 i = 0; i < size; i++) {
        buf[i] = (u8)((seed + i * 7 + 0xA5) & 0xFF);
    }
}

static int verify_pattern(u8 *src, u8 *dst, u32 size)
{
    int errors = 0;
    for (u32 i = 0; i < size; i++) {
        if (src[i] != dst[i]) {
            if (errors < 10) {
                xil_printf("  MISMATCH [%d]: src=0x%02x dst=0x%02x\r\n",
                           i, src[i], dst[i]);
            }
            errors++;
        }
    }
    return errors;
}

/* ---- DMA Transfer (polling) ---- */
static int dma_transfer(XAxiDma *dma, u8 *src, u8 *dst, u32 size)
{
    int status;

    /* Flush source, invalidate dest */
    Xil_DCacheFlushRange((UINTPTR)src, size);
    Xil_DCacheInvalidateRange((UINTPTR)dst, size);

    /* Start S2MM (receive) first */
    status = XAxiDma_SimpleTransfer(dma, (UINTPTR)dst, size, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM transfer start failed (%d)\r\n", status);
        return XST_FAILURE;
    }

    /* Start MM2S (send) */
    status = XAxiDma_SimpleTransfer(dma, (UINTPTR)src, size, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S transfer start failed (%d)\r\n", status);
        return XST_FAILURE;
    }

    /* Wait for both to complete */
    while (XAxiDma_Busy(dma, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(dma, XAXIDMA_DEVICE_TO_DMA));

    /* Invalidate dest cache before reading */
    Xil_DCacheInvalidateRange((UINTPTR)dst, size);

    return XST_SUCCESS;
}

/* ---- Main ---- */
int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    int total_errors = 0;
    int tests_passed = 0;

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf("  DMA Loopback Test - ZedBoard\r\n");
    xil_printf("  Transfer size: %d bytes\r\n", TRANSFER_SIZE);
    xil_printf("  DDR regions:   %d\r\n", NUM_TESTS);
    xil_printf("========================================\r\n\r\n");

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

    /* Disable interrupts (polling mode) */
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    xil_printf("DMA inicializado OK\r\n\r\n");

    /* Test each DDR region */
    for (int t = 0; t < NUM_TESTS; t++) {
        u32 base = DDR_BASE + (t * REGION_STEP);
        u8 *src = (u8 *)(base + SRC_OFFSET);
        u8 *dst = (u8 *)(base + DST_OFFSET);

        xil_printf("Test %d/%d: src=0x%08x dst=0x%08x ... ",
                   t + 1, NUM_TESTS, (u32)src, (u32)dst);

        /* Fill source with pattern, clear dest */
        fill_pattern(src, TRANSFER_SIZE, t);
        memset(dst, 0, TRANSFER_SIZE);

        /* DMA transfer */
        status = dma_transfer(&dma_inst, src, dst, TRANSFER_SIZE);
        if (status != XST_SUCCESS) {
            xil_printf("FAIL (DMA error)\r\n");
            total_errors++;
            continue;
        }

        /* Verify */
        int errors = verify_pattern(src, dst, TRANSFER_SIZE);
        if (errors == 0) {
            xil_printf("PASS\r\n");
            tests_passed++;
        } else {
            xil_printf("FAIL (%d mismatches)\r\n", errors);
            total_errors += errors;
        }
    }

    /* Summary */
    xil_printf("\r\n========================================\r\n");
    xil_printf("  RESULTADO: %d/%d tests passed\r\n", tests_passed, NUM_TESTS);
    if (total_errors == 0) {
        xil_printf("  DDR + DMA: TODO OK\r\n");
    } else {
        xil_printf("  ERRORES: %d total\r\n", total_errors);
    }
    xil_printf("========================================\r\n");

    return (total_errors == 0) ? XST_SUCCESS : XST_FAILURE;
}
