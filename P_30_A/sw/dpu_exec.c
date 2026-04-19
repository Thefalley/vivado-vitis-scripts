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

/* Accessor usado por dpu_exec_tiled.c (tiling H+W por ARM). */
XAxiDma *dpu_get_dma(void) { return &g_dma; }
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
    /* Direct register writes — bypasses Xilinx SimpleTransfer which has
     * a broken busy check (rejects RUNNING+IDLE channels). */
    Xil_DCacheFlushRange(src, bytes);
    uint32_t base = g_dma.RegBase;
    /* Wait for any previous transfer to finish */
    int t = 0;
    while (!(Xil_In32(base + 0x04) & 0x03)) {
        if (++t > 5000000) return DPU_ERR_TIMEOUT;
    }
    uint32_t cr = Xil_In32(base + 0x00);
    if (!(cr & 1)) Xil_Out32(base + 0x00, cr | 1);  /* set RUNSTOP */
    Xil_Out32(base + 0x18, (uint32_t)src);            /* source addr */
    Xil_Out32(base + 0x28, bytes);                     /* length → start */
    t = 0;
    for (;;) {
        uint32_t sr = Xil_In32(base + 0x04);
        if (sr & 0x01) return DPU_OK;  /* HALTED */
        if (sr & 0x02) return DPU_OK;  /* IDLE */
        if (++t > 20000000) return DPU_ERR_TIMEOUT;
    }
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

    /* Invalidate D-cache para los buffers source ANTES de leerlos: el PC
     * los escribio via DDR y sin esto el ARM lee cache stale (ceros del
     * boot o basura antigua). 2026-04-17 bug confirmado con dump_scratch.py
     * Tamanios alineados a 64 para garantizar cubrir cache lines.
     */
    {
        #define ALIGN_UP(x, a)   (((x) + ((a)-1)) & ~((a)-1))
        uint32_t in_align = ALIGN_UP(in_bytes, 64);
        uint32_t w_align  = ALIGN_UP(w_bytes, 64);
        uint32_t b_align  = ALIGN_UP(b_bytes, 64);
        Xil_DCacheInvalidateRange((UINTPTR)in_ddr, in_align);
        Xil_DCacheInvalidateRange((UINTPTR)weights_ddr, w_align);
        Xil_DCacheInvalidateRange((UINTPTR)bias_ddr, b_align);
    }

    memcpy(src + IN_OFF, in_ddr, in_bytes);

    /* Pesos YA vienen en OHWI desde el PC (extract_weights_blob.py los
     * transpone, y los tests XSIM usan el mismo layout).
     * Antes aqui habia un transpose_oihw_to_ohwi que doblaba el orden y
     * rompia el bit-exact. FIX 2026-04-17: copia directa.
     */
    int8_t *wbuf = (int8_t *)(src + W_OFF);
    memcpy(wbuf, (const void *)weights_ddr, (size_t)w_bytes);

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
/* El wrapper tiene reg_n_words de 10 bits -> max 1023 words = 4092 bytes.
 * Partimos en chunks de ese tamano (copiado de P_17 runtime verificado). */
#define STREAM_CHUNK_WORDS_MAX 1023
#define STREAM_CHUNK_BYTES_MAX (STREAM_CHUNK_WORDS_MAX * 4)  /* 4092 */

