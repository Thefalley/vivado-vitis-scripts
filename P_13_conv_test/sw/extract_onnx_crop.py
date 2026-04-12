#!/usr/bin/env python3
"""
extract_onnx_crop.py -- Extract YOLOv4 layer-1 data for 8x8 crop test
Generates: input (8x8x3), weights (32x3x3x3), bias (32), expected output (8x8x32)
Uses quantization parameters from the real ONNX model.
"""

import onnx
import numpy as np
from onnx import numpy_helper
import math

# ============================================================================
# 1. Load ONNX model and extract first QLinearConv parameters
# ============================================================================
model = onnx.load("C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx")

init_map = {}
for init in model.graph.initializer:
    init_map[init.name] = numpy_helper.to_array(init)

# Extract quantization parameters
x_scale = float(init_map["conv2d/Conv2D__24:0_scale"])
x_zp    = int(init_map["conv2d/Conv2D__24:0_zero_point"])
w_data  = init_map["conv2d/Conv2D_weights_fused_bn_quantized"]  # [32,3,3,3] int8
w_scale = float(init_map["conv2d/Conv2D_weights_fused_bn_scale"])
w_zp    = int(init_map["conv2d/Conv2D_weights_fused_bn_zero_point"])
y_scale = float(init_map["batch_normalization/FusedBatchNormV3:0_scale"])
y_zp    = int(init_map["batch_normalization/FusedBatchNormV3:0_zero_point"])
bias    = init_map["conv2d/Conv2D_bias_fused_bn_quantized"]  # [32] int32

print("=== Quantization Parameters ===")
print(f"x_scale = {x_scale}")
print(f"x_zp    = {x_zp}")
print(f"w_scale = {w_scale}")
print(f"w_zp    = {w_zp}")
print(f"y_scale = {y_scale}")
print(f"y_zp    = {y_zp}")
print(f"weights shape = {w_data.shape} (OIHW)")
print(f"bias shape    = {bias.shape}")

# Compute M0 and n_shift
# M = x_scale * w_scale / y_scale
# M0 * 2^(-n_shift) = M, M0 in [2^31, 2^32)
M = x_scale * w_scale / y_scale
n_shift = math.ceil(31 - math.log2(M))
M0 = round(M * (2**n_shift))

print(f"\nM = {M}")
print(f"M0 = {M0}")
print(f"n_shift = {n_shift}")
print(f"M0 fits u32: {0 <= M0 < 2**32}")

# Compare with existing test values
print(f"\n=== Comparison with existing conv_test.c ===")
print(f"Old: M0=656954014, n_shift=37")
print(f"New: M0={M0}, n_shift={n_shift}")
old_ratio = 656954014 / (2**37)
new_ratio = M0 / (2**n_shift)
print(f"Old M0/2^37 = {old_ratio}")
print(f"New M0/2^39 = {new_ratio}")
print(f"Exact M     = {M}")

# ============================================================================
# 2. Create 8x8x3 input (gradient pattern, quantized INT8)
# ============================================================================
# Use a pattern that looks like a real image crop:
# Channel 0 (R): horizontal gradient 0..255
# Channel 1 (G): vertical gradient
# Channel 2 (B): diagonal gradient
# These are uint8 values; quantized int8 = uint8 - 128 (since x_zp=-128)

C_IN = 3
C_OUT = 32
H_IN = 8
W_IN = 8
KH = KW = 3
STRIDE = 1
PAD = 1
H_OUT = 8
W_OUT = 8

input_uint8 = np.zeros((C_IN, H_IN, W_IN), dtype=np.uint8)
for c in range(C_IN):
    for h in range(H_IN):
        for w in range(W_IN):
            if c == 0:
                input_uint8[c, h, w] = (h * 32 + w * 4) % 256      # R: row gradient
            elif c == 1:
                input_uint8[c, h, w] = (w * 32 + h * 4) % 256      # G: col gradient
            else:
                input_uint8[c, h, w] = ((h + w) * 18) % 256         # B: diagonal

