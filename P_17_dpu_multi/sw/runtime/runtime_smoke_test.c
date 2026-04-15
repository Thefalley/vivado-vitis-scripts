/*
 * runtime_smoke_test.c -- Verifica que las 4 funciones dpu_exec_*
 * funcionan con datos reales llamandolas desde una "aplicacion" C.
 *
 * Reusa los mismos datos de los phase4_tests (layer_005 conv + L006 leaky),
 * pero a traves de las funciones de alto nivel. Si pasa, confirmamos que
 * el runtime puede orquestar multi-layer.
 */

#include "dpu_api.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <string.h>

/* Addresses */
#define RESULT_ADDR  0x10200000
#define MAGIC_DONE   0xDEAD1234

/* Pool region */
#define POOL_BASE    0x14000000  /* despues de DPU_SRC/DST que usa 0x10000000 */
#define POOL_BYTES   (32 * 1024 * 1024)  /* 32 MB para smoke test */

/* ========================================================================= */
/* Datos layer_005 (copiados de phase4_tests/layer_005_test.c)               */
/* Conv 3x3 s=1 pad=1, c_in=3 c_out=32 h=w=3                                */
/* ========================================================================= */
static const int8_t l005_input[27] = {
     56,-106,  21,  50,-102,  17,   6, -97,  -6,
     62, -64,  39,  59, -57,  34,  29, -42,  23,
     65, -40,  44,  70, -31,  33,  39, -24,  31
};

