/*
 * dm_test.c - AXI DataMover S2MM test (bare-metal, ZedBoard)
 * P_500_datamover
 *
 * Test flow:
 *   1. Fill DDR[SRC_ADDR] with known pattern
 *   2. Clear DDR[DST_ADDR]
 *   3. Configure dm_s2mm_ctrl via GPIO (dest_addr + byte_count)
 *   4. Trigger DataMover command (start pulse)
 *   5. Start DMA MM2S to stream data from SRC_ADDR
 *   6. Wait for completion
 *   7. Verify DDR[DST_ADDR] matches DDR[SRC_ADDR]
 *
 * NOTE: Update base addresses after checking Vivado address editor!
 *       Run: Address Editor -> check assigned addresses
 */

#include <stdio.h>
#include <stdint.h>
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"

/* ============================================================
 * Base addresses (CHECK THESE in Vivado Address Editor!)
 * These are typical defaults for ZedBoard GP0 peripherals.
 * ============================================================ */
#define DMA_BASE        0x40400000   /* axi_dma_0 S_AXI_LITE */
#define GPIO_ADDR_BASE  0x41200000   /* gpio_addr (dest address) */
#define GPIO_CTRL_BASE  0x41210000   /* gpio_ctrl (ctrl + status) */

/* DMA MM2S registers (offset from DMA_BASE) */
#define MM2S_DMACR      0x00   /* DMA Control */
#define MM2S_DMASR      0x04   /* DMA Status */
#define MM2S_SA         0x18   /* Source Address */
#define MM2S_LENGTH     0x28   /* Transfer Length (bytes) */

/* GPIO registers */
#define GPIO_DATA       0x00   /* Channel 1 data */
#define GPIO_DATA2      0x08   /* Channel 2 data */

/* DDR test addresses (must be in PS DDR range: 0x00100000 - 0x1FFFFFFF) */
#define SRC_ADDR        0x01000000   /* 16 MB offset */
#define DST_ADDR        0x02000000   /* 32 MB offset */
#define XFER_BYTES      256          /* Transfer size in bytes */

/* ============================================================
 * Helper functions
 * ============================================================ */

static void dma_mm2s_reset(void)
{
    Xil_Out32(DMA_BASE + MM2S_DMACR, 0x4);  /* Reset */
    while (Xil_In32(DMA_BASE + MM2S_DMACR) & 0x4)
        ;  /* Wait for reset complete */
}

static void dma_mm2s_start(uint32_t src_addr, uint32_t length)
{
    /* Enable DMA, no interrupts for simplicity */
    Xil_Out32(DMA_BASE + MM2S_DMACR, 0x1);

    /* Set source address */
    Xil_Out32(DMA_BASE + MM2S_SA, src_addr);

    /* Set transfer length (this starts the transfer) */
    Xil_Out32(DMA_BASE + MM2S_LENGTH, length);
}

static int dma_mm2s_wait(void)
{
    uint32_t status;
    int timeout = 1000000;

    do {
        status = Xil_In32(DMA_BASE + MM2S_DMASR);
        if (status & 0x70) {  /* Error bits */
            xil_printf("ERROR: DMA MM2S error, DMASR=0x%08X\r\n", status);
            return -1;
        }
        timeout--;
    } while (!(status & 0x2) && timeout > 0);  /* Idle bit */

    if (timeout <= 0) {
        xil_printf("ERROR: DMA MM2S timeout, DMASR=0x%08X\r\n", status);
        return -2;
    }
    return 0;
}

static void dm_ctrl_configure(uint32_t dest_addr, uint32_t byte_count)
{
    /* Set destination address via GPIO */
    Xil_Out32(GPIO_ADDR_BASE + GPIO_DATA, dest_addr);

    /* Set byte count (bits [22:0]) without start bit */
    Xil_Out32(GPIO_CTRL_BASE + GPIO_DATA, byte_count & 0x7FFFFF);
}

static void dm_ctrl_start(uint32_t byte_count)
{
    /* Assert start bit [31] + byte_count [22:0] */
    Xil_Out32(GPIO_CTRL_BASE + GPIO_DATA, (1u << 31) | (byte_count & 0x7FFFFF));

    /* Small delay for edge detection */
    volatile int i;
    for (i = 0; i < 10; i++) ;

    /* Deassert start bit */
    Xil_Out32(GPIO_CTRL_BASE + GPIO_DATA, byte_count & 0x7FFFFF);
}

