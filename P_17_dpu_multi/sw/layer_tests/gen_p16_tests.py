#!/usr/bin/env python3
"""Generate P_16 flow layer tests from P_13 sources.

Reads each P_13 layer_XXX_test.c, extracts:
  - layer metadata (c_in, c_out, h_in, w_in, k, stride, pads, x_zp, w_zp, y_zp,
    m0, n_shift)
  - input_data[], weight_data[] (already OHWI in P_13), bias_data[],
    expected_full[]
and emits a P_16 flow test (DMA MM2S -> conv -> DataMover S2MM).

BRAM layout in P_16: output at 0x000 (read by DRAIN), then input, weights,
bias packed contiguously after output region. DDR source buffer mirrors BRAM.
"""
import re
import os
import sys

SRC_DIR = r"C:/project/vivado/P_13_conv_test/sw/layer_tests"
DST_DIR = r"C:/project/vivado/P_16_conv_datamover/sw/layer_tests"

# Full 110-layer port (P_13 -> P_16).
LAYERS = list(range(110))

# Manually-ported layers: preserve existing *_test.c if the generator output
# does not match byte-identically; the auto version is written as *_auto.c
# with a discrepancy note.
PRESERVED = {5, 38, 43, 45, 47, 49, 57}

BRAM_LIMIT_BYTES = 4096


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def extract_define(text, name):
    m = re.search(r"^\s*#define\s+" + re.escape(name) + r"\s+([^\s/]+)", text,
                  re.MULTILINE)
    if not m:
        return None
    return m.group(1)


def extract_define_signed(text, name):
    """#define X (u32)(s32)(-109) & 0x1FF style doesn't exist for these; direct #define NUM."""
    v = extract_define(text, name)
    if v is None:
        return None
    return int(v)


def extract_array(text, name, is_s32=False):
    """Extract body of 'static const sX name[N] = { ... };' as list of ints."""
    # Find declaration
    m = re.search(r"static\s+const\s+s\d+\s+" + re.escape(name)
                  + r"\s*\[[^\]]+\]\s*=\s*\{([^}]*)\}\s*;",
                  text, re.DOTALL)
    if not m:
        raise RuntimeError(f"Array {name} not found")
    body = m.group(1)
    # strip comments
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    # Extract all signed integers (and unsigned suffix u)
    tokens = re.findall(r"-?\d+[uU]?", body)
    out = []
    for t in tokens:
        t = t.rstrip("uU")
        out.append(int(t))
    return out


def _match_zp(text, reg):
    # Either "(u32)(s32)(-NN) & 0xMASK" or plain "NN" (unsigned positive)
    m = re.search(re.escape(reg) + r",\s*\(u32\)\(s32\)\((-?\d+)\)", text)
    if m:
        return int(m.group(1))
    m = re.search(re.escape(reg) + r",\s*(-?\d+)\s*\)", text)
    if m:
        return int(m.group(1))
    raise RuntimeError(f"Could not parse {reg}")


def extract_quant(text):
    x_zp = _match_zp(text, "REG_X_ZP")
    w_zp = int(re.search(r"REG_W_ZP,\s*(-?\d+)", text).group(1))
    m0 = int(re.search(r"REG_M0,\s*(\d+)u?", text).group(1))
    nsh = int(re.search(r"REG_N_SHIFT,\s*(\d+)", text).group(1))
    y_zp = _match_zp(text, "REG_Y_ZP")
    return x_zp, w_zp, m0, nsh, y_zp


def fmt_s8_array(name, data):
    lines = [f"static const s8 {name}[{len(data)}] = {{"]
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        lines.append("    " + ", ".join(f"{v:4d}" for v in chunk) + ",")
    # remove trailing comma on last entry line
    lines[-1] = lines[-1].rstrip(",")
    lines.append("};")
    return "\n".join(lines)


def fmt_s32_array(name, data):
    lines = [f"static const s32 {name}[{len(data)}] = {{"]
    for i in range(0, len(data), 8):
        chunk = data[i:i+8]
        lines.append("    " + ", ".join(f"{v:11d}" for v in chunk) + ",")
    lines[-1] = lines[-1].rstrip(",")
    lines.append("};")
    return "\n".join(lines)


