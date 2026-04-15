/*
 * dpu_exec.c -- Implementacion de las 4 funciones dpu_exec_* sobre P_17.
 *
 * VERSION 1 (no tiling): solo ejecuta capas que caben en 4 KB BRAM.
 * Para capas mas grandes retorna DPU_ERR_TILING (el orquestrador debe
 * implementar tiling encima).
 *
 * Patron: reusa el flujo ya verificado en phase4_tests/*_test.c.
 */

#include "dpu_api.h"
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

/* ========================================================================= */
/* Addresses y registros                                                     */
/* ========================================================================= */
#ifndef XPAR_DPU_STREAM_WRAPPER_0_BASEADDR
#define XPAR_DPU_STREAM_WRAPPER_0_BASEADDR 0x40000000
#endif
#ifndef XPAR_GPIO_ADDR_BASEADDR
#define XPAR_GPIO_ADDR_BASEADDR 0x41200000
#endif
#ifndef XPAR_GPIO_CTRL_BASEADDR
#define XPAR_GPIO_CTRL_BASEADDR 0x41210000
#endif
#define DPU_BASE        XPAR_DPU_STREAM_WRAPPER_0_BASEADDR
#define GPIO_ADDR_BASE  XPAR_GPIO_ADDR_BASEADDR
#define GPIO_CTRL_BASE  XPAR_GPIO_CTRL_BASEADDR

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
#define REG_LAYER_TYPE   0x54
#define REG_M0_NEG       0x58
#define REG_N_NEG        0x5C
#define REG_B_ZP         0x60
#define REG_M0_B         0x64

#define LAYER_CONV       0
#define LAYER_MAXPOOL    1
#define LAYER_LEAKY_RELU 2
#define LAYER_ELEM_ADD   3

/* Scratch DDR regions para staging de BRAM image + output */
#define DPU_SRC_ADDR    0x10000000
#define DPU_DST_ADDR    0x10100000

/* ========================================================================= */
/* Helpers                                                                    */
/* ========================================================================= */
static void dpu_write(uint32_t off, uint32_t v) { Xil_Out32(DPU_BASE + off, v); }
static uint32_t dpu_read (uint32_t off)         { return Xil_In32(DPU_BASE + off); }
static void gpio_addr_write(uint32_t v) { Xil_Out32(GPIO_ADDR_BASE + 0x00, v); }
static void gpio_ctrl_write(uint32_t v) { Xil_Out32(GPIO_CTRL_BASE + 0x00, v); }
static uint32_t gpio_ctrl_read_status(void) { return Xil_In32(GPIO_CTRL_BASE + 0x08); }

/* Shared DMA instance (populated by dpu_init) */
static XAxiDma g_dma;
static int g_dma_ready = 0;

/* ========================================================================= */
/* dpu_init / dpu_reset                                                       */
/* ========================================================================= */
int dpu_init(void)
{
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) return DPU_ERR_PARAMS;
    if (XAxiDma_CfgInitialize(&g_dma, cfg) != XST_SUCCESS) return DPU_ERR_PARAMS;
    XAxiDma_IntrDisable(&g_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    g_dma_ready = 1;
    return DPU_OK;
}

void dpu_reset(void)
{
    dpu_write(REG_CTRL, 0);
}

/* ========================================================================= */
/* Helper: OIHW -> OHWI weight transpose (caller aloja buffer suficiente)     */
/* conv_engine_v3 espera OHWI.                                                 */
/* ========================================================================= */
static void transpose_oihw_to_ohwi(const int8_t *oihw, int8_t *ohwi,
                                   int oc, int ic, int kh, int kw)
{
    for (int o = 0; o < oc; o++) {
        for (int h = 0; h < kh; h++) {
            for (int w = 0; w < kw; w++) {
                for (int c = 0; c < ic; c++) {
                    ohwi[o*kh*kw*ic + h*kw*ic + w*ic + c] =
                        oihw[o*ic*kh*kw + c*kh*kw + h*kw + w];
                }
            }
        }
    }
}