int dpu_exec_leaky(const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof)
{
    if (!g_dma_ready) return DPU_ERR_PARAMS;

    #ifndef ALIGN_UP
    #define ALIGN_UP(x, a)   (((x) + ((a)-1)) & ~((a)-1))
    #endif

    const uint32_t n_bytes_total = (uint32_t)L->c_in * L->h_in * L->w_in;
    if (n_bytes_total % 4 != 0) return DPU_ERR_PARAMS;

    /* Wait DMA idle + invalidate cache input */
    {
        int wait_t = 0;
        while (!(Xil_In32(g_dma.RegBase+0x04) & 0x03)) {
            if (++wait_t > 5000000) return DPU_ERR_TIMEOUT;
        }
    }
    Xil_DCacheInvalidateRange((UINTPTR)in_ddr, ALIGN_UP(n_bytes_total, 64));

    /* Programar registros constantes una vez (M0, zp, etc.) */
    dpu_write(REG_LAYER_TYPE, LAYER_LEAKY_RELU);
    dpu_write(REG_X_ZP,       (uint32_t)(int32_t)L->x_zp & 0x1FF);
    dpu_write(REG_Y_ZP,       (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_M0,         L->M0);
    dpu_write(REG_N_SHIFT,    L->n_shift);
    dpu_write(REG_M0_NEG,     L->M0_neg);
    dpu_write(REG_N_NEG,      L->n_neg);

    /* Chunking loop — patron copiado de P_17 runtime verificado en HW. */
    uint32_t n_chunks = 0;
    uint32_t off = 0;
    while (off < n_bytes_total) {
        uint32_t chunk = n_bytes_total - off;
        if (chunk > STREAM_CHUNK_BYTES_MAX) chunk = STREAM_CHUNK_BYTES_MAX;
        chunk &= ~0x3u;
        if (chunk == 0) break;

        /* Wait DMA idle from previous chunk */
        {
            int wait_t = 0;
            while (!(Xil_In32(g_dma.RegBase+0x04) & 0x03)) {
                if (++wait_t > 10000000) return DPU_ERR_TIMEOUT;
            }
        }

        Xil_DCacheFlushRange((UINTPTR)(in_ddr + off), chunk);

        dpu_write(REG_N_WORDS, chunk / 4);
        dm_configure((uintptr_t)(out_ddr + off), chunk);
        dpu_write(REG_CTRL, 0x02);

        { uint32_t cr=Xil_In32(g_dma.RegBase);
          if(!(cr&1)) Xil_Out32(g_dma.RegBase,cr|1);
          Xil_Out32(g_dma.RegBase+0x18,(uint32_t)(in_ddr+off));
          Xil_Out32(g_dma.RegBase+0x28,chunk); }

        if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;
        if (wait_dm_done(20000000)    != DPU_OK) return DPU_ERR_DM_FAULT;

        off += chunk;
        n_chunks++;
    }

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, ALIGN_UP(n_bytes_total, 64));
    if (prof) { prof->n_tiles = n_chunks; }
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

    /* Each window = 4 input bytes → 1 output byte (2x2 max).
     * reg_n_words is 11 bits (max 2047). Input is n_words words.
     * Max chunk = 2047 words = 8188 bytes input = 2047 windows.
     * We chunk by windows to keep alignment. */
    const int total_windows = L->h_out * L->w_out * L->c_in;
    const int max_win_chunk = 2047;  /* max windows per chunk (reg_n_words limit) */

    dpu_write(REG_LAYER_TYPE, LAYER_MAXPOOL);
    Xil_DCacheInvalidateRange((UINTPTR)in_ddr, total_windows * 4);

    int total_tiles = 0;
    uint8_t *src = (uint8_t *)DPU_SRC_ADDR;

    for (int win_off = 0; win_off < total_windows; win_off += max_win_chunk) {
        int win_chunk = total_windows - win_off;
        if (win_chunk > max_win_chunk) win_chunk = max_win_chunk;

        int in_chunk  = win_chunk * 4;   /* 4 bytes per window input */
        int out_chunk = win_chunk;       /* 1 byte per window output */

        memcpy(src, in_ddr + win_off * 4, in_chunk);
        Xil_DCacheFlushRange((UINTPTR)src, in_chunk);

        dpu_write(REG_N_WORDS, in_chunk / 4);
        dm_configure((uintptr_t)(out_ddr + win_off), out_chunk);
        dpu_write(REG_CTRL, 0x02);

        { uint32_t cr=Xil_In32(g_dma.RegBase);
          if(!(cr&1)) Xil_Out32(g_dma.RegBase,cr|1);
          Xil_Out32(g_dma.RegBase+0x18,(uint32_t)src);
          Xil_Out32(g_dma.RegBase+0x28,in_chunk); }

        if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;
        if (wait_dm_done(20000000) != DPU_OK) return DPU_ERR_DM_FAULT;

        total_tiles++;
    }

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, total_windows);
    if (prof) { prof->n_tiles = total_tiles; }
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

    /* Max chunk: A+B must fit in BRAM AND reg_n_words (11 bits, max 2047).
     * Since n_words = (2*chunk)/4 must be <= 2047: chunk <= 2047*4/2 = 4094.
     * Align down to 4 bytes. */
    const int max_chunk = 4092;

    dpu_write(REG_LAYER_TYPE,   LAYER_ELEM_ADD);
    dpu_write(REG_X_ZP,         (uint32_t)(int32_t)L->x_zp & 0x1FF);
    dpu_write(REG_B_ZP,         (uint32_t)(int32_t)L->b_zp & 0xFF);
    dpu_write(REG_Y_ZP,         (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_M0,           L->M0);
    dpu_write(REG_M0_B,         L->M0_b);
    dpu_write(REG_N_SHIFT,      L->n_shift);

    Xil_DCacheInvalidateRange((UINTPTR)in_a_ddr, n_bytes);
    Xil_DCacheInvalidateRange((UINTPTR)in_b_ddr, n_bytes);

    int total_tiles = 0;
    uint8_t *src = (uint8_t *)DPU_SRC_ADDR;

    for (int off = 0; off < n_bytes; off += max_chunk) {
        int chunk = n_bytes - off;
        if (chunk > max_chunk) chunk = max_chunk;

        /* Concatenate A_chunk + B_chunk in scratch buffer */
        memcpy(src,         in_a_ddr + off, chunk);
        memcpy(src + chunk, in_b_ddr + off, chunk);
        Xil_DCacheFlushRange((UINTPTR)src, 2 * chunk);

        dpu_write(REG_N_WORDS,      (2 * chunk) / 4);
        dpu_write(REG_ADDR_INPUT,   0x000);
        dpu_write(REG_ADDR_WEIGHTS, chunk);

        /* LOAD A+B → BRAM */
        dpu_write(REG_CTRL, 0x01);
        if (dma_load((uintptr_t)src, 2 * chunk) != DPU_OK) return DPU_ERR_TIMEOUT;
        if (wait_idle(1000000) != DPU_OK) return DPU_ERR_TIMEOUT;

        /* DataMover dest + START → compute + drain
         * Don't change N_WORDS — wrapper uses it from LOAD phase */
        dm_configure((uintptr_t)(out_ddr + off), chunk);
        dpu_write(REG_CTRL, 0x02);

        if (wait_done_latch(20000000) != DPU_OK) return DPU_ERR_TIMEOUT;
        if (wait_dm_done(20000000) != DPU_OK) return DPU_ERR_DM_FAULT;

        total_tiles++;
    }

    Xil_DCacheInvalidateRange((UINTPTR)out_ddr, n_bytes);
    if (prof) { prof->n_tiles = total_tiles; }
    return DPU_OK;
}

