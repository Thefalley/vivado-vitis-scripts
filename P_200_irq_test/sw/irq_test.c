/*
 * irq_test.c - Test de interrupciones PL -> PS en ZedBoard (16 registros)
 *
 * TEST 1: threshold=100, condition=100, mask=1 -> IRQ
 * TEST 2: threshold=100, condition=50 -> NO IRQ
 * TEST 3: prescaler=9, threshold=10 -> IRQ (cuenta cada 10 clocks)
 * TEST 4: scratch R/W
 * TEST 5: VERSION read-only
 */

#include "xscugic.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xparameters.h"

#ifdef XPAR_IRQ_TOP_0_S_AXI_BASEADDR
#define IRQ_BASE  XPAR_IRQ_TOP_0_S_AXI_BASEADDR
#else
#define IRQ_BASE  0x40000000
#endif

/* Register offsets (16 registers) */
#define REG_CTRL       0x00
#define REG_THRESHOLD  0x04
#define REG_CONDITION  0x08
#define REG_STATUS     0x0C
#define REG_COUNT      0x10
#define REG_IRQ_COUNT  0x14
#define REG_PRESCALER  0x18
#define REG_SCRATCH0   0x1C
#define REG_SCRATCH1   0x20
#define REG_SCRATCH2   0x24
#define REG_SCRATCH3   0x28
#define REG_VERSION    0x2C

/* CTRL bits: bit0=start, bit1=irq_clear, bit2=irq_mask */
#define CTRL_START     0x01
#define CTRL_CLR       0x02
#define CTRL_MASK      0x04
#define CTRL_START_MASK (CTRL_START | CTRL_MASK)  /* 0x05 */

#define PL_IRQ_ID      61
#define INTC_DEVICE_ID XPAR_SCUGIC_SINGLE_DEVICE_ID

static XScuGic Intc;
static volatile u32 g_irq_count = 0;

static inline void wreg(u32 off, u32 val) { Xil_Out32(IRQ_BASE + off, val); }
static inline u32  rreg(u32 off)          { return Xil_In32(IRQ_BASE + off); }

static void IrqHandler(void *cb)
{
    (void)cb;
    wreg(REG_CTRL, CTRL_CLR);
    wreg(REG_CTRL, 0);
    g_irq_count++;
}

static int SetupInterrupts(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(INTC_DEVICE_ID);
    if (!cfg) return XST_FAILURE;
    int s = XScuGic_CfgInitialize(&Intc, cfg, cfg->CpuBaseAddress);
    if (s != XST_SUCCESS) return s;
    XScuGic_SetPriorityTriggerType(&Intc, PL_IRQ_ID, 0xA0, 0x1);
    s = XScuGic_Connect(&Intc, PL_IRQ_ID, (Xil_InterruptHandler)IrqHandler, NULL);
    if (s != XST_SUCCESS) return s;
    XScuGic_Enable(&Intc, PL_IRQ_ID);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler, &Intc);
    Xil_ExceptionEnable();
    return XST_SUCCESS;
}

/* Result markers in DDR for JTAG verification */
#define DDR_MARKER   0x00100000
#define DDR_RESULTS  0x00100004  /* 5 words: test1..test5 result (1=pass) */