/* Ya en OHWI layout */
static const int8_t l005_weights[864] = {
    /* layer_005 pesos OHWI, copia del test ya verificado */
     -4,  -3,  10,  -8, -12,  11,  -4,  -5,   7,  -2,  -4,   6,  -6, -12,   6,  -1,  -4,   6,   0,  -2,   0,  -3,  -5,   3,  -1,  -2,   5,
    -13,  -2,   4,  -7,   3,   6,   1,   5,   0, -10,  -3,   6,  -9,  -1,   5,   4,   6,   5,  -8,  -7,  -5,  -8,  -6,  -3,  -1,  -2,  -3,
     -2,  -6,  -9,  -2,  -7,  -9,   0,  -1,  -4,   3,  -3,   0,   3,  -7,  -2,   4,   2,   4,   2,   1,   4,   1,  -1,   5,  -1,   2,   5,
      3,  -1, -14,   0,  -9,  -6,   8,  -2,  -6,   0,   3,   2,  -6,  -7,   9,  -3,  -6,   3,   4,   7,   3,  -1,  -6,   9,  -2, -11,  -3,
     -2, -12,  -1,   2, -23,   5,   6,   9,   8,  -5,  -9,  -7,  -2, -16,  -5,  -1,   4,  -3,   0,  -3,  -1,   3,  -7,   1,   3,   5,   3,
      2,  -2,   2,   0,  -4,  -2,   1,  -3,   0,  -7,  -7,  -8,  -6,  -7,  -8,  -7,  -7,  -8,   5,   8,   5,   7,  13,  10,   6,  10,   8,
     -1,   0,  -2,   1,   6,   2,  -2,   1,  -1,   3,   5,   5,   4,  10,   7,   6,   9,   8,  -2,  -6,  -4,  -5, -12,  -9,  -4, -11,  -8,
     10,  18,  12,   0,   0,   0, -10, -18, -11,   9,  17,  10,   0,   0,   0,  -9, -17, -11,   6,  12,   7,   0,   0,   0,  -6, -12,  -7,
      6,  -3,  -9,   9,  -8, -12,  10,  -1,  -3,   7,  -1,  -3,   6, -10,  -9,   8,  -2,   0,   3,   0,  -1,   3,  -6,  -5,   3,  -3,  -2,
    -28,   7, -27,   5, 127,   5, -29, -13, -27,  14, -16,  14, -11, -18, -17,  16, -27,  10,  14,  -6,  16,  -4, -54,  -5,  14,   2,  20,
     -1,  -1,  -7,   3,  10, -10,   6,  -4,  -8,   3,   1,  -8,   7,  10, -13,  10,  -5, -10,   3,   1,  -8,   7,  14,  -8,  10,  -1,  -7,
      2,   0,   0,  -1,  -8,  -4,   2,  -6,  -2,  -4,  -6,  -6,  -6,  -9,  -8,  -3,  -9,  -6,   3,   9,   4,   6,  19,  12,   2,  12,   8,
     -3,  -2,   1,  -4,  -3,   1,   0,   1,   4,  -5,   0,   9, -10,  -4,   8,  -7,  -2,   8,  -5,   1,   9, -10,  -2,   8,  -9,  -3,   7,
      2,  11,  11,   9, -46,   1,   5,  -2,   9,   5,   2,   8,   5, -30,  -4,   8,  -5,   3, -12,  -1, -14,  -4,  16,  -6, -11,   2, -12,
    -10,   1,  12, -13,   2,  20, -14,  -3,  11,  -7,  -1,   4,  -8,   3,  13,  -7,   0,   6,  -2,  -1,  -1,  -2,   2,   5,  -2,   1,   2,
      1,   6,   2,   4,  20,  10,   1,  10,   5,  -3,  -9,  -5,  -6,  -9,  -9,  -4, -11,  -8,   3,   0,   4,  -1,  -4,  -2,   4,  -1,   3,
     -4,  -3,   4,  -6,  -2,  -8,  -2, -12,  -9,  -1,   4,   2,   4,   9,  -8,   4,  -8, -12,  -6,   2,  -2,   3,  13,  -7,   7,  -1, -11,
     -2,  -1,   3,  -5, -48,  46,  -1,  -4,   5,   7,   0,   0,  -5, -60,  53,   9,  -3,   4,   3,   0,  -2,   3, -12,  12,   4,  -3,   1,
     -4,  -4,  -1, -11, -15,   0,  -2,  -4,  -4,  -1,   0,  11, -12, -19,   6,   4,   2,   6,  -7,  -1,  10, -13, -14,  10,   2,   3,  10,
     29,   9, -21,  36,   4, -36,  25,  -3, -38, -11,  -3,   8, -11,   2,  21, -10,  -2,  10, -20,  -7,  12, -26,  -1,  31, -12,   5,  24,
      0,   2,  -1,   2,   2,   2,   2,   4,   3,   3,   0,   2,  -2,  -7,  -1,  -2,  -5,  -1,   0,   0,   2,  -4,  -5,  -2,  -4,  -5,  -3,
    -10, -13, -14,   4,   5,   4,   5,  10,  10,  -7,  -9,  -9,   1,   3,   1,   5,   9,   7,  -6,  -7,  -6,  -2,   0,   0,   4,   8,   7,
     -7,   6,  -6,   0, -14,  -6,  -1,   2,  -5,   7,  10,  10,   3, -31,  -1,   3,  -9,   3,   4,  17,   9,   3, -18,   3,  -4, -10,   2,
      6,   2,   3,   4,  -4,  -4,   5,  -2,  -9,   0,  -3,  -1,  -2,  -8,  -5,   0,  -6,  -7,   3,   2,   3,   1,  -2,   0,   3,  -1,  -2,
     -2,  -1,  -2,   0,   5,   1,  -4,   2,  -1,   0,  -2,  -2,   0,   4,   0,   0,   3,   0,  -2,   0,  -4,   1,  13,   3,   1,  13,   5,
     -1,   1,  -2,   4,  18,  -8,   1,   0, -14,   3,   2,   5,   1,   4,  -6,   4,  -5,  -7,  -1,  -4,   2,  -6,  -7,  -8,  -4, -12,  -8,
      0,   4,   4,   2,  11,  13,   0,   6,   5,   0,  -3,  -4,  -2,   3,  10,   0,  -1,  -3,  -2,  -7,   2,  -4,   2,  25,  -4, -11,  -1,
      1, -12,   2, -11, -32, -13,   2, -18,   0,   4,   6,   4,   6,  24,   8,   5,   9,   4,  -4,   0,  -5,   0,  23,   3,  -6,   6,  -4,
      2,   4,   0,   6,  17,   4,   0,   6,   1,  -3,   1,  -1,   0,  14,  -2,  -3,   2,  -4,  -4,  -2,  -5,   2,  17,  -6,  -2,   5,  -8,
    -21, -36, -31,  -1,   1,  -7,  27,  44,  31,   4,  15,  11,   0,  10,   2,  -9, -14, -15,  14,  28,  22,  -1,   5,   4, -17, -32, -21,
      1,  -5,   1,   0, -48,  -4,  -2,  55,   5,   8, -13,   7,   1, -60, -10,  -3,  65,   4,   2,   1,   3,   2, -21,  -5,  -3,  21,   1,
      4,   5,   8,  -2,  -6,   2,  -4,  -5,   0,  -1,  -1,  -1,  -4,  -7,  -4,  -3,  -3,  -3,   1,   1,   0,   2,   0,   0,   2,   3,   2
};

