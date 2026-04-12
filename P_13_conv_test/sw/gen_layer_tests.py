#!/usr/bin/env python3
"""
gen_layer_tests.py -- Generate per-layer HW test .c files for ALL QLinearConv
layers in YOLOv4 (yolov4_int8_qop.onnx).

Each .c is self-contained: input data, weights (OIHW->OHWI), bias, expected
output, plus the register setup for conv_engine_v2 on the ZedBoard BRAM
wrapper (4 KB BRAM).

Strategy for large layers:
  - c_out_test = min(c_out, 32)   (one OC tile)
  - c_in_test  = min(c_in, max that fits in 4 KB)
  - ic_tile_size = c_in_test       (one IC tile, no tiling needed)
  - crop = largest square that fits with weights+bias+input+output <= 4096

Usage:
  python gen_layer_tests.py [--layers 0,1,2,3,4] [--outdir ./layer_tests]
"""

import onnx
import numpy as np
from onnx import numpy_helper
import math
import os
import sys
import argparse

# ============================================================================
# Configuration
# ============================================================================
ONNX_PATH = "C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
BRAM_BUDGET = 4096  # bytes
N_MAC = 32          # conv_engine_v2 OC tile = 32

# ============================================================================
# Load ONNX model
# ============================================================================
def load_model():
    print(f"Loading ONNX model: {ONNX_PATH}")
    model = onnx.load(ONNX_PATH)
    init_map = {}
    for init in model.graph.initializer:
        init_map[init.name] = numpy_helper.to_array(init)
    qlconv_nodes = [n for n in model.graph.node if n.op_type == "QLinearConv"]
    print(f"  Total QLinearConv layers: {len(qlconv_nodes)}")
    return model, init_map, qlconv_nodes


# ============================================================================
# Extract layer info
# ============================================================================
def extract_layer_info(node, init_map, layer_idx):
    """Extract all parameters for a QLinearConv node."""
    info = {"idx": layer_idx, "name": node.name}

    # QLinearConv inputs:
    #   0: x, 1: x_scale, 2: x_zp, 3: w, 4: w_scale, 5: w_zp,
    #   6: y_scale, 7: y_zp, 8: B (optional)
    info["x_scale"] = float(init_map[node.input[1]])
    info["x_zp"]    = int(init_map[node.input[2]])
    info["w_data"]  = init_map[node.input[3]]  # [c_out, c_in/g, kh, kw]
    info["w_scale"] = float(init_map[node.input[4]])
    info["w_zp"]    = int(init_map[node.input[5]])
    info["y_scale"] = float(init_map[node.input[6]])
    info["y_zp"]    = int(init_map[node.input[7]])

    if len(node.input) > 8 and node.input[8] in init_map:
        info["bias"] = init_map[node.input[8]]  # [c_out] int32
    else:
        info["bias"] = None

    # Weight shape
    wshape = info["w_data"].shape
    info["c_out"] = wshape[0]
    info["c_in_per_group"] = wshape[1]
    info["kh"] = wshape[2]
    info["kw"] = wshape[3]

    # Attributes
    attrs = {}
    for attr in node.attribute:
        if attr.name == "kernel_shape":
            attrs["kernel_shape"] = list(attr.ints)
        elif attr.name == "strides":
            attrs["strides"] = list(attr.ints)
        elif attr.name == "pads":
            attrs["pads"] = list(attr.ints)
        elif attr.name == "group":
            attrs["group"] = attr.i
        elif attr.name == "dilations":
            attrs["dilations"] = list(attr.ints)

    info["group"] = attrs.get("group", 1)
    info["strides"] = attrs.get("strides", [1, 1])
    info["pads"] = attrs.get("pads", [0, 0, 0, 0])
    info["c_in"] = info["c_in_per_group"] * info["group"]

    # Determine padding for our test
    # pads = [top, left, bottom, right]
    # For stride=2 layers: pads = [1,1,0,0] typically
    # For stride=1 with 3x3: pads = [1,1,1,1]
    # For 1x1: pads = [0,0,0,0]
    info["pad_top"] = info["pads"][0]
    info["pad_left"] = info["pads"][1]
    info["pad_bottom"] = info["pads"][2]
    info["pad_right"] = info["pads"][3]

    return info


