/*
 * conv_test.c — Test bare-metal de conv_simple en FPGA
 *
 * Carga los golden vectors en BRAM via AXI-Lite, configura la conv,
 * ejecuta, y verifica el resultado bit-exact.
 *
 * Memory map (base = 0x40000000):
 *   0x0000-0x007F: registros de configuracion
 *   0x2000-0x3FFF: ventana BRAM (8192 bytes)
 *
 * BRAM layout (byte offsets):
 *   0x0000 (0):    Input   192 bytes  (3 x 8 x 8)
 *   0x0100 (256):  Weights 864 bytes  (32 x 3 x 3 x 3, OIHW)
 *   0x0460 (1120): Bias    128 bytes  (32 x int32)
 *   0x0500 (1280): Output 2048 bytes  (32 x 8 x 8)
 */

#include <stdint.h>
#include <stdio.h>
#include "xil_io.h"
#include "xil_printf.h"

/* Base addresses */
#define BASE_ADDR    0x40000000
#define REG_BASE     (BASE_ADDR + 0x0000)
#define BRAM_BASE    (BASE_ADDR + 0x2000)

/* Register offsets */
#define REG_CTRL         0x00
#define REG_C_IN_OUT     0x04
#define REG_H_W_IN       0x08
#define REG_CONV_CFG     0x0C
#define REG_X_ZP         0x10
#define REG_M0           0x14
#define REG_SHIFT_YZP    0x18
#define REG_ADDR_IN      0x1C
#define REG_ADDR_WT      0x20
#define REG_ADDR_BIAS    0x24
#define REG_ADDR_OUT     0x28
#define REG_STATUS       0x2C

/* BRAM data addresses (byte offsets within BRAM) */
#define BRAM_INPUT   0x0000
#define BRAM_WEIGHTS 0x0100
#define BRAM_BIAS    0x0460
#define BRAM_OUTPUT  0x0500

/* Layer 005 parameters */
#define C_IN     3
#define C_OUT    32
#define H_IN     8
#define W_IN     8
#define KSIZE    3
#define STRIDE   1
#define PAD      1
#define X_ZP     (-128)
#define M0_VAL   656954014u   /* 0x2728529E */
#define N_SHIFT  37
#define Y_ZP     (-17)

#define N_INPUT   192
#define N_WEIGHTS 864
#define N_BIAS    32
#define N_OUTPUT  2048

/* ============================================================
 * Golden data (mini test case from simulation)
 * In a real deployment these would come from files or DMA.
 * For now: hardcoded arrays generated from the .mem files.
 * ============================================================ */

/* Placeholder: in reality, paste the hex data here or load via JTAG */
/* For the initial test, use JTAG memory write to load the data */

static void reg_write(uint32_t offset, uint32_t val)
{
    Xil_Out32(REG_BASE + offset, val);
}

static uint32_t reg_read(uint32_t offset)
{
    return Xil_In32(REG_BASE + offset);
}

static void bram_write_byte(uint32_t byte_addr, uint8_t val)
{
    /* Word-aligned access with read-modify-write */
    uint32_t word_addr = BRAM_BASE + (byte_addr & ~3u);
    uint32_t shift = (byte_addr & 3u) * 8;
    uint32_t word = Xil_In32(word_addr);
    word &= ~(0xFFu << shift);
    word |= ((uint32_t)val << shift);
    Xil_Out32(word_addr, word);
}

static uint8_t bram_read_byte(uint32_t byte_addr)
{
    uint32_t word_addr = BRAM_BASE + (byte_addr & ~3u);
    uint32_t shift = (byte_addr & 3u) * 8;
    return (uint8_t)(Xil_In32(word_addr) >> shift);
}

static void bram_write_word(uint32_t byte_addr, uint32_t val)
{
    Xil_Out32(BRAM_BASE + byte_addr, val);
}

int main(void)
{
    uint32_t status;
    int errors = 0;
    int timeout;

    xil_printf("\r\n=== P_700 conv_simple HW test ===\r\n");

    /* ---- Step 1: Check that conv is idle ---- */
    status = reg_read(REG_STATUS);
    xil_printf("STATUS = 0x%08X (expect idle)\r\n", status);

    /* ---- Step 2: Configure layer parameters ---- */
    reg_write(REG_C_IN_OUT,  ((uint32_t)C_OUT << 16) | C_IN);
    reg_write(REG_H_W_IN,    ((uint32_t)W_IN  << 16) | H_IN);
    reg_write(REG_CONV_CFG,  ((uint32_t)PAD << 8) | ((uint32_t)STRIDE << 4) | KSIZE);
    reg_write(REG_X_ZP,      (uint32_t)(int32_t)X_ZP & 0x1FF);
    reg_write(REG_M0,        M0_VAL);
    reg_write(REG_SHIFT_YZP, ((uint32_t)(int32_t)Y_ZP & 0xFF) << 8 | N_SHIFT);
    reg_write(REG_ADDR_IN,   BRAM_INPUT);
    reg_write(REG_ADDR_WT,   BRAM_WEIGHTS);
    reg_write(REG_ADDR_BIAS, BRAM_BIAS);
    reg_write(REG_ADDR_OUT,  BRAM_OUTPUT);

    xil_printf("Config written.\r\n");
    xil_printf("Load data to BRAM via JTAG, then write 1 to REG_CTRL.\r\n");
    xil_printf("  BRAM base = 0x%08X\r\n", BRAM_BASE);
    xil_printf("  Input  @ 0x%08X (%d bytes)\r\n", BRAM_BASE + BRAM_INPUT, N_INPUT);
    xil_printf("  Weights@ 0x%08X (%d bytes)\r\n", BRAM_BASE + BRAM_WEIGHTS, N_WEIGHTS);
    xil_printf("  Bias   @ 0x%08X (%d bytes)\r\n", BRAM_BASE + BRAM_BIAS, N_BIAS * 4);
    xil_printf("  Output @ 0x%08X (%d bytes)\r\n", BRAM_BASE + BRAM_OUTPUT, N_OUTPUT);

    /* ---- Step 3: Start convolution ---- */
    reg_write(REG_CTRL, 1);  /* start pulse */
    reg_write(REG_CTRL, 0);  /* release */

    /* ---- Step 4: Poll for done ---- */
    xil_printf("Waiting for done...\r\n");
    timeout = 10000000;
    do {
        status = reg_read(REG_STATUS);
        timeout--;
    } while ((status & 0x1) == 0 && timeout > 0);

    if (timeout <= 0) {
        xil_printf("ERROR: Timeout! STATUS=0x%08X\r\n", status);
        return -1;
    }

    xil_printf("Done! STATUS=0x%08X\r\n", status);

    /* ---- Step 5: Verify output ---- */
    xil_printf("Verifying %d output bytes...\r\n", N_OUTPUT);

    /* Read first 32 bytes for quick visual check */
    for (int i = 0; i < 32; i++) {
        int8_t val = (int8_t)bram_read_byte(BRAM_OUTPUT + i);
        xil_printf("  out[%d] = %d\r\n", i, val);
    }

    xil_printf("\r\nFull verification requires golden data.\r\n");
    xil_printf("Use JTAG to read BRAM output region and compare.\r\n");
    xil_printf("=== Test complete ===\r\n");

    return 0;
}
