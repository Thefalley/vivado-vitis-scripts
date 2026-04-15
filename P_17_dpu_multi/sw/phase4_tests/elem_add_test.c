/*
 * elem_add_test.c -- Test P_17 Fase 4: ELEM_ADD con A+B en BRAM
 *
 * Flujo:
 *   1. Empaqueta A+B contiguos en DDR_SRC (128 bytes)
 *   2. LOAD via DMA MM2S: A @ BRAM[0x000], B @ BRAM[0x040]
 *   3. Config regs: layer_type=3, reg_n_words=32 (2*N=128 bytes LOAD)
 *   4. cmd_start -> S_STREAM_EA. Lee A y B de BRAM, feeds elem_add, emite
 *   5. DataMover captura output a DDR_DST
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
#define REG_X_ZP         0x1C
#define REG_M0           0x24
#define REG_N_SHIFT      0x28
#define REG_Y_ZP         0x2C
#define REG_ADDR_INPUT   0x30
#define REG_ADDR_WEIGHTS 0x34
#define REG_LAYER_TYPE   0x54
#define REG_B_ZP         0x60
#define REG_M0_B         0x64

#define LAYER_ELEM_ADD  3

#define EA_N_BYTES  64
#define EA_N_WORDS  16
#define EA_A_ZP     -102
#define EA_B_ZP     -97
#define EA_Y_ZP     -102
#define EA_M0_A     605961470u
#define EA_M0_B     715593500u
#define EA_N_SHIFT  30

#define BRAM_A_BYTE_OFFSET  0x000
#define BRAM_B_BYTE_OFFSET  0x040

static const u8 ea_a[EA_N_BYTES] = {
    0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
};

static const u8 ea_b[EA_N_BYTES] = {
    0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x7A, 0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x72, 0x71, 0x70,
    0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x68, 0x67, 0x66, 0x65, 0x64, 0x63, 0x62, 0x61, 0x60,
    0x5F, 0x5E, 0x5D, 0x5C, 0x5B, 0x5A, 0x59, 0x58, 0x57, 0x56, 0x55, 0x54, 0x53, 0x52, 0x51, 0x50,
    0x4F, 0x4E, 0x4D, 0x4C, 0x4B, 0x4A, 0x49, 0x48, 0x47, 0x46, 0x45, 0x44, 0x43, 0x42, 0x41, 0x40,
};

static const u8 ea_expected[EA_N_BYTES] = {
    0x57, 0x57, 0x57, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x55, 0x55, 0x55,
    0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x54, 0x54, 0x54, 0x54, 0x54, 0x54, 0x54, 0x54, 0x54,
    0x54, 0x53, 0x53, 0x53, 0x53, 0x53, 0x53, 0x53, 0x53, 0x53, 0x53, 0x52, 0x52, 0x52, 0x52, 0x52,
    0x52, 0x52, 0x52, 0x52, 0x51, 0x51, 0x51, 0x51, 0x51, 0x51, 0x51, 0x51, 0x51, 0x51, 0x50, 0x50,
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

    xil_printf("\r\n  P_17 Fase 4 ELEM_ADD test\r\n");

    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) goto fail;
    if (XAxiDma_CfgInitialize(&dma_inst, cfg) != XST_SUCCESS) goto fail;
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    memcpy(src + BRAM_A_BYTE_OFFSET, ea_a, EA_N_BYTES);
    memcpy(src + BRAM_B_BYTE_OFFSET, ea_b, EA_N_BYTES);
    memset(dst, 0xAB, EA_N_BYTES + 64);
    Xil_DCacheFlushRange((UINTPTR)src, 2 * EA_N_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, EA_N_BYTES + 64);

    dpu_write(REG_LAYER_TYPE,   LAYER_ELEM_ADD);
    dpu_write(REG_N_WORDS,      2 * EA_N_WORDS);
    dpu_write(REG_X_ZP,         (u32)(s32)EA_A_ZP & 0x1FF);
    dpu_write(REG_B_ZP,         (u32)(s32)EA_B_ZP & 0xFF);
    dpu_write(REG_Y_ZP,         (u32)(s32)EA_Y_ZP & 0xFF);
    dpu_write(REG_M0,           EA_M0_A);
    dpu_write(REG_M0_B,         EA_M0_B);
    dpu_write(REG_N_SHIFT,      EA_N_SHIFT);
    dpu_write(REG_ADDR_INPUT,   BRAM_A_BYTE_OFFSET);
    dpu_write(REG_ADDR_WEIGHTS, BRAM_B_BYTE_OFFSET);

    dpu_write(REG_CTRL, 0x01);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, 2 * EA_N_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) goto fail;
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));

    while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 0);
    xil_printf("  LOAD done\r\n");

    gpio_addr_write(DDR_DST_ADDR);
    gpio_ctrl_write(EA_N_BYTES & 0x7FFFFF);
    gpio_ctrl_write((EA_N_BYTES & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(EA_N_BYTES & 0x7FFFFF);
    usleep(10);

    dpu_write(REG_CTRL, 0x02);

    {
        int timeout = 0;
        while (!(dpu_read(REG_CTRL) & 0x100)) {
            if (++timeout > 20000000) goto fail;
        }
        xil_printf("  ea done (polls=%d)\r\n", timeout);
    }

    {
        int timeout = 0;
        u32 sts;
        do {
            sts = gpio_ctrl_read_status();
            if (++timeout > 20000000) goto fail;
        } while ((sts & 0x02) == 0);
    }

    Xil_DCacheInvalidateRange((UINTPTR)dst, EA_N_BYTES + 64);

    for (int i = 0; i < EA_N_BYTES; i++) {
        u8 got = dst[i], exp = ea_expected[i];
        int ok = (got == exp);
        total++; if (!ok) errors++;
        if (!ok || i < 4 || i >= EA_N_BYTES - 4) {
            xil_printf("  [%2d] got=0x%02X exp=0x%02X  %s\r\n",
                       i, got, exp, ok ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n  Checks: %d/%d\r\n", total - errors, total);
    if (errors == 0) xil_printf("  >>> ELEM_ADD ALL PASSED <<<\r\n");

    res[0] = MAGIC_DONE;
    res[1] = total;
    res[2] = errors;
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
