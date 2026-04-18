/*
 * dpu_exec_tiled.c -- Tiling ARM para capas CONV que no caben en BRAM.
 *
 * v2: soporta pads asimétricos por tile (corrección crítica del run #2).
 *     Programa los 4 regs pad_* directamente por cada sub-tile, evitando
 *     el wrapper dpu_exec_conv que asume pad simétrico.
 */

#include "dpu_api.h"
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "sleep.h"
#include <string.h>

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

#define LAYER_CONV       0

/* Scratch dedicado a tiled conv (separado de dpu_exec.c) */
#define TILE_SCRATCH_ADDR 0x14000000u

#define BRAM_DEPTH_BYTES  4096
#define BRAM_ALIGN(x)     (((x) + 63) & ~63U)

extern XAxiDma *dpu_get_dma(void);   /* accessor — defined in dpu_exec.c */

/* Locals (duplicadas de dpu_exec.c para no exponer helpers) */
static void dpu_write(uint32_t off, uint32_t v) { Xil_Out32(DPU_BASE + off, v); }
static uint32_t dpu_read(uint32_t off) { return Xil_In32(DPU_BASE + off); }
static void gpio_addr_write(uint32_t v) { Xil_Out32(GPIO_ADDR_BASE + 0x00, v); }
static void gpio_ctrl_write(uint32_t v) { Xil_Out32(GPIO_CTRL_BASE + 0x00, v); }
static uint32_t gpio_ctrl_read_status(void) { return Xil_In32(GPIO_CTRL_BASE + 0x08); }

/* Calcula tile size que cabe en 4 KB BRAM */
static int compute_tile_size(const layer_config_t *L, int *h_tile, int *w_tile)
{
    const int kh = L->kernel;
    const int stride = (L->stride == 2) ? 2 : 1;
    const int b_bytes = L->c_out * 4;
    const int w_bytes = L->c_out * kh * kh * L->c_in;

    int aligned_w = BRAM_ALIGN(w_bytes);
    int aligned_b = BRAM_ALIGN(b_bytes);
    if (aligned_w + aligned_b + 256 >= BRAM_DEPTH_BYTES) return 0;
    int room = BRAM_DEPTH_BYTES - aligned_w - aligned_b - 128;

    for (int t = 32; t >= 1; t--) {
        int in_h = (stride == 2) ? (2 * t + kh - 1) : (t + kh - 1);
        int in_bytes  = in_h * in_h * L->c_in;
        int out_bytes = t * t * L->c_out;
        if (BRAM_ALIGN(in_bytes) + BRAM_ALIGN(out_bytes) <= room) {
            *h_tile = t; *w_tile = t;
            return 1;
        }
    }
    return 0;
}

