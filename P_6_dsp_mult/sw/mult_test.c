/*
 * mult_test.c - Test multiplicador signed 32x32 via DMA en ZedBoard
 *
 * Flujo:
 *   1. Llena buffer source con pares {A, B} empaquetados como u64
 *   2. DMA envia a mult_stream (64-bit stream)
 *   3. mult_stream multiplica: signed(A) * signed(B) = P (64 bits)
 *   4. DMA recibe resultado en buffer dest
 *   5. ARM compara contra referencia (A*B calculado en C con int64)
 *
 * Formato en DDR (64 bits por entrada):
 *   src[i] = { A[31:0] , B[31:0] }   (A en bits 63:32, B en bits 31:0)
 *   dst[i] = { P[63:0] }             (resultado signed 64 bits)
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include <string.h>

#define DMA_BASEADDR    XPAR_XAXIDMA_0_BASEADDR

/* Cada test es 8 bytes entrada + 8 bytes salida */
#define MAX_TESTS       128
#define TRANSFER_SIZE   (MAX_TESTS * 8)

#define SRC_ADDR        0x01000000
#define DST_ADDR        0x01100000

static XAxiDma dma_inst;

/* Estructura de un test case */
typedef struct {
    s32 a;
    s32 b;
    s64 expected;  /* a * b */
    const char *desc;
} test_case_t;

/* Referencia: multiplicacion signed 32x32 -> 64 */
static s64 ref_mult(s32 a, s32 b)
{
    return (s64)a * (s64)b;
}

int main(void)
{
    int status;
    XAxiDma_Config *cfg;
    volatile u64 *src = (volatile u64 *)SRC_ADDR;
    volatile u64 *dst = (volatile u64 *)DST_ADDR;
    int errors = 0;
    int num_tests = 0;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  Multiplicador signed 32x32 - DMA Test\r\n");
    xil_printf("==========================================\r\n\r\n");

    /* ============================================ */
    /* Test cases: todos los casos criticos         */
    /* ============================================ */
    test_case_t tests[] = {
        /* Basicos */
        { 0, 0, 0, "0 x 0" },
        { 1, 1, 1, "1 x 1" },
        { 1, -1, -1, "1 x -1" },
        { -1, -1, 1, "-1 x -1" },
        { -1, 1, -1, "-1 x 1" },

        /* Potencias de 2 */
        { 2, 2, 4, "2 x 2" },
        { 1024, 1024, 1048576, "1024 x 1024" },
        { -1024, 1024, -1048576, "-1024 x 1024" },
        { 65536, 65536, 0, "2^16 x 2^16 (=2^32)" },

        /* Limites positivos */
        { 0x7FFFFFFF, 1, 0x7FFFFFFF, "MAX_INT x 1" },
        { 0x7FFFFFFF, 2, 0xFFFFFFFE, "MAX_INT x 2" },
        { 0x7FFFFFFF, 0x7FFFFFFF, 0, "MAX_INT x MAX_INT" },

        /* Limites negativos */
        { (s32)0x80000000, 1, (s64)((s32)0x80000000), "MIN_INT x 1" },
        { (s32)0x80000000, -1, 0x80000000LL, "MIN_INT x -1 (=+2^31)" },
        { (s32)0x80000000, (s32)0x80000000, 0, "MIN_INT x MIN_INT" },

        /* Mixtos positivo x negativo */
        { 12345, -6789, 0, "12345 x -6789" },
        { -12345, -6789, 0, "neg x neg" },
        { 100000, 200000, 0, "100K x 200K" },
        { -100000, 200000, 0, "neg x 200K" },

        /* Carry entre zonas (bits 17-18 boundary) */
        { 0x0003FFFF, 0x0003FFFF, 0, "262143 x 262143 (18-bit max)" },
        { 0x00040000, 0x00040000, 0, "2^18 x 2^18 (zona boundary)" },
        { 0x0003FFFF, 0x00040000, 0, "18-bit max x 2^18" },

        /* Carry entre zonas (bits 35-36 boundary) */
        { 0x0007FFFF, 0x0007FFFF, 0, "19-bit x 19-bit" },
        { 0x7FFF0000, 0x00020000, 0, "high x low" },

        /* Patron alternante */
        { (s32)0xAAAAAAAA, (s32)0x55555555, 0, "0xAAA x 0x555" },
        { (s32)0x55555555, (s32)0x55555555, 0, "0x555 x 0x555" },

        /* Numeros grandes negativos */
        { (s32)0xFFFFFFFE, (s32)0xFFFFFFFE, 0, "-2 x -2 = 4" },
        { (s32)0xFFFFFF00, 0x100, 0, "-256 x 256" },
        { (s32)0x80000001, (s32)0x80000001, 0, "(MIN+1) x (MIN+1)" },

        /* Random-ish */
        { 0x12345678, 0x12345678, 0, "same x same" },
        { (s32)0xDEADBEEF, 0x01234567, 0, "DEADBEEF x 01234567" },
        { (s32)0xCAFEBABE, (s32)0xBADC0FFE, 0, "CAFEBABE x BADC0FFE" },
    };

    num_tests = sizeof(tests) / sizeof(tests[0]);

    /* Calcular expected para los que estan a 0 */
    for (int i = 0; i < num_tests; i++) {
        if (tests[i].expected == 0 && !(tests[i].a == 0 && tests[i].b == 0)) {
            tests[i].expected = ref_mult(tests[i].a, tests[i].b);
        }
    }

    /* Init DMA */
    cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed\r\n");
        return -1;
    }
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Fill source buffer: pack {A, B} as 64-bit words */
    for (int i = 0; i < num_tests; i++) {
        u64 packed = ((u64)(u32)tests[i].a << 32) | (u32)tests[i].b;
        src[i] = packed;
    }
    memset((void *)dst, 0xDE, num_tests * 8);

    u32 xfer_bytes = num_tests * 8;

    Xil_DCacheFlushRange((UINTPTR)src, xfer_bytes);
    Xil_DCacheInvalidateRange((UINTPTR)dst, xfer_bytes);

    /* DMA transfer */
    xil_printf("Enviando %d tests por DMA (%d bytes)...\r\n\r\n", num_tests, xfer_bytes);

    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)dst, xfer_bytes, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, xfer_bytes, XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst, xfer_bytes);

    /* Verify results */
    xil_printf("  # | A          | B          | Got              | Expected         | %s\r\n", "OK?");
    xil_printf("  --|------------|------------|------------------|------------------|----\r\n");

    for (int i = 0; i < num_tests; i++) {
        s64 got = (s64)dst[i];
        s64 exp = tests[i].expected;

        int ok = (got == exp);
        if (!ok) errors++;

        xil_printf("  %2d| 0x%08X | 0x%08X | 0x%08X%08X | 0x%08X%08X | %s  %s\r\n",
                   i,
                   (u32)tests[i].a, (u32)tests[i].b,
                   (u32)(got >> 32), (u32)(got & 0xFFFFFFFF),
                   (u32)(exp >> 32), (u32)(exp & 0xFFFFFFFF),
                   ok ? "OK  " : "FAIL",
                   tests[i].desc);
    }

    xil_printf("\r\n==========================================\r\n");
    if (errors == 0) {
        xil_printf("  PASS: %d/%d tests OK\r\n", num_tests, num_tests);
    } else {
        xil_printf("  FAIL: %d/%d errores\r\n", errors, num_tests);
    }
    xil_printf("==========================================\r\n");

    while(1);
    return 0;
}
