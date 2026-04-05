/*
 * mult_stress.c - Test exhaustivo del multiplicador signed 32x32
 *
 * Fase 1: Barrido de valores criticos en los carries entre zonas
 *         (boundary en bit 18 y bit 36, sign flip, carry 0/1/2)
 * Fase 2: Millones de valores random por DMA
 *
 * Envia batches de 1024 multiplicaciones por DMA, verifica cada una.
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR

#define BATCH_SIZE      1024
#define BATCH_BYTES     (BATCH_SIZE * 8)

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000
#define RESULT_ADDR     0x01200000  /* Resultado legible por JTAG */

/* Estructura de resultado en DDR para lectura JTAG */
#define MAGIC_RUNNING   0xAAAA0001
#define MAGIC_DONE      0xDEAD1234

typedef struct {
    volatile u32 magic;         /* 0x00: MAGIC_RUNNING -> MAGIC_DONE */
    volatile u32 total_tests;   /* 0x04 */
    volatile u32 total_errors;  /* 0x08 */
    volatile u32 phase1_errors; /* 0x0C */
    volatile u32 phase2_errors; /* 0x10 */
    volatile u32 phase3_errors; /* 0x14 */
    volatile u32 phase1_count;  /* 0x18 */
    volatile u32 phase2_count;  /* 0x1C */
    volatile u32 phase3_count;  /* 0x20 */
} jtag_result_t;

static XAxiDma dma_inst;
static volatile u64 *src = (volatile u64 *)SRC_ADDR;
static volatile u64 *dst = (volatile u64 *)DST_ADDR;

static u32 total_tests = 0;
static u32 total_errors = 0;
static jtag_result_t *jtag_res = (jtag_result_t *)RESULT_ADDR;

/* LFSR pseudo-random (rapido, determinista) */
static u32 lfsr_state = 0xDEADBEEF;
static u32 lfsr_next(void)
{
    u32 bit = ((lfsr_state >> 31) ^ (lfsr_state >> 21) ^
               (lfsr_state >> 1)  ^ lfsr_state) & 1;
    lfsr_state = (lfsr_state << 1) | bit;
    return lfsr_state;
}

static s64 ref_mult(s32 a, s32 b)
{
    return (s64)a * (s64)b;
}

static void pack(int idx, s32 a, s32 b)
{
    src[idx] = ((u64)(u32)a << 32) | (u32)b;
}

/* Envia batch por DMA y verifica */
static int run_batch(int count, const char *desc)
{
    int errors = 0;
    u32 xfer = count * 8;

    Xil_DCacheFlushRange((UINTPTR)src, xfer);
    Xil_DCacheInvalidateRange((UINTPTR)dst, xfer);

    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, xfer, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, xfer, XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, xfer);

    for (int i = 0; i < count; i++) {
        u64 src_val = src[i];
        s32 a = (s32)(src_val >> 32);
        s32 b = (s32)(src_val & 0xFFFFFFFF);
        s64 got = (s64)dst[i];
        s64 exp = ref_mult(a, b);

        if (got != exp) {
            errors++;
            if (errors <= 5) {
                xil_printf("  FAIL [%s] A=0x%08X B=0x%08X got=0x%08X%08X exp=0x%08X%08X\r\n",
                    desc, (u32)a, (u32)b,
                    (u32)(got >> 32), (u32)(got & 0xFFFFFFFF),
                    (u32)(exp >> 32), (u32)(exp & 0xFFFFFFFF));
            }
        }
    }

    total_tests += count;
    total_errors += errors;
    return errors;
}

/* ============================================================
 * FASE 1: Barrido de carries entre zonas
 *
 * Split: A = A_H(14 bits, signed) * 2^18 + A_L(18 bits, unsigned)
 *
 * Valores criticos de A_L / B_L (18 bits):
 *   0x00000, 0x00001, 0x1FFFF, 0x20000, 0x3FFFE, 0x3FFFF
 *
 * Valores criticos de A_H / B_H (14 bits, signed):
 *   0x0000, 0x0001, 0x1FFF (max pos), 0x2000 (min neg = -8192),
 *   0x3FFE (-2), 0x3FFF (-1)
 *
 * Total: 6 * 6 * 6 * 6 = 1296 combinaciones
 * ============================================================ */
static void fase1_boundary(void)
{
    /* Valores criticos para la parte baja (18 bits, unsigned) */
    static const u32 lo_vals[] = {
        0x00000, 0x00001, 0x1FFFF, 0x20000, 0x3FFFE, 0x3FFFF
    };
    /* Valores criticos para la parte alta (14 bits, signed) */
    static const u32 hi_vals[] = {
        0x0000, 0x0001, 0x1FFF, 0x2000, 0x3FFE, 0x3FFF
    };
    int n_lo = sizeof(lo_vals) / sizeof(lo_vals[0]);
    int n_hi = sizeof(hi_vals) / sizeof(hi_vals[0]);

    int idx = 0;
    int batch_errors = 0;

    xil_printf("[FASE 1] Boundary carry sweep (%d lo x %d hi)^2 ...\r\n",
               n_lo, n_hi);

    for (int ah = 0; ah < n_hi; ah++) {
        for (int al = 0; al < n_lo; al++) {
            for (int bh = 0; bh < n_hi; bh++) {
                for (int bl = 0; bl < n_lo; bl++) {
                    s32 a = (s32)((hi_vals[ah] << 18) | lo_vals[al]);
                    s32 b = (s32)((hi_vals[bh] << 18) | lo_vals[bl]);
                    pack(idx, a, b);
                    idx++;

                    if (idx >= BATCH_SIZE) {
                        batch_errors += run_batch(idx, "boundary");
                        idx = 0;
                    }
                }
            }
        }
    }

    /* Flush remaining */
    if (idx > 0) {
        batch_errors += run_batch(idx, "boundary");
    }

    jtag_res->phase1_errors = batch_errors;
    jtag_res->phase1_count = n_lo * n_lo * n_hi * n_hi;
    Xil_DCacheFlushRange((UINTPTR)jtag_res, sizeof(jtag_result_t));

    xil_printf("  -> %d tests, %d errors\r\n\r\n",
               n_lo * n_lo * n_hi * n_hi, batch_errors);
}