# ============================================================================
# Compute M0 and n_shift
# ============================================================================
def compute_m0_nshift(x_scale, w_scale, y_scale):
    """Compute requantization M0 and n_shift.
    M0 must fit in signed 31 bits (< 2^31) for the HW multiplier.
    We want the LARGEST n_shift for best precision."""
    combined = (x_scale * w_scale) / y_scale
    # Search from high n_shift down to find the largest that fits
    best_n = None
    for n in range(47, 19, -1):
        M0 = round(combined * (2**n))
        if 0 < M0 < 2**31:
            best_n = n
            break
    if best_n is None:
        raise ValueError(f"Cannot find valid M0/n_shift for scale={combined}")
    M0 = round(combined * (2**best_n))
    return M0, best_n


# ============================================================================
# Compute feasible test dimensions (fit in 4 KB BRAM)
# ============================================================================
def compute_test_dims(info):
    """Determine c_out_test, c_in_test, crop_h, crop_w that fit in BRAM."""
    c_out = info["c_out"]
    c_in = info["c_in"]
    kh = info["kh"]
    kw = info["kw"]
    stride_h = info["strides"][0]

    c_out_test = min(c_out, N_MAC)  # one OC tile

    # For pad: conv_engine uses cfg_pad which means symmetric pad=1
    # For stride=2 with pads [1,1,0,0]: the engine uses pad on top/left
    # For the crop, pad_val = 1 if kh==3, 0 if kh==1
    pad = 1 if kh == 3 else 0

    # Try decreasing crop sizes and c_in values
    best = None
    for crop in [8, 6, 5, 4, 3, 2]:
        if kh == 3 and crop < 3:
            continue

        # Compute output size for this crop
        if stride_h == 2:
            # h_out = (h_in + 2*pad - kh) / 2 + 1
            crop_out = (crop + 2 * pad - kh) // 2 + 1
        else:
            crop_out = crop + 2 * pad - kh + 1 if kh > 1 else crop

        if crop_out < 1:
            continue

        output_bytes = crop_out * crop_out * c_out_test

        # Try full c_in first, then reduce
        for c_in_t in range(c_in, 0, -1):
            w_bytes = c_out_test * c_in_t * kh * kw
            b_bytes = c_out_test * 4
            i_bytes = crop * crop * c_in_t
            total = w_bytes + b_bytes + i_bytes + output_bytes

            if total <= BRAM_BUDGET:
                best = {
                    "c_out_test": c_out_test,
                    "c_in_test": c_in_t,
                    "crop_h": crop,
                    "crop_w": crop,
                    "crop_h_out": crop_out,
                    "crop_w_out": crop_out,
                    "pad": pad,
                    "total_bytes": total,
                }
                break

        if best is not None:
            break

    if best is None:
        return None
    return best


# ============================================================================
# Generate synthetic input (deterministic, covers range)
# ============================================================================
def gen_input(c_in, h, w, x_zp):
    """Generate a deterministic input pattern."""
    inp = np.zeros((c_in, h, w), dtype=np.int8)
    for c in range(c_in):
        for r in range(h):
            for col in range(w):
                # Mix of channel, row, col to create varying patterns
                val = ((c * 37 + r * 17 + col * 7 + c * r * 3) % 256) - 128
                inp[c, r, col] = np.int8(val)
    return inp


