/*
 * conv_dm_test.c -- Test conv_engine_v3 + DataMover S2MM output on ZedBoard
 *
 * P_16_conv_datamover: DPU architecture with:
 *   - DMA MM2S for LOADING data into the conv wrapper BRAM
 *   - DataMover S2MM for DRAINING conv results to DDR
 *   - dm_s2mm_ctrl generating 72-bit DataMover commands via GPIO
 *
 * Flow:
 *   1. Pack weights (OHWI) + input + bias into DDR source buffer
 *   2. Configure conv via AXI-Lite registers (including asymmetric padding)
 *   3. Issue LOAD command + DMA MM2S: stream data into wrapper BRAM
 *   4. Wait for DMA MM2S complete
 *   5. Issue START command: conv_engine_v3 processes data
 *   6. Poll for conv DONE
 *   7. Configure dm_s2mm_ctrl via GPIO (dest_addr + byte_count + start)
 *   8. Issue DRAIN command: wrapper streams output -> DataMover S2MM -> DDR
 *   9. Poll dm_s2mm_ctrl status for DONE
 *  10. Verify output against expected values
 *
 * Test layer: layer_005 (3x3 input, 3 IC, 32 OC, 3x3 kernel, stride 1,
 *             pad=[1,1,1,1] symmetric -- validates v3 asymmetric pad regs)
 *
 * BRAM layout:
 *   output  @ byte 0x000 (288 B)
 *   input   @ byte 0x200 (27 B)
 *   weights @ byte 0x300 (864 B)
 *   bias    @ byte 0x6C0 (128 B)
 *
 *   Load: 480 words = 1920 bytes
 *   Drain: 72 words = 288 bytes
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

/* conv_stream_wrapper base (GP0 M01) */
#ifndef XPAR_CONV_STREAM_WRAPPER_0_BASEADDR
#define XPAR_CONV_STREAM_WRAPPER_0_BASEADDR 0x40000000
#endif
#define CONV_BASE   XPAR_CONV_STREAM_WRAPPER_0_BASEADDR

/* DMA */
#define DMA_BASEADDR    XPAR_AXIDMA_0_BASEADDR

/* GPIO for dm_s2mm_ctrl */
#ifndef XPAR_GPIO_ADDR_BASEADDR
#define XPAR_GPIO_ADDR_BASEADDR 0x41200000
#endif
#ifndef XPAR_GPIO_CTRL_BASEADDR
#define XPAR_GPIO_CTRL_BASEADDR 0x41210000
#endif
#define GPIO_ADDR_BASE  XPAR_GPIO_ADDR_BASEADDR
#define GPIO_CTRL_BASE  XPAR_GPIO_CTRL_BASEADDR

/* DDR buffers */
#define DDR_SRC_ADDR    0x10000000  /* DMA source (packed data for LOAD) */
#define DDR_DST_ADDR    0x10100000  /* DataMover destination (DRAIN output) */

/* Shared result area for XSCT polling */
#define RESULT_ADDR     0x10200000
#define MAGIC_DONE      0xDEAD1234

/* ========================================================================= */
/* conv_stream_wrapper register map (from VHDL entity)                       */
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

/* FSM state encoding in ctrl register bits[11:10] */
#define FSM_IDLE   0
#define FSM_LOAD   1
#define FSM_CONV   2
#define FSM_DRAIN  3

/* ========================================================================= */
/* BRAM layout (byte addresses for conv_engine)                              */
/* ========================================================================= */
#define BRAM_OUTPUT_ADDR   0x000
#define BRAM_INPUT_ADDR    0x200
#define BRAM_WEIGHTS_ADDR  0x300
#define BRAM_BIAS_ADDR     0x6C0

/* Conv config (layer_005) */
#define C_IN    3
#define C_OUT   32
#define H_IN    3
#define W_IN    3
#define KSIZE   2    /* encoding: 2 = 3x3 */
#define STRIDE  0    /* stride 1 */
#define PAD_T   1
#define PAD_B   1
#define PAD_L   1
#define PAD_R   1
#define H_OUT   3
#define W_OUT   3

