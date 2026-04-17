/*
 * dpu_api.h -- Public API for the P_17 DPU runtime
 *
 * Layer kernels that run on the FPGA wrapper (CONV / LEAKY / POOL / ADD)
 * are exposed through dpu_exec_*().  They take pre-resolved DDR pointers
 * for input(s), weights, bias and output and a layer_config_t.
 *
 * Concat and Upsample do not touch the DPU and are implemented entirely
 * on the ARM via arm_concat() / arm_upsample().
 *
 * All buffers are uint8_t (signed-int8 reinterpret-cast).  Memory layout
 * for activations is NHWC == channels-last (matches the conv_engine OHWI
 * weights ordering used in P_16 / P_17 wrappers).
 */
#ifndef DPU_API_H
#define DPU_API_H

#include <stdint.h>
#include "layer_configs.h"   /* shared with vitis-ai/workspace/c_dpu */

/* Status codes */
#define DPU_OK            0
#define DPU_ERR_TIMEOUT  -1
#define DPU_ERR_DM_FAULT -2
#define DPU_ERR_TILING   -3
#define DPU_ERR_PARAMS   -4

/* Wrapper BRAM is 4 KB.  After bias / weights / etc. an activation tile
 * has at most ~512 B free for input and ~512 B free for output (CONV).
 * For pure stream layers (LEAKY / POOL / ADD) the input + output share
 * the BRAM so the cap is ~1.5 KB per side.  These thresholds drive the
 * automatic ARM-side tiling in dpu_exec_*().
 */
#define DPU_BRAM_BYTES        4096
#define DPU_TILE_INPUT_MAX     512   /* CONV worst-case (3x3, IC large) */
#define DPU_TILE_STREAM_MAX   1536   /* LEAKY/POOL/ADD                  */

/* Per-layer profiling record, filled by dpu_exec_*() */
typedef struct {
    uint32_t cycles_load;     /* MM2S DMA into BRAM        */
    uint32_t cycles_compute;  /* DPU compute (poll DONE)   */
    uint32_t cycles_drain;    /* DataMover S2MM out        */
    uint32_t cycles_total;    /* end-to-end incl. ARM glue */
    uint16_t n_tiles;         /* >1 if ARM tiled the layer */
} dpu_prof_t;

/* ----------------------- Wrapper / DMA bring-up ----------------------- */
int  dpu_init(void);            /* one-shot: DMA, GPIO, scratch buffers   */
void dpu_reset(void);           /* assert reset, return wrapper to IDLE   */

/* ----------------------- DPU-resident kernels ------------------------- */
/* CONV: y = requantize(W * x + b).  Weights/bias are layer-baked and live
 * in DDR at `weights_ddr` / `bias_ddr` (preloaded by XSCT before boot).  */
int dpu_exec_conv (const layer_config_t *L,
                   const uint8_t *in_ddr,
                   const int8_t  *weights_ddr,
                   const int32_t *bias_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* Como dpu_exec_conv pero con tiling H+W automatico en ARM si la layer
 * no cabe en el BRAM del wrapper (4 KB). Delega en dpu_exec_conv si cabe. */
int dpu_exec_conv_tiled(const layer_config_t *L,
                        const uint8_t *in_ddr,
                        const int8_t  *weights_ddr,
                        const int32_t *bias_ddr,
                        uint8_t       *out_ddr,
                        dpu_prof_t    *prof);

/* LEAKY: y = leaky_relu(x).  Single input, no weights. */
int dpu_exec_leaky(const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* POOL: 2x2 maxpool, stride from layer cfg. */
int dpu_exec_pool (const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* ADD: element-wise add of two equally-shaped tensors. */
int dpu_exec_add  (const layer_config_t *L,
                   const uint8_t *in_a_ddr,
                   const uint8_t *in_b_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* ----------------------- ARM-side primitives -------------------------- */
/* Concat along channel axis: [A | B] -> out, NHWC layout. */
int arm_concat   (const layer_config_t *L,
                  const uint8_t *in_a_ddr, uint16_t c_a,
                  const uint8_t *in_b_ddr, uint16_t c_b,
                  uint8_t       *out_ddr,
                  dpu_prof_t    *prof);

/* Nearest-neighbour 2x upsample (h_out=2*h_in, w_out=2*w_in, c unchanged). */
int arm_upsample (const layer_config_t *L,
                  const uint8_t *in_ddr,
                  uint8_t       *out_ddr,
                  dpu_prof_t    *prof);

/* ----------------------- Memory pool API ------------------------------ */
/* Bump-and-recycle allocator backed by a single 256 MB DDR region.     */
typedef struct mem_pool mem_pool_t;
mem_pool_t *pool_create (uintptr_t base, uint32_t bytes);
uint8_t    *pool_alloc  (mem_pool_t *p, uint32_t bytes, uint16_t producer_layer);
void        pool_release(mem_pool_t *p, uint16_t producer_layer);
uint32_t    pool_bytes_used(mem_pool_t *p);

#endif /* DPU_API_H */