static uint32_t dm_ctrl_status(void)
{
    return Xil_In32(GPIO_CTRL_BASE + GPIO_DATA2);
}

/* ============================================================
 * Main
 * ============================================================ */
int main(void)
{
    uint32_t *src = (uint32_t *)SRC_ADDR;
    uint32_t *dst = (uint32_t *)DST_ADDR;
    int n_words = XFER_BYTES / 4;
    int errors = 0;

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf("P_500 DataMover S2MM Test\r\n");
    xil_printf("========================================\r\n");
    xil_printf("SRC: 0x%08X  DST: 0x%08X  SIZE: %d bytes\r\n",
               SRC_ADDR, DST_ADDR, XFER_BYTES);

    /* 1. Fill source with test pattern */
    xil_printf("[1] Filling source buffer...\r\n");
    for (int i = 0; i < n_words; i++)
        src[i] = 0xDEAD0000 | i;

    /* 2. Clear destination */
    xil_printf("[2] Clearing destination buffer...\r\n");
    for (int i = 0; i < n_words; i++)
        dst[i] = 0;

    /* Flush cache so DMA/DataMover see correct data */
    Xil_DCacheFlush();

    /* 3. Reset DMA */
    xil_printf("[3] Resetting DMA...\r\n");
    dma_mm2s_reset();

    /* 4. Configure DataMover S2MM command (via dm_s2mm_ctrl) */
    xil_printf("[4] Configuring DataMover: dest=0x%08X, BTT=%d\r\n",
               DST_ADDR, XFER_BYTES);
    dm_ctrl_configure(DST_ADDR, XFER_BYTES);

    /* 5. Start DataMover command (sends 72-bit cmd to DataMover) */
    xil_printf("[5] Starting DataMover S2MM command...\r\n");
    dm_ctrl_start(XFER_BYTES);

    /* 6. Start DMA MM2S (this feeds AXI-Stream data to DataMover) */
    xil_printf("[6] Starting DMA MM2S transfer...\r\n");
    dma_mm2s_start(SRC_ADDR, XFER_BYTES);

    /* 7. Wait for DMA to finish sending data */
    xil_printf("[7] Waiting for DMA MM2S...\r\n");
    if (dma_mm2s_wait() != 0) {
        xil_printf("FAIL: DMA MM2S error\r\n");
        return -1;
    }

    /* 8. Wait for DataMover to finish writing */
    xil_printf("[8] Waiting for DataMover S2MM...\r\n");
    int timeout = 1000000;
    uint32_t status;
    do {
        status = dm_ctrl_status();
        timeout--;
    } while (!(status & 0x2) && timeout > 0);  /* bit[1] = done */

    if (timeout <= 0) {
        xil_printf("FAIL: DataMover timeout, status=0x%08X\r\n", status);
        return -1;
    }

    if (status & 0x4) {
        xil_printf("FAIL: DataMover error, status=0x%08X\r\n", status);
        xil_printf("  Raw STS byte: 0x%02X\r\n", (status >> 4) & 0xFF);
        return -1;
    }

    xil_printf("  DataMover done, status=0x%08X\r\n", status);

    /* 9. Invalidate cache to see DataMover's writes */
    Xil_DCacheInvalidateRange(DST_ADDR, XFER_BYTES);

    /* 10. Verify */
    xil_printf("[9] Verifying data...\r\n");
    for (int i = 0; i < n_words; i++) {
        if (dst[i] != src[i]) {
            if (errors < 8) {
                xil_printf("  MISMATCH [%d]: expected=0x%08X got=0x%08X\r\n",
                           i, src[i], dst[i]);
            }
            errors++;
        }
    }

    xil_printf("\r\n");
    if (errors == 0) {
        xil_printf("PASS: %d words verified OK\r\n", n_words);
    } else {
        xil_printf("FAIL: %d / %d words mismatched\r\n", errors, n_words);
    }
    xil_printf("========================================\r\n");

    return errors;
}
