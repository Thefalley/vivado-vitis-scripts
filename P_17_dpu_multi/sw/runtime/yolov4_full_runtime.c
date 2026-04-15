/*
 * yolov4_full_runtime.c -- Orquestador completo de las 255 layers YOLOv4.
 *
 * Uso:
 *   XSCT carga via JTAG (~6 min):
 *     - bitstream dpu_multi_bd_wrapper.bit
 *     - yolov4_weights.bin @ 0x12000000
 *     - input_image (int8 416x416x3) @ 0x10000000
 *     - este ELF
 *   Boot: el ARM ejecuta main() que llama yolov4_run_all()
 *   Output: 3 heads en DDR @ ADDR_HEAD_{52,26,13}
 *   Mailbox: RESULT_ADDR[0]=MAGIC, [1]=n_layers_ok, [2]=n_layers_fail
 *
 * Despues XSCT hace mrd de los 3 heads y los guarda a disco; Python
 * los pasa por draw_bboxes.py para generar la imagen final.
 */

#include "dpu_api.h"
#include "yolov4_weights_manifest.h"
#include "layer_configs.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xtime_l.h"
#include <string.h>

/* Memory map (ampliado tras overnight run #1) */
#define ADDR_INPUT        0x10000000u   /* 416x416x3 = 519 KB input image */
#define ADDR_SCRATCH      0x13000000u   /* Scratch maxpool reorder, etc (16 MB) */
#define ADDR_WEIGHTS_BLOB 0x12000000u   /* 61 MB pesos */
#define ADDR_ACT_POOL     0x1A000000u   /* 96 MB activaciones (vs 16 MB pre) */
#define POOL_SIZE         (96u * 1024u * 1024u)
#define ADDR_HEAD_52      0x18000000u
#define ADDR_HEAD_26      0x18200000u
#define ADDR_HEAD_13      0x18400000u
#define RESULT_ADDR       0x10200000u
#define MAGIC_DONE        0xDEAD1234u

/* Fallback: si una capa no se puede correr, marcamos su output con magic
 * byte para detectar garbage downstream. */
#define GARBAGE_BYTE      0x5A

extern int dpu_exec_conv_tiled(const layer_config_t *L,
                               const uint8_t *in_ddr,
                               const int8_t  *weights_ddr,
                               const int32_t *bias_ddr,
                               uint8_t       *out_ddr,
                               dpu_prof_t    *prof);

/* ========================================================================= */
/* Memory pool v2: bump allocator con tamaños reales por capa.               */
/* Pool 96 MB. Sin recycle (overnight run 1-shot).                            */
/* ========================================================================= */
static uint32_t g_layer_out_addr[NUM_FPGA_LAYERS];
static uint32_t g_pool_cursor = 0;

static uint32_t pool_alloc_for_layer(int layer_idx, uint32_t size_bytes)
{
    /* Align 64 bytes para cache lines */
    uint32_t aligned = (size_bytes + 63u) & ~63u;
    if (g_pool_cursor + aligned > POOL_SIZE) {
        xil_printf("POOL EXHAUSTED layer=%d cursor=%u need=%u\r\n",
                   layer_idx, g_pool_cursor, aligned);
        return 0;
    }
    uint32_t addr = ADDR_ACT_POOL + g_pool_cursor;
    g_layer_out_addr[layer_idx] = addr;
    g_pool_cursor += aligned;
    return addr;
}

static uint32_t layer_input_addr(const layer_config_t *L, int layer_idx)
{
    (void)layer_idx;
    if (L->input_a_idx < 0) return ADDR_INPUT;
    if (L->input_a_idx >= NUM_FPGA_LAYERS) return 0;
    return g_layer_out_addr[L->input_a_idx];
}

static uint32_t layer_input_b_addr(const layer_config_t *L)
{
    if (L->input_b_idx < 0) return 0;
    if (L->input_b_idx >= NUM_FPGA_LAYERS) return 0;
    return g_layer_out_addr[L->input_b_idx];
}

/* ========================================================================= */
/* Output addr: los 3 heads finales van a direcciones fijas; el resto al pool */
/* ========================================================================= */
static uint32_t get_output_addr(const layer_config_t *L, int layer_idx)
{
    uint32_t out_bytes = L->c_out * L->h_out * L->w_out;
    if (layer_idx == NUM_FPGA_LAYERS - 3) {
        g_layer_out_addr[layer_idx] = ADDR_HEAD_52;
        return ADDR_HEAD_52;
    }
    if (layer_idx == NUM_FPGA_LAYERS - 2) {
        g_layer_out_addr[layer_idx] = ADDR_HEAD_26;
        return ADDR_HEAD_26;
    }
    if (layer_idx == NUM_FPGA_LAYERS - 1) {
        g_layer_out_addr[layer_idx] = ADDR_HEAD_13;
        return ADDR_HEAD_13;
    }
    return pool_alloc_for_layer(layer_idx, out_bytes);
}