/* ========================================================================= */
/* Helper: DMA MM2S + wait                                                    */
/* ========================================================================= */
static int dma_load(uintptr_t src, uint32_t bytes)
{
    int timeout;
    Xil_DCacheFlushRange((UINTPTR)src, bytes);
    if (XAxiDma_SimpleTransfer(&g_dma, src, bytes,
                               XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return DPU_ERR_PARAMS;
    timeout = 0;
    while (XAxiDma_Busy(&g_dma, XAXIDMA_DMA_TO_DEVICE)) {
        if (++timeout > 20000000) return DPU_ERR_TIMEOUT;
    }
    return DPU_OK;
}

/* Poll wrapper done_latch */
static int wait_done_latch(int max_polls)
{
    int t = 0;
    while (!(dpu_read(REG_CTRL) & 0x100)) {
        if (++t > max_polls) return DPU_ERR_TIMEOUT;
    }
    return DPU_OK;
}

/* Poll DataMover done */
static int wait_dm_done(int max_polls)
{
    int t = 0;
    while ((gpio_ctrl_read_status() & 0x02) == 0) {
        if (++t > max_polls) return DPU_ERR_TIMEOUT;
    }
    return DPU_OK;
}

/* Configure DataMover S2MM: dest + BTT + start pulse */
static void dm_configure(uint32_t dest_addr, uint32_t bytes)
{
    gpio_addr_write(dest_addr);
    gpio_ctrl_write(bytes & 0x7FFFFF);
    gpio_ctrl_write((bytes & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(bytes & 0x7FFFFF);
    usleep(10);
}

/* Wait FSM return to IDLE (bits 11:10 of REG_CTRL) */
static int wait_idle(int max_polls)
{
    int t = 0;
    while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 0) {
        if (++t > max_polls) return DPU_ERR_TIMEOUT;
    }
    return DPU_OK;
}

/* ========================================================================= */
/* dpu_exec_conv                                                              */
/* ========================================================================= */
/* BRAM layout CONV (igual phase3/4 tests):
 *   0x000: output zone (oc_out * h_out * w_out bytes, zeros iniciales)
 *   0x200: input activations (NHWC: h_in * w_in * c_in bytes)
 *   0x300: weights OHWI (c_out * kh * kw * c_in bytes)
 *   bias: despues de weights, aligned int32
 */
int dpu_exec_conv(const layer_config_t *L,
                  const uint8_t *in_ddr,
                  const int8_t  *weights_ddr,
                  const int32_t *bias_ddr,
                  uint8_t       *out_ddr,
                  dpu_prof_t    *prof)
{
    if (!g_dma_ready) return DPU_ERR_PARAMS;

    const int kh = L->kernel;
    const int kw = L->kernel;
    const int out_bytes = L->c_out * L->h_out * L->w_out;
    const int in_bytes  = L->c_in  * L->h_in  * L->w_in;
    const int w_bytes   = L->c_out * kh * kw * L->c_in;
    const int b_bytes   = L->c_out * 4;

    const uint32_t OUT_OFF  = 0x000;
    const uint32_t IN_OFF   = (OUT_OFF + out_bytes + 0x3F) & ~0x3FU;
    const uint32_t W_OFF    = (IN_OFF  + in_bytes  + 0x3F) & ~0x3FU;
    const uint32_t B_OFF    = (W_OFF   + w_bytes   + 0x3F) & ~0x3FU;
    const uint32_t TOT_BYTES = (B_OFF  + b_bytes   + 0x3FU) & ~0x3FU;

    if (TOT_BYTES > DPU_BRAM_BYTES) return DPU_ERR_TILING;

    uint8_t *src = (uint8_t *)DPU_SRC_ADDR;
    memset(src, 0, TOT_BYTES);
    memcpy(src + IN_OFF, in_ddr, in_bytes);

    /* Transpose weights OIHW -> OHWI */
    int8_t *wbuf = (int8_t *)(src + W_OFF);
    transpose_oihw_to_ohwi((const int8_t *)weights_ddr, wbuf,
                           L->c_out, L->c_in, kh, kw);

    /* Bias int32 -> little-endian bytes */
    uint8_t *bbuf = src + B_OFF;
    for (int i = 0; i < L->c_out; i++) {
        uint32_t v = (uint32_t)bias_ddr[i];
        bbuf[i*4 + 0] = (uint8_t)(v & 0xFF);
        bbuf[i*4 + 1] = (uint8_t)((v >> 8) & 0xFF);
        bbuf[i*4 + 2] = (uint8_t)((v >> 16) & 0xFF);
        bbuf[i*4 + 3] = (uint8_t)((v >> 24) & 0xFF);
    }

    /* Configure wrapper */
    const uint32_t ksize_enc  = (kh == 3) ? 2 : 0;
    const uint32_t stride_enc = (L->stride == 2) ? 1 : 0;

    dpu_write(REG_LAYER_TYPE,   LAYER_CONV);
    dpu_write(REG_N_WORDS,      TOT_BYTES / 4);
    dpu_write(REG_C_IN,         L->c_in);
    dpu_write(REG_C_OUT,        L->c_out);
    dpu_write(REG_H_IN,         L->h_in);
    dpu_write(REG_W_IN,         L->w_in);
    dpu_write(REG_KSP,          (stride_enc << 2) | ksize_enc);
    dpu_write(REG_X_ZP,         (uint32_t)(int32_t)L->x_zp & 0x1FF);
    dpu_write(REG_W_ZP,         (uint32_t)(int32_t)L->w_zp & 0xFF);
    dpu_write(REG_M0,           L->M0);
    dpu_write(REG_N_SHIFT,      L->n_shift);
    dpu_write(REG_Y_ZP,         (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_ADDR_INPUT,   IN_OFF);
    dpu_write(REG_ADDR_WEIGHTS, W_OFF);
    dpu_write(REG_ADDR_BIAS,    B_OFF);
    dpu_write(REG_ADDR_OUTPUT,  OUT_OFF);
    dpu_write(REG_IC_TILE_SIZE, L->c_in);  /* no tiling IC por ahora */
    dpu_write(REG_PAD_TOP,      L->pad);
    dpu_write(REG_PAD_BOTTOM,   L->pad);
    dpu_write(REG_PAD_LEFT,     L->pad);
    dpu_write(REG_PAD_RIGHT,    L->pad);

    /* LOAD */
    dpu_write(REG_CTRL, 0x01);
    if (dma_load((uintptr_t)src, TOT_BYTES) != DPU_OK) return DPU_ERR_TIMEOUT;
    if (wait_idle(1000000) != DPU_OK) return DPU_ERR_TIMEOUT;

    /* START */
    dpu_write(REG_CTRL, 0x02);
    if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;

    /* DRAIN via DataMover */
    dm_configure((uintptr_t)out_ddr, out_bytes);
    dpu_write(REG_N_WORDS, (out_bytes + 3) / 4);
    dpu_write(REG_CTRL, 0x04);
    if (wait_dm_done(20000000) != DPU_OK) return DPU_ERR_DM_FAULT;

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, out_bytes);

    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}

/* ========================================================================= */
/* dpu_exec_leaky                                                             */
/* ========================================================================= */
int dpu_exec_leaky(const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof)
{
    if (!g_dma_ready) return DPU_ERR_PARAMS;

    const int n_bytes = L->c_in * L->h_in * L->w_in;
    if (n_bytes % 4 != 0) return DPU_ERR_PARAMS;
    const int n_words = n_bytes / 4;

    if ((uintptr_t)in_ddr != DPU_SRC_ADDR) {
        memcpy((void *)DPU_SRC_ADDR, in_ddr, n_bytes);
    }
    Xil_DCacheFlushRange((UINTPTR)DPU_SRC_ADDR, n_bytes);

    dpu_write(REG_LAYER_TYPE, LAYER_LEAKY_RELU);
    dpu_write(REG_N_WORDS,    n_words);
    dpu_write(REG_X_ZP,       (uint32_t)(int32_t)L->x_zp & 0x1FF);
    dpu_write(REG_Y_ZP,       (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_M0,         L->M0);
    dpu_write(REG_N_SHIFT,    L->n_shift);
    dpu_write(REG_M0_NEG,     L->M0_neg);
    dpu_write(REG_N_NEG,      L->n_neg);

    dm_configure((uintptr_t)out_ddr, n_bytes);
    dpu_write(REG_CTRL, 0x02);

    if (XAxiDma_SimpleTransfer(&g_dma, (UINTPTR)DPU_SRC_ADDR, n_bytes,
                               XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return DPU_ERR_PARAMS;

    if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;
    if (wait_dm_done(20000000) != DPU_OK) return DPU_ERR_DM_FAULT;

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, n_bytes);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}

/* ========================================================================= */
/* dpu_exec_pool                                                              */
/* Requiere input pre-ordenado por ARM en ventanas 2x2 contiguas (4 bytes     */
/* consecutivos = 1 ventana). Output: 1 byte por ventana.                     */
/* Aqui asumimos que in_ddr YA esta ordenado. El caller lo debe preparar.     */
/* ========================================================================= */
int dpu_exec_pool(const layer_config_t *L,
                  const uint8_t *in_ddr,
                  uint8_t       *out_ddr,
                  dpu_prof_t    *prof)
{
    if (!g_dma_ready) return DPU_ERR_PARAMS;

    /* Numero de ventanas = h_out * w_out * c_in. Cada ventana = 4 bytes */
    const int n_windows = L->h_out * L->w_out * L->c_in;
    const int n_input_bytes = n_windows * 4;
    const int n_output_bytes = n_windows;
    if (n_input_bytes % 4 != 0) return DPU_ERR_PARAMS;

    if ((uintptr_t)in_ddr != DPU_SRC_ADDR) {
        memcpy((void *)DPU_SRC_ADDR, in_ddr, n_input_bytes);
    }
    Xil_DCacheFlushRange((UINTPTR)DPU_SRC_ADDR, n_input_bytes);

    dpu_write(REG_LAYER_TYPE, LAYER_MAXPOOL);
    dpu_write(REG_N_WORDS,    n_input_bytes / 4);

    dm_configure((uintptr_t)out_ddr, n_output_bytes);
    dpu_write(REG_CTRL, 0x02);

    if (XAxiDma_SimpleTransfer(&g_dma, (UINTPTR)DPU_SRC_ADDR, n_input_bytes,
                               XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return DPU_ERR_PARAMS;

    if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;
    if (wait_dm_done(20000000) != DPU_OK) return DPU_ERR_DM_FAULT;

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, n_output_bytes);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}

/* ========================================================================= */
/* dpu_exec_add                                                               */
/* A y B concatenados: DDR_SRC[0..N-1] = A, DDR_SRC[N..2N-1] = B              */
/* ========================================================================= */
int dpu_exec_add(const layer_config_t *L,
                 const uint8_t *in_a_ddr,
                 const uint8_t *in_b_ddr,
                 uint8_t       *out_ddr,
                 dpu_prof_t    *prof)
{
    if (!g_dma_ready) return DPU_ERR_PARAMS;

    const int n_bytes = L->c_in * L->h_in * L->w_in;
    if (n_bytes % 4 != 0) return DPU_ERR_PARAMS;
    if (2 * n_bytes > DPU_BRAM_BYTES) return DPU_ERR_TILING;

    uint8_t *src = (uint8_t *)DPU_SRC_ADDR;
    memcpy(src,             in_a_ddr, n_bytes);
    memcpy(src + n_bytes,   in_b_ddr, n_bytes);
    Xil_DCacheFlushRange((UINTPTR)src, 2 * n_bytes);

    dpu_write(REG_LAYER_TYPE,   LAYER_ELEM_ADD);
    dpu_write(REG_N_WORDS,      (2 * n_bytes) / 4);
    dpu_write(REG_X_ZP,         (uint32_t)(int32_t)L->x_zp & 0x1FF);  /* = a_zp */
    dpu_write(REG_B_ZP,         (uint32_t)(int32_t)L->b_zp & 0xFF);
    dpu_write(REG_Y_ZP,         (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_M0,           L->M0);    /* M0_a */
    dpu_write(REG_M0_B,         L->M0_b);
    dpu_write(REG_N_SHIFT,      L->n_shift);
    dpu_write(REG_ADDR_INPUT,   0x000);
    dpu_write(REG_ADDR_WEIGHTS, n_bytes);

    /* LOAD */
    dpu_write(REG_CTRL, 0x01);
    if (dma_load((uintptr_t)src, 2 * n_bytes) != DPU_OK) return DPU_ERR_TIMEOUT;
    if (wait_idle(1000000) != DPU_OK) return DPU_ERR_TIMEOUT;

    /* DataMover + start */
    dm_configure((uintptr_t)out_ddr, n_bytes);
    dpu_write(REG_CTRL, 0x02);

    if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;
    if (wait_dm_done(20000000) != DPU_OK) return DPU_ERR_DM_FAULT;

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, n_bytes);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}

/* ========================================================================= */
/* arm_concat (NHWC: [h, w, c_a + c_b])                                        */
/* ========================================================================= */
int arm_concat(const layer_config_t *L,
               const uint8_t *in_a_ddr, uint16_t c_a,
               const uint8_t *in_b_ddr, uint16_t c_b,
               uint8_t       *out_ddr,
               dpu_prof_t    *prof)
{
    (void)L;
    for (int h = 0; h < L->h_in; h++) {
        for (int w = 0; w < L->w_in; w++) {
            const uint8_t *sa = in_a_ddr + (h * L->w_in + w) * c_a;
            const uint8_t *sb = in_b_ddr + (h * L->w_in + w) * c_b;
            uint8_t *d = out_ddr + (h * L->w_in + w) * (c_a + c_b);
            memcpy(d,         sa, c_a);
            memcpy(d + c_a,   sb, c_b);
        }
    }
    Xil_DCacheFlushRange((UINTPTR)out_ddr, L->h_in * L->w_in * (c_a + c_b));
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}

/* ========================================================================= */
/* arm_upsample 2x nearest-neighbour (NHWC)                                   */
/* ========================================================================= */
int arm_upsample(const layer_config_t *L,
                 const uint8_t *in_ddr,
                 uint8_t       *out_ddr,
                 dpu_prof_t    *prof)
{
    const int H = L->h_in, W = L->w_in, C = L->c_in;
    const int OW = 2 * W;
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            const uint8_t *s = in_ddr + (h * W + w) * C;
            /* 4 destinos: (2h, 2w), (2h, 2w+1), (2h+1, 2w), (2h+1, 2w+1) */
            uint8_t *d00 = out_ddr + ((2*h)  *OW + (2*w))  *C;
            uint8_t *d01 = out_ddr + ((2*h)  *OW + (2*w+1))*C;
            uint8_t *d10 = out_ddr + ((2*h+1)*OW + (2*w))  *C;
            uint8_t *d11 = out_ddr + ((2*h+1)*OW + (2*w+1))*C;
            memcpy(d00, s, C);
            memcpy(d01, s, C);
            memcpy(d10, s, C);
            memcpy(d11, s, C);
        }
    }
    Xil_DCacheFlushRange((UINTPTR)out_ddr, 2*H * 2*W * C);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}
