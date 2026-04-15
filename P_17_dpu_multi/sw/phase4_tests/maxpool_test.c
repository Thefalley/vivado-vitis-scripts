/*
 * maxpool_test.c -- Test P_17 Fase 3: MAXPOOL 2x2 stream bypass BRAM
 *
 * 16 ventanas 2x2, 64 bytes input -> 16 bytes output.
 * Cada word (4 bytes) = 1 ventana pre-ordenada por el ARM.
 * mp_clear en byte 0 de cada word. mp_valid_in en cada byte.
 * Output byte por ventana completada.
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

#ifndef XPAR_DPU_STREAM_WRAPPER_0_BASEADDR
#define XPAR_DPU_STREAM_WRAPPER_0_BASEADDR 0x40000000
#endif
#define DPU_BASE        XPAR_DPU_STREAM_WRAPPER_0_BASEADDR
#define DMA_BASEADDR    XPAR_AXIDMA_0_BASEADDR
#ifndef XPAR_GPIO_ADDR_BASEADDR
#define XPAR_GPIO_ADDR_BASEADDR 0x41200000
#endif
#ifndef XPAR_GPIO_CTRL_BASEADDR
#define XPAR_GPIO_CTRL_BASEADDR 0x41210000
#endif
#define GPIO_ADDR_BASE  XPAR_GPIO_ADDR_BASEADDR
#define GPIO_CTRL_BASE  XPAR_GPIO_CTRL_BASEADDR

#define DDR_SRC_ADDR    0x10000000
#define DDR_DST_ADDR    0x10100000
#define RESULT_ADDR     0x10200000
#define MAGIC_DONE      0xDEAD1234

#define REG_CTRL         0x00
#define REG_N_WORDS      0x04
#define REG_LAYER_TYPE   0x54
#define LAYER_MAXPOOL    1

#define MP_TEST_N_INPUT_BYTES  64
#define MP_TEST_N_INPUT_WORDS  16
#define MP_TEST_N_OUTPUT_BYTES 16
#define MP_TEST_N_OUTPUT_WORDS 4

static const u8 mp_input[MP_TEST_N_INPUT_BYTES] = {
    0x00, 0x01, 0x02, 0x03, 0xFC, 0xFD, 0xFE, 0xFF, 0x7F, 0x00, 0x80, 0x2A, 0x80, 0x80, 0x80, 0x80,
    0x64, 0xCE, 0x32, 0x9C, 0x0A, 0x14, 0x1E, 0x28, 0xFF, 0xFE, 0xFD, 0xFC, 0x05, 0x05, 0x05, 0x05,
    0x63, 0x64, 0x65, 0x66, 0xF6, 0xEC, 0x0F, 0xE2, 0x32, 0x32, 0x32, 0x7F, 0x80, 0x7F, 0x80, 0x7F,
    0x01, 0x00, 0xFF, 0xFE, 0x21, 0x42, 0x0B, 0x16, 0x07, 0x07, 0x07, 0x08, 0x00, 0x00, 0x00, 0x80,
};

static const u8 mp_expected[MP_TEST_N_OUTPUT_BYTES] = {
    0x03, 0xFF, 0x7F, 0x80, 0x64, 0x28, 0xFF, 0x05, 0x66, 0x0F, 0x7F, 0x7F, 0x01, 0x42, 0x08, 0x00,
};

static void dpu_write(u32 off, u32 v) { Xil_Out32(DPU_BASE + off, v); }
static u32  dpu_read (u32 off)        { return Xil_In32(DPU_BASE + off); }
static void gpio_addr_write(u32 v) { Xil_Out32(GPIO_ADDR_BASE + 0x00, v); }
static void gpio_ctrl_write(u32 v) { Xil_Out32(GPIO_CTRL_BASE + 0x00, v); }
static u32  gpio_ctrl_read_status(void) { return Xil_In32(GPIO_CTRL_BASE + 0x08); }

static XAxiDma dma_inst;

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    int errors = 0, total = 0;
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    u8 *src = (u8 *)DDR_SRC_ADDR;
    u8 *dst = (u8 *)DDR_DST_ADDR;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n  P_17 Fase 3 MAXPOOL 2x2 test\r\n");

    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) goto fail;
    if (XAxiDma_CfgInitialize(&dma_inst, cfg) != XST_SUCCESS) goto fail;
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    memcpy(src, mp_input, MP_TEST_N_INPUT_BYTES);
    memset(dst, 0xAB, MP_TEST_N_OUTPUT_BYTES + 64);
    Xil_DCacheFlushRange((UINTPTR)src, MP_TEST_N_INPUT_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, MP_TEST_N_OUTPUT_BYTES + 64);

    dpu_write(REG_LAYER_TYPE, LAYER_MAXPOOL);
    dpu_write(REG_N_WORDS,    MP_TEST_N_INPUT_WORDS);

    gpio_addr_write(DDR_DST_ADDR);
    gpio_ctrl_write(MP_TEST_N_OUTPUT_BYTES & 0x7FFFFF);
    gpio_ctrl_write((MP_TEST_N_OUTPUT_BYTES & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(MP_TEST_N_OUTPUT_BYTES & 0x7FFFFF);
    usleep(10);

    dpu_write(REG_CTRL, 0x02);

    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, MP_TEST_N_INPUT_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) goto fail;

    {
        int timeout = 0;
        while (!(dpu_read(REG_CTRL) & 0x100)) {
            if (++timeout > 20000000) {
                xil_printf("ERR: mp done timeout ctrl=0x%08X\r\n",
                           (int)dpu_read(REG_CTRL));
                goto fail;
            }
        }
        xil_printf("  mp done (polls=%d)\r\n", timeout);
    }

    {
        int timeout = 0;
        u32 sts;
        do {
            sts = gpio_ctrl_read_status();
            if (++timeout > 20000000) {
                xil_printf("ERR: DM timeout\r\n"); goto fail;
            }
        } while ((sts & 0x02) == 0);
    }

    Xil_DCacheInvalidateRange((UINTPTR)dst, MP_TEST_N_OUTPUT_BYTES + 64);

    for (int i = 0; i < MP_TEST_N_OUTPUT_BYTES; i++) {
        u8 got = dst[i], exp = mp_expected[i];
        int ok = (got == exp);
        total++; if (!ok) errors++;
        xil_printf("  [%2d] got=0x%02X exp=0x%02X  %s\r\n",
                   i, got, exp, ok ? "OK" : "FAIL");
    }

    xil_printf("\r\n  Checks: %d/%d\r\n", total - errors, total);
    if (errors == 0) xil_printf("  >>> MAXPOOL ALL PASSED <<<\r\n");
    else             xil_printf("  >>> MAXPOOL FAILED %d errors <<<\r\n", errors);

    res[0] = MAGIC_DONE;
    res[1] = total;
    res[2] = errors;
    /* Dump 16 output bytes como 4 words para inspeccion via mrd */
    for (int i = 0; i < 4; i++) {
        u32 w = ((u32)dst[i*4+0]) | ((u32)dst[i*4+1] << 8) |
                ((u32)dst[i*4+2] << 16) | ((u32)dst[i*4+3] << 24);
        res[3 + i] = w;
    }
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 0;

fail:
    res[0] = MAGIC_DONE;
    res[1] = 0;
    res[2] = 1;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 1;
}