# Convert to int8 with x_zp=-128: int8 = uint8 - 128
input_int8 = (input_uint8.astype(np.int16) - 128).astype(np.int8)

print(f"\n=== Input (8x8x3, CHW, INT8) ===")
print(f"Shape: {input_int8.shape}")
print(f"Range: [{input_int8.min()}, {input_int8.max()}]")
for c in range(C_IN):
    print(f"\n  Channel {c}:")
    for h in range(H_IN):
        vals = ", ".join(f"{input_int8[c,h,w]:4d}" for w in range(W_IN))
        print(f"    row {h}: {vals}")

# ============================================================================
# 3. Compute expected output using EXACT hardware math
# ============================================================================
# The conv_engine computes:
#   acc = bias[oc]
#   for kh, kw, ic:
#     if in bounds: x_val = input_int8[ic,ih,iw] - x_zp = input_int8 + 128
#     else (pad):   x_val = 0 (pad with x_zp, so x_zp - x_zp = 0)
#     w_val = weight[oc,ic,kh,kw] - w_zp = weight[oc,ic,kh,kw] (w_zp=0)
#     acc += x_val * w_val
#
#   Requantize: output = clamp(round_shift(acc * M0, n_shift) + y_zp, -128, 127)
#   round_shift: (acc * M0 + (1 << (n_shift-1))) >> n_shift

output = np.zeros((C_OUT, H_OUT, W_OUT), dtype=np.int8)
output_acc = np.zeros((C_OUT, H_OUT, W_OUT), dtype=np.int64)  # raw accumulators

for oc in range(C_OUT):
    for oh in range(H_OUT):
        for ow in range(W_OUT):
            acc = int(bias[oc])
            for kh in range(KH):
                for kw in range(KW):
                    ih = oh * STRIDE + kh - PAD
                    iw = ow * STRIDE + kw - PAD
                    for ic in range(C_IN):
                        if 0 <= ih < H_IN and 0 <= iw < W_IN:
                            x_val = int(input_int8[ic, ih, iw]) - x_zp
                        else:
                            x_val = 0  # pad: x_zp - x_zp = 0
                        w_val = int(w_data[oc, ic, kh, kw]) - w_zp
                        acc += x_val * w_val

            output_acc[oc, oh, ow] = acc

            # Requantize
            prod = acc * M0
            prod += (1 << (n_shift - 1))
            result = prod >> n_shift
            result += y_zp
            result = max(-128, min(127, result))
            output[oc, oh, ow] = np.int8(result)

print(f"\n=== Expected Output (8x8x32) ===")
print(f"Shape: {output.shape}")
print(f"Range: [{output.min()}, {output.max()}]")

# Pixel (0,0) all 32 channels
print(f"\nPixel (0,0) - all 32 channels:")
print(output[:, 0, 0].tolist())

# Channel 0 all pixels
print(f"\nChannel 0 - 8x8 grid:")
for h in range(H_OUT):
    vals = ", ".join(f"{output[0,h,w]:4d}" for w in range(W_OUT))
    print(f"  row {h}: {vals}")

# ============================================================================
# 4. Generate C arrays for conv_crop_test.c
# ============================================================================

def format_c_array_s8(name, data, cols=16):
    """Format int8 array as C initializer"""
    flat = data.flatten().tolist()
    lines = []
    lines.append(f"static const s8 {name}[{len(flat)}] = {{")
    for i in range(0, len(flat), cols):
        chunk = flat[i:i+cols]
        line = "    " + ", ".join(f"{v:4d}" for v in chunk)
        if i + cols < len(flat):
            line += ","
        lines.append(line)
    lines.append("};")
    return "\n".join(lines)

def format_c_array_s32(name, data, cols=8):
    """Format int32 array as C initializer"""
    flat = data.flatten().tolist()
    lines = []
    lines.append(f"static const s32 {name}[{len(flat)}] = {{")
    for i in range(0, len(flat), cols):
        chunk = flat[i:i+cols]
        line = "    " + ", ".join(f"{v}" for v in chunk)
        if i + cols < len(flat):
            line += ","
        lines.append(line)
    lines.append("};")
    return "\n".join(lines)