/* DMA transfer sizes */
#define LOAD_N_WORDS    480
#define LOAD_BYTES      (LOAD_N_WORDS * 4)  /* 1920 bytes */
#define DRAIN_N_WORDS   72
#define DRAIN_BYTES     (DRAIN_N_WORDS * 4) /* 288 bytes */
#define OUTPUT_BYTES    288

/* ========================================================================= */
/* Test data (identical to P_13/P_14 -- layer_005)                           */
/* ========================================================================= */

static const s8 input_data[27] = {
     56,-106,  21,  50,-102,  17,   6, -97,  -6,
     62, -64,  39,  59, -57,  34,  29, -42,  23,
     65, -40,  44,  70, -31,  33,  39, -24,  31
};

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

static const s32 bias_data[32] = {
    1623, 1048, 1258, 232, 1845, 1748, 1300, 1221,
    1861, 123, -859, -1173, 4085, 2515, 659, 825,
    1526, 3951, 1526, 1647, 1409, -616, 1566, 984,
    -6950, 1229, -10249, 2056, -8582, 1821, 3756, 814
};

/* Expected center pixel (1,1) for all 32 output channels */
static const s8 expected_center[32] = {
     -9, -53, -10, -25, -20,  -2, -17,  -7,
     -5, -56, -31, -14,  -6, -15, -14, -24,
    -43,  67, -25,   2, -23, -27, -11, -18,
    -39, -51, -43,   9, -57, -16,  14, -17
};

/* Expected all 9 pixels for channel 0 */
static const s8 expected_ch0_all[9] = {
    -36, -11, -45,
    -37,  -9, -52,
    -29, -14, -42
};

/* ========================================================================= */
/* Helpers                                                                   */
/* ========================================================================= */

static void conv_write(u32 offset, u32 val)
{
    Xil_Out32(CONV_BASE + offset, val);
}

static u32 conv_read(u32 offset)
{
    return Xil_In32(CONV_BASE + offset);
}

static int get_fsm_state(void)
{
    u32 ctrl = conv_read(REG_CTRL);
    return (int)((ctrl >> 10) & 0x3);
}

/* GPIO helpers for dm_s2mm_ctrl */
static void gpio_addr_write(u32 val)
{
    Xil_Out32(GPIO_ADDR_BASE + 0x00, val);  /* GPIO data channel 1 */
}

static void gpio_ctrl_write(u32 val)
{
    Xil_Out32(GPIO_CTRL_BASE + 0x00, val);  /* GPIO data channel 1 */
}

static u32 gpio_ctrl_read_status(void)
{
    return Xil_In32(GPIO_CTRL_BASE + 0x08);  /* GPIO data channel 2 */
}

/* ========================================================================= */
/* Transpose weights from OIHW to OHWI                                      */
/* ========================================================================= */
static void transpose_weights_ohwi(const s8 *oihw, s8 *ohwi,
                                   int oc, int ic, int kh, int kw)
{
    for (int o = 0; o < oc; o++) {
        const s8 *filt = &oihw[o * ic * kh * kw];
        s8 *dst = &ohwi[o * ic * kh * kw];
        for (int h = 0; h < kh; h++) {
            for (int w = 0; w < kw; w++) {
                for (int c = 0; c < ic; c++) {
                    dst[h * kw * ic + w * ic + c] =
                        filt[c * kh * kw + h * kw + w];
                }
            }
        }
    }
}

/* ========================================================================= */
/* Main test                                                                 */
/* ========================================================================= */

