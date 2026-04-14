/*
 * leaky_relu_test.c -- Test P_17 Fase 2: LEAKY_RELU stream bypass BRAM
 *
 * Flujo:
 *   1. Prepara 64 bytes de input en DDR_SRC (pattern -32..+31 como signed)
 *   2. Configura conv regs: layer_type=2, params de layer_006 YOLOv4
 *   3. Configura DataMover (dest addr + BTT)
 *   4. cmd_start: entra a S_STREAM_LR
 *   5. Lanza DMA MM2S → s_axis → leaky_relu → m_axis → DataMover S2MM → DDR_DST
 *   6. Poll done + DataMover done
 *   7. Verifica output vs golden (precomputado en gen_leaky_test.py)
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

/* ========================================================================= */
/* Address definitions                                                       */
/* ========================================================================= */
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

/* ========================================================================= */
/* dpu_stream_wrapper register map (P_17)                                    */
/* ========================================================================= */
#define REG_CTRL         0x00
#define REG_N_WORDS      0x04
#define REG_C_IN         0x08
#define REG_C_OUT        0x0C
#define REG_H_IN         0x10
#define REG_W_IN         0x14
#define REG_KSP          0x18
#define REG_X_ZP         0x1C
#define REG_W_ZP         0x20
#define REG_M0           0x24
#define REG_N_SHIFT      0x28
#define REG_Y_ZP         0x2C
#define REG_ADDR_INPUT   0x30
#define REG_ADDR_WEIGHTS 0x34
#define REG_ADDR_BIAS    0x38
#define REG_ADDR_OUTPUT  0x3C
#define REG_IC_TILE_SIZE 0x40
#define REG_PAD_TOP      0x44
#define REG_PAD_BOTTOM   0x48
#define REG_PAD_LEFT     0x4C
#define REG_PAD_RIGHT    0x50
/* P_17 nuevos */
#define REG_LAYER_TYPE   0x54
#define REG_M0_NEG       0x58
#define REG_N_NEG        0x5C
#define REG_B_ZP         0x60
#define REG_M0_B         0x64

/* Layer types */
#define LAYER_CONV       0
#define LAYER_MAXPOOL    1
#define LAYER_LEAKY_RELU 2
#define LAYER_ELEM_ADD   3

/* ========================================================================= */
/* Test data (auto-generado por gen_leaky_test.py con params de L006)         */
/* ========================================================================= */
#define LEAKY_TEST_N_BYTES 64
#define LEAKY_TEST_N_WORDS 16
#define LEAKY_X_ZP   -17
#define LEAKY_Y_ZP   -110
#define LEAKY_M0_POS 881676063u
#define LEAKY_N_POS  29
#define LEAKY_M0_NEG 705340861u
#define LEAKY_N_NEG  32

static const u8 leaky_input[LEAKY_TEST_N_BYTES] = {
    0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
};

static const u8 leaky_expected[LEAKY_TEST_N_BYTES] = {
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x91, 0x91, 0x91, 0x91, 0x91, 0x91, 0x92, 0x92, 0x92, 0x92,
    0x94, 0x95, 0x97, 0x99, 0x9A, 0x9C, 0x9D, 0x9F, 0xA1, 0xA2, 0xA4, 0xA6, 0xA7, 0xA9, 0xAB, 0xAC,
    0xAE, 0xB0, 0xB1, 0xB3, 0xB4, 0xB6, 0xB8, 0xB9, 0xBB, 0xBD, 0xBE, 0xC0, 0xC2, 0xC3, 0xC5, 0xC7,
    0xC8, 0xCA, 0xCB, 0xCD, 0xCF, 0xD0, 0xD2, 0xD4, 0xD5, 0xD7, 0xD9, 0xDA, 0xDC, 0xDE, 0xDF, 0xE1,
};