# ============================================================================
# Compute expected output (HW-exact integer math)
# ============================================================================
def compute_expected(inp, weights, bias, x_zp, w_zp, M0, n_shift, y_zp,
                     stride, pad, c_out_test, c_in_test):
    """
    inp:     [c_in_test, h_in, w_in] int8
    weights: [c_out_test, c_in_test, kh, kw] int8
    bias:    [c_out_test] int32 (or None)
    Returns: [c_out_test, h_out, w_out] int8
    """
    c_in_t, h_in, w_in = inp.shape
    kh, kw = weights.shape[2], weights.shape[3]

    if stride == 2:
        h_out = (h_in + 2 * pad - kh) // 2 + 1
        w_out = (w_in + 2 * pad - kw) // 2 + 1
    else:
        h_out = h_in + 2 * pad - kh + 1 if kh > 1 else h_in
        w_out = w_in + 2 * pad - kw + 1 if kw > 1 else w_in

    output = np.zeros((c_out_test, h_out, w_out), dtype=np.int8)

    for oc in range(c_out_test):
        for oh in range(h_out):
            for ow in range(w_out):
                acc = int(bias[oc]) if bias is not None else 0
                for kkh in range(kh):
                    for kkw in range(kw):
                        ih = oh * stride + kkh - pad
                        iw = ow * stride + kkw - pad
                        for ic in range(c_in_t):
                            if 0 <= ih < h_in and 0 <= iw < w_in:
                                x_val = int(inp[ic, ih, iw]) - x_zp
                            else:
                                x_val = 0  # pad with x_zp -> x_zp - x_zp = 0
                            w_val = int(weights[oc, ic, kkh, kkw]) - w_zp
                            acc += x_val * w_val

                # Requantize (HW-exact)
                prod = acc * M0
                prod += (1 << (n_shift - 1))  # round
                result = prod >> n_shift       # arithmetic right shift
                result += y_zp
                result = max(-128, min(127, result))
                output[oc, oh, ow] = np.int8(result)

    return output


# ============================================================================
# Format C arrays
# ============================================================================
def c_array_s8(name, data, cols=16):
    flat = data.flatten().tolist()
    lines = [f"static const s8 {name}[{len(flat)}] = {{"]
    for i in range(0, len(flat), cols):
        chunk = flat[i:i+cols]
        s = "    " + ", ".join(f"{v:4d}" for v in chunk)
        if i + cols < len(flat):
            s += ","
        lines.append(s)
    lines.append("};")
    return "\n".join(lines)

def c_array_s32(name, data, cols=8):
    flat = data.flatten().tolist()
    lines = [f"static const s32 {name}[{len(flat)}] = {{"]
    for i in range(0, len(flat), cols):
        chunk = flat[i:i+cols]
        s = "    " + ", ".join(f"{v}" for v in chunk)
        if i + cols < len(flat):
            s += ","
        lines.append(s)
    lines.append("};")
    return "\n".join(lines)