print("\n\n" + "=" * 70)
print("C ARRAYS FOR conv_crop_test.c")
print("=" * 70)

# Input: CHW order, 192 bytes
print("\n/* Input image: 8x8, 3 channels, CHW order = 192 bytes */")
print(format_c_array_s8("input_data", input_int8))

# Weights: OIHW order, 864 bytes (transpose to OHWI done in C code)
print("\n/* Weights: 32 filters x 3x3x3, OIHW order = 864 bytes */")
print(format_c_array_s8("weight_data", w_data))

# Bias
print("\n/* Bias: 32 values as int32 */")
print(format_c_array_s32("bias_data", bias))

# Expected: pixel(0,0) all 32 channels
print("\n/* Expected output: pixel(0,0) for all 32 channels */")
print(format_c_array_s8("expected_pixel00", output[:, 0, 0]))

# Expected: all 64 pixels for channel 0
print("\n/* Expected output: all 64 pixels for channel 0 (8x8) */")
print(format_c_array_s8("expected_ch0_all", output[0]))

# Full expected output (all 2048 bytes) for comprehensive check
print("\n/* Expected output: all 2048 bytes (32 channels x 8x8) */")
print(format_c_array_s8("expected_full", output))

# Print M0, n_shift
print(f"\n/* M0 = {M0}u */")
print(f"/* n_shift = {n_shift} */")
print(f"/* x_zp = {x_zp} */")
print(f"/* w_zp = {w_zp} */")
print(f"/* y_zp = {y_zp} */")

# ============================================================================
# 5. BRAM layout check
# ============================================================================
input_bytes = C_IN * H_IN * W_IN  # 192
weight_bytes = C_OUT * C_IN * KH * KW  # 864
bias_bytes = C_OUT * 4  # 128
output_bytes = C_OUT * H_OUT * W_OUT  # 2048

print(f"\n=== BRAM Layout ===")
print(f"Input:   {input_bytes} bytes")
print(f"Weights: {weight_bytes} bytes")
print(f"Bias:    {bias_bytes} bytes")
print(f"Output:  {output_bytes} bytes")
print(f"Total:   {input_bytes + weight_bytes + bias_bytes + output_bytes} bytes")

# Proposed layout (tight packing, word-aligned):
inp_start = 0x000
inp_end   = inp_start + input_bytes  # 0x0C0
wgt_start = (inp_end + 3) & ~3       # 0x0C0 (already aligned)
wgt_end   = wgt_start + weight_bytes  # 0x0C0 + 0x360 = 0x420
bias_start = (wgt_end + 3) & ~3       # 0x420 (already aligned)
bias_end   = bias_start + bias_bytes   # 0x420 + 0x80 = 0x4A0
out_start  = (bias_end + 3) & ~3       # 0x4A0
out_end    = out_start + output_bytes  # 0x4A0 + 0x800 = 0xCA0

print(f"\nTight layout:")
print(f"  Input:   0x{inp_start:03X} - 0x{inp_end-1:03X}")
print(f"  Weights: 0x{wgt_start:03X} - 0x{wgt_end-1:03X}")
print(f"  Bias:    0x{bias_start:03X} - 0x{bias_end-1:03X}")
print(f"  Output:  0x{out_start:03X} - 0x{out_end-1:03X}")
print(f"  Total used: 0x{out_end:03X} = {out_end} bytes")
print(f"  Fits in 4KB: {out_end <= 4096}")

# Also check the layout from the prompt
print(f"\nPrompt layout:")
print(f"  Input:   0x000-0x0BF (192 bytes)")
print(f"  Weights: 0x100-0x45F (864 bytes)")
print(f"  Bias:    0x460-0x4DF (128 bytes)")
print(f"  Output:  0x500-0xCFF (2048 bytes)")
print(f"  Total:   0xD00 = {0xD00} bytes")
print(f"  Fits: {0xD00 <= 4096}")
