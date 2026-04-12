#!/usr/bin/env python3
"""
gen_crop_data.py -- Generate all data for conv_crop_test.c
Extracts from YOLOv4 ONNX, computes expected output with HW-exact math.

CRITICAL: M0 must fit in signed 31 bits (bit 31 = 0) because the
requantize module's multiplier treats M0 as signed(32).
We use n_shift=38, M0=1313907685 (< 2^31).
"""

import onnx
import numpy as np
from onnx import numpy_helper
import math
import sys

# ============================================================================
# 1. Load ONNX model
# ============================================================================
model = onnx.load("C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx")

init_map = {}
for init in model.graph.initializer:
    init_map[init.name] = numpy_helper.to_array(init)

x_scale = float(init_map["conv2d/Conv2D__24:0_scale"])
x_zp    = int(init_map["conv2d/Conv2D__24:0_zero_point"])
w_data  = init_map["conv2d/Conv2D_weights_fused_bn_quantized"]
w_scale = float(init_map["conv2d/Conv2D_weights_fused_bn_scale"])
w_zp    = int(init_map["conv2d/Conv2D_weights_fused_bn_zero_point"])
y_scale = float(init_map["batch_normalization/FusedBatchNormV3:0_scale"])
y_zp    = int(init_map["batch_normalization/FusedBatchNormV3:0_zero_point"])
bias    = init_map["conv2d/Conv2D_bias_fused_bn_quantized"]

# ============================================================================
# 2. Compute M0 and n_shift (MUST fit in signed 31 bits)
# ============================================================================
M_exact = x_scale * w_scale / y_scale

# Choose n_shift=38 -> M0 = 1313907685 < 2^31
N_SHIFT = 38
M0 = round(M_exact * (2**N_SHIFT))
assert M0 < 2**31, f"M0={M0} does not fit in signed 31 bits!"
assert M0 > 0

print(f"=== Quantization Parameters ===")
print(f"x_scale  = {x_scale}")
print(f"x_zp     = {x_zp}")
print(f"w_scale  = {w_scale}")
print(f"w_zp     = {w_zp}")
print(f"y_scale  = {y_scale}")
print(f"y_zp     = {y_zp}")
print(f"M_exact  = {M_exact}")
print(f"M0       = {M0} (0x{M0:08X})")
print(f"n_shift  = {N_SHIFT}")
print(f"M0 < 2^31: {M0 < 2**31}")
print(f"Approx M = {M0 / (2**N_SHIFT)}")

# ============================================================================
# 3. Create 8x8x3 input
# ============================================================================
C_IN = 3
C_OUT = 32
H_IN = 8
W_IN = 8
KH = KW = 3
STRIDE = 1
PAD = 1
H_OUT = 8
W_OUT = 8

# Gradient pattern: simulates a real image crop
input_uint8 = np.zeros((C_IN, H_IN, W_IN), dtype=np.uint8)
for c in range(C_IN):
    for h in range(H_IN):
        for w in range(W_IN):
            if c == 0:
                input_uint8[c, h, w] = (h * 32 + w * 4) % 256
            elif c == 1:
                input_uint8[c, h, w] = (w * 32 + h * 4) % 256
            else:
                input_uint8[c, h, w] = ((h + w) * 18) % 256

# int8 = uint8 - 128 (since x_zp = -128)
input_int8 = (input_uint8.astype(np.int16) - 128).astype(np.int8)

# ============================================================================
# 4. Compute expected output (HW-exact math)
# ============================================================================
# The conv_engine does:
#   acc = bias[oc]
#   for kh, kw, ic:
#     if in_bounds: x_val = input_int8[ic,ih,iw] - x_zp = input_int8 + 128
#     else (pad):   x_val = 0 (pad with x_zp, so x_zp - x_zp = 0)
#     w_val = weight[oc,ic,kh,kw]  (w_zp = 0)
#     acc += x_val * w_val
#   Requantize: output = clamp(((acc * M0) + 2^(n-1)) >> n + y_zp, -128, 127)

output = np.zeros((C_OUT, H_OUT, W_OUT), dtype=np.int8)

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
                            x_val = 0
                        w_val = int(w_data[oc, ic, kh, kw]) - w_zp
                        acc += x_val * w_val

            # Requantize (exact HW math)
            prod = acc * M0
            prod += (1 << (N_SHIFT - 1))
            result = prod >> N_SHIFT  # arithmetic right shift (Python >> is arithmetic for int)
            result += y_zp
            result = max(-128, min(127, result))
            output[oc, oh, ow] = np.int8(result)

