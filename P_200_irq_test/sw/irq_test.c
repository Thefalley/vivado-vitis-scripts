/*
 * irq_test.c - Test de interrupciones PL -> PS en ZedBoard
 *
 * Configura la FSM irq_top via AXI-Lite, arranca el conteo,
 * y verifica que la interrupcion llega correctamente al GIC del ARM.
 *
 * TEST 1: threshold=100, condition=100 -> IRQ debe disparar
 * TEST 2: threshold=100, condition=50  -> IRQ NO debe disparar
 * TEST 3: re-arranque -> segundo IRQ, irq_count=2
 */

#include "xscugic.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xparameters.h"

/* ---- Base address (from Vivado address map) ---- */
/* Try auto-generated parameter first, fallback to typical GP0 addr */
#ifdef XPAR_IRQ_TOP_0_S_AXI_BASEADDR
#define IRQ_BASE  XPAR_IRQ_TOP_0_S_AXI_BASEADDR
#else
#define IRQ_BASE  0x40000000
#endif

/* Register offsets */
#define REG_CTRL       0x00
#define REG_THRESHOLD  0x04
#define REG_CONDITION  0x08
#define REG_STATUS     0x0C
#define REG_COUNT      0x10
#define REG_IRQ_COUNT  0x14

/* Zynq PL interrupt: IRQ_F2P[0] = SPI ID 61 */
#define PL_IRQ_ID      61

/* GIC */
#define INTC_DEVICE_ID XPAR_SCUGIC_SINGLE_DEVICE_ID

/* ---- Globals ---- */
static XScuGic Intc;
static volatile u32 g_irq_count = 0;

/* ---- Helpers ---- */
static inline void reg_write(u32 offset, u32 val) {
    Xil_Out32(IRQ_BASE + offset, val);
}
static inline u32 reg_read(u32 offset) {
    return Xil_In32(IRQ_BASE + offset);
}

/* ---- ISR ---- */
static void IrqHandler(void *CallbackRef)
{
    u32 status   = reg_read(REG_STATUS);
    u32 count    = reg_read(REG_COUNT);
    u32 irq_cnt  = reg_read(REG_IRQ_COUNT);

    xil_printf("  [ISR] status=0x%08x count=%d irq_count=%d\r\n",
               status, count, irq_cnt);

    /* Clear interrupt: write irq_clear bit, then release */
    reg_write(REG_CTRL, 0x2);
    reg_write(REG_CTRL, 0x0);

    g_irq_count++;
}

/* ---- Interrupt setup ---- */
static int SetupInterrupts(void)
{
    XScuGic_Config *cfg;
    int status;

    cfg = XScuGic_LookupConfig(INTC_DEVICE_ID);
    if (!cfg) return XST_FAILURE;

    status = XScuGic_CfgInitialize(&Intc, cfg, cfg->CpuBaseAddress);
    if (status != XST_SUCCESS) return status;

    /* High-level sensitive trigger for PL interrupt */
    XScuGic_SetPriorityTriggerType(&Intc, PL_IRQ_ID, 0xA0, 0x1);

    status = XScuGic_Connect(&Intc, PL_IRQ_ID,
                             (Xil_InterruptHandler)IrqHandler, NULL);
    if (status != XST_SUCCESS) return status;

    XScuGic_Enable(&Intc, PL_IRQ_ID);

    /* ARM exception table */
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler, &Intc);
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}

/* ---- Main ---- */
int main(void)
{
    xil_printf("\r\n==========================================\r\n");
    xil_printf("  P_200 IRQ Test (ZedBoard)\r\n");
    xil_printf("  Base addr: 0x%08x\r\n", IRQ_BASE);
    xil_printf("==========================================\r\n\r\n");

    /* Setup GIC + handler */
    if (SetupInterrupts() != XST_SUCCESS) {
        xil_printf("ERROR: GIC init failed\r\n");
        return -1;
    }
    xil_printf("GIC configurado, IRQ %d habilitado\r\n\r\n", PL_IRQ_ID);

    /* ===== TEST 1: threshold=100, condition=100 -> IRQ ===== */
    xil_printf("--- TEST 1: threshold=100, condition=100 ---\r\n");
    g_irq_count = 0;

    reg_write(REG_THRESHOLD, 100);
    reg_write(REG_CONDITION, 100);
    reg_write(REG_CTRL, 0x1);  /* start */

    /* Wait for ISR (at 100 MHz, 100 cycles = 1 us) */
    for (volatile u32 i = 0; i < 100000 && g_irq_count == 0; i++);

    if (g_irq_count >= 1) {
        xil_printf("  PASS: IRQ recibido (%d veces)\r\n\r\n", g_irq_count);
    } else {
        xil_printf("  FAIL: IRQ no llego\r\n\r\n");
    }

    /* ===== TEST 2: threshold=100, condition=50 -> NO IRQ ===== */
    xil_printf("--- TEST 2: threshold=100, condition=50 (no IRQ) ---\r\n");
    g_irq_count = 0;

    reg_write(REG_THRESHOLD, 100);
    reg_write(REG_CONDITION, 50);
    reg_write(REG_CTRL, 0x1);  /* start */

    /* Wait a while */
    for (volatile u32 i = 0; i < 500000; i++);

    /* Stop FSM */
    reg_write(REG_CTRL, 0x0);

    if (g_irq_count == 0) {
        xil_printf("  PASS: no IRQ (correcto)\r\n\r\n");
    } else {
        xil_printf("  FAIL: IRQ disparo cuando no debia (%d)\r\n\r\n", g_irq_count);
    }

    /* ===== TEST 3: condition=100 otra vez -> 2do IRQ ===== */
    xil_printf("--- TEST 3: restart, condition=100 ---\r\n");
    g_irq_count = 0;

    reg_write(REG_CONDITION, 100);
    reg_write(REG_CTRL, 0x1);

    for (volatile u32 i = 0; i < 100000 && g_irq_count == 0; i++);

    /* Read HW irq_count register */
    u32 hw_irq_cnt = reg_read(REG_IRQ_COUNT);

    if (g_irq_count >= 1) {
        xil_printf("  PASS: 2do IRQ recibido (HW irq_count=%d)\r\n\r\n", hw_irq_cnt);
    } else {
        xil_printf("  FAIL: 2do IRQ no llego\r\n\r\n");
    }

    /* Stop */
    reg_write(REG_CTRL, 0x0);

    /* ===== Summary ===== */
    xil_printf("==========================================\r\n");
    xil_printf("  HW registers finales:\r\n");
    xil_printf("    STATUS    = 0x%08x\r\n", reg_read(REG_STATUS));
    xil_printf("    COUNT     = %d\r\n",     reg_read(REG_COUNT));
    xil_printf("    IRQ_COUNT = %d\r\n",     reg_read(REG_IRQ_COUNT));
    xil_printf("==========================================\r\n");
    xil_printf("  DONE\r\n");

    /* Marker for JTAG verification: write 0xDEAD at known DDR address */
    Xil_Out32(0x00100000, 0xDEADBEEF);

    while (1);
    return 0;
}
