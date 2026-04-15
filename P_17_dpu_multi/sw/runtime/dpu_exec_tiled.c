/*
 * dpu_exec_tiled.c -- Tiling ARM para capas CONV que no caben en 4 KB BRAM.
 *
 * Estrategia H+W strip mining:
 *   Output se parte en tiles de H_TILE × W_TILE (calculados para que
 *   pesos+bias+strip_input+strip_output caban en BRAM_DEPTH_BYTES).
 *   Cada tile se ejecuta con dpu_exec_conv_single (un shot en BRAM),
 *   con padding ajustado: interior pad=0, bordes pad real.
 *
 * Para 3x3 kernel stride=1: input_strip = (h_tile + 2) × (w_tile + 2)
 *   con halo de 1 pixel alrededor.
 * Para stride=2: input_strip = (2*h_tile + 1) × (2*w_tile + 1).
 *
 * Input y output viven en DDR en layout NHWC.
 * Weights + bias se asumen ya en DDR, apuntados por weights_ddr / bias_ddr.
 */

#include "dpu_api.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include <string.h>

#define BRAM_DEPTH_BYTES  4096
#define BRAM_ALIGN(x)     (((x) + 63) & ~63U)

/* Scratch buffer en DDR para staging del tile (layout BRAM de cada tile
 * antes del DMA: output zone | input strip | weights | bias). Reusamos
 * DPU_SRC_ADDR definido en dpu_exec.c. */
extern int dpu_exec_conv(const layer_config_t *L,
                         const uint8_t *in_ddr,
                         const int8_t  *weights_ddr,
                         const int32_t *bias_ddr,
                         uint8_t       *out_ddr,
                         dpu_prof_t    *prof);

/* Calcula el tile size maximo H,W que cabe en BRAM para la capa dada.
 * Returns 0 si no hay tile factible (caso extremo c_in enorme). */
static int compute_tile_size(const layer_config_t *L,
                             int *h_tile_out, int *w_tile_out)
{
    const int kh = L->kernel;
    const int kw = L->kernel;
    const int stride = (L->stride == 2) ? 2 : 1;
    const int b_bytes = L->c_out * 4;
    const int w_bytes = L->c_out * kh * kw * L->c_in;

    /* Si pesos+bias ya no caben, no podemos tile aqui (hace falta IC tile
     * que no implementamos aun; retornamos 0 para que el caller falle). */
    if (BRAM_ALIGN(w_bytes) + BRAM_ALIGN(b_bytes) >= BRAM_DEPTH_BYTES) {
        xil_printf("[tile] weights alone (%d) + bias (%d) exceed BRAM\r\n",
                   w_bytes, b_bytes);
        return 0;
    }

    /* Queda esta cantidad para input strip + output strip */
    int room = BRAM_DEPTH_BYTES
               - BRAM_ALIGN(w_bytes)
               - BRAM_ALIGN(b_bytes)
               - 128;  /* margen */

    /* Probar tiles cuadrados h_tile == w_tile */
    int best_h = 0;
    for (int t = 32; t >= 1; t--) {
        int in_h = (stride == 2) ? (2 * t + kh - 1) : (t + kh - 1);
        int in_w = in_h;  /* cuadrado */
        int in_bytes  = in_h * in_w * L->c_in;
        int out_bytes = t * t * L->c_out;
        int total = BRAM_ALIGN(in_bytes) + BRAM_ALIGN(out_bytes);
        if (total <= room) {
            best_h = t;
            break;
        }
    }

    if (best_h <= 0) {
        xil_printf("[tile] no H/W tile fits (c_in=%d c_out=%d)\r\n",
                   L->c_in, L->c_out);
        return 0;
    }

    *h_tile_out = best_h;
    *w_tile_out = best_h;
    return 1;
}