int main(void)
{
    u32 pass;

    xil_printf("\r\n==========================================\r\n");
    xil_printf("  P_200 IRQ Test v2 (16 regs)\r\n");
    xil_printf("  Base: 0x%08x\r\n", IRQ_BASE);
    xil_printf("==========================================\r\n\r\n");

    if (SetupInterrupts() != XST_SUCCESS) {
        xil_printf("ERROR: GIC init failed\r\n");
        return -1;
    }

    /* ===== TEST 1: threshold=100, condition=100, mask=1 ===== */
    xil_printf("--- TEST 1: IRQ fire (th=100, cond=100) ---\r\n");
    g_irq_count = 0;
    wreg(REG_PRESCALER, 0);
    wreg(REG_THRESHOLD, 100);
    wreg(REG_CONDITION, 100);
    wreg(REG_CTRL, CTRL_START_MASK);

    for (volatile u32 i = 0; i < 100000 && g_irq_count == 0; i++);
    pass = (g_irq_count >= 1);
    xil_printf("  %s (irq=%d)\r\n\r\n", pass ? "PASS" : "FAIL", g_irq_count);
    Xil_Out32(DDR_RESULTS + 0, pass);

    /* ===== TEST 2: condition=50 -> no IRQ ===== */
    xil_printf("--- TEST 2: no IRQ (cond=50) ---\r\n");
    g_irq_count = 0;
    wreg(REG_CONDITION, 50);
    wreg(REG_CTRL, CTRL_START_MASK);
    for (volatile u32 i = 0; i < 500000; i++);
    wreg(REG_CTRL, 0);
    pass = (g_irq_count == 0);
    xil_printf("  %s (irq=%d)\r\n\r\n", pass ? "PASS" : "FAIL", g_irq_count);
    Xil_Out32(DDR_RESULTS + 4, pass);

    /* ===== TEST 3: prescaler=9, threshold=10 ===== */
    xil_printf("--- TEST 3: prescaler=9 (th=10, 100 real clocks) ---\r\n");
    g_irq_count = 0;
    wreg(REG_PRESCALER, 9);
    wreg(REG_THRESHOLD, 10);
    wreg(REG_CONDITION, 10);
    wreg(REG_CTRL, CTRL_START_MASK);
    for (volatile u32 i = 0; i < 200000 && g_irq_count == 0; i++);
    pass = (g_irq_count >= 1);
    xil_printf("  %s (irq=%d, count=%d)\r\n\r\n", pass ? "PASS" : "FAIL",
               g_irq_count, rreg(REG_COUNT));
    Xil_Out32(DDR_RESULTS + 8, pass);
    wreg(REG_CTRL, CTRL_CLR);
    wreg(REG_CTRL, 0);
    wreg(REG_PRESCALER, 0);

    /* ===== TEST 4: scratch R/W ===== */
    xil_printf("--- TEST 4: scratch registers ---\r\n");
    wreg(REG_SCRATCH0, 0xDEADBEEF);
    wreg(REG_SCRATCH1, 0xCAFEBABE);
    wreg(REG_SCRATCH2, 0x12345678);
    wreg(REG_SCRATCH3, 0xA5A5A5A5);
    pass = (rreg(REG_SCRATCH0) == 0xDEADBEEF) &&
           (rreg(REG_SCRATCH1) == 0xCAFEBABE) &&
           (rreg(REG_SCRATCH2) == 0x12345678) &&
           (rreg(REG_SCRATCH3) == 0xA5A5A5A5);
    xil_printf("  S0=0x%08x S1=0x%08x S2=0x%08x S3=0x%08x\r\n",
               rreg(REG_SCRATCH0), rreg(REG_SCRATCH1),
               rreg(REG_SCRATCH2), rreg(REG_SCRATCH3));
    xil_printf("  %s\r\n\r\n", pass ? "PASS" : "FAIL");
    Xil_Out32(DDR_RESULTS + 12, pass);

    /* ===== TEST 5: VERSION ===== */
    xil_printf("--- TEST 5: VERSION register ---\r\n");
    u32 ver = rreg(REG_VERSION);
    pass = (ver == 0x20000001);
    xil_printf("  VERSION = 0x%08x  %s\r\n\r\n", ver, pass ? "PASS" : "FAIL");
    Xil_Out32(DDR_RESULTS + 16, pass);

    /* Summary */
    u32 hw_irq = rreg(REG_IRQ_COUNT);
    xil_printf("==========================================\r\n");
    xil_printf("  HW IRQ_COUNT = %d\r\n", hw_irq);
    xil_printf("  VERSION      = 0x%08x\r\n", ver);
    xil_printf("==========================================\r\n");
    xil_printf("  DONE\r\n");

    Xil_Out32(DDR_MARKER, 0xDEADBEEF);

    while (1);
    return 0;
}