/* ============================================================
 * FASE 2: Valores especiales (extremos signed)
 * ============================================================ */
static void fase2_extremes(void)
{
    static const s32 specials[] = {
        0, 1, -1, 2, -2,
        0x7FFFFFFF,   /* MAX_INT */
        (s32)0x80000000,  /* MIN_INT */
        (s32)0x80000001,  /* MIN_INT + 1 */
        0x7FFFFFFE,   /* MAX_INT - 1 */
        0x00040000,   /* 2^18 exacto (boundary) */
        (s32)0xFFFC0000,  /* -2^18 */
        0x0003FFFF,   /* 2^18 - 1 */
        (s32)0xFFFC0001,  /* -(2^18 - 1) */
        0x55555555,
        (s32)0xAAAAAAAA,
        0x12345678,
        (s32)0xDEADBEEF,
        0x01234567,
        (s32)0xFEDCBA98,
        (s32)0xCAFEBABE,
    };
    int n = sizeof(specials) / sizeof(specials[0]);
    int idx = 0;
    int batch_errors = 0;

    xil_printf("[FASE 2] Extremos signed (%d x %d = %d tests)...\r\n",
               n, n, n * n);

    /* Todas las combinaciones de specials x specials */
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            pack(idx, specials[i], specials[j]);
            idx++;
            if (idx >= BATCH_SIZE) {
                batch_errors += run_batch(idx, "extremes");
                idx = 0;
            }
        }
    }
    if (idx > 0) {
        batch_errors += run_batch(idx, "extremes");
    }

    jtag_res->phase2_errors = batch_errors;
    jtag_res->phase2_count = n * n;
    Xil_DCacheFlushRange((UINTPTR)jtag_res, sizeof(jtag_result_t));

    xil_printf("  -> %d tests, %d errors\r\n\r\n", n * n, batch_errors);
}

/* ============================================================
 * FASE 3: Random masivo
 * ============================================================ */
static void fase3_random(u32 num_batches)
{
    int batch_errors = 0;
    u32 total_random = num_batches * BATCH_SIZE;

    xil_printf("[FASE 3] Random: %d batches x %d = %d tests...\r\n",
               num_batches, BATCH_SIZE, total_random);

    for (u32 b = 0; b < num_batches; b++) {
        for (int i = 0; i < BATCH_SIZE; i++) {
            s32 a = (s32)lfsr_next();
            s32 b_val = (s32)lfsr_next();
            pack(i, a, b_val);
        }
        int err = run_batch(BATCH_SIZE, "random");
        batch_errors += err;

        /* Progress cada 100 batches */
        if ((b + 1) % 100 == 0) {
            xil_printf("  batch %d/%d (%d tests, %d errors so far)\r\n",
                       b + 1, num_batches, (b + 1) * BATCH_SIZE, batch_errors);
        }
    }

    jtag_res->phase3_errors = batch_errors;
    jtag_res->phase3_count = total_random;
    Xil_DCacheFlushRange((UINTPTR)jtag_res, sizeof(jtag_result_t));

    xil_printf("  -> %d tests, %d errors\r\n\r\n", total_random, batch_errors);
}

int main(void)
{
    XAxiDma_Config *cfg;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  STRESS TEST: mul_s32x32_pipe\r\n");
    xil_printf("  4 DSP48E1, carry por zonas\r\n");
    xil_printf("  Batch size: %d (DMA 64-bit)\r\n", BATCH_SIZE);
    xil_printf("==========================================\r\n\r\n");

    /* Init DMA */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    XAxiDma_CfgInitialize(&dma_inst, cfg);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    memset((void *)dst, 0xDE, BATCH_BYTES);

    /* Marcar resultado como "en progreso" */
    memset((void *)jtag_res, 0, sizeof(jtag_result_t));
    jtag_res->magic = MAGIC_RUNNING;
    Xil_DCacheFlushRange((UINTPTR)jtag_res, sizeof(jtag_result_t));

    /* Fase 1: Boundary carry (1296 tests) */
    fase1_boundary();

    /* Fase 2: Extremos signed (400 tests) */
    fase2_extremes();

    /* Fase 3: Random masivo (1000 batches x 1024 = 1,024,000 tests) */
    fase3_random(1000);

    /* Escribir resultado final en DDR para JTAG */
    jtag_res->total_tests = total_tests;
    jtag_res->total_errors = total_errors;
    jtag_res->magic = MAGIC_DONE;
    Xil_DCacheFlushRange((UINTPTR)jtag_res, sizeof(jtag_result_t));

    /* Resumen final */
    xil_printf("==========================================\r\n");
    xil_printf("  RESULTADO FINAL\r\n");
    xil_printf("  Total tests:  %d\r\n", total_tests);
    xil_printf("  Total errors: %d\r\n", total_errors);
    if (total_errors == 0) {
        xil_printf("  >>> ALL PASSED <<<\r\n");
    } else {
        xil_printf("  >>> FAILED <<<\r\n");
    }
    xil_printf("==========================================\r\n");

    while(1);
    return 0;
}