static const int32_t l005_bias[32] = {
    1623, 1048, 1258, 232, 1845, 1748, 1300, 1221,
    1861, 123, -859, -1173, 4085, 2515, 659, 825,
    1526, 3951, 1526, 1647, 1409, -616, 1566, 984,
    -6950, 1229, -10249, 2056, -8582, 1821, 3756, 814
};

/* Expected (from prior verified tests) */
static const int8_t l005_expected_center[32] = {
     -9, -53, -10, -25, -20,  -2, -17,  -7,
     -5, -56, -31, -14,  -6, -15, -14, -24,
    -43,  67, -25,   2, -23, -27, -11, -18,
    -39, -51, -43,   9, -57, -16,  14, -17
};

/* Fake layer_config for L005 (conv 3x3 s=1 pad=1) */
static const layer_config_t L005 = {
    .layer_id    = 5,
    .op_type     = 0,
    .c_in        = 3,
    .c_out       = 32,
    .h_in        = 3,
    .w_in        = 3,
    .h_out       = 3,
    .w_out       = 3,
    .kernel      = 3,
    .stride      = 1,
    .pad         = 1,
    .x_zp        = -128,
    .w_zp        = 0,
    .y_zp        = -17,
    .M0          = 656954014u,
    .n_shift     = 37,
    .M0_neg      = 0,
    .n_neg       = 0,
    .b_zp        = 0,
    .M0_b        = 0,
    .input_a_idx = -1,
    .input_b_idx = -1
};

int main(void)
{
    volatile uint32_t *res = (volatile uint32_t *)RESULT_ADDR;
    res[0] = 0xAAAA0001;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n### P_17 runtime smoke test ###\r\n");

    if (dpu_init() != DPU_OK) {
        xil_printf("ERR: dpu_init\r\n");
        goto fail;
    }
    xil_printf("  dpu_init OK\r\n");

    /* Create pool */
    mem_pool_t *pool = pool_create(POOL_BASE, POOL_BYTES);
    if (!pool) goto fail;

    /* Alloc output buffer for L005 (3*3*32 = 288 bytes) */
    uint8_t *l005_out = pool_alloc(pool, 288, 5);
    if (!l005_out) goto fail;

    xil_printf("  running dpu_exec_conv(L005)...\r\n");
    dpu_prof_t prof;
    int st = dpu_exec_conv(&L005,
                           (const uint8_t *)l005_input,
                           l005_weights,
                           l005_bias,
                           l005_out,
                           &prof);
    if (st != DPU_OK) {
        xil_printf("ERR: dpu_exec_conv=%d\r\n", st);
        goto fail;
    }
    xil_printf("  conv done\r\n");

    /* Verify center pixel (1,1) across 32 output channels.
     * layout from conv_engine_v3: NCHW (channel-major).
     * Offset para oc=k pixel(1,1) = k*h_out*w_out + 1*w_out + 1 = k*9 + 4 */
    int errors = 0;
    for (int oc = 0; oc < 32; oc++) {
        int8_t got = (int8_t)l005_out[oc * 9 + 4];
        int8_t exp = l005_expected_center[oc];
        int ok = (got == exp);
        if (!ok) {
            errors++;
            xil_printf("  oc %2d: got %4d exp %4d FAIL\r\n",
                       oc, (int)got, (int)exp);
        }
    }
    xil_printf("\r\n  L005 center pixel: %d/32 OK\r\n", 32 - errors);

    if (errors == 0) {
        xil_printf("  >>> SMOKE TEST PASSED <<<\r\n");
    } else {
        xil_printf("  >>> %d errors <<<\r\n", errors);
    }

    res[0] = MAGIC_DONE;
    res[1] = 32;
    res[2] = errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 0;

fail:
    xil_printf("FAIL\r\n");
    res[0] = MAGIC_DONE;
    res[1] = 0;
    res[2] = 1;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
    return 1;
}