TEMPLATE = r'''/*
 * layer_{LAYER:03d}_test.c  --  P_16 flow port of P_13 layer {LAYER:03d} test
 *
 * Port strategy:
 *   - BRAM layout repositioned so OUTPUT is at BRAM addr 0x000 (required by
 *     the P_16 conv_stream_wrapper -- DRAIN reads sequentially from addr 0).
 *   - Input, weights, bias placed contiguously after the output region.
 *   - DDR source buffer mirrors the full BRAM image so a single DMA MM2S
 *     transfer populates everything (output area is initialized to zero).
 *   - Weights are copied verbatim: P_13 layer tests already store them in
 *     OHWI order, which is what conv_engine_v3 expects.
 *   - conv_engine_v3 + DataMover S2MM flow identical to conv_dm_test.c.
 *
 * Layer params: c_in={C_IN} c_out={C_OUT} {H_IN}x{W_IN} -> {H_OUT}x{W_OUT}
 *               k={KH}x{KW} stride={STRIDE_INT}
 *               pad=[T={PAD_T},B={PAD_B},L={PAD_L},R={PAD_R}]
 * Quant: x_zp={X_ZP} w_zp={W_ZP} y_zp={Y_ZP} M0={M0}u n_shift={N_SHIFT}
 *
 * BRAM layout (total {TOTAL_BYTES} bytes):
 *   Output  @ 0x{BRAM_OUTPUT_ADDR:03X} ({OUTPUT_BYTES} B)
 *   Input   @ 0x{BRAM_INPUT_ADDR:03X} ({INPUT_BYTES} B)
 *   Weights @ 0x{BRAM_WEIGHTS_ADDR:03X} ({WEIGHT_BYTES} B)
 *   Bias    @ 0x{BRAM_BIAS_ADDR:03X} ({BIAS_BYTES} B)
 *   LOAD words = {LOAD_N_WORDS}, DRAIN words = {DRAIN_N_WORDS}
 *
 * Auto-generated from P_13 source by gen_p16_tests.py.
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

/* ========================================================================= */
/* Address definitions (same as conv_dm_test.c)                              */
/* ========================================================================= */
#ifndef XPAR_CONV_STREAM_WRAPPER_0_BASEADDR
#define XPAR_CONV_STREAM_WRAPPER_0_BASEADDR 0x40000000
#endif
#define CONV_BASE   XPAR_CONV_STREAM_WRAPPER_0_BASEADDR

#define DMA_BASEADDR    XPAR_AXIDMA_0_BASEADDR

#ifndef XPAR_GPIO_ADDR_BASEADDR
#define XPAR_GPIO_ADDR_BASEADDR 0x41200000
#endif
#ifndef XPAR_GPIO_CTRL_BASEADDR
#define XPAR_GPIO_CTRL_BASEADDR 0x41210000
#endif
#define GPIO_ADDR_BASE  XPAR_GPIO_ADDR_BASEADDR
#define GPIO_CTRL_BASE  XPAR_GPIO_CTRL_BASEADDR

#define DDR_SRC_ADDR    0x10000000
#define DDR_DST_ADDR    0x10100000
#define RESULT_ADDR     0x10200000
#define MAGIC_DONE      0xDEAD1234
#define LAYER_IDX       {LAYER}

/* Register map */
#define REG_CTRL         0x00
#define REG_N_WORDS      0x04
#define REG_C_IN         0x08
#define REG_C_OUT        0x0C
#define REG_H_IN         0x10
#define REG_W_IN         0x14
#define REG_KSP          0x18
#define REG_X_ZP         0x1C
#define REG_W_ZP         0x20
#define REG_M0           0x24
#define REG_N_SHIFT      0x28
#define REG_Y_ZP         0x2C
#define REG_ADDR_INPUT   0x30
#define REG_ADDR_WEIGHTS 0x34
#define REG_ADDR_BIAS    0x38
#define REG_ADDR_OUTPUT  0x3C
#define REG_IC_TILE_SIZE 0x40
#define REG_PAD_TOP      0x44
#define REG_PAD_BOTTOM   0x48
#define REG_PAD_LEFT     0x4C
#define REG_PAD_RIGHT    0x50

#define FSM_IDLE   0
#define FSM_LOAD   1
#define FSM_CONV   2
#define FSM_DRAIN  3

/* BRAM layout (P_16 -- output MUST be at 0x000) */
#define BRAM_OUTPUT_ADDR   0x{BRAM_OUTPUT_ADDR:03X}
#define BRAM_INPUT_ADDR    0x{BRAM_INPUT_ADDR:03X}
#define BRAM_WEIGHTS_ADDR  0x{BRAM_WEIGHTS_ADDR:03X}
#define BRAM_BIAS_ADDR     0x{BRAM_BIAS_ADDR:03X}

/* Layer params */
#define C_IN    {C_IN}
#define C_OUT   {C_OUT}
#define H_IN    {H_IN}
#define W_IN    {W_IN}
#define KH      {KH}
#define KW      {KW}
#define KSIZE   {KSIZE}    /* 0=1x1, 2=3x3 */
#define STRIDE  {STRIDE}   /* 0=stride1, 1=stride2 */
#define PAD_T   {PAD_T}
#define PAD_B   {PAD_B}
#define PAD_L   {PAD_L}
#define PAD_R   {PAD_R}
#define H_OUT   {H_OUT}
#define W_OUT   {W_OUT}

/* Transfer sizes */
#define INPUT_BYTES     {INPUT_BYTES}
#define WEIGHT_BYTES    {WEIGHT_BYTES}
#define BIAS_BYTES      {BIAS_BYTES}
#define BIAS_WORDS      {BIAS_WORDS}
#define OUTPUT_BYTES    {OUTPUT_BYTES}
#define LOAD_N_WORDS    {LOAD_N_WORDS}
#define LOAD_BYTES      (LOAD_N_WORDS * 4)
#define DRAIN_N_WORDS   {DRAIN_N_WORDS}
#define DRAIN_BYTES     (DRAIN_N_WORDS * 4)

/* ========================================================================= */
/* Test data (copied verbatim from P_13 layer_{LAYER:03d}_test.c)            */
/* ========================================================================= */

{INPUT_ARRAY}

/* Weights in OHWI order (already transposed in P_13 source) */
{WEIGHT_ARRAY}

{BIAS_ARRAY}

{EXPECTED_ARRAY}

/* ========================================================================= */
/* Helpers                                                                   */
/* ========================================================================= */
static void conv_write(u32 offset, u32 val) {{ Xil_Out32(CONV_BASE + offset, val); }}
static u32  conv_read (u32 offset)          {{ return Xil_In32(CONV_BASE + offset); }}
static int  get_fsm_state(void) {{ return (int)((conv_read(REG_CTRL) >> 10) & 0x3); }}
static void gpio_addr_write(u32 val)        {{ Xil_Out32(GPIO_ADDR_BASE + 0x00, val); }}
static void gpio_ctrl_write(u32 val)        {{ Xil_Out32(GPIO_CTRL_BASE + 0x00, val); }}
static u32  gpio_ctrl_read_status(void)     {{ return Xil_In32(GPIO_CTRL_BASE + 0x08); }}

/* ========================================================================= */
/* Main                                                                      */
/* ========================================================================= */
static XAxiDma dma_inst;

int main(void)
{{
    int status;
    XAxiDma_Config *cfg;
    int errors = 0;
    int total_checks = 0;
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    u32 *src = (u32 *)DDR_SRC_ADDR;
    u8  *dst = (u8 *)DDR_DST_ADDR;

    res[0] = 0xAAAA0000 | LAYER_IDX;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\r\n=== P_16 Layer {LAYER:03d} test ===\r\n");
    xil_printf("  c_in=%d c_out=%d %dx%d->%dx%d k=%dx%d stride=%d pad=[%d,%d,%d,%d]\r\n",
               C_IN, C_OUT, H_IN, W_IN, H_OUT, W_OUT, KH, KW,
               {STRIDE_INT}, PAD_T, PAD_B, PAD_L, PAD_R);
    xil_printf("  BRAM: out@0x%03X in@0x%03X w@0x%03X b@0x%03X (load=%d w, drain=%d w)\r\n",
               BRAM_OUTPUT_ADDR, BRAM_INPUT_ADDR, BRAM_WEIGHTS_ADDR,
               BRAM_BIAS_ADDR, LOAD_N_WORDS, DRAIN_N_WORDS);

    /* 1. DMA init */
    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) {{ xil_printf("ERROR: DMA lookup\r\n"); goto fail; }}
    status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {{ xil_printf("ERROR: DMA init %d\r\n", status); goto fail; }}
    XAxiDma_IntrDisable(&dma_inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    /* 2. Pack DDR source buffer = image of BRAM */
    memset((void *)src, 0, LOAD_BYTES);
    {{
        u8 *buf = (u8 *)src;
        /* Output area left at zero */
        /* Input (CHW, verbatim) */
        for (int i = 0; i < INPUT_BYTES; i++)
            buf[BRAM_INPUT_ADDR + i] = (u8)input_data[i];
        /* Weights (OHWI, verbatim) */
        for (int i = 0; i < WEIGHT_BYTES; i++)
            buf[BRAM_WEIGHTS_ADDR + i] = (u8)weight_data[i];
        /* Bias (int32 LE) */
        for (int i = 0; i < BIAS_WORDS; i++) {{
            u32 v = (u32)bias_data[i];
            int off = BRAM_BIAS_ADDR + i * 4;
            buf[off + 0] = (u8)(v & 0xFF);
            buf[off + 1] = (u8)((v >> 8) & 0xFF);
            buf[off + 2] = (u8)((v >> 16) & 0xFF);
            buf[off + 3] = (u8)((v >> 24) & 0xFF);
        }}
    }}

    memset((void *)dst, 0xDE, DRAIN_BYTES + 256);
    Xil_DCacheFlushRange((UINTPTR)src, LOAD_BYTES);
    Xil_DCacheFlushRange((UINTPTR)dst, DRAIN_BYTES + 256);

    /* 3. Configure conv registers */
    conv_write(REG_N_WORDS,      LOAD_N_WORDS);
    conv_write(REG_C_IN,         C_IN);
    conv_write(REG_C_OUT,        C_OUT);
    conv_write(REG_H_IN,         H_IN);
    conv_write(REG_W_IN,         W_IN);
    conv_write(REG_KSP,          (STRIDE << 2) | KSIZE);
    conv_write(REG_X_ZP,         (u32)(s32)({X_ZP}) & 0x1FF);
    conv_write(REG_W_ZP,         {W_ZP});
    conv_write(REG_M0,           {M0}u);
    conv_write(REG_N_SHIFT,      {N_SHIFT});
    conv_write(REG_Y_ZP,         (u32)(s32)({Y_ZP}) & 0xFF);
    conv_write(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);
    conv_write(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);
    conv_write(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);
    conv_write(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);
    conv_write(REG_IC_TILE_SIZE, C_IN);
    conv_write(REG_PAD_TOP,      PAD_T);
    conv_write(REG_PAD_BOTTOM,   PAD_B);
    conv_write(REG_PAD_LEFT,     PAD_L);
    conv_write(REG_PAD_RIGHT,    PAD_R);

    /* 4. LOAD */
    conv_write(REG_CTRL, 0x01);
    status = XAxiDma_SimpleTransfer(&dma_inst, (UINTPTR)src, LOAD_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {{ xil_printf("ERROR: MM2S start %d\r\n", status); goto fail; }}
    {{
        int to = 0;
        while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE)) {{
            if (++to > 10000000) {{ xil_printf("ERROR: MM2S timeout\r\n"); goto fail; }}
        }}
    }}
    {{
        int to = 0;
        while (get_fsm_state() != FSM_IDLE) {{
            if (++to > 1000000) {{ xil_printf("ERROR: FSM stuck post-LOAD %d\r\n", get_fsm_state()); goto fail; }}
        }}
    }}

    /* 5. CONV */
    conv_write(REG_CTRL, 0x02);
    {{
        int to = 0; u32 ctrl;
        do {{
            ctrl = conv_read(REG_CTRL);
            if (++to > 20000000) {{ xil_printf("ERROR: CONV timeout ctrl=0x%08X fsm=%d\r\n", ctrl, get_fsm_state()); goto fail; }}
        }} while ((ctrl & 0x100) == 0);
    }}

    /* 6. Configure DataMover S2MM */
    gpio_addr_write(DDR_DST_ADDR);
    gpio_ctrl_write(DRAIN_BYTES & 0x7FFFFF);
    /* 7. DRAIN: pulse start, then issue drain cmd */
    gpio_ctrl_write((DRAIN_BYTES & 0x7FFFFF) | 0x80000000);
    gpio_ctrl_write(DRAIN_BYTES & 0x7FFFFF);
    usleep(10);
    conv_write(REG_N_WORDS, DRAIN_N_WORDS);
    conv_write(REG_CTRL, 0x04);

    /* 8. Wait DataMover done */
    {{
        int to = 0; u32 sts;
        do {{
            sts = gpio_ctrl_read_status();
            if (++to > 20000000) {{ xil_printf("ERROR: DataMover timeout sts=0x%08X fsm=%d\r\n", sts, get_fsm_state()); goto fail; }}
        }} while ((sts & 0x02) == 0);
        if (sts & 0x04) xil_printf("  WARN: DataMover err flag, raw=0x%02X\r\n", (sts >> 4) & 0xFF);
    }}

    Xil_DCacheInvalidateRange((UINTPTR)dst, DRAIN_BYTES + 256);

    /* 9. Verify every output byte */
    {{
        u8 *out = dst;
        for (int i = 0; i < OUTPUT_BYTES; i++) {{
            s8 got = (s8)out[i];
            s8 exp = expected_full[i];
            total_checks++;
            if (got != exp) {{
                errors++;
                if (errors <= 10) {{
                    int oc = i / (H_OUT * W_OUT);
                    int rem = i % (H_OUT * W_OUT);
                    int oh = rem / W_OUT;
                    int ow = rem % W_OUT;
                    xil_printf("  MISMATCH [%d] oc=%d (%d,%d): got %d exp %d\r\n",
                               i, oc, oh, ow, (int)got, (int)exp);
                }}
            }}
        }}
    }}

    xil_printf("  Result: %d/%d match (%d errors)\r\n",
               OUTPUT_BYTES - errors, OUTPUT_BYTES, errors);
    if (errors == 0) xil_printf("  >>> PASS <<<\r\n");
    else             xil_printf("  >>> FAIL <<<\r\n");

    res[0] = MAGIC_DONE;
    res[1] = (u32)total_checks;
    res[2] = (u32)errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    while (1);
    return 0;

fail:
    xil_printf("\r\n>>> INIT/DMA FAILURE -- aborting <<<\r\n");
    res[0] = MAGIC_DONE;
    res[1] = 0;
    res[2] = 99;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while (1);
    return 1;
}}
'''