# ============================================================================
# Generate a .c test file for one layer
# ============================================================================
def gen_c_file(info, dims, inp, weights_ohwi, bias_test, expected, M0, n_shift):
    """Generate a complete .c test file."""
    layer_idx = info["idx"]
    layer_name = info["name"]
    c_in_test = dims["c_in_test"]
    c_out_test = dims["c_out_test"]
    crop_h = dims["crop_h"]
    crop_w = dims["crop_w"]
    crop_h_out = dims["crop_h_out"]
    crop_w_out = dims["crop_w_out"]
    pad = dims["pad"]
    kh = info["kh"]
    kw = info["kw"]
    stride = info["strides"][0]
    x_zp = info["x_zp"]
    w_zp = info["w_zp"]
    y_zp = info["y_zp"]

    input_bytes = c_in_test * crop_h * crop_w
    weight_bytes = c_out_test * c_in_test * kh * kw
    bias_bytes = c_out_test * 4
    output_bytes = c_out_test * crop_h_out * crop_w_out

    # BRAM layout (tight, word-aligned)
    inp_start = 0x000
    inp_end = inp_start + input_bytes
    wgt_start = (inp_end + 3) & ~3
    wgt_end = wgt_start + weight_bytes
    bias_start = (wgt_end + 3) & ~3
    bias_end = bias_start + bias_bytes
    out_start = (bias_end + 3) & ~3
    out_end = out_start + output_bytes

    assert out_end <= BRAM_BUDGET, f"Layer {layer_idx}: total {out_end} > {BRAM_BUDGET}"

    # KSP encoding: bits [1:0]=ksize, bit [2]=stride, bit [3]=pad
    if kh == 1:
        ksize_enc = 0  # 1x1
    elif kh == 3:
        ksize_enc = 2  # 3x3
    else:
        raise ValueError(f"Unsupported kh={kh}")
    stride_enc = 1 if stride == 2 else 0
    pad_enc = 1 if pad > 0 else 0
    ksp = (pad_enc << 3) | (stride_enc << 2) | ksize_enc

    lines = []
    lines.append(f"/*")
    lines.append(f" * layer_{layer_idx:03d}_test.c -- YOLOv4 QLinearConv layer {layer_idx}")
    lines.append(f" * {layer_name}")
    lines.append(f" *")
    lines.append(f" * Original layer: c_in={info['c_in']}, c_out={info['c_out']}, "
                 f"k={kh}x{kw}, stride={stride}, pad={info['pads']}")
    lines.append(f" * Test subset:    c_in={c_in_test}, c_out={c_out_test}, "
                 f"crop={crop_h}x{crop_w} -> {crop_h_out}x{crop_w_out}")
    lines.append(f" *")
    lines.append(f" * Quant: x_zp={x_zp}, w_zp={w_zp}, y_zp={y_zp}, M0={M0}u, n_shift={n_shift}")
    lines.append(f" *")
    lines.append(f" * BRAM layout ({out_end} bytes):")
    lines.append(f" *   Input:   0x{inp_start:03X}-0x{inp_end-1:03X} ({input_bytes} B)")
    lines.append(f" *   Weights: 0x{wgt_start:03X}-0x{wgt_end-1:03X} ({weight_bytes} B)")
    lines.append(f" *   Bias:    0x{bias_start:03X}-0x{bias_end-1:03X} ({bias_bytes} B)")
    lines.append(f" *   Output:  0x{out_start:03X}-0x{out_end-1:03X} ({output_bytes} B)")
    lines.append(f" *")
    lines.append(f" * Auto-generated by gen_layer_tests.py")
    lines.append(f" */")
    lines.append(f"")
    lines.append(f'#include "xparameters.h"')
    lines.append(f'#include "xil_printf.h"')
    lines.append(f'#include "xil_io.h"')
    lines.append(f'#include "xil_cache.h"')
    lines.append(f'#include "sleep.h"')
    lines.append(f'#include <string.h>')
    lines.append(f"")
    lines.append(f"#ifndef XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR")
    lines.append(f"#define XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR 0x43C00000")
    lines.append(f"#endif")
    lines.append(f"#define WRAPPER_BASE  XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR")
    lines.append(f"")
    lines.append(f"#define REG_CTRL           0x00")
    lines.append(f"#define REG_C_IN           0x04")
    lines.append(f"#define REG_C_OUT          0x08")
    lines.append(f"#define REG_H_IN           0x0C")
    lines.append(f"#define REG_W_IN           0x10")
    lines.append(f"#define REG_KSP            0x14")
    lines.append(f"#define REG_X_ZP           0x18")
    lines.append(f"#define REG_W_ZP           0x1C")
    lines.append(f"#define REG_M0             0x20")
    lines.append(f"#define REG_N_SHIFT        0x24")
    lines.append(f"#define REG_Y_ZP           0x28")
    lines.append(f"#define REG_ADDR_INPUT     0x2C")
    lines.append(f"#define REG_ADDR_WEIGHTS   0x30")
    lines.append(f"#define REG_ADDR_BIAS      0x34")
    lines.append(f"#define REG_ADDR_OUTPUT    0x38")
    lines.append(f"#define REG_IC_TILE_SIZE   0x3C")
    lines.append(f"#define REG_BRAM_BASE      0x1000")
    lines.append(f"")
    lines.append(f"#define BRAM_INPUT_ADDR    0x{inp_start:03X}")
    lines.append(f"#define BRAM_WEIGHTS_ADDR  0x{wgt_start:03X}")
    lines.append(f"#define BRAM_BIAS_ADDR     0x{bias_start:03X}")
    lines.append(f"#define BRAM_OUTPUT_ADDR   0x{out_start:03X}")
    lines.append(f"")
    lines.append(f"#define C_IN    {c_in_test}")
    lines.append(f"#define C_OUT   {c_out_test}")
    lines.append(f"#define H_IN    {crop_h}")
    lines.append(f"#define W_IN    {crop_w}")
    lines.append(f"#define KH      {kh}")
    lines.append(f"#define KW      {kw}")
    lines.append(f"#define KSIZE   {ksize_enc}    /* encoding: 0=1x1, 2=3x3 */")
    lines.append(f"#define STRIDE  {stride_enc}    /* encoding: 0=stride1, 1=stride2 */")
    lines.append(f"#define PAD     {pad_enc}")
    lines.append(f"#define KSP     0x{ksp:02X}")
    lines.append(f"#define H_OUT   {crop_h_out}")
    lines.append(f"#define W_OUT   {crop_w_out}")
    lines.append(f"")
    lines.append(f"#define INPUT_BYTES   {input_bytes}")
    lines.append(f"#define WEIGHT_BYTES  {weight_bytes}")
    lines.append(f"#define BIAS_WORDS    {c_out_test}")
    lines.append(f"#define OUTPUT_BYTES  {output_bytes}")
    lines.append(f"")
    lines.append(f"#define RESULT_ADDR   0x01200000")
    lines.append(f"#define MAGIC_DONE    0xDEAD1234")
    lines.append(f"#define LAYER_IDX     {layer_idx}")
    lines.append(f"")

    # Data arrays
    lines.append(f"/* Input: {c_in_test}ch x {crop_h}x{crop_w}, CHW order */")
    lines.append(c_array_s8("input_data", inp))
    lines.append(f"")

    # Weights already in OHWI order
    lines.append(f"/* Weights: {c_out_test} filters, OHWI order "
                 f"({c_out_test}x{kh}x{kw}x{c_in_test} = {weight_bytes} B) */")
    lines.append(c_array_s8("weight_data", weights_ohwi))
    lines.append(f"")

    lines.append(f"/* Bias: {c_out_test} values as int32 */")
    lines.append(c_array_s32("bias_data", bias_test))
    lines.append(f"")

    lines.append(f"/* Expected output: {c_out_test}ch x {crop_h_out}x{crop_w_out} = {output_bytes} B */")
    lines.append(c_array_s8("expected_full", expected))
    lines.append(f"")

    # Helper functions + main
    lines.append(f"/* ========= Helper functions ========= */")
    lines.append(f"")
    lines.append(f"static void write_reg(u32 offset, u32 val)")
    lines.append(f"{{")
    lines.append(f"    Xil_Out32(WRAPPER_BASE + offset, val);")
    lines.append(f"}}")
    lines.append(f"")
    lines.append(f"static u32 read_reg(u32 offset)")
    lines.append(f"{{")
    lines.append(f"    return Xil_In32(WRAPPER_BASE + offset);")
    lines.append(f"}}")
    lines.append(f"")
    lines.append(f"static void write_bram_word(u32 bram_addr, u32 val)")
    lines.append(f"{{")
    lines.append(f"    Xil_Out32(WRAPPER_BASE + REG_BRAM_BASE + bram_addr, val);")
    lines.append(f"}}")
    lines.append(f"")
    lines.append(f"static void write_bram_bytes(u32 bram_addr, const s8 *data, int len)")
    lines.append(f"{{")
    lines.append(f"    int i = 0;")
    lines.append(f"    for (; i + 3 < len; i += 4) {{")
    lines.append(f"        u32 word = ((u32)(u8)data[i])")
    lines.append(f"                 | ((u32)(u8)data[i+1] << 8)")
    lines.append(f"                 | ((u32)(u8)data[i+2] << 16)")
    lines.append(f"                 | ((u32)(u8)data[i+3] << 24);")
    lines.append(f"        write_bram_word(bram_addr + i, word);")
    lines.append(f"    }}")
    lines.append(f"    if (i < len) {{")
    lines.append(f"        u32 word = 0;")
    lines.append(f"        for (int j = 0; j < len - i; j++)")
    lines.append(f"            word |= ((u32)(u8)data[i+j]) << (j * 8);")
    lines.append(f"        write_bram_word(bram_addr + i, word);")
    lines.append(f"    }}")
    lines.append(f"}}")
    lines.append(f"")
    lines.append(f"static s8 read_bram_byte(u32 bram_addr)")
    lines.append(f"{{")
    lines.append(f"    u32 word_addr = bram_addr & ~0x3u;")
    lines.append(f"    u32 byte_pos  = bram_addr & 0x3u;")
    lines.append(f"    u32 word = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + word_addr);")
    lines.append(f"    return (s8)((word >> (byte_pos * 8)) & 0xFF);")
    lines.append(f"}}")
    lines.append(f"")

    # main()
    lines.append(f"int main(void)")
    lines.append(f"{{")
    lines.append(f"    volatile u32 *res = (volatile u32 *)RESULT_ADDR;")
    lines.append(f"    int errors = 0;")
    lines.append(f"    u32 ctrl;")
    lines.append(f"")
    lines.append(f"    res[0] = 0xAAAA0000 | LAYER_IDX;")
    lines.append(f"    Xil_DCacheFlushRange((UINTPTR)res, 64);")
    lines.append(f"")
    lines.append(f'    xil_printf("\\r\\n=== Layer {layer_idx}: {layer_name} ===\\r\\n");')
    lines.append(f'    xil_printf("  c_in=%d c_out=%d %dx%d->%dx%d k=%dx%d s=%d p=%d\\r\\n",')
    lines.append(f"               C_IN, C_OUT, H_IN, W_IN, H_OUT, W_OUT, KH, KW,")
    lines.append(f"               {stride}, {pad_enc});")
    lines.append(f"")

    # Write input
    lines.append(f"    /* Write input to BRAM */")
    lines.append(f"    write_bram_bytes(BRAM_INPUT_ADDR, input_data, INPUT_BYTES);")
    lines.append(f"")

    # Write weights -- already in OHWI order, write directly
    lines.append(f"    /* Write weights (already OHWI) to BRAM */")
    lines.append(f"    write_bram_bytes(BRAM_WEIGHTS_ADDR, weight_data, WEIGHT_BYTES);")
    lines.append(f"")

    # Write bias
    lines.append(f"    /* Write bias */")
    lines.append(f"    for (int i = 0; i < BIAS_WORDS; i++)")
    lines.append(f"        write_bram_word(BRAM_BIAS_ADDR + i * 4, (u32)bias_data[i]);")
    lines.append(f"")

    # Clear output
    lines.append(f"    /* Clear output area */")
    lines.append(f"    for (int i = 0; i < OUTPUT_BYTES; i += 4)")
    lines.append(f"        write_bram_word(BRAM_OUTPUT_ADDR + i, 0xDEDEDEDE);")
    lines.append(f"")

    # Configure registers
    lines.append(f"    /* Configure conv_engine registers */")
    lines.append(f"    write_reg(REG_CTRL, 0);")
    lines.append(f"    write_reg(REG_C_IN,  C_IN);")
    lines.append(f"    write_reg(REG_C_OUT, C_OUT);")
    lines.append(f"    write_reg(REG_H_IN,  H_IN);")
    lines.append(f"    write_reg(REG_W_IN,  W_IN);")
    lines.append(f"    write_reg(REG_KSP,   KSP);")

    # x_zp: sign-extend to 9 bits
    if x_zp < 0:
        x_zp_hex = f"(u32)(s32)({x_zp}) & 0x1FF"
    else:
        x_zp_hex = f"{x_zp}"
    lines.append(f"    write_reg(REG_X_ZP, {x_zp_hex});")

    # w_zp: sign-extend to 8 bits
    if w_zp < 0:
        w_zp_hex = f"(u32)(s32)({w_zp}) & 0xFF"
    else:
        w_zp_hex = f"{w_zp}"
    lines.append(f"    write_reg(REG_W_ZP, {w_zp_hex});")

    lines.append(f"    write_reg(REG_M0, {M0}u);")
    lines.append(f"    write_reg(REG_N_SHIFT, {n_shift});")

    # y_zp: sign-extend to 8 bits
    if y_zp < 0:
        y_zp_hex = f"(u32)(s32)({y_zp}) & 0xFF"
    else:
        y_zp_hex = f"{y_zp}"
    lines.append(f"    write_reg(REG_Y_ZP, {y_zp_hex});")

    lines.append(f"    write_reg(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);")
    lines.append(f"    write_reg(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);")
    lines.append(f"    write_reg(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);")
    lines.append(f"    write_reg(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);")
    lines.append(f"    write_reg(REG_IC_TILE_SIZE, C_IN);")
    lines.append(f"")

    # Start
    lines.append(f"    /* Start conv_engine */")
    lines.append(f"    write_reg(REG_CTRL, 1);")
    lines.append(f"")

    # Poll
    lines.append(f"    /* Poll for done */")
    lines.append(f"    int timeout = 0;")
    lines.append(f"    do {{")
    lines.append(f"        ctrl = read_reg(REG_CTRL);")
    lines.append(f"        timeout++;")
    lines.append(f"        if (timeout > 10000000) {{")
    lines.append(f'            xil_printf("ERROR: Timeout! ctrl=0x%08X\\r\\n", ctrl);')
    lines.append(f"            res[0] = MAGIC_DONE;")
    lines.append(f"            res[1] = LAYER_IDX;")
    lines.append(f"            res[2] = 0;")
    lines.append(f"            res[3] = 99;")
    lines.append(f"            Xil_DCacheFlushRange((UINTPTR)res, 64);")
    lines.append(f"            while(1);")
    lines.append(f"        }}")
    lines.append(f"    }} while ((ctrl & 0x02) == 0);")
    lines.append(f"    write_reg(REG_CTRL, 0);")
    lines.append(f"")

    # Verify
    lines.append(f"    /* Compare output */")
    lines.append(f"    for (int i = 0; i < OUTPUT_BYTES; i++) {{")
    lines.append(f"        s8 got = read_bram_byte(BRAM_OUTPUT_ADDR + i);")
    lines.append(f"        s8 exp = expected_full[i];")
    lines.append(f"        if (got != exp) {{")
    lines.append(f"            errors++;")
    lines.append(f"            if (errors <= 10) {{")
    lines.append(f"                int oc = i / (H_OUT * W_OUT);")
    lines.append(f"                int rem = i % (H_OUT * W_OUT);")
    lines.append(f"                int oh = rem / W_OUT;")
    lines.append(f"                int ow = rem % W_OUT;")
    lines.append(f'                xil_printf("  MISMATCH [%d] oc=%d (%d,%d): got %d exp %d\\r\\n",')
    lines.append(f"                           i, oc, oh, ow, (int)got, (int)exp);")
    lines.append(f"            }}")
    lines.append(f"        }}")
    lines.append(f"    }}")
    lines.append(f"")
    lines.append(f'    xil_printf("  Result: %d/%d match (%d errors)\\r\\n",')
    lines.append(f"               OUTPUT_BYTES - errors, OUTPUT_BYTES, errors);")
    lines.append(f"    if (errors == 0)")
    lines.append(f'        xil_printf("  >>> PASS <<<\\r\\n");')
    lines.append(f"    else")
    lines.append(f'        xil_printf("  >>> FAIL <<<\\r\\n");')
    lines.append(f"")

    # Signal to XSCT
    lines.append(f"    /* Signal result to XSCT */")
    lines.append(f"    res[0] = MAGIC_DONE;")
    lines.append(f"    res[1] = LAYER_IDX;")
    lines.append(f"    res[2] = (u32)OUTPUT_BYTES;")
    lines.append(f"    res[3] = (u32)errors;")
    lines.append(f"    Xil_DCacheFlushRange((UINTPTR)res, 64);")
    lines.append(f"")
    lines.append(f"    while(1);")
    lines.append(f"    return 0;")
    lines.append(f"}}")

    return "\n".join(lines)


