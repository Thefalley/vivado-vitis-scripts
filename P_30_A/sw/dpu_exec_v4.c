/*
 * dpu_exec_v4.c -- Runtime para P_30_A: conv con FIFO de pesos + IC tiling ARM.
 *
 * Diferencias vs dpu_exec.c de P_18:
 *   - Pesos van por DMA_W → FIFO_W → wb_ram (cmd_load_weights, bit 3 CTRL)
 *   - Input+bias van por DMA_IN → BRAM 8KB (como antes, cmd_load, bit 0)
 *   - IC tiling controlado por ARM: flags no_clear (0x68) y no_requantize (0x6C)
 *   - Registros nuevos: REG_NO_CLEAR, REG_NO_REQUANTIZE, REG_WB_N_BYTES
 *
 * La secuencia para UNA capa CONV con IC tiling es:
 *   for each ic_tile:
 *     1. DMA_W: pesos de este ic_tile → FIFO → wb_ram (CTRL bit 3)
 *     2. DMA_IN: input de este ic_tile + bias(1st only) → BRAM (CTRL bit 0)
 *     3. REG_NO_CLEAR = (not first), REG_NO_REQUANTIZE = (not last)
 *     4. CTRL bit 1 (START) → conv ejecuta
 *     5. wait done
 *   CTRL bit 2 (DRAIN) → DataMover → DDR (solo tras ultimo ic_tile)
 */

#include "dpu_api.h"
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include <string.h>

/* Registros wrapper (mismos que P_18 + nuevos P_30_A) */
#define DPU_BASE         XPAR_DPU_STREAM_WRAPPER_0_BASEADDR
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
/* P_30_A nuevos */
#define REG_NO_CLEAR      0x68
#define REG_NO_REQUANTIZE 0x6C
#define REG_WB_N_BYTES    0x70
#define REG_SKIP_WL       0x74  /* '1' = skip weight preload from BRAM (use FIFO path) */
#define REG_DBG_CE_STATE  0x78  /* RO: conv_engine internal FSM state index */

#define LAYER_CONV 0
#define CMD_LOAD         0x01
#define CMD_START        0x02
#define CMD_DRAIN        0x04
#define CMD_LOAD_WEIGHTS 0x08

#define ALIGN_UP(x, a) (((x) + ((a)-1)) & ~((a)-1))

/* DMAs */
static XAxiDma g_dma_in;   /* DMA para input+bias → BRAM */
static XAxiDma g_dma_w;    /* DMA para pesos → FIFO_W → wb_ram */
static int g_dma_ready = 0;

static void dpu_write(uint32_t off, uint32_t v) { Xil_Out32(DPU_BASE + off, v); }
static uint32_t dpu_read(uint32_t off) { return Xil_In32(DPU_BASE + off); }

/* GPIO para DataMover S2MM */
#define GPIO_ADDR_BASE XPAR_GPIO_ADDR_BASEADDR
#define GPIO_CTRL_BASE XPAR_GPIO_CTRL_BASEADDR
static void gpio_addr_write(uint32_t v) { Xil_Out32(GPIO_ADDR_BASE, v); }
static void gpio_ctrl_write(uint32_t v) { Xil_Out32(GPIO_CTRL_BASE, v); }
static uint32_t gpio_ctrl_read_status(void) { return Xil_In32(GPIO_CTRL_BASE + 0x08); }

