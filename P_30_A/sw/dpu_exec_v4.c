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
        if (sr & 0x01) return DPU_OK;  /* HALTED */
        if (sr & 0x02) return DPU_OK;  /* IDLE (transfer done, channel running) */
        if (++t > max) return DPU_ERR_TIMEOUT;
    }
}

/* Direct DMA transfer — bypasses Xilinx SimpleTransfer which has a broken
 * busy check (rejects RUNNING+IDLE channels). Writes MM2S registers directly:
 * 1. Set RUNSTOP if not set  2. Write source addr  3. Write length (triggers) */
static int dma_send(XAxiDma *dma, UINTPTR addr, uint32_t len) {
    uint32_t base = dma->RegBase;
    uint32_t cr = Xil_In32(base + 0x00);
    if (!(cr & 1)) Xil_Out32(base + 0x00, cr | 1);  /* set RUNSTOP */
    Xil_Out32(base + 0x18, (uint32_t)addr);           /* MM2S source addr */
    Xil_Out32(base + 0x28, len);                       /* MM2S length → triggers */
    return DPU_OK;
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
        if (_s >= 0xE0) \
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

    /* Invalidate input+bias DDR once (not per-tile!) so ARM reads fresh data */
    Xil_DCacheInvalidateRange((UINTPTR)in_ddr,
        ALIGN_UP((uint32_t)L->c_in * L->h_in * L->w_in, 64));
    Xil_DCacheInvalidateRange((UINTPTR)bias_ddr, ALIGN_UP(L->c_out * 4, 64));

    const int kh = L->kernel;
    const int kw = L->kernel;
    const int stride = (L->stride == 2) ? 2 : 1;
    const int b_bytes = L->c_out * 4;

    /*
     * IC tiling strategy:
     *
     * The conv_engine has N_MAC=32 accumulators (one per output channel).
     * When c_out > 32, it processes output channels in OC tiles of 32.
     * Each OC tile OVERWRITES the accumulators from the previous one.
     *
     * ARM IC tiling (splitting c_in across CMD_STARTs) requires that
     * the accumulators survive between IC tiles. This only works if
     * there is exactly 1 OC tile per CMD_START (c_out_per_start ≤ 32).
     *
     * For layers needing IC tiling (total weights > 32KB wb_ram):
     *   - ARM splits BOTH c_out (into groups of 32) AND c_in (into IC tiles)
     *   - Each CMD_START: c_out_group ≤ 32, ic_ts channels
     *   - Weights per start: 32 * kk * ic_ts — always fits in wb_ram
     *   - Accumulators are preserved between IC tiles (same 32 channels)
     *   - DRAIN after all IC tiles of one OC group complete
     *
     * For layers NOT needing IC tiling (weights ≤ 32KB):
     *   - Load all weights to wb_ram via FIFO
     *   - Conv_engine handles OC tiling internally (no ARM split)
     *   - One CMD_START per spatial tile
     */
    #define N_MAC 32

    /* ic_tile_size: max input channels per IC tile.
     * Constrained so that ONE OC GROUP's weights fit in wb_ram:
     *   N_MAC * kk * ic_tile_size ≤ 32768 */
    int ic_tile_size = L->c_in;
    if (N_MAC * kh * kw * ic_tile_size > 32768) {
        ic_tile_size = 32768 / (N_MAC * kh * kw);
        if (ic_tile_size < 1) ic_tile_size = 1;
    }

    /* Force ARM OC grouping if:
     * - weights > 32KB (need IC tiling), OR
     * - c_out not multiple of N_MAC (conv_engine internal OC tiling
     *   always processes N_MAC=32 channels, would overflow for last tile) */
    int needs_ic_tiling = (L->c_out * kh * kw * L->c_in > 32768)
                       || (L->c_out % N_MAC != 0);

    /* Spatial tiling.
     *
     * With the PAUSE_FOR_WEIGHTS RTL mechanism, the conv_engine handles
     * IC tiling internally per-pixel. When it needs new weights for the
     * next IC tile, it pauses (need_weights=1) and the ARM reloads wb_ram
     * via FIFO. This allows tiles > 1x1 even with IC tiling.
     *
     * For IC-tiled layers: BRAM must hold FULL c_in channels of input
     * (not just ic_tile_size) so the conv_engine can read any IC tile's
     * channels without reloading BRAM. */
    int real_ic_tiling = (ic_tile_size < L->c_in);
    int c_out_bram = needs_ic_tiling ? N_MAC : L->c_out;
    int c_in_bram  = real_ic_tiling ? L->c_in : ic_tile_size;
    int tile_h, tile_w;
    for (tile_h = 16; tile_h >= 1; tile_h--) {
        tile_w = tile_h;
        int in_h = (tile_h - 1) * stride + kh;
        int in_w = (tile_w - 1) * stride + kw;
        int tot = ALIGN_UP(c_out_bram * tile_h * tile_w, 64)
                + ALIGN_UP(c_in_bram * in_h * in_w, 64)
                + ALIGN_UP(c_out_bram * 4, 64);
        if (tot <= DPU_BRAM_BYTES) break;
    }
    if (tile_h < 1) tile_h = tile_w = 1;

    xil_printf("tile=%dx%d ic_ts=%d oc_groups=%d%s\r\n",
               tile_h, tile_w, ic_tile_size,
               needs_ic_tiling ? (L->c_out + N_MAC - 1) / N_MAC : 1,
               needs_ic_tiling ? " [ARM IC+OC]" : "");

    /* Registros constantes */
    const uint32_t ksize_enc = (kh == 3) ? 2 : 0;
    const uint32_t stride_enc = (stride == 2) ? 1 : 0;
    #define DMA_MAX_CHUNK 16380

    dpu_write(REG_LAYER_TYPE, LAYER_CONV);
    dpu_write(REG_KSP,        (stride_enc << 2) | ksize_enc);
    dpu_write(REG_X_ZP,       (uint32_t)(int32_t)L->x_zp & 0x1FF);
    dpu_write(REG_W_ZP,       (uint32_t)(int32_t)L->w_zp & 0xFF);
    dpu_write(REG_M0,         L->M0);
    dpu_write(REG_N_SHIFT,    L->n_shift);
    dpu_write(REG_Y_ZP,       (uint32_t)(int32_t)L->y_zp & 0xFF);
    dpu_write(REG_ADDR_OUTPUT, 0);

    int total_tiles = 0;
    int rc;

    /* Number of OC groups: 1 for non-IC-tiled, ceil(c_out/32) for IC-tiled */
    int n_oc_groups = needs_ic_tiling ? (L->c_out + N_MAC - 1) / N_MAC : 1;

    /* ================================================================
     * MAIN LOOP: spatial tiles → OC groups → IC tiles
     *
     * Spatial: divides the output H×W into tile_h × tile_w regions
     * OC group: divides output channels into groups of N_MAC=32
     *           (only when IC tiling needed; otherwise conv_engine handles)
     * IC tile: divides input channels into ic_tile_size chunks
     *          (only when total weights > 32KB)
     * ================================================================ */
    for (int oh0 = 0; oh0 < L->h_out; oh0 += tile_h) {
        int h_tile = (oh0 + tile_h <= L->h_out) ? tile_h : (L->h_out - oh0);
        for (int ow0 = 0; ow0 < L->w_out; ow0 += tile_w) {
            int w_tile = (ow0 + tile_w <= L->w_out) ? tile_w : (L->w_out - ow0);

            /* Compute input region and padding for this spatial tile */
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

            /* --- OC group loop --- */
            for (int oc_grp = 0; oc_grp < n_oc_groups; oc_grp++) {
                int oc_base = oc_grp * N_MAC;
                int oc_count = (oc_base + N_MAC <= L->c_out) ? N_MAC : (L->c_out - oc_base);

                int oc_w = needs_ic_tiling ? oc_count : L->c_out;
                int ic_ts0 = ic_tile_size;
                if (ic_ts0 > L->c_in) ic_ts0 = L->c_in;
                int w_bytes_0 = oc_w * kh * kw * ic_ts0;
                int in_bytes_full = L->c_in * in_h_real * in_w_real;
                int bias_bytes = oc_w * 4;

                /* === STEP 1: Load IC tile 0 weights via FIFO → wb_ram === */
                {
                    int8_t *wt;
                    UINTPTR w_dma_src;
                    if (!needs_ic_tiling && ic_ts0 == L->c_in) {
                        w_dma_src = (UINTPTR)weights_ddr;
                    } else {
                        wt = (int8_t *)W_TILE_BUF;
                        int full_ic_stride = kh * kw * L->c_in;
                        for (int oc = 0; oc < oc_w; oc++) {
                            for (int p = 0; p < kh * kw; p++) {
                                memcpy(wt + (oc * kh * kw + p) * ic_ts0,
                                       weights_ddr + (oc_base + oc) * full_ic_stride
                                                   + p * L->c_in,
                                       ic_ts0);
                            }
                        }
                        w_dma_src = (UINTPTR)wt;
                    }
                    Xil_DCacheFlushRange(w_dma_src, ALIGN_UP(w_bytes_0, 64));
                    dpu_write(REG_WB_N_BYTES, w_bytes_0);
                    dpu_write(REG_CTRL, CMD_LOAD_WEIGHTS);
                    int rem = w_bytes_0; UINTPTR src = w_dma_src;
                    while (rem > 0) {
                        int chunk = rem > DMA_MAX_CHUNK ? DMA_MAX_CHUNK : rem;
                        chunk = ALIGN_UP(chunk, 4);
                        rc = wait_dma_idle(&g_dma_w, 5000000);
                        if (rc != DPU_OK) { DBGSNAP(0xE1, 0); return rc; }
                        dma_send(&g_dma_w, src, chunk);
                        src += chunk; rem -= chunk;
                    }
                    rc = wait_done_latch(20000000);
                    if (rc != DPU_OK) { DBGSNAP(0xE3, 0); return rc; }
                }

                /* === STEP 2: Load FULL input (all c_in channels) + bias → BRAM === */
                {
                    uint8_t *tile_buf = (uint8_t *)TILE_SCRATCH;
                    int out_bytes_tile = oc_w * h_tile * w_tile;
                    uint32_t IN_OFF = ALIGN_UP(out_bytes_tile, 64);
                    uint32_t B_OFF  = ALIGN_UP(IN_OFF + in_bytes_full, 64);
                    uint32_t TOT    = ALIGN_UP(B_OFF + bias_bytes, 64);

                    memset(tile_buf, 0, TOT);
                    /* Load ALL c_in channels (conv_engine reads any IC tile from BRAM) */
                    for (int c = 0; c < L->c_in; c++) {
                        for (int rr = 0; rr < in_h_real; rr++) {
                            memcpy(tile_buf + IN_OFF + c * in_h_real * in_w_real + rr * in_w_real,
                                   in_ddr + (uint32_t)c * L->h_in * L->w_in
                                          + (uint32_t)(ih_lo + rr) * L->w_in + iw_lo,
                                   in_w_real);
                        }
                    }
                    memcpy(tile_buf + B_OFF, bias_ddr + oc_base, bias_bytes);
                    Xil_DCacheFlushRange((UINTPTR)tile_buf, TOT);

                    /* Set conv registers — FULL c_in, conv handles IC tiling internally */
                    dpu_write(REG_C_OUT,         oc_w);
                    dpu_write(REG_C_IN,          L->c_in);
                    dpu_write(REG_H_IN,          in_h_real);
                    dpu_write(REG_W_IN,          in_w_real);
                    dpu_write(REG_IC_TILE_SIZE,  ic_tile_size);
                    dpu_write(REG_N_WORDS,       TOT / 4);
                    dpu_write(REG_ADDR_INPUT,    IN_OFF);
                    dpu_write(REG_ADDR_WEIGHTS,  0);
                    dpu_write(REG_SKIP_WL,       1);
                    dpu_write(REG_ADDR_BIAS,     B_OFF);
                    dpu_write(REG_PAD_TOP,       pad_t);
                    dpu_write(REG_PAD_BOTTOM,    pad_b);
                    dpu_write(REG_PAD_LEFT,      pad_l);
                    dpu_write(REG_PAD_RIGHT,     pad_r);
                    dpu_write(REG_NO_CLEAR,      0);
                    dpu_write(REG_NO_REQUANTIZE, 0);

                    dpu_write(REG_CTRL, CMD_LOAD);
                    Xil_Out32(g_dma_in.RegBase + 0x04,
                              Xil_In32(g_dma_in.RegBase + 0x04) | 0x7000);
                    rc = wait_dma_idle(&g_dma_in, 5000000);
                    if (rc != DPU_OK) { DBGSNAP(0xE4, 0); return rc; }
                    dma_send(&g_dma_in, (UINTPTR)tile_buf, TOT);
                    rc = wait_dma_idle(&g_dma_in, 10000000);
                    if (rc != DPU_OK) { DBGSNAP(0xE4, 1); return rc; }
                    int tm = 0;
                    while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 0) {
                        if (++tm > 1000000) { DBGSNAP(0xE5, 0); return DPU_ERR_TIMEOUT; }
                    }
                }

                /* === STEP 3: START conv + feed weights on demand === */
                dpu_write(REG_CTRL, CMD_START);

                if (real_ic_tiling) {
                    /* Conv_engine processes IC tiles internally per-pixel.
                     * Between IC tiles, it pauses (need_weights=1) and we
                     * reload wb_ram with the next IC tile's weights. */
                    int ic_idx = 1;  /* IC tile 0 already loaded */
                    int n_ic_tiles = (L->c_in + ic_tile_size - 1) / ic_tile_size;

                    for (;;) {
                        uint32_t ctrl = dpu_read(REG_CTRL);
                        if (ctrl & 0x100) break;     /* done_latch → finished */
                        if (ctrl & 0x1000) {          /* need_weights → reload */
                            if (ic_idx >= n_ic_tiles) {
                                /* Shouldn't happen — conv asks for more tiles than exist */
                                DBGSNAP(0xE8, ic_idx);
                                return DPU_ERR_PARAMS;
                            }
                            int ic_base = ic_idx * ic_tile_size;
                            int ic_ts = ic_tile_size;
                            if (ic_base + ic_ts > L->c_in) ic_ts = L->c_in - ic_base;
                            int w_bytes = oc_w * kh * kw * ic_ts;

                            /* Extract and load next IC tile's weights */
                            int8_t *wt = (int8_t *)W_TILE_BUF;
                            int full_ic_stride = kh * kw * L->c_in;
                            for (int oc = 0; oc < oc_w; oc++) {
                                for (int p = 0; p < kh * kw; p++) {
                                    memcpy(wt + (oc * kh * kw + p) * ic_ts,
                                           weights_ddr + (oc_base + oc) * full_ic_stride
                                                       + p * L->c_in + ic_base,
                                           ic_ts);
                                }
                            }
                            Xil_DCacheFlushRange((UINTPTR)wt, ALIGN_UP(w_bytes, 64));

                            dpu_write(REG_WB_N_BYTES, w_bytes);
                            dpu_write(REG_CTRL, CMD_LOAD_WEIGHTS);
                            int rem = w_bytes; UINTPTR src = (UINTPTR)wt;
                            while (rem > 0) {
                                int chunk = rem > DMA_MAX_CHUNK ? DMA_MAX_CHUNK : rem;
                                chunk = ALIGN_UP(chunk, 4);
                                rc = wait_dma_idle(&g_dma_w, 5000000);
                                if (rc != DPU_OK) { DBGSNAP(0xE1, ic_idx); return rc; }
                                dma_send(&g_dma_w, src, chunk);
                                src += chunk; rem -= chunk;
                            }
                            rc = wait_done_latch(20000000);
                            if (rc != DPU_OK) { DBGSNAP(0xE3, ic_idx); return rc; }

                            ic_idx++;
                        }
                    }
                } else {
                    /* No IC tiling — just wait for done */
                    rc = wait_done_latch(20000000);
                    if (rc != DPU_OK) { DBGSNAP(0xE6, 0); return rc; }
                }

                /* === STEP 4: DRAIN output for this OC group === */
                int out_bytes_grp = oc_count * h_tile * w_tile;
                /* DataMover requires 4-byte aligned transfers.
                 * Pad to multiple of 4; extra bytes are harmless (discarded). */
                int drain_bytes = ALIGN_UP(out_bytes_grp, 4);
                uint8_t *out_tile = (uint8_t *)TILE_OUT_BUF;
                dm_configure((uintptr_t)out_tile, drain_bytes);
                dpu_write(REG_N_WORDS, drain_bytes / 4);
                dpu_write(REG_CTRL, CMD_DRAIN);
                rc = wait_dm_done(20000000);
                if (rc != DPU_OK) { DBGSNAP(0xE7, 0); return DPU_ERR_DM_FAULT; }

                /* Copy OC group output to correct position in global NCHW tensor */
                Xil_DCacheInvalidateRange((UINTPTR)out_tile, out_bytes_grp);
                for (int c = 0; c < oc_count; c++) {
                    for (int rr = 0; rr < h_tile; rr++) {
                        memcpy(out_ddr + (uint32_t)(oc_base + c) * L->h_out * L->w_out
                                       + (uint32_t)(oh0 + rr) * L->w_out + ow0,
                               out_tile + (uint32_t)c * h_tile * w_tile + rr * w_tile,
                               w_tile);
                    }
                }

            } /* oc_group loop */

            total_tiles++;
            if (total_tiles <= 2 || (total_tiles % 500) == 0) dbg_verbose = 1;
            else dbg_verbose = 0;
        } /* ow0 */
    } /* oh0 */

    Xil_DCacheFlushRange((UINTPTR)out_ddr,
                         (uint32_t)L->c_out * L->h_out * L->w_out);
    if (prof) prof->n_tiles = total_tiles;
    xil_printf("[DONE] tiles=%d\r\n", total_tiles);
    return DPU_OK;
}