# ============================================================================
# OIHW -> OHWI transpose
# ============================================================================
def transpose_oihw_to_ohwi(w_oihw):
    """Transpose weights from OIHW to OHWI layout expected by conv_engine."""
    # w_oihw shape: [c_out, c_in, kh, kw]
    # w_ohwi shape: [c_out, kh, kw, c_in]
    return np.transpose(w_oihw, (0, 2, 3, 1)).copy()


# ============================================================================
# Main
# ============================================================================
def main():
    parser = argparse.ArgumentParser(description="Generate per-layer HW test .c files")
    parser.add_argument("--layers", type=str, default=None,
                        help="Comma-separated layer indices (default: first 5)")
    parser.add_argument("--all", action="store_true",
                        help="Generate for ALL 110 layers")
    parser.add_argument("--outdir", type=str,
                        default="C:/project/vivado/P_13_conv_test/sw/layer_tests",
                        help="Output directory for .c files")
    args = parser.parse_args()

    model, init_map, qlconv_nodes = load_model()

    if args.all:
        layer_indices = list(range(len(qlconv_nodes)))
    elif args.layers:
        layer_indices = [int(x.strip()) for x in args.layers.split(",")]
    else:
        layer_indices = list(range(min(5, len(qlconv_nodes))))

    os.makedirs(args.outdir, exist_ok=True)

    summary = []
    for li in layer_indices:
        if li >= len(qlconv_nodes):
            print(f"  WARNING: layer {li} out of range (max {len(qlconv_nodes)-1})")
            continue

        node = qlconv_nodes[li]
        info = extract_layer_info(node, init_map, li)

        print(f"\n--- Layer {li}: {info['name']} ---")
        print(f"  Original: c_in={info['c_in']}, c_out={info['c_out']}, "
              f"k={info['kh']}x{info['kw']}, s={info['strides']}, p={info['pads']}")

        # Compute M0 / n_shift
        M0, n_shift = compute_m0_nshift(info["x_scale"], info["w_scale"],
                                         info["y_scale"])
        print(f"  M0={M0}, n_shift={n_shift}")

        # Compute feasible test dimensions
        dims = compute_test_dims(info)
        if dims is None:
            print(f"  SKIP: cannot fit in {BRAM_BUDGET} bytes")
            summary.append((li, info["name"], "SKIP", "cannot fit"))
            continue

        print(f"  Test: c_in={dims['c_in_test']}, c_out={dims['c_out_test']}, "
              f"crop={dims['crop_h']}x{dims['crop_w']}->{dims['crop_h_out']}x{dims['crop_w_out']}, "
              f"total={dims['total_bytes']}B")

        # Extract weight/bias subsets
        w_full = info["w_data"]  # [c_out, c_in_per_group, kh, kw]
        c_out_test = dims["c_out_test"]
        c_in_test = dims["c_in_test"]
        w_sub = w_full[:c_out_test, :c_in_test, :, :]  # [c_out_test, c_in_test, kh, kw]

        if info["bias"] is not None:
            b_sub = info["bias"][:c_out_test].copy()
        else:
            b_sub = np.zeros(c_out_test, dtype=np.int32)

        # Generate input
        inp = gen_input(c_in_test, dims["crop_h"], dims["crop_w"], info["x_zp"])

        # Compute expected output
        stride = info["strides"][0]
        pad = dims["pad"]
        expected = compute_expected(inp, w_sub, b_sub, info["x_zp"], info["w_zp"],
                                    M0, n_shift, info["y_zp"], stride, pad,
                                    c_out_test, c_in_test)

        print(f"  Expected output shape: {expected.shape}, "
              f"range: [{expected.min()}, {expected.max()}]")

        # Transpose weights OIHW -> OHWI
        w_ohwi = transpose_oihw_to_ohwi(w_sub)

        # Generate .c file
        c_code = gen_c_file(info, dims, inp, w_ohwi, b_sub, expected, M0, n_shift)

        out_path = os.path.join(args.outdir, f"layer_{li:03d}_test.c")
        with open(out_path, "w", newline="\n") as f:
            f.write(c_code)
        print(f"  Written: {out_path}")

        summary.append((li, info["name"], "OK",
                        f"c_in={c_in_test} c_out={c_out_test} "
                        f"crop={dims['crop_h']}x{dims['crop_w']} "
                        f"{dims['total_bytes']}B"))

    # Print summary
    print(f"\n{'='*70}")
    print(f"SUMMARY: {len(summary)} layers processed")
    print(f"{'='*70}")
    for li, name, status, detail in summary:
        print(f"  Layer {li:3d}: {status:4s}  {detail}  ({name})")


if __name__ == "__main__":
    main()