/* Ejecuta UN tile de conv con 4 pads explicitos. Bloqueante. */
static int run_one_tile(XAxiDma *dma,
                        const layer_config_t *L,
                        int tile_h_in, int tile_w_in, int tile_h_out, int tile_w_out,
                        int pad_t, int pad_b, int pad_l, int pad_r,
                        const uint8_t *in_tile_ddr,  /* bytes h*w*c_in */
                        const int8_t  *weights_ddr,
                        const int32_t *bias_ddr,
                        uint8_t       *out_tile_ddr)
{
    const int kh = L->kernel;
    const int kw = L->kernel;
    const int out_bytes = L->c_out * tile_h_out * tile_w_out;
    const int in_bytes  = L->c_in  * tile_h_in  * tile_w_in;
    const int w_bytes   = L->c_out * kh * kw * L->c_in;
    const int b_bytes   = L->c_out * 4;

    const uint32_t OUT_OFF  = 0x000;
    const uint32_t IN_OFF   = (OUT_OFF + out_bytes + 0x3F) & ~0x3FU;
    const uint32_t W_OFF    = (IN_OFF  + in_bytes  + 0x3F) & ~0x3FU;
    const uint32_t B_OFF    = (W_OFF   + w_bytes   + 0x3F) & ~0x3FU;
    const uint32_t TOT      = (B_OFF   + b_bytes   + 0x3FU) & ~0x3FU;

    if (TOT > BRAM_DEPTH_BYTES) return DPU_ERR_TILING;

    uint8_t *src = (uint8_t *)TILE_SCRATCH_ADDR;
    memset(src, 0, TOT);

    /* Invalidar D-cache antes de leer input/weights/bias desde DDR —
     * mismo fix que en dpu_exec.c fast-path. Sin esto, el ARM lee cache
     * stale y el scratch se llena de ceros. 2026-04-17. */
    {
        #ifndef ALIGN_UP
        #define ALIGN_UP(x, a)   (((x) + ((a)-1)) & ~((a)-1))
        #endif
        Xil_DCacheInvalidateRange((UINTPTR)in_tile_ddr, ALIGN_UP(in_bytes, 64));
        Xil_DCacheInvalidateRange((UINTPTR)weights_ddr, ALIGN_UP(w_bytes, 64));
        Xil_DCacheInvalidateRange((UINTPTR)bias_ddr,    ALIGN_UP(b_bytes, 64));
    }

    memcpy(src + IN_OFF, in_tile_ddr, in_bytes);

    /* Weights: ya estan en layout OHWI en la DDR (extract_weights_blob.py),
     * copiar directo. */
    memcpy(src + W_OFF, weights_ddr, w_bytes);

    /* Bias int32 LE copia directa */
    memcpy(src + B_OFF, (const uint8_t *)bias_ddr, b_bytes);

    const uint32_t ksize_enc  = (kh == 3) ? 2 : 0;
    const uint32_t stride_enc = (L->stride == 2) ? 1 : 0;

    dpu_write(REG_LAYER_TYPE,   LAYER_CONV);
    dpu_write(REG_N_WORDS,      TOT / 4);
    dpu_write(REG_C_IN,         L->c_in);
    dpu_write(REG_C_OUT,        L->c_out);
    dpu_write(REG_H_IN,         tile_h_in);
    dpu_write(REG_W_IN,         tile_w_in);
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
    dpu_write(REG_IC_TILE_SIZE, L->c_in);
    dpu_write(REG_PAD_TOP,      pad_t);   /* <<< 4 PADS EXPLICITOS */
    dpu_write(REG_PAD_BOTTOM,   pad_b);
    dpu_write(REG_PAD_LEFT,     pad_l);
    dpu_write(REG_PAD_RIGHT,    pad_r);

    /* LOAD */
    Xil_DCacheFlushRange((UINTPTR)src, TOT);
    dpu_write(REG_CTRL, 0x01);
    if (XAxiDma_SimpleTransfer(dma, (UINTPTR)src, TOT,
                               XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return DPU_ERR_PARAMS;
    int tm = 0;
    while (XAxiDma_Busy(dma, XAXIDMA_DMA_TO_DEVICE)) {
        if (++tm > 10000000) return DPU_ERR_TIMEOUT;
    }
    tm = 0;
    while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 0) {
        if (++tm > 1000000) return DPU_ERR_TIMEOUT;
    }

    /* START */
    dpu_write(REG_CTRL, 0x02);
    tm = 0;
    while (!(dpu_read(REG_CTRL) & 0x100)) {
        if (++tm > 20000000) return DPU_ERR_TIMEOUT;
    }

    /* DRAIN */
    gpio_addr_write((uintptr_t)out_tile_ddr);
    gpio_ctrl_write(out_bytes & 0x7FFFFF);
    gpio_ctrl_write((out_bytes & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(out_bytes & 0x7FFFFF);
    usleep(10);

    dpu_write(REG_N_WORDS, (out_bytes + 3) / 4);
    dpu_write(REG_CTRL, 0x04);

    tm = 0;
    while ((gpio_ctrl_read_status() & 0x02) == 0) {
        if (++tm > 20000000) return DPU_ERR_DM_FAULT;
    }

    Xil_DCacheInvalidateRange((UINTPTR)out_tile_ddr, out_bytes);
    return DPU_OK;
}

extern int dpu_exec_conv(const layer_config_t *L,
                         const uint8_t *in_ddr,
                         const int8_t  *weights_ddr,
                         const int32_t *bias_ddr,
                         uint8_t       *out_ddr,
                         dpu_prof_t    *prof);

/* ========================================================================= */
/* dpu_exec_conv_tiled v2 — strip mining H+W con pads asim per tile          */
/* ========================================================================= */
int dpu_exec_conv_tiled(const layer_config_t *L,
                        const uint8_t *in_ddr,
                        const int8_t  *weights_ddr,
                        const int32_t *bias_ddr,
                        uint8_t       *out_ddr,
                        dpu_prof_t    *prof)
{
    /* Fast path: full layer cabe */
    int r = dpu_exec_conv(L, in_ddr, weights_ddr, bias_ddr, out_ddr, prof);
    if (r == DPU_OK) return DPU_OK;
    if (r != DPU_ERR_TILING) return r;

    int H_TILE, W_TILE;
    if (!compute_tile_size(L, &H_TILE, &W_TILE)) return DPU_ERR_TILING;

    const int kh = L->kernel;
    const int kw = L->kernel;
    const int stride = (L->stride == 2) ? 2 : 1;
    const int pad = L->pad;
    int total_tiles = 0;

    XAxiDma *dma = dpu_get_dma();
    if (!dma) return DPU_ERR_PARAMS;

    uint8_t *tile_in_buf  = (uint8_t *)(TILE_SCRATCH_ADDR + 0x100000);  /* +1 MB */
    uint8_t *tile_out_buf = (uint8_t *)(TILE_SCRATCH_ADDR + 0x200000);  /* +2 MB */

    for (int oh0 = 0; oh0 < L->h_out; oh0 += H_TILE) {
        int h_tile = (oh0 + H_TILE <= L->h_out) ? H_TILE : (L->h_out - oh0);

        for (int ow0 = 0; ow0 < L->w_out; ow0 += W_TILE) {
            int w_tile = (ow0 + W_TILE <= L->w_out) ? W_TILE : (L->w_out - ow0);

            int ih_start = oh0 * stride - pad;
            int iw_start = ow0 * stride - pad;
            int in_h_needed = (h_tile - 1) * stride + kh;
            int in_w_needed = (w_tile - 1) * stride + kw;

            int pad_t = (ih_start < 0) ? (-ih_start) : 0;
            int pad_l = (iw_start < 0) ? (-iw_start) : 0;
            int ih_end = ih_start + in_h_needed;
            int iw_end = iw_start + in_w_needed;
            int pad_b = (ih_end > L->h_in) ? (ih_end - L->h_in) : 0;
            int pad_r = (iw_end > L->w_in) ? (iw_end - L->w_in) : 0;

            /* Clamp pads a 0..2 (registros de 2 bits) */
            if (pad_t > 2) pad_t = 2;
            if (pad_b > 2) pad_b = 2;
            if (pad_l > 2) pad_l = 2;
            if (pad_r > 2) pad_r = 2;

            int ih_lo = ih_start < 0 ? 0 : ih_start;
            int iw_lo = iw_start < 0 ? 0 : iw_start;
            int ih_hi = ih_end > L->h_in ? L->h_in : ih_end;
            int iw_hi = iw_end > L->w_in ? L->w_in : iw_end;
            int in_h_real = ih_hi - ih_lo;
            int in_w_real = iw_hi - iw_lo;

            if (in_h_real <= 0 || in_w_real <= 0) continue;

            /* Copiar sub-input en NCHW (channels-first, que es lo que el
             * RTL espera). Para cada canal c, copiar la fila del
             * sub-rectangulo espacial (ih_lo..ih_hi, iw_lo..iw_hi). */
            Xil_DCacheInvalidateRange((UINTPTR)in_ddr,
                                      (uint32_t)L->c_in * L->h_in * L->w_in);
            for (int c = 0; c < L->c_in; c++) {
                for (int rr = 0; rr < in_h_real; rr++) {
                    const uint8_t *src = in_ddr
                        + (uint32_t)c * L->h_in * L->w_in
                        + (uint32_t)(ih_lo + rr) * L->w_in
                        + iw_lo;
                    uint8_t *dst = tile_in_buf
                        + (uint32_t)c * in_h_real * in_w_real
                        + rr * in_w_real;
                    memcpy(dst, src, in_w_real);
                }
            }
            Xil_DCacheFlushRange((UINTPTR)tile_in_buf,
                                 (uint32_t)L->c_in * in_h_real * in_w_real);

            int st = run_one_tile(dma, L,
                                  in_h_real, in_w_real, h_tile, w_tile,
                                  pad_t, pad_b, pad_l, pad_r,
                                  tile_in_buf, weights_ddr, bias_ddr,
                                  tile_out_buf);
            if (st != DPU_OK) {
                xil_printf("[tile] L=%d sub (%d,%d) t=(%d,%d) pad=[%d,%d,%d,%d] fail %d\r\n",
                           L->layer_id, oh0, ow0, h_tile, w_tile,
                           pad_t, pad_b, pad_l, pad_r, st);
                return st;
            }

            /* Copiar tile_out al output tensor grande. El RTL escribe NCHW
             * (c stride = h_out_tile * w_out_tile). Recomponer al tensor
             * global NCHW (c stride = L->h_out * L->w_out). */
            for (int c = 0; c < L->c_out; c++) {
                for (int rr = 0; rr < h_tile; rr++) {
                    const uint8_t *src = tile_out_buf
                        + (uint32_t)c * h_tile * w_tile
                        + rr * w_tile;
                    uint8_t *dst = out_ddr
                        + (uint32_t)c * L->h_out * L->w_out
                        + (uint32_t)(oh0 + rr) * L->w_out
                        + ow0;
                    memcpy(dst, src, w_tile);
                }
            }
            total_tiles++;
        }
    }

    Xil_DCacheFlushRange((UINTPTR)out_ddr, L->h_out * L->w_out * L->c_out);
    if (prof) prof->n_tiles = total_tiles;
    return DPU_OK;
}
