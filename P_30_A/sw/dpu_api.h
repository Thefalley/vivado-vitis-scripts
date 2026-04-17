/*
 * dpu_api.h -- Public API for the P_30_A DPU runtime
 *
 * Based on P_18 dpu_api.h, extended with:
 *   - dpu_v4_init(): initializes dual DMA (DMA_IN + DMA_W)
 *   - dpu_exec_conv_v4(): conv with weight FIFO + IC tiling
 */
#ifndef DPU_API_H
#define DPU_API_H

#include <stdint.h>
#include "layer_configs.h"

/* Status codes */
#define DPU_OK            0
#define DPU_ERR_TIMEOUT  -1
#define DPU_ERR_DM_FAULT -2
#define DPU_ERR_TILING   -3
#define DPU_ERR_PARAMS   -4

#define DPU_BRAM_BYTES        4096
#define DPU_TILE_INPUT_MAX     512
#define DPU_TILE_STREAM_MAX   1536

/* Per-layer profiling record */
typedef struct {
    uint32_t cycles_load;
    uint32_t cycles_compute;
    uint32_t cycles_drain;
    uint32_t cycles_total;
    uint16_t n_tiles;
} dpu_prof_t;

/* ----------------------- Wrapper / DMA bring-up ----------------------- */
int  dpu_init(void);            /* legacy single-DMA init (for leaky/pool/add) */
void dpu_reset(void);

/* P_30_A dual-DMA init (DMA_IN + DMA_W) */
int  dpu_v4_init(void);

/* ----------------------- DPU-resident kernels ------------------------- */
/* CONV (legacy, single-DMA, small layers only) */
int dpu_exec_conv (const layer_config_t *L,
                   const uint8_t *in_ddr,
                   const int8_t  *weights_ddr,
                   const int32_t *bias_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* CONV tiled (legacy, H+W tiling via ARM, single-DMA) */
int dpu_exec_conv_tiled(const layer_config_t *L,
                        const uint8_t *in_ddr,
                        const int8_t  *weights_ddr,
                        const int32_t *bias_ddr,
                        uint8_t       *out_ddr,
                        dpu_prof_t    *prof);

/* CONV v4: weight FIFO + IC tiling via ARM (P_30_A primary path) */
int dpu_exec_conv_v4(const layer_config_t *L,
                     const uint8_t *in_ddr,
                     const int8_t  *weights_ddr,
                     const int32_t *bias_ddr,
                     uint8_t       *out_ddr,
                     dpu_prof_t    *prof);

/* LEAKY: y = leaky_relu(x). */
int dpu_exec_leaky(const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* POOL: 2x2 maxpool */
int dpu_exec_pool (const layer_config_t *L,
                   const uint8_t *in_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* ADD: element-wise add */
int dpu_exec_add  (const layer_config_t *L,
                   const uint8_t *in_a_ddr,
                   const uint8_t *in_b_ddr,
                   uint8_t       *out_ddr,
                   dpu_prof_t    *prof);

/* ----------------------- ARM-side primitives -------------------------- */
int arm_concat   (const layer_config_t *L,
                  const uint8_t *in_a_ddr, uint16_t c_a,
                  const uint8_t *in_b_ddr, uint16_t c_b,
                  uint8_t       *out_ddr,
                  dpu_prof_t    *prof);

int arm_upsample (const layer_config_t *L,
                  const uint8_t *in_ddr,
                  uint8_t       *out_ddr,
                  dpu_prof_t    *prof);

/* ----------------------- Memory pool API ------------------------------ */
typedef struct mem_pool mem_pool_t;
mem_pool_t *pool_create (uintptr_t base, uint32_t bytes);
uint8_t    *pool_alloc  (mem_pool_t *p, uint32_t bytes, uint16_t producer_layer);
void        pool_release(mem_pool_t *p, uint16_t producer_layer);
uint32_t    pool_bytes_used(mem_pool_t *p);

#endif /* DPU_API_H */
