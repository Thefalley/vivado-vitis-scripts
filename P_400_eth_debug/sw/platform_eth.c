/*
 * platform_eth.c - Platform init for Zynq bare-metal lwIP
 *
 * Sets up:
 *   - CPU caches
 *   - SCU private timer (250 ms tick for lwIP TCP timers)
 *   - GIC interrupt controller
 */

#include "platform_eth.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xscugic.h"
#include "xscutimer.h"
#include "lwip/tcp.h"

#define INTC_DEVICE_ID   XPAR_SCUGIC_SINGLE_DEVICE_ID
#define TIMER_DEVICE_ID  XPAR_XSCUTIMER_0_DEVICE_ID
#define TIMER_IRPT_INTR  XPAR_SCUTIMER_INTR

static XScuGic   IntcInstance;
static XScuTimer  TimerInstance;

/* lwIP timer flags - polled in main loop */
volatile int TcpFastTmrFlag = 0;
volatile int TcpSlowTmrFlag = 0;

/* ---- Timer ISR (fires every 250 ms) ---- */
static void timer_callback(XScuTimer *inst)
{
    static int odd = 1;

    TcpFastTmrFlag = 1;     /* tcp_fasttmr() every 250 ms */
    odd = !odd;
    if (odd)
        TcpSlowTmrFlag = 1; /* tcp_slowtmr() every 500 ms */

    XScuTimer_ClearInterruptStatus(inst);
}

/* ---- Setup ---- */
static void setup_timer(void)
{
    XScuTimer_Config *cfg;

    cfg = XScuTimer_LookupConfig(TIMER_DEVICE_ID);
    XScuTimer_CfgInitialize(&TimerInstance, cfg, cfg->BaseAddr);

    /* 250 ms reload: CPU_CLK / 2 (prescaler=0 -> timer clk = CPU_CLK/2)
       But the SCU timer counts at PERIPHCLK = CPU_CLK / 2.
       So load = (CPU_CLK / 2) / 4 = CPU_CLK / 8   for 250 ms   */
    XScuTimer_LoadTimer(&TimerInstance,
                        XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ / 8);
    XScuTimer_EnableAutoReload(&TimerInstance);
    XScuTimer_Start(&TimerInstance);
}

static void setup_interrupts(void)
{
    XScuGic_Config *cfg;

    cfg = XScuGic_LookupConfig(INTC_DEVICE_ID);
    XScuGic_CfgInitialize(&IntcInstance, cfg, cfg->CpuBaseAddress);

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler,
        &IntcInstance);

    /* Connect timer interrupt */
    XScuGic_Connect(&IntcInstance, TIMER_IRPT_INTR,
        (Xil_ExceptionHandler)timer_callback,
        (void *)&TimerInstance);
    XScuGic_Enable(&IntcInstance, TIMER_IRPT_INTR);

    XScuTimer_EnableInterrupt(&TimerInstance);
}

/* ---- Public API ---- */
void init_platform(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    setup_timer();
    setup_interrupts();
}

void cleanup_platform(void)
{
    Xil_ICacheDisable();
    Xil_DCacheDisable();
}

void platform_enable_interrupts(void)
{
    Xil_ExceptionEnableMask(XIL_EXCEPTION_IRQ);
}

XScuGic *get_gic_instance(void)
{
    return &IntcInstance;
}