/* ========================================================================= */
/* arm_concat (NHWC: [h, w, c_a + c_b])                                        */
/* ========================================================================= */
/* Requantize helper: out = clamp(round((in - zp_in) * M0 / 2^n) + zp_out, -128, 127)
 * Same formula as the DPU's requantize module but in software. */
static inline int8_t requant_byte(int8_t in, int32_t zp_in, uint32_t M0,
                                  int n_shift, int32_t zp_out)
{
    int64_t val = ((int64_t)(in - zp_in) * (int64_t)M0 + (1LL << (n_shift - 1))) >> n_shift;
    val += zp_out;
    if (val < -128) val = -128;
    if (val >  127) val =  127;
    return (int8_t)val;
}

int arm_concat(const layer_config_t *L,
               const uint8_t *in_a_ddr, uint16_t c_a,
               const uint8_t *in_b_ddr, uint16_t c_b,
               uint8_t       *out_ddr,
               dpu_prof_t    *prof)
{
    /* NCHW concatenation along channel axis.
     * Raw copy — the requantization parameters in layer_configs are
     * not correct for CONCAT (they're for the subsequent CONV layer).
     * TODO: extract proper CONCAT requant scales from the ONNX model. */
    const uint32_t HW = (uint32_t)L->h_in * L->w_in;

    Xil_DCacheInvalidateRange((UINTPTR)in_a_ddr, c_a * HW);
    Xil_DCacheInvalidateRange((UINTPTR)in_b_ddr, c_b * HW);
    memcpy(out_ddr,            in_a_ddr, c_a * HW);
    memcpy(out_ddr + c_a * HW, in_b_ddr, c_b * HW);
    Xil_DCacheFlushRange((UINTPTR)out_ddr, (c_a + c_b) * HW);
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
    /* NCHW 2x nearest-neighbour upsample.
     * Each channel plane (H×W) → (2H×2W) by duplicating each pixel to 2x2. */
    const int H = L->h_in, W = L->w_in, C = L->c_in;
    const int OW = 2 * W;
    Xil_DCacheInvalidateRange((UINTPTR)in_ddr, C * H * W);
    for (int c = 0; c < C; c++) {
        const uint8_t *src_plane = in_ddr + (uint32_t)c * H * W;
        uint8_t *dst_plane = out_ddr + (uint32_t)c * (2*H) * OW;
        for (int h = 0; h < H; h++) {
            for (int w = 0; w < W; w++) {
                uint8_t v = src_plane[h * W + w];
                dst_plane[(2*h)   * OW + (2*w)]   = v;
                dst_plane[(2*h)   * OW + (2*w+1)] = v;
                dst_plane[(2*h+1) * OW + (2*w)]   = v;
                dst_plane[(2*h+1) * OW + (2*w+1)] = v;
            }
        }
    }
    Xil_DCacheFlushRange((UINTPTR)out_ddr, C * 2*H * 2*W);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}