/* ========================================================================= */
/* Ejecuta una capa conv con strip mining H y W.                              */
/* ========================================================================= */
int dpu_exec_conv_tiled(const layer_config_t *L,
                        const uint8_t *in_ddr,
                        const int8_t  *weights_ddr,
                        const int32_t *bias_ddr,
                        uint8_t       *out_ddr,
                        dpu_prof_t    *prof)
{
    /* Fast path: si la capa cabe de una, usar dpu_exec_conv directamente */
    int r = dpu_exec_conv(L, in_ddr, weights_ddr, bias_ddr, out_ddr, prof);
    if (r == DPU_OK) return DPU_OK;
    if (r != DPU_ERR_TILING) return r;

    /* Need tiling */
    int H_TILE, W_TILE;
    if (!compute_tile_size(L, &H_TILE, &W_TILE)) {
        return DPU_ERR_TILING;
    }
    xil_printf("[tile] L=%d c_in=%d c_out=%d %dx%d tile -> out %dx%d\r\n",
               L->layer_id, L->c_in, L->c_out,
               H_TILE, W_TILE, L->h_out, L->w_out);

    const int kh = L->kernel;
    const int kw = L->kernel;
    const int stride = (L->stride == 2) ? 2 : 1;
    const int pad = L->pad;
    int total_tiles = 0;

    /* Recorre output en tiles */
    for (int oh0 = 0; oh0 < L->h_out; oh0 += H_TILE) {
        int h_tile = (oh0 + H_TILE <= L->h_out) ? H_TILE : (L->h_out - oh0);

        for (int ow0 = 0; ow0 < L->w_out; ow0 += W_TILE) {
            int w_tile = (ow0 + W_TILE <= L->w_out) ? W_TILE : (L->w_out - ow0);

            /* Determinar region de input correspondiente */
            int ih_start = oh0 * stride - pad;
            int iw_start = ow0 * stride - pad;
            int in_h_needed = (h_tile - 1) * stride + kh;
            int in_w_needed = (w_tile - 1) * stride + kw;

            /* Padding por-tile (bordes reales, interiores 0) */
            int pad_top    = (ih_start < 0) ? pad : 0;
            int pad_left   = (iw_start < 0) ? pad : 0;
            int ih_end     = ih_start + in_h_needed;
            int iw_end     = iw_start + in_w_needed;
            int pad_bottom = (ih_end > L->h_in) ? (ih_end - L->h_in) : 0;
            int pad_right  = (iw_end > L->w_in) ? (iw_end - L->w_in) : 0;

            /* Clamp al interior real */
            int ih_lo = ih_start < 0 ? 0 : ih_start;
            int iw_lo = iw_start < 0 ? 0 : iw_start;
            int ih_hi = ih_end > L->h_in ? L->h_in : ih_end;
            int iw_hi = iw_end > L->w_in ? L->w_in : iw_end;
            int in_h_real = ih_hi - ih_lo;
            int in_w_real = iw_hi - iw_lo;

            /* Copiar sub-tile del input tensor a buffer contiguo NHWC */
            /* Usamos DDR scratch en 0x13000000 (fuera de weights blob) */
            uint8_t *tile_in_buf = (uint8_t *)0x13000000u;
            for (int r = 0; r < in_h_real; r++) {
                const uint8_t *src = in_ddr + ((ih_lo + r) * L->w_in + iw_lo) * L->c_in;
                uint8_t *dst = tile_in_buf + r * in_w_real * L->c_in;
                memcpy(dst, src, in_w_real * L->c_in);
            }
            Xil_DCacheFlushRange((UINTPTR)tile_in_buf,
                                 in_h_real * in_w_real * L->c_in);

            /* Construir sub-layer_config con h_in/w_in/h_out/w_out del tile */
            layer_config_t Lt = *L;
            Lt.h_in  = in_h_real;
            Lt.w_in  = in_w_real;
            Lt.h_out = h_tile;
            Lt.w_out = w_tile;
            /* pad campo principal ya no se usa con pad_top/bot/left/right
             * explícitos — dpu_exec_conv pasa L->pad a los 4 registros por
             * igual. Para evitar confusion, parcheamos pad asimetrico a mano
             * mediante puntero escritura previa a regs. TODO: refactor
             * dpu_exec_conv para exponer los 4 pads explicitos.
             * Simplification aqui: solo manejamos pad simetrico (pad_top ==
             * pad_bottom == pad_left == pad_right == L->pad). Tiles
             * interiores con pad=0 forzamos Lt.pad=0.
             */
            if (pad_top == 0 && pad_bottom == 0 && pad_left == 0 && pad_right == 0)
                Lt.pad = 0;
            else if (pad_top == pad && pad_bottom == pad
                     && pad_left == pad && pad_right == pad)
                Lt.pad = pad;
            else {
                /* Caso asimetrico en bordes: por ahora, simplemente paramos */
                xil_printf("[tile] asym pad tile (t=%d b=%d l=%d r=%d) NOT IMPL\r\n",
                           pad_top, pad_bottom, pad_left, pad_right);
                return DPU_ERR_TILING;
            }

            /* Output scratch en 0x13100000 */
            uint8_t *tile_out_buf = (uint8_t *)0x13100000u;

            dpu_prof_t tp;
            int st = dpu_exec_conv(&Lt, tile_in_buf, weights_ddr, bias_ddr,
                                   tile_out_buf, &tp);
            if (st != DPU_OK) {
                xil_printf("[tile] sub-conv fail st=%d @ (%d,%d)\r\n",
                           st, oh0, ow0);
                return st;
            }

            /* Copiar tile_out_buf (h_tile × w_tile × c_out NHWC) al output
             * tensor grande en posicion (oh0, ow0) */
            for (int r = 0; r < h_tile; r++) {
                const uint8_t *src = tile_out_buf + r * w_tile * L->c_out;
                uint8_t *dst = out_ddr
                             + ((oh0 + r) * L->w_out + ow0) * L->c_out;
                memcpy(dst, src, w_tile * L->c_out);
            }
            total_tiles++;
        }
    }

    Xil_DCacheFlushRange((UINTPTR)out_ddr,
                         L->h_out * L->w_out * L->c_out);
    xil_printf("[tile] L=%d done, %d tiles\r\n", L->layer_id, total_tiles);

    if (prof) prof->n_tiles = total_tiles;
    return DPU_OK;
}