def align_up(v, a):
    return (v + a - 1) & ~(a - 1)


def gen_one(layer):
    src_path = os.path.join(SRC_DIR, f"layer_{layer:03d}_test.c")
    text = read_text(src_path)

    C_IN = int(extract_define(text, "C_IN"))
    C_OUT = int(extract_define(text, "C_OUT"))
    H_IN = int(extract_define(text, "H_IN"))
    W_IN = int(extract_define(text, "W_IN"))
    KH = int(extract_define(text, "KH"))
    KW = int(extract_define(text, "KW"))
    KSIZE = int(extract_define(text, "KSIZE"))
    STRIDE = int(extract_define(text, "STRIDE"))
    PAD_T = int(extract_define(text, "PAD_TOP"))
    PAD_B = int(extract_define(text, "PAD_BOTTOM"))
    PAD_L = int(extract_define(text, "PAD_LEFT"))
    PAD_R = int(extract_define(text, "PAD_RIGHT"))
    H_OUT = int(extract_define(text, "H_OUT"))
    W_OUT = int(extract_define(text, "W_OUT"))

    INPUT_BYTES = int(extract_define(text, "INPUT_BYTES"))
    WEIGHT_BYTES = int(extract_define(text, "WEIGHT_BYTES"))
    BIAS_WORDS = int(extract_define(text, "BIAS_WORDS"))
    OUTPUT_BYTES = int(extract_define(text, "OUTPUT_BYTES"))
    BIAS_BYTES = BIAS_WORDS * 4

    x_zp, w_zp, m0, nsh, y_zp = extract_quant(text)

    input_data = extract_array(text, "input_data")
    weight_data = extract_array(text, "weight_data")
    bias_data = extract_array(text, "bias_data", is_s32=True)
    expected = extract_array(text, "expected_full")

    assert len(input_data) == INPUT_BYTES, (
        f"layer {layer}: input length {len(input_data)} != {INPUT_BYTES}")
    assert len(weight_data) == WEIGHT_BYTES, (
        f"layer {layer}: weight length {len(weight_data)} != {WEIGHT_BYTES}")
    assert len(bias_data) == BIAS_WORDS
    assert len(expected) == OUTPUT_BYTES

    # BRAM layout: output first, then input/weights/bias, each 4-byte aligned
    BRAM_OUTPUT_ADDR = 0x000
    BRAM_INPUT_ADDR = align_up(BRAM_OUTPUT_ADDR + OUTPUT_BYTES, 4)
    BRAM_WEIGHTS_ADDR = align_up(BRAM_INPUT_ADDR + INPUT_BYTES, 4)
    BRAM_BIAS_ADDR = align_up(BRAM_WEIGHTS_ADDR + WEIGHT_BYTES, 4)
    total_end = BRAM_BIAS_ADDR + BIAS_BYTES
    total_bytes = total_end

    if total_bytes > BRAM_LIMIT_BYTES:
        return {
            "layer": layer,
            "skipped": True,
            "reason": f"BRAM_OVERFLOW ({total_bytes} > {BRAM_LIMIT_BYTES})",
            "total_bram": total_bytes,
        }

    LOAD_N_WORDS = (total_bytes + 3) // 4  # words to load to cover everything
    DRAIN_N_WORDS = (OUTPUT_BYTES + 3) // 4

    ctx = dict(
        LAYER=layer,
        C_IN=C_IN, C_OUT=C_OUT, H_IN=H_IN, W_IN=W_IN,
        KH=KH, KW=KW, KSIZE=KSIZE, STRIDE=STRIDE,
        STRIDE_INT=(2 if STRIDE == 1 else 1),
        PAD_T=PAD_T, PAD_B=PAD_B, PAD_L=PAD_L, PAD_R=PAD_R,
        H_OUT=H_OUT, W_OUT=W_OUT,
        X_ZP=x_zp, W_ZP=w_zp, M0=m0, N_SHIFT=nsh, Y_ZP=y_zp,
        INPUT_BYTES=INPUT_BYTES, WEIGHT_BYTES=WEIGHT_BYTES,
        BIAS_BYTES=BIAS_BYTES, BIAS_WORDS=BIAS_WORDS,
        OUTPUT_BYTES=OUTPUT_BYTES,
        LOAD_N_WORDS=LOAD_N_WORDS, DRAIN_N_WORDS=DRAIN_N_WORDS,
        BRAM_OUTPUT_ADDR=BRAM_OUTPUT_ADDR, BRAM_INPUT_ADDR=BRAM_INPUT_ADDR,
        BRAM_WEIGHTS_ADDR=BRAM_WEIGHTS_ADDR, BRAM_BIAS_ADDR=BRAM_BIAS_ADDR,
        TOTAL_BYTES=total_bytes,
        INPUT_ARRAY=fmt_s8_array("input_data", input_data),
        WEIGHT_ARRAY=fmt_s8_array("weight_data", weight_data),
        BIAS_ARRAY=fmt_s32_array("bias_data", bias_data),
        EXPECTED_ARRAY=fmt_s8_array("expected_full", expected),
    )

    out = TEMPLATE.format(**ctx)
    dst_path = os.path.join(DST_DIR, f"layer_{layer:03d}_test.c")
    auto_path = os.path.join(DST_DIR, f"layer_{layer:03d}_test_auto.c")

    discrepancy = False
    if layer in PRESERVED and os.path.isfile(dst_path):
        # Compare byte-identical to existing manual port
        with open(dst_path, "r", encoding="utf-8") as f:
            existing = f.read()
        if existing == out:
            # Identical: keep existing, remove any stale _auto
            if os.path.isfile(auto_path):
                os.remove(auto_path)
        else:
            # Write auto alongside, keep manual version intact
            with open(auto_path, "w", encoding="utf-8") as f:
                f.write(out)
            discrepancy = True
    else:
        with open(dst_path, "w", encoding="utf-8") as f:
            f.write(out)
        # If this layer is not preserved, clean up any lingering _auto file
        if os.path.isfile(auto_path):
            os.remove(auto_path)

    return {
        "layer": layer, "skipped": False,
        "c_in": C_IN, "c_out": C_OUT,
        "h_in": H_IN, "w_in": W_IN,
        "h_out": H_OUT, "w_out": W_OUT,
        "k": f"{KH}x{KW}",
        "stride": (2 if STRIDE == 1 else 1),
        "pad": f"[{PAD_T},{PAD_B},{PAD_L},{PAD_R}]",
        "total_bram": total_bytes,
        "load_words": LOAD_N_WORDS,
        "drain_words": DRAIN_N_WORDS,
        "output_bytes": OUTPUT_BYTES,
        "checks": OUTPUT_BYTES,
        "preserved": layer in PRESERVED,
        "discrepancy": discrepancy,
    }