/* ========================================================================= */
/* MAXPOOL real via pre-reorder ARM                                           */
/* Input NHWC @ in_ddr, output NHWC @ out_ddr.                                */
/* ARM reordena input a window-major (4 bytes contiguos por 2x2 window),     */
/* luego invoca dpu_exec_pool (chunked).                                      */
/* ========================================================================= */
static int run_maxpool_2x2(const layer_config_t *L, int idx)
{
    uint32_t in_addr  = layer_input_addr(L, idx);
    uint32_t out_addr = get_output_addr(L, idx);
    if (!out_addr) return DPU_ERR_PARAMS;

    const uint8_t *in = (const uint8_t *)(uintptr_t)in_addr;
    uint8_t *tmp = (uint8_t *)(uintptr_t)ADDR_SCRATCH;
    uint8_t *out = (uint8_t *)(uintptr_t)out_addr;

    int H_in = L->h_in, W_in = L->w_in, C = L->c_in;
    int H_out = L->h_out, W_out = L->w_out;

    Xil_DCacheInvalidateRange(in_addr, H_in * W_in * C);

    /* Reorder: cada ventana 2x2 -> 4 bytes contiguos en tmp */
    int widx = 0;
    for (int oh = 0; oh < H_out; oh++) {
        for (int ow = 0; ow < W_out; ow++) {
            int ih = oh * 2, iw = ow * 2;
            for (int c = 0; c < C; c++) {
                tmp[widx*4 + 0] = in[((ih)   * W_in + (iw))   * C + c];
                tmp[widx*4 + 1] = in[((ih)   * W_in + (iw+1)) * C + c];
                tmp[widx*4 + 2] = in[((ih+1) * W_in + (iw))   * C + c];
                tmp[widx*4 + 3] = in[((ih+1) * W_in + (iw+1)) * C + c];
                widx++;
            }
        }
    }
    Xil_DCacheFlushRange((UINTPTR)tmp, widx * 4);

    dpu_prof_t pr;
    return dpu_exec_pool(L, tmp, out, &pr);
}

/* ========================================================================= */
/* Concat en ARM (NHWC channel-wise)                                          */
/* ========================================================================= */
static int run_concat(const layer_config_t *L, int idx)
{
    const uint8_t *a = (const uint8_t *)(uintptr_t)layer_input_addr(L, idx);
    const uint8_t *b = (const uint8_t *)(uintptr_t)layer_input_b_addr(L);
    uint32_t out_addr = get_output_addr(L, idx);
    if (!out_addr) return DPU_ERR_PARAMS;
    uint8_t *out = (uint8_t *)(uintptr_t)out_addr;
    int H = L->h_out, W = L->w_out;
    int c_a = L->c_in;          /* input A channels */
    int c_b = L->c_out - c_a;   /* B fills the rest */

    Xil_DCacheInvalidateRange((UINTPTR)a, H * W * c_a);
    Xil_DCacheInvalidateRange((UINTPTR)b, H * W * c_b);

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            int off = (h * W + w);
            memcpy(out + off * (c_a + c_b) + 0,   a + off * c_a, c_a);
            memcpy(out + off * (c_a + c_b) + c_a, b + off * c_b, c_b);
        }
    }
    Xil_DCacheFlushRange((UINTPTR)out, H * W * (c_a + c_b));
    return DPU_OK;
}

/* ========================================================================= */
/* Upsample 2x nearest NHWC                                                   */
/* ========================================================================= */
static int run_upsample(const layer_config_t *L, int idx)
{
    const uint8_t *in = (const uint8_t *)(uintptr_t)layer_input_addr(L, idx);
    uint32_t out_addr = get_output_addr(L, idx);
    if (!out_addr) return DPU_ERR_PARAMS;
    uint8_t *out = (uint8_t *)(uintptr_t)out_addr;
    int H = L->h_in, W = L->w_in, C = L->c_in;
    int OW = 2 * W;

    Xil_DCacheInvalidateRange((UINTPTR)in, H * W * C);

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            const uint8_t *s = in + (h * W + w) * C;
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    uint8_t *d = out + ((2*h + dy) * OW + (2*w + dx)) * C;
                    memcpy(d, s, C);
                }
            }
        }
    }
    Xil_DCacheFlushRange((UINTPTR)out, (2*H) * (2*W) * C);
    return DPU_OK;
}