/* ========================================================================= */
/* Helpers                                                                    */
/* ========================================================================= */
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
    int errors = 0;
    int total_checks = 0;
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    u8 *src = (u8 *)DDR_SRC_ADDR;
    u8 *dst = (u8 *)DDR_DST_ADDR;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n#######################################################\r\n");
    xil_printf("  P_17 Fase 2 LEAKY_RELU test (bypass BRAM)\r\n");
    xil_printf("  %d bytes, layer_type=2, params L006 YOLOv4\r\n",
               LEAKY_TEST_N_BYTES);
    xil_printf("#######################################################\r\n\r\n");

    /* 1. Init DMA */
    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) { xil_printf("ERR: DMA LookupConfig\r\n"); goto fail; }
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) { xil_printf("ERR: DMA init\r\n"); goto fail; }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    /* 2. Preparar DDR src y dst */
    memcpy(src, leaky_input, LEAKY_TEST_N_BYTES);
    memset(dst, 0xAB, LEAKY_TEST_N_BYTES + 64);  /* relleno para detectar writes */
    Xil_DCacheFlushRange((UINTPTR)src, LEAKY_TEST_N_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, LEAKY_TEST_N_BYTES + 64);

    /* 3. Configurar DPU regs para LEAKY_RELU */
    dpu_write(REG_LAYER_TYPE, LAYER_LEAKY_RELU);
    dpu_write(REG_N_WORDS,    LEAKY_TEST_N_WORDS);
    dpu_write(REG_X_ZP,       (u32)(s32)LEAKY_X_ZP & 0x1FF);
    dpu_write(REG_Y_ZP,       (u32)(s32)LEAKY_Y_ZP & 0xFF);
    dpu_write(REG_M0,         LEAKY_M0_POS);
    dpu_write(REG_N_SHIFT,    LEAKY_N_POS);
    dpu_write(REG_M0_NEG,     LEAKY_M0_NEG);
    dpu_write(REG_N_NEG,      LEAKY_N_NEG);

    xil_printf("  regs: layer_type=%d n_words=%d x_zp=%d y_zp=%d\r\n",
               (int)dpu_read(REG_LAYER_TYPE), (int)dpu_read(REG_N_WORDS),
               (int)dpu_read(REG_X_ZP), (int)dpu_read(REG_Y_ZP));

    /* 4. Configurar DataMover S2MM: dest + BTT, luego pulso start */
    gpio_addr_write(DDR_DST_ADDR);
    gpio_ctrl_write(LEAKY_TEST_N_BYTES & 0x7FFFFF);
    gpio_ctrl_write((LEAKY_TEST_N_BYTES & 0x7FFFFF) | 0x80000000);  /* start pulse high */
    gpio_ctrl_write(LEAKY_TEST_N_BYTES & 0x7FFFFF);                  /* start pulse low */
    usleep(10);

    /* 5. cmd_start → S_STREAM_LR */
    dpu_write(REG_CTRL, 0x02);

    /* 6. Lanzar DMA MM2S */
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, LEAKY_TEST_N_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: DMA MM2S start\r\n"); goto fail;
    }

    /* 7. Poll done_latch (REG_CTRL bit 8) */
    {
        int timeout = 0;
        while (!(dpu_read(REG_CTRL) & 0x100)) {
            timeout++;
            if (timeout > 20000000) {
                xil_printf("ERR: leaky done timeout, ctrl=0x%08X\r\n",
                           (int)dpu_read(REG_CTRL));
                goto fail;
            }
        }
        xil_printf("  leaky done (polls=%d)\r\n", timeout);
    }

    /* 8. Poll DataMover done */
    {
        int timeout = 0;
        u32 sts;
        do {
            sts = gpio_ctrl_read_status();
            timeout++;
            if (timeout > 20000000) {
                xil_printf("ERR: DM timeout sts=0x%08X\r\n", sts);
                goto fail;
            }
        } while ((sts & 0x02) == 0);
        xil_printf("  DM done (polls=%d sts=0x%08X)\r\n", timeout, sts);
    }

    Xil_DCacheInvalidateRange((UINTPTR)dst, LEAKY_TEST_N_BYTES + 64);

    /* 9. Verificar */
    for (int i = 0; i < LEAKY_TEST_N_BYTES; i++) {
        u8 got = dst[i];
        u8 exp = leaky_expected[i];
        int ok = (got == exp);
        total_checks++;
        if (!ok) errors++;
        if (!ok || i < 4 || i >= LEAKY_TEST_N_BYTES - 4) {
            xil_printf("  [%3d] got=0x%02X exp=0x%02X  %s\r\n",
                       i, got, exp, ok ? "OK" : "FAIL");
        }
    }

    xil_printf("\r\n  Checks: %d/%d passed\r\n",
               total_checks - errors, total_checks);
    if (errors == 0) {
        xil_printf("  >>> LEAKY_RELU ALL PASSED <<<\r\n");
    } else {
        xil_printf("  >>> LEAKY_RELU FAILED: %d errors <<<\r\n", errors);
    }

    res[0] = MAGIC_DONE;
    res[1] = total_checks;
    res[2] = errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 0;

fail:
    xil_printf(">>> FAIL (init/DMA/timeout) <<<\r\n");
    res[0] = MAGIC_DONE;
    res[1] = 0;
    res[2] = 1;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 1;
}