static XAxiDma dma_inst;

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    int errors = 0;
    int total_checks = 0;
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    u32 *src = (u32 *)DDR_SRC_ADDR;
    u8  *dst = (u8 *)DDR_DST_ADDR;

    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n###################################################\r\n");
    xil_printf("  P_16 Conv + DataMover Test -- ZedBoard\r\n");
    xil_printf("  Layer 005: 3x3 input, 3 IC, 32 OC, 3x3 kernel\r\n");
    xil_printf("  DMA MM2S -> conv_v3 -> DataMover S2MM -> DDR\r\n");
    xil_printf("###################################################\r\n\r\n");

    /* ================================================================== */
    /* 1. Initialize DMA (MM2S only -- no S2MM in DMA)                    */
    /* ================================================================== */
    xil_printf("[1] Initializing DMA (MM2S only)...\r\n");
    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) {
        xil_printf("ERROR: DMA LookupConfig failed\r\n");
        goto fail;
    }
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA CfgInitialize failed (%d)\r\n", status);
        goto fail;
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    xil_printf("    DMA initialized OK\r\n");

    /* ================================================================== */
    /* 2. Prepare DDR source buffer (BRAM image for LOAD)                 */
    /* ================================================================== */
    xil_printf("[2] Preparing DDR source buffer (%d bytes)...\r\n", LOAD_BYTES);

    memset((void *)src, 0, LOAD_BYTES);

    /* Place input at byte offset BRAM_INPUT_ADDR (0x200) */
    {
        u8 *buf = (u8 *)src;
        for (int i = 0; i < 27; i++) {
            buf[BRAM_INPUT_ADDR + i] = (u8)input_data[i];
        }
    }

    /* Place weights (OHWI) at byte offset BRAM_WEIGHTS_ADDR (0x300) */
    {
        s8 w_ohwi[864];
        transpose_weights_ohwi(weight_data, w_ohwi, C_OUT, C_IN, 3, 3);
        u8 *buf = (u8 *)src;
        for (int i = 0; i < 864; i++) {
            buf[BRAM_WEIGHTS_ADDR + i] = (u8)w_ohwi[i];
        }
    }

    /* Place bias at byte offset BRAM_BIAS_ADDR (0x6C0) */
    {
        u8 *buf = (u8 *)src;
        for (int i = 0; i < 32; i++) {
            u32 val = (u32)bias_data[i];
            int off = BRAM_BIAS_ADDR + i * 4;
            buf[off + 0] = (u8)(val & 0xFF);
            buf[off + 1] = (u8)((val >> 8) & 0xFF);
            buf[off + 2] = (u8)((val >> 16) & 0xFF);
            buf[off + 3] = (u8)((val >> 24) & 0xFF);
        }
    }

    /* Clear destination buffer (where DataMover will write) */
    memset((void *)dst, 0xDE, DRAIN_BYTES + 256);

    /* Flush caches */
    Xil_DCacheFlushRange((UINTPTR)src, LOAD_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, DRAIN_BYTES + 256);

    xil_printf("    Input at BRAM 0x%03X, Weights at 0x%03X, Bias at 0x%03X\r\n",
               BRAM_INPUT_ADDR, BRAM_WEIGHTS_ADDR, BRAM_BIAS_ADDR);
    xil_printf("    Output at BRAM 0x%03X\r\n", BRAM_OUTPUT_ADDR);

    /* ================================================================== */
    /* 3. Configure conv_stream_wrapper via AXI-Lite (v3 with 4 pads)    */
    /* ================================================================== */
    xil_printf("[3] Configuring conv registers (v3 asymmetric pad)...\r\n");

    conv_write(REG_N_WORDS,      LOAD_N_WORDS);
    conv_write(REG_C_IN,         C_IN);
    conv_write(REG_C_OUT,        C_OUT);
    conv_write(REG_H_IN,         H_IN);
    conv_write(REG_W_IN,         W_IN);
    conv_write(REG_KSP,          (STRIDE << 2) | KSIZE);  /* no packed pad bit */
    conv_write(REG_X_ZP,         (u32)(s32)(-128) & 0x1FF);
    conv_write(REG_W_ZP,         0);
    conv_write(REG_M0,           656954014u);
    conv_write(REG_N_SHIFT,      37);
    conv_write(REG_Y_ZP,         (u32)(s32)(-17) & 0xFF);
    conv_write(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);
    conv_write(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);
    conv_write(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);
    conv_write(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);
    conv_write(REG_IC_TILE_SIZE, C_IN);
    /* v3 asymmetric padding registers */
    conv_write(REG_PAD_TOP,      PAD_T);
    conv_write(REG_PAD_BOTTOM,   PAD_B);
    conv_write(REG_PAD_LEFT,     PAD_L);
    conv_write(REG_PAD_RIGHT,    PAD_R);

    xil_printf("    Readback: c_in=%d c_out=%d fsm_state=%d\r\n",
               (int)conv_read(REG_C_IN), (int)conv_read(REG_C_OUT),
               get_fsm_state());

    /* ================================================================== */
    /* 4. LOAD phase: DMA MM2S -> wrapper s_axis -> BRAM                  */
    /* ================================================================== */
    xil_printf("[4] LOAD: sending %d words (%d bytes) via DMA MM2S...\r\n",
               LOAD_N_WORDS, LOAD_BYTES);

    /* Issue LOAD command (bit 0 of ctrl) */
    conv_write(REG_CTRL, 0x01);

    {
        int fsm = get_fsm_state();
        xil_printf("    FSM state after LOAD cmd: %d (expect 1)\r\n", fsm);
    }

    /* Start DMA MM2S transfer */
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, LOAD_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA MM2S transfer start failed (%d)\r\n", status);
        goto fail;
    }

    /* Poll for MM2S completion */
    {
        int timeout = 0;
        while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE)) {
            timeout++;
            if (timeout > 10000000) {
                xil_printf("ERROR: DMA MM2S timeout!\r\n");
                xil_printf("    FSM state: %d\r\n", get_fsm_state());
                goto fail;
            }
        }
        xil_printf("    DMA MM2S complete (polls=%d)\r\n", timeout);
    }

    /* Wait for FSM to return to IDLE */
    {
        int timeout = 0;
        while (get_fsm_state() != FSM_IDLE) {
            timeout++;
            if (timeout > 1000000) {
                xil_printf("ERROR: FSM stuck in state %d after LOAD\r\n",
                           get_fsm_state());
                goto fail;
            }
        }
        xil_printf("    FSM back to IDLE after LOAD\r\n");
    }

    /* ================================================================== */
    /* 5. CONV phase: start conv_engine_v3, wait for done                 */
    /* ================================================================== */
    xil_printf("[5] CONV: starting conv_engine_v3...\r\n");

    conv_write(REG_CTRL, 0x02);

    {
        int timeout = 0;
        u32 ctrl;
        do {
            ctrl = conv_read(REG_CTRL);
            timeout++;
            if (timeout > 20000000) {
                xil_printf("ERROR: Conv timeout! ctrl=0x%08X fsm=%d\r\n",
                           ctrl, get_fsm_state());
                goto fail;
            }
        } while ((ctrl & 0x100) == 0);

        xil_printf("    Conv DONE (polls=%d, ctrl=0x%08X)\r\n", timeout, ctrl);
    }

    /* ================================================================== */
    /* 6. Configure dm_s2mm_ctrl via GPIO for DataMover write             */
    /* ================================================================== */
    xil_printf("[6] Configuring DataMover S2MM (dest=0x%08X, %d bytes)...\r\n",
               DDR_DST_ADDR, DRAIN_BYTES);

    /* Set destination address in DDR */
    gpio_addr_write(DDR_DST_ADDR);

    /* Set byte count in ctrl register (bits [22:0]) -- do NOT set start yet */
    gpio_ctrl_write(DRAIN_BYTES & 0x7FFFFF);

    /* ================================================================== */
    /* 7. DRAIN phase: trigger DataMover cmd THEN issue DRAIN             */
    /*                                                                    */
    /* The DataMover needs the 72-bit command BEFORE data arrives on      */
    /* S_AXIS_S2MM. So we: (a) pulse dm_s2mm_ctrl start to send the      */
    /* command, then (b) issue DRAIN on the wrapper so data flows.        */
    /* ================================================================== */
    xil_printf("[7] DRAIN: DataMover cmd -> wrapper drain -> DDR...\r\n");

    /* (a) Pulse start bit: set bit[31] high, then low */
    gpio_ctrl_write((DRAIN_BYTES & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(DRAIN_BYTES & 0x7FFFFF);

    /* Small delay to let cmd propagate to DataMover */
    usleep(10);

    /* (b) Set n_words for drain and issue DRAIN command */
    conv_write(REG_N_WORDS, DRAIN_N_WORDS);
    conv_write(REG_CTRL, 0x04);

    /* ================================================================== */
    /* 8. Poll dm_s2mm_ctrl status for DONE                               */
    /* ================================================================== */
    xil_printf("[8] Waiting for DataMover DONE...\r\n");

    {
        int timeout = 0;
        u32 sts;
        do {
            sts = gpio_ctrl_read_status();
            timeout++;
            if (timeout > 20000000) {
                xil_printf("ERROR: DataMover timeout! status=0x%08X\r\n", sts);
                xil_printf("    FSM state: %d\r\n", get_fsm_state());
                goto fail;
            }
        } while ((sts & 0x02) == 0);  /* bit[1] = done */

        xil_printf("    DataMover DONE (polls=%d, status=0x%08X)\r\n", timeout, sts);

        if (sts & 0x04) {
            xil_printf("    WARNING: DataMover error flag set!\r\n");
            xil_printf("    Raw DM status byte: 0x%02X\r\n", (sts >> 4) & 0xFF);
        }
    }

    /* Invalidate destination cache to read fresh DataMover output */
    Xil_DCacheInvalidateRange((UINTPTR)dst, DRAIN_BYTES + 256);

    /* ================================================================== */
    /* 9. Verify output                                                   */
    /* ================================================================== */
    xil_printf("\r\n[9] Verifying output...\r\n");

    {
        u8 *out = dst;

        /* Test A: pixel (1,1) for all 32 channels */
        xil_printf("\r\n=== Pixel (1,1) - all 32 output channels ===\r\n");
        for (int oc = 0; oc < 32; oc++) {
            int byte_off = oc * (H_OUT * W_OUT) + 1 * W_OUT + 1;
            s8 got = (s8)out[byte_off];
            s8 exp = expected_center[oc];
            int ok = (got == exp);
            if (!ok) errors++;
            total_checks++;
            xil_printf("  oc %2d: got %4d  exp %4d  %s\r\n",
                       oc, (int)got, (int)exp, ok ? "OK" : "FAIL");
        }

        /* Test B: all 9 pixels for channel 0 */
        xil_printf("\r\n=== Channel 0 - all 9 pixels ===\r\n");
        for (int oh = 0; oh < 3; oh++) {
            for (int ow = 0; ow < 3; ow++) {
                int byte_off = 0 * 9 + oh * W_OUT + ow;
                s8 got = (s8)out[byte_off];
                s8 exp = expected_ch0_all[oh * 3 + ow];
                int ok = (got == exp);
                if (!ok) errors++;
                total_checks++;
                xil_printf("  (%d,%d): got %4d  exp %4d  %s\r\n",
                           oh, ow, (int)got, (int)exp, ok ? "OK" : "FAIL");
            }
        }
    }

    /* ================================================================== */
    /* Summary                                                            */
    /* ================================================================== */
    xil_printf("\r\n###################################################\r\n");
    xil_printf("  RESULTADOS P_16 Conv + DataMover\r\n");
    xil_printf("###################################################\r\n");
    xil_printf("  Checks: %d/%d passed\r\n", total_checks - errors, total_checks);
    if (errors == 0) {
        xil_printf("\r\n  >>> ALL PASSED -- Conv v3 + DataMover S2MM OK <<<\r\n");
    } else {
        xil_printf("\r\n  >>> FAILED: %d errors <<<\r\n", errors);
    }
    xil_printf("###################################################\r\n");

    /* Signal to XSCT */
    res[0] = MAGIC_DONE;
    res[1] = (u32)total_checks;
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    while(1);
    return 0;

fail:
    xil_printf("\r\n>>> INIT/DMA FAILURE -- aborting <<<\r\n");
    res[0] = MAGIC_DONE;
    res[1] = 0;
    res[2] = 1;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 1;
}