def histogram(values, buckets):
    """Return counts per bucket edge (right-inclusive)."""
    counts = [0] * len(buckets)
    labels = []
    prev = 0
    for i, e in enumerate(buckets):
        labels.append(f"{prev}-{e}")
        prev = e + 1
    for v in values:
        for i, e in enumerate(buckets):
            if v <= e:
                counts[i] += 1
                break
    return list(zip(labels, counts))


def main():
    os.makedirs(DST_DIR, exist_ok=True)
    generated = []
    skipped = []
    preserved_ident = []
    discrepancies = []
    for L in LAYERS:
        try:
            r = gen_one(L)
        except Exception as e:
            print(f"  layer {L:03d}: ERROR {e}")
            skipped.append({"layer": L, "reason": f"PARSE_ERROR: {e}",
                            "total_bram": None})
            continue
        if r.get("skipped"):
            print(f"  layer {L:03d}: SKIP ({r['reason']})")
            skipped.append(r)
            continue
        generated.append(r)
        tag = ""
        if r["preserved"]:
            if r["discrepancy"]:
                tag = " [PRESERVED + _auto DISCREPANCY]"
                discrepancies.append(r["layer"])
            else:
                tag = " [PRESERVED identical]"
                preserved_ident.append(r["layer"])
        print(f"  layer {L:03d}: c_in={r['c_in']} c_out={r['c_out']} "
              f"{r['h_in']}x{r['w_in']}->{r['h_out']}x{r['w_out']} "
              f"k={r['k']} s={r['stride']} pad={r['pad']} "
              f"BRAM={r['total_bram']}B load={r['load_words']}w "
              f"drain={r['drain_words']}w{tag}")

    print(f"\nTotals: generated={len(generated)} skipped={len(skipped)} "
          f"preserved_identical={len(preserved_ident)} "
          f"discrepancies={len(discrepancies)}")
    if skipped:
        print("Skipped:")
        for s in skipped:
            print(f"  L{s['layer']:03d}: {s['reason']}")
    if discrepancies:
        print(f"Discrepancies vs preserved manual ports: {discrepancies}")

    # BRAM size stats
    brams = sorted(r["total_bram"] for r in generated)
    if brams:
        bmin = brams[0]
        bmax = brams[-1]
        bmed = brams[len(brams) // 2]
    else:
        bmin = bmax = bmed = 0
    hist = histogram(brams, [3300, 3500, 3700, 3900, 4000, 4096])

    # Emit README
    readme = os.path.join(DST_DIR, "README.md")
    with open(readme, "w", encoding="utf-8") as f:
        f.write("# P_16 Layer Tests (full 110-layer port from P_13)\n\n")
        f.write("Layer tests re-run on the P_16 platform "
                "(DMA MM2S -> conv_engine_v3 -> DataMover S2MM -> DDR).\n\n")
        f.write(f"- Generated: **{len(generated)}** layers\n")
        f.write(f"- Skipped (BRAM overflow or parse error): "
                f"**{len(skipped)}**\n")
        f.write(f"- Preserved manual ports (byte-identical to generator): "
                f"**{len(preserved_ident)}** -> {preserved_ident}\n")
        f.write(f"- Preserved manual ports with discrepancy (`_auto.c` "
                f"written alongside): **{len(discrepancies)}** "
                f"-> {discrepancies}\n\n")
        f.write("## BRAM footprint summary\n\n")
        f.write(f"Range: min={bmin} B, median={bmed} B, max={bmax} B "
                f"(limit {BRAM_LIMIT_BYTES} B).\n\n")
        f.write("| BRAM bytes | count |\n|------------|------:|\n")
        for lab, cnt in hist:
            f.write(f"| {lab} | {cnt} |\n")
        f.write("\n")
        if skipped:
            f.write("## Skipped layers\n\n")
            f.write("| Layer | Reason | BRAM (B) |\n|------:|--------|---------:|\n")
            for s in skipped:
                f.write(f"| {s['layer']:03d} | {s['reason']} | "
                        f"{s.get('total_bram','?')} |\n")
            f.write("\n")
        f.write("## Layer configs\n\n")
        f.write("| Layer | c_in | c_out | in | out | k | stride | "
                "pad (T,B,L,R) | BRAM | load w | drain w | checks |\n")
        f.write("|------:|-----:|------:|----|-----|---|-------:|"
                "---------------|-----:|-------:|--------:|-------:|\n")
        for r in generated:
            f.write(f"| {r['layer']:03d} | {r['c_in']} | {r['c_out']} | "
                    f"{r['h_in']}x{r['w_in']} | {r['h_out']}x{r['w_out']} | "
                    f"{r['k']} | {r['stride']} | {r['pad']} | "
                    f"{r['total_bram']} | {r['load_words']} | "
                    f"{r['drain_words']} | {r['checks']} |\n")
        f.write("\n## BRAM layout (P_16 flow)\n\n")
        f.write("Output MUST be at BRAM address 0x000 (DRAIN reads "
                "sequentially from address 0, ignoring REG_ADDR_OUTPUT for "
                "the drain start). All other regions are packed "
                "contiguously after the output.\n\n")
        f.write("## Register map (P_16)\n\n")
        f.write("- 0x00 CTRL, 0x04 N_WORDS, 0x08 C_IN, 0x0C C_OUT\n")
        f.write("- 0x10 H_IN, 0x14 W_IN, 0x18 KSP=(stride<<2)|ksize, "
                "0x1C X_ZP\n")
        f.write("- 0x20 W_ZP, 0x24 M0, 0x28 N_SHIFT, 0x2C Y_ZP\n")
        f.write("- 0x30..0x3C ADDR_INPUT/WEIGHTS/BIAS/OUTPUT, "
                "0x40 IC_TILE_SIZE\n")
        f.write("- 0x44 PAD_TOP, 0x48 PAD_BOTTOM, 0x4C PAD_LEFT, "
                "0x50 PAD_RIGHT\n\n")
        f.write("## Verification\n\n")
        f.write("Each test compares every byte of the output against "
                "`expected_full[]` copied verbatim from the P_13 test, and "
                "publishes the result at 0x10200000: word0=MAGIC_DONE "
                "(0xDEAD1234), word1=total_checks, word2=errors.\n")
    print(f"  wrote README {readme}")


if __name__ == "__main__":
    main()