/* ========================================================================= */
/* yolov4_run_all: loop por las 255 layers                                    */
/* ========================================================================= */
static int yolov4_run_all(void)
{
    int n_ok = 0, n_fail = 0;
    XTime t_start, t_end;
    XTime_GetTime(&t_start);

    for (int i = 0; i < NUM_FPGA_LAYERS; i++) {
        const layer_config_t *L = &LAYERS[i];
        int st = DPU_OK;
        dpu_prof_t prof = {0};

        switch (L->op_type) {
        case OP_CONV: {
            const weights_entry_t *w = &WEIGHTS_TABLE[i];
            const int8_t  *wptr = (const int8_t *)(uintptr_t)
                                  (ADDR_WEIGHTS_BLOB + w->weights_offset);
            const int32_t *bptr = (const int32_t *)(uintptr_t)
                                  (ADDR_WEIGHTS_BLOB + w->bias_offset);
            const uint8_t *inp  = (const uint8_t *)(uintptr_t)
                                  layer_input_addr(L, i);
            uint32_t out_addr = get_output_addr(L, i);
            if (!out_addr) { st = DPU_ERR_PARAMS; break; }
            st = dpu_exec_conv_tiled(L, inp, wptr, bptr,
                                     (uint8_t *)(uintptr_t)out_addr, &prof);
            break;
        }

        case OP_LEAKY_RELU: {
            const uint8_t *inp = (const uint8_t *)(uintptr_t)
                                 layer_input_addr(L, i);
            uint32_t out_addr = get_output_addr(L, i);
            if (!out_addr) { st = DPU_ERR_PARAMS; break; }
            st = dpu_exec_leaky(L, inp,
                                (uint8_t *)(uintptr_t)out_addr, &prof);
            break;
        }

        case OP_ADD: {
            const uint8_t *a = (const uint8_t *)(uintptr_t)
                               layer_input_addr(L, i);
            const uint8_t *b = (const uint8_t *)(uintptr_t)
                               layer_input_b_addr(L);
            uint32_t out_addr = get_output_addr(L, i);
            if (!out_addr) { st = DPU_ERR_PARAMS; break; }
            st = dpu_exec_add(L, a, b,
                              (uint8_t *)(uintptr_t)out_addr, &prof);
            break;
        }

        case OP_MAXPOOL:
            st = run_maxpool_2x2(L, i);
            break;

        case OP_CONCAT:
            st = run_concat(L, i);
            break;

        case OP_RESIZE:
            st = run_upsample(L, i);
            break;

        default:
            xil_printf("[%3d] unknown op_type %d\r\n", i, L->op_type);
            st = DPU_ERR_PARAMS;
        }

        if (st == DPU_OK) {
            n_ok++;
            if ((i & 0x1F) == 0 || i < 5 || i >= NUM_FPGA_LAYERS - 5) {
                xil_printf("[%3d] L%d op=%d OK (tiles=%d)\r\n",
                           i, L->layer_id, L->op_type, prof.n_tiles);
            }
        } else {
            n_fail++;
            if (n_fail <= 10 || (n_fail % 20) == 0) {
                xil_printf("[%3d] L%d op=%d FAIL st=%d\r\n",
                           i, L->layer_id, L->op_type, st);
            }
            /* No podemos hacer memset(GARBAGE) sin saber el buffer.
             * El consumer downstream leerá basura, lo detectaremos en
             * el head final. */
        }
    }

    XTime_GetTime(&t_end);
    uint64_t cycles = 2 * (t_end - t_start);  /* XTime is COUNTS_PER_SECOND / 2 */
    xil_printf("\r\n### yolov4 done: %d ok / %d fail (%lu cycles) ###\r\n",
               n_ok, n_fail, (unsigned long)cycles);
    return n_ok;
}

/* ========================================================================= */
/* main                                                                       */
/* ========================================================================= */
int main(void)
{
    volatile uint32_t *res = (volatile uint32_t *)RESULT_ADDR;
    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n##################################################\r\n");
    xil_printf("  YOLOv4 full runtime (255 layers)\r\n");
    xil_printf("  weights_blob @ 0x%08X (%u bytes)\r\n",
               ADDR_WEIGHTS_BLOB, WEIGHTS_BLOB_BYTES);
    xil_printf("##################################################\r\n");

    if (dpu_init() != DPU_OK) {
        xil_printf("ERR dpu_init\r\n");
        res[0] = MAGIC_DONE;
        res[1] = 0;
        res[2] = 0xFFFFFFFF;
        Xil_DCacheFlushRange((UINTPTR)res, 64);
        while(1);
    }

    /* Invalidate caches sobre weights blob (cargado via JTAG by XSCT) */
    Xil_DCacheInvalidateRange(ADDR_WEIGHTS_BLOB, 64 * 1024 * 1024);
    Xil_DCacheInvalidateRange(ADDR_INPUT, 416 * 416 * 3);

    int n_ok = yolov4_run_all();

    /* Final: señalizar XSCT con mailbox */
    res[0] = MAGIC_DONE;
    res[1] = (uint32_t)n_ok;
    res[2] = (uint32_t)(NUM_FPGA_LAYERS - n_ok);
    /* heads addresses para XSCT mrd */
    res[3] = ADDR_HEAD_52;
    res[4] = ADDR_HEAD_26;
    res[5] = ADDR_HEAD_13;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    while(1);
    return 0;
}