int dpu_v4_init(void)
{
    XAxiDma_Config *cfg;

    /* DMA_IN (existente) */
    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) return DPU_ERR_PARAMS;
    if (XAxiDma_CfgInitialize(&g_dma_in, cfg) != XST_SUCCESS) return DPU_ERR_PARAMS;
    XAxiDma_IntrDisable(&g_dma_in, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    /* DMA_W (nuevo P_30_A) */
    cfg = XAxiDma_LookupConfig(XPAR_AXI_DMA_W_DEVICE_ID);
    if (!cfg) return DPU_ERR_PARAMS;
    if (XAxiDma_CfgInitialize(&g_dma_w, cfg) != XST_SUCCESS) return DPU_ERR_PARAMS;
    XAxiDma_IntrDisable(&g_dma_w, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    g_dma_ready = 1;
    return DPU_OK;
}

static int wait_dma_idle(XAxiDma *dma, int max) {
    int t = 0;
    for (;;) {
        uint32_t sr = Xil_In32(dma->RegBase + 0x04);
        if (sr & 0x01) return DPU_OK;  /* HALTED → channel stopped, no transfer */
        if (sr & 0x02) return DPU_OK;  /* IDLE → running but no active transfer */
        if (++t > max) return DPU_ERR_TIMEOUT;
    }
}

static int wait_done_latch(int max) {
    int t = 0;
    while (!(dpu_read(REG_CTRL) & 0x100)) {
        if (++t > max) return DPU_ERR_TIMEOUT;
    }
    return DPU_OK;
}

static int wait_dm_done(int max) {
    int t = 0;
    while ((gpio_ctrl_read_status() & 0x02) == 0) {
        if (++t > max) return DPU_ERR_TIMEOUT;
    }
    return DPU_OK;
}

static void dm_configure(uint32_t dest, uint32_t bytes) {
    gpio_addr_write(dest);
    gpio_ctrl_write(bytes & 0x7FFFFF);
    gpio_ctrl_write((bytes & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(bytes & 0x7FFFFF);
}

/* Scratch buffers en DDR (mismas regiones que P_18) */
#define TILE_SCRATCH   0x14000000u
#define TILE_IN_BUF    (TILE_SCRATCH + 0x100000u)  /* +1 MB */
#define TILE_OUT_BUF   (TILE_SCRATCH + 0x200000u)  /* +2 MB */
#define W_TILE_BUF     (TILE_SCRATCH + 0x300000u)  /* +3 MB, max 32KB */

/*
 * dpu_exec_conv_v4 -- Ejecuta una capa CONV con IC tiling via ARM.
 *
 * Pesos van por DMA_W → FIFO_W → wb_ram (bypass BRAM).
 * Input+bias van por DMA_IN → BRAM 8KB.
 *
 * Para capas donde todos los pesos caben en wb_ram (32 KB):
 *   1 sola iteracion de IC tiling.
 * Para capas mas grandes:
 *   N iteraciones, ARM carga pesos parciales cada vez.
 */
int dpu_exec_conv_v4(const layer_config_t *L,
                     const uint8_t *in_ddr,
                     const int8_t  *weights_ddr,
                     const int32_t *bias_ddr,
                     uint8_t       *out_ddr,
                     dpu_prof_t    *prof)
{
    if (!g_dma_ready) return DPU_ERR_PARAMS;

    /*
     * Debug trace — cada paso critico se escribe al mailbox DDR Y se
     * imprime por UART. Desde el PC se ve con un terminal serie al COM
     * del ZedBoard (115200 8N1).
     *
     * Mailbox DDR 0x10100000 — 4 words (ultima snapshot):
     *   +0: step   +4: REG_CTRL   +8: CE_STATE   +12: extra
     *
     * Formato UART:
     *   [0x10] W=0 CE=0 x=0       (wrapper_fsm, conv_state, extra)
     *   [0xF0] ERR W=2 CE=5 x=... (state mismatch → abort)
     */
    #define DBG_ADDR 0x10100000u
    #define DBGSNAP(step, extra) do { \
        uint32_t _s = (step), _x = (extra); \
        uint32_t _ctrl = dpu_read(REG_CTRL); \
        uint32_t _ce   = dpu_read(REG_DBG_CE_STATE); \
        *(volatile uint32_t *)(DBG_ADDR +  0) = _s; \
        *(volatile uint32_t *)(DBG_ADDR +  4) = _ctrl; \
        *(volatile uint32_t *)(DBG_ADDR +  8) = _ce; \
        *(volatile uint32_t *)(DBG_ADDR + 12) = _x; \
        Xil_DCacheFlushRange(DBG_ADDR, 16); \
        if (dbg_verbose || (_s & 0xE0) == 0xE0) \
            xil_printf("[0x%02x] W=%d CE=%d x=0x%08x\r\n", \
                       _s, (_ctrl>>10)&3, _ce, _x); \
    } while(0)

    /* Throttle: solo imprime tile 0, 1 y cada 500 para no saturar UART.
     * Errores SIEMPRE se imprimen. Mailbox DDR siempre se actualiza. */
    int dbg_verbose = 1;  /* se pone a 0 despues del primer tile */

    /* Check: verify wrapper_fsm and conv_engine state match expected.
     * wrapper_fsm: bits 11:10 of REG_CTRL (0=IDLE,1=LOAD,2=CONV,3=DRAIN)
     * ce_state:    REG_DBG_CE_STATE (0=IDLE, see state_t in conv_engine_v4.vhd)
     * On mismatch: prints ERR, writes snapshot, returns DPU_ERR_PARAMS. */
    #define CE_IDLE 0
    #define WRAPPER_IDLE 0
    #define WRAPPER_LOAD 1
    #define WRAPPER_CONV 2
    #define CHK_STATE(step, exp_w, exp_ce) do { \
        uint32_t _ctrl = dpu_read(REG_CTRL); \
        uint32_t _ce   = dpu_read(REG_DBG_CE_STATE); \
        uint32_t _wfsm = (_ctrl >> 10) & 0x3; \
        if (_wfsm != (uint32_t)(exp_w) || _ce != (uint32_t)(exp_ce)) { \
            xil_printf("[0x%02x] ERR W=%d(exp %d) CE=%d(exp %d)\r\n", \
                       (step), _wfsm, (exp_w), _ce, (exp_ce)); \
            DBGSNAP(0xF0 | ((step) & 0x0F), (_wfsm << 16) | (_ce & 0xFFFF)); \
            return DPU_ERR_PARAMS; \
        } \
    } while(0)

    /* --- Entry: wrapper and conv_engine should both be IDLE --- */
    CHK_STATE(0x10, WRAPPER_IDLE, CE_IDLE);

    const int kh = L->kernel;
    const int kw = L->kernel;
    const int stride = (L->stride == 2) ? 2 : 1;
    const int b_bytes = L->c_out * 4;

    /* Calcular ic_tile_size maximo que cabe en wb_ram (32 KB) */
    int ic_tile_size = L->c_in;
    int w_per_tile = L->c_out * kh * kw * ic_tile_size;
    if (w_per_tile > 32768) {
        ic_tile_size = 32768 / (L->c_out * kh * kw);
        if (ic_tile_size < 1) ic_tile_size = 1;
    }
    w_per_tile = L->c_out * kh * kw * ic_tile_size;

    /* Spatial tiling: tile_h x tile_w output que quepa en BRAM 8KB sin pesos */
    int tile_h = 8, tile_w = 8;
    /* TODO: calcular segun BRAM 8KB room (output + input_tile + bias) */

    /* Registros constantes (no cambian entre ic_tiles) */
    const uint32_t ksize_enc = (kh == 3) ? 2 : 0;
    const uint32_t stride_enc = (stride == 2) ? 1 : 0;

    dpu_write(REG_LAYER_TYPE, LAYER_CONV);
    dpu_write(REG_C_OUT,      L->c_out);
    dpu_write(REG_KSP,        (stride_enc << 2) | ksize_enc);
    dpu_write(REG_X_ZP,       (uint32_t)(int32_t)L->x_zp & 0x1FF);
    dpu_write(REG_W_ZP,       (uint32_t)(int32_t)L->w_zp & 0xFF);
    dpu_write(REG_M0,         L->M0);
    dpu_write(REG_N_SHIFT,    L->n_shift);
    dpu_write(REG_Y_ZP,       (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_ADDR_OUTPUT, 0);  /* output siempre al inicio del BRAM */

    int total_tiles = 0;
    int rc;

    /* Loop por spatial tiles (H+W) */
    for (int oh0 = 0; oh0 < L->h_out; oh0 += tile_h) {
        int h_tile = (oh0 + tile_h <= L->h_out) ? tile_h : (L->h_out - oh0);
        for (int ow0 = 0; ow0 < L->w_out; ow0 += tile_w) {
            int w_tile = (ow0 + tile_w <= L->w_out) ? tile_w : (L->w_out - ow0);

            /* Calcular input region y pads */
            int ih_start = oh0 * stride - L->pad;
            int iw_start = ow0 * stride - L->pad;
            int in_h_needed = (h_tile - 1) * stride + kh;
            int in_w_needed = (w_tile - 1) * stride + kw;
            int pad_t = (ih_start < 0) ? -ih_start : 0;
            int pad_l = (iw_start < 0) ? -iw_start : 0;
            int ih_end = ih_start + in_h_needed;
            int iw_end = iw_start + in_w_needed;
            int pad_b = (ih_end > L->h_in) ? (ih_end - L->h_in) : 0;
            int pad_r = (iw_end > L->w_in) ? (iw_end - L->w_in) : 0;
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

            /* IC tile loop */
            for (int ic_base = 0; ic_base < L->c_in; ic_base += ic_tile_size) {
                int ic_ts = ic_tile_size;
                if (ic_base + ic_ts > L->c_in) ic_ts = L->c_in - ic_base;
                int is_first = (ic_base == 0);
                int is_last  = (ic_base + ic_ts >= L->c_in);

                int w_bytes = L->c_out * kh * kw * ic_ts;
                int in_bytes = ic_ts * in_h_real * in_w_real;

                /* ============================================ */
                /* PASO 1: Cargar pesos via DMA_W → FIFO → wb_ram */
                /* ============================================ */
                UINTPTR w_dma_src;
                if (ic_ts == L->c_in) {
                    w_dma_src = (UINTPTR)weights_ddr;
                    Xil_DCacheFlushRange(w_dma_src, w_bytes);
                } else {
                    int8_t *wt = (int8_t *)W_TILE_BUF;
                    int inner = kh * kw * L->c_in;
                    for (int oc = 0; oc < L->c_out; oc++) {
                        for (int p = 0; p < kh * kw; p++) {
                            memcpy(wt + (oc * kh * kw + p) * ic_ts,
                                   weights_ddr + oc * inner + p * L->c_in + ic_base,
                                   ic_ts);
                        }
                    }
                    w_dma_src = (UINTPTR)wt;
                    Xil_DCacheFlushRange(w_dma_src, w_bytes);
                }

                /* --- PASO 1: pesos via DMA_W → FIFO → wb_ram ---
                 * DMA max = 16380 bytes (14-bit length register).
                 * Wrapper stays in S_LOAD_WEIGHTS counting total bytes.
                 * ARM sends N chunks, FIFO buffers between DMA and wrapper. */
                #define DMA_MAX_CHUNK 16380
                DBGSNAP(0x20, w_bytes);
                dpu_write(REG_WB_N_BYTES, w_bytes);
                dpu_write(REG_CTRL, CMD_LOAD_WEIGHTS);

                {
                    int remaining = w_bytes;
                    UINTPTR src = w_dma_src;
                    while (remaining > 0) {
                        int chunk = remaining > DMA_MAX_CHUNK ? DMA_MAX_CHUNK : remaining;
                        chunk = ALIGN_UP(chunk, 4);
                        rc = wait_dma_idle(&g_dma_w, 5000000);
                        if (rc != DPU_OK) { DBGSNAP(0xE1, Xil_In32(g_dma_w.RegBase+0x04)); return rc; }
                        if (XAxiDma_SimpleTransfer(&g_dma_w, src, chunk,
                                                   XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
                            { DBGSNAP(0xE2, remaining); return DPU_ERR_PARAMS; }
                        src += chunk;
                        remaining -= chunk;
                    }
                }

                rc = wait_done_latch(20000000);
                if (rc != DPU_OK) { DBGSNAP(0xE3, 0); return rc; }

                /* Weights loaded — wrapper should be back to IDLE */
                CHK_STATE(0x23, WRAPPER_IDLE, CE_IDLE);

                /* ============================================ */
                /* PASO 2: Cargar input+bias via DMA_IN → BRAM   */
                /* ============================================ */
                uint8_t *tile_buf = (uint8_t *)TILE_SCRATCH;
                int out_bytes_tile = L->c_out * h_tile * w_tile;
                uint32_t OUT_OFF = 0;
                uint32_t IN_OFF  = ALIGN_UP(out_bytes_tile, 64);
                uint32_t B_OFF   = ALIGN_UP(IN_OFF + in_bytes, 64);
                uint32_t TOT     = ALIGN_UP(B_OFF + (is_first ? b_bytes : 0), 64);

                memset(tile_buf, 0, TOT);

                /* Extraer input NCHW para este ic_tile */
                Xil_DCacheInvalidateRange((UINTPTR)in_ddr,
                    ALIGN_UP((uint32_t)L->c_in * L->h_in * L->w_in, 64));
                for (int c = 0; c < ic_ts; c++) {
                    for (int rr = 0; rr < in_h_real; rr++) {
                        const uint8_t *src = in_ddr
                            + (uint32_t)(ic_base + c) * L->h_in * L->w_in
                            + (uint32_t)(ih_lo + rr) * L->w_in + iw_lo;
                        uint8_t *dst = tile_buf + IN_OFF
                            + (uint32_t)c * in_h_real * in_w_real
                            + rr * in_w_real;
                        memcpy(dst, src, in_w_real);
                    }
                }

                /* Bias (solo en el primer ic_tile) */
                if (is_first) {
                    Xil_DCacheInvalidateRange((UINTPTR)bias_ddr, ALIGN_UP(b_bytes, 64));
                    memcpy(tile_buf + B_OFF, bias_ddr, b_bytes);
                }

                Xil_DCacheFlushRange((UINTPTR)tile_buf, TOT);

                /* Programar registros para este tile */
                dpu_write(REG_C_IN,         ic_ts);
                dpu_write(REG_H_IN,         in_h_real);
                dpu_write(REG_W_IN,         in_w_real);
                dpu_write(REG_IC_TILE_SIZE, ic_ts);
                dpu_write(REG_N_WORDS,      TOT / 4);
                dpu_write(REG_ADDR_INPUT,   IN_OFF);
                dpu_write(REG_ADDR_WEIGHTS, 0);
                dpu_write(REG_SKIP_WL,      1);  /* weights via FIFO, skip BRAM preload */
                dpu_write(REG_ADDR_BIAS,    B_OFF);
                dpu_write(REG_PAD_TOP,      pad_t);
                dpu_write(REG_PAD_BOTTOM,   pad_b);
                dpu_write(REG_PAD_LEFT,     pad_l);
                dpu_write(REG_PAD_RIGHT,    pad_r);
                dpu_write(REG_NO_CLEAR,     is_first ? 0 : 1);
                dpu_write(REG_NO_REQUANTIZE, is_last ? 0 : 1);

                /* --- PASO 2: input+bias via DMA_IN → BRAM --- */
                DBGSNAP(0x30, TOT);
                dpu_write(REG_CTRL, CMD_LOAD);
                rc = wait_dma_idle(&g_dma_in, 5000000);
                if (rc != DPU_OK) { DBGSNAP(0xE4, Xil_In32(g_dma_in.RegBase+0x04)); return rc; }
                if (XAxiDma_SimpleTransfer(&g_dma_in, (UINTPTR)tile_buf,
                                           TOT, XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
                    { DBGSNAP(0xE4, 1); return DPU_ERR_PARAMS; }
                rc = wait_dma_idle(&g_dma_in, 10000000);
                if (rc != DPU_OK) { DBGSNAP(0xE4, 2); return rc; }
                /* Wait wrapper idle after LOAD */
                int tm = 0;
                while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 0) {
                    if (++tm > 1000000) { DBGSNAP(0xE5, 0); return DPU_ERR_TIMEOUT; }
                }
                /* Input loaded — wrapper and conv should be IDLE */
                CHK_STATE(0x35, WRAPPER_IDLE, CE_IDLE);

                /* --- PASO 3: START conv --- */
                DBGSNAP(0x40, total_tiles);
                dpu_write(REG_CTRL, CMD_START);
                rc = wait_done_latch(20000000);
                if (rc != DPU_OK) { DBGSNAP(0xE6, 0); return rc; }
                /* Conv done — back to IDLE */
                CHK_STATE(0x45, WRAPPER_IDLE, CE_IDLE);

                /* --- PASO 4: DRAIN output (solo ultimo ic_tile) --- */
                if (is_last) {
                    uint8_t *out_tile = (uint8_t *)TILE_OUT_BUF;
                    DBGSNAP(0x50, out_bytes_tile);
                    dm_configure((uintptr_t)out_tile, out_bytes_tile);
                    dpu_write(REG_N_WORDS, (out_bytes_tile + 3) / 4);
                    dpu_write(REG_CTRL, CMD_DRAIN);
                    rc = wait_dm_done(20000000);
                    if (rc != DPU_OK) { DBGSNAP(0xE7, 0); return DPU_ERR_DM_FAULT; }

                    /* Copiar tile output al tensor global NCHW */
                    Xil_DCacheInvalidateRange((UINTPTR)out_tile, out_bytes_tile);
                    for (int c = 0; c < L->c_out; c++) {
                        for (int rr = 0; rr < h_tile; rr++) {
                            memcpy(out_ddr + (uint32_t)c * L->h_out * L->w_out
                                           + (uint32_t)(oh0 + rr) * L->w_out + ow0,
                                   out_tile + (uint32_t)c * h_tile * w_tile
                                            + rr * w_tile,
                                   w_tile);
                        }
                    }
                }

                total_tiles++;
                /* After first tile OK, reduce UART output to errors only */
                if (total_tiles == 1)
                    xil_printf("[OK] tile 0 done, quiet mode (errors still print)\r\n");
                if (total_tiles <= 2 || (total_tiles % 500) == 0)
                    dbg_verbose = 1;
                else
                    dbg_verbose = 0;
            } /* ic_tile loop */
        } /* ow0 */
    } /* oh0 */

    Xil_DCacheFlushRange((UINTPTR)out_ddr,
                         (uint32_t)L->c_out * L->h_out * L->w_out);
    if (prof) prof->n_tiles = total_tiles;
    xil_printf("[DONE] tiles=%d\r\n", total_tiles);
    return DPU_OK;
}