/* ========================================================================= */
/* arm_pool_large — Software max pooling for kernel > 2 (SPP layers).       */
/* NCHW layout. Stride = L->stride, kernel = L->kernel, pad = L->pad.      */
/* ========================================================================= */
int arm_pool_large(const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof)
{
    const int C = L->c_in, H = L->h_in, W = L->w_in;
    const int K = L->kernel, S = L->stride, P = L->pad;
    const int OH = L->h_out, OW = L->w_out;

    Xil_DCacheInvalidateRange((UINTPTR)in_ddr, C * H * W);

    for (int c = 0; c < C; c++) {
        const int8_t *src = (const int8_t *)in_ddr + (uint32_t)c * H * W;
        int8_t *dst = (int8_t *)out_ddr + (uint32_t)c * OH * OW;
        for (int oh = 0; oh < OH; oh++) {
            for (int ow = 0; ow < OW; ow++) {
                int8_t maxv = -128;
                for (int kh = 0; kh < K; kh++) {
                    int ih = oh * S - P + kh;
                    if (ih < 0 || ih >= H) continue;
                    for (int kw = 0; kw < K; kw++) {
                        int iw = ow * S - P + kw;
                        if (iw < 0 || iw >= W) continue;
                        int8_t v = src[ih * W + iw];
                        if (v > maxv) maxv = v;
                    }
                }
                dst[oh * OW + ow] = maxv;
            }
        }
    }

    Xil_DCacheFlushRange((UINTPTR)out_ddr, C * OH * OW);
    if (prof) { prof->n_tiles = 1; }
    return DPU_OK;
}