# ============================================================================
# 5. Cross-check: also compute with old M0/n_shift from existing test
# ============================================================================
OLD_M0 = 656954014
OLD_NS = 37
output_old = np.zeros((C_OUT, H_OUT, W_OUT), dtype=np.int8)

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
                            x_val = 0
                        w_val = int(w_data[oc, ic, kh, kw]) - w_zp
                        acc += x_val * w_val

            prod = acc * OLD_M0
            prod += (1 << (OLD_NS - 1))
            result = prod >> OLD_NS
            result += y_zp
            result = max(-128, min(127, result))
            output_old[oc, oh, ow] = np.int8(result)

diff = output.astype(np.int16) - output_old.astype(np.int16)
print(f"\n=== Cross-check: new vs old M0/n_shift ===")
print(f"Max diff: {np.abs(diff).max()}")
print(f"Nonzero: {np.count_nonzero(diff)} of {diff.size}")
if np.count_nonzero(diff) > 0:
    idx = np.where(diff != 0)
    for i in range(min(10, len(idx[0]))):
        oc, oh, ow = idx[0][i], idx[1][i], idx[2][i]
        print(f"  [{oc},{oh},{ow}]: new={output[oc,oh,ow]}, old={output_old[oc,oh,ow]}, diff={diff[oc,oh,ow]}")

# Use old M0/n_shift since it matches the HW that already passed 41/41
# and the difference is at most 1 bit (rounding)
USE_OLD = True
if USE_OLD and np.abs(diff).max() <= 1:
    print("\nUsing OLD M0/n_shift (matches existing HW test, max diff <= 1)")
    FINAL_M0 = OLD_M0
    FINAL_NS = OLD_NS
    final_output = output_old
else:
    print("\nUsing NEW M0/n_shift")
    FINAL_M0 = M0
    FINAL_NS = N_SHIFT
    final_output = output

# ============================================================================
# 6. Output C arrays
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

print(f"\n/* ===== CONSTANTS FOR conv_crop_test.c ===== */")
print(f"/* M0 = {FINAL_M0}u */")
print(f"/* n_shift = {FINAL_NS} */")
print(f"/* x_zp = {x_zp} */")
print(f"/* w_zp = {w_zp} */")
print(f"/* y_zp = {y_zp} */")

print()
print("/* Input image: 8x8, 3 channels, CHW order = 192 bytes */")
print(c_array_s8("input_data", input_int8))

print()
print("/* Weights: 32 filters x 3x3x3, OIHW order = 864 bytes */")
print(c_array_s8("weight_data", w_data))

print()
print("/* Bias: 32 values as int32 */")
print(c_array_s32("bias_data", bias))

print()
print("/* Expected output: pixel(0,0) for all 32 channels */")
print(c_array_s8("expected_pixel00", final_output[:, 0, 0]))

print()
print("/* Expected output: all 64 pixels for channel 0 (8x8) */")
print(c_array_s8("expected_ch0_all", final_output[0]))

print()
print("/* Full expected output: 32ch x 8x8 = 2048 bytes */")
print(c_array_s8("expected_full", final_output))

# ============================================================================
# 7. Verify BRAM layout fits
# ============================================================================
# Tight layout:
#   Input:   0x000 - 0x0BF (192 bytes)
#   Weights: 0x0C0 - 0x41F (864 bytes)
#   Bias:    0x420 - 0x49F (128 bytes)
#   Output:  0x4A0 - 0xC9F (2048 bytes)
#   Total:   0xCA0 = 3232 bytes  (fits in 4KB)
print(f"\n=== BRAM Layout (tight) ===")
print(f"Input:   0x000 - 0x0BF (192 bytes)")
print(f"Weights: 0x0C0 - 0x41F (864 bytes)")
print(f"Bias:    0x420 - 0x49F (128 bytes)")
print(f"Output:  0x4A0 - 0xC9F (2048 bytes)")
print(f"Total:   0xCA0 = 3232 bytes -- FITS in 4KB")

# ============================================================================
# 8. Summary
# ============================================================================
print(f"\n=== Output Summary ===")
print(f"Shape: {final_output.shape}")
print(f"Range: [{final_output.min()}, {final_output.max()}]")
print(f"\nPixel (0,0) all 32 ch: {final_output[:, 0, 0].tolist()}")
print(f"\nChannel 0, 8x8:")
for h in range(H_OUT):
    print(f"  {final_output[0, h, :].tolist()}")
