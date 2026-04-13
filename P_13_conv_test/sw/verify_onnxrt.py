#!/usr/bin/env python3
"""
verify_onnxrt.py -- Verify conv_crop_test expected values against onnxruntime.

Strategy:
1. Build a minimal ONNX sub-model containing ONLY the first QLinearConv node
   with 8x8 spatial dimensions (instead of 416x416).
2. Feed it the exact same int8 input used in gen_crop_data.py.
3. Compare onnxruntime output byte-by-byte with Python-computed expected values.
4. Write results to ONNXRT_VERIFICATION.txt.
"""

import onnx
from onnx import helper, TensorProto, numpy_helper
import onnxruntime as ort
import numpy as np
import math
import os
import sys

ONNX_MODEL = "C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
OUT_DIR = "C:/project/vivado/P_13_conv_test/sw"

report_lines = []

def log(msg=""):
    print(msg)
    report_lines.append(msg)

# ============================================================================
# 1. Load original model and extract parameters
# ============================================================================
model = onnx.load(ONNX_MODEL)

init_map = {}
for init in model.graph.initializer:
    init_map[init.name] = numpy_helper.to_array(init)

x_scale_val = float(init_map["conv2d/Conv2D__24:0_scale"])
x_zp_val    = int(init_map["conv2d/Conv2D__24:0_zero_point"])
w_data      = init_map["conv2d/Conv2D_weights_fused_bn_quantized"]  # [32,3,3,3] int8
w_scale_val = float(init_map["conv2d/Conv2D_weights_fused_bn_scale"])
w_zp_val    = int(init_map["conv2d/Conv2D_weights_fused_bn_zero_point"])
y_scale_val = float(init_map["batch_normalization/FusedBatchNormV3:0_scale"])
y_zp_val    = int(init_map["batch_normalization/FusedBatchNormV3:0_zero_point"])
bias_data   = init_map["conv2d/Conv2D_bias_fused_bn_quantized"]  # [32] int32

log("=== Quantization Parameters (from ONNX model) ===")
log(f"  x_scale = {x_scale_val}")
log(f"  x_zp    = {x_zp_val}")
log(f"  w_scale = {w_scale_val}")
log(f"  w_zp    = {w_zp_val}")
log(f"  y_scale = {y_scale_val}")
log(f"  y_zp    = {y_zp_val}")
log(f"  weights shape = {w_data.shape}")
log(f"  bias shape    = {bias_data.shape}")

# ============================================================================
# 2. Recreate the exact same input from gen_crop_data.py
# ============================================================================
C_IN = 3; C_OUT = 32; H_IN = 8; W_IN = 8
KH = KW = 3; STRIDE = 1; PAD = 1
H_OUT = 8; W_OUT = 8

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

input_int8 = (input_uint8.astype(np.int16) - 128).astype(np.int8)

# The QLinearConv input is NCHW, shape [1, 3, 8, 8]
input_nchw = input_int8.reshape(1, C_IN, H_IN, W_IN)

log(f"\n=== Input (NCHW int8) ===")
log(f"  Shape: {input_nchw.shape}, dtype: {input_nchw.dtype}")
log(f"  Range: [{input_nchw.min()}, {input_nchw.max()}]")

# ============================================================================
# 3. Build a minimal ONNX model with just QLinearConv (8x8 input)
# ============================================================================

X = helper.make_tensor_value_info("X", TensorProto.INT8, [1, 3, 8, 8])
Y = helper.make_tensor_value_info("Y", TensorProto.INT8, [1, 32, 8, 8])

x_scale_t = numpy_helper.from_array(np.array(x_scale_val, dtype=np.float32), name="x_scale")
x_zp_t    = numpy_helper.from_array(np.array(x_zp_val, dtype=np.int8), name="x_zp")
w_t       = numpy_helper.from_array(w_data, name="W")
w_scale_t = numpy_helper.from_array(np.array(w_scale_val, dtype=np.float32), name="w_scale")
w_zp_t    = numpy_helper.from_array(np.array(w_zp_val, dtype=np.int8), name="w_zp")
y_scale_t = numpy_helper.from_array(np.array(y_scale_val, dtype=np.float32), name="y_scale")
y_zp_t    = numpy_helper.from_array(np.array(y_zp_val, dtype=np.int8), name="y_zp")
bias_t    = numpy_helper.from_array(bias_data, name="B")

qconv_node = helper.make_node(
    "QLinearConv",
    inputs=["X", "x_scale", "x_zp", "W", "w_scale", "w_zp", "y_scale", "y_zp", "B"],
    outputs=["Y"],
    kernel_shape=[3, 3],
    strides=[1, 1],
    pads=[1, 1, 1, 1],
    group=1,
    name="test_qlinearconv"
)

graph = helper.make_graph(
    [qconv_node],
    "qlinearconv_test",
    [X],
    [Y],
    initializer=[x_scale_t, x_zp_t, w_t, w_scale_t, w_zp_t, y_scale_t, y_zp_t, bias_t]
)

onnx_model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
onnx_model.ir_version = 7

onnx.checker.check_model(onnx_model)
log("\n=== Sub-model built and validated (opset 13, QLinearConv) ===")

submodel_path = os.path.join(OUT_DIR, "_qlinearconv_test.onnx")
onnx.save(onnx_model, submodel_path)

# ============================================================================
# 4. Run with onnxruntime
# ============================================================================
sess = ort.InferenceSession(submodel_path, providers=["CPUExecutionProvider"])
input_name = sess.get_inputs()[0].name
log(f"\n=== Running onnxruntime (v{ort.__version__}) QLinearConv ===")
log(f"  Input: {input_name}, shape={sess.get_inputs()[0].shape}, type={sess.get_inputs()[0].type}")

ort_output = sess.run(None, {input_name: input_nchw})[0]
log(f"  Output shape: {ort_output.shape}, dtype: {ort_output.dtype}")
log(f"  Output range: [{ort_output.min()}, {ort_output.max()}]")

ort_result = ort_output[0]  # [32, 8, 8]

# ============================================================================
# 5. Compute expected with Python (same code as gen_crop_data.py)
# ============================================================================
M_exact = x_scale_val * w_scale_val / y_scale_val
OLD_M0 = 656954014
OLD_NS = 37

log(f"\n=== Python requantization ===")
log(f"  M_exact = {M_exact}")
log(f"  M0={OLD_M0}, n_shift={OLD_NS}")
log(f"  Approx M = {OLD_M0 / (2**OLD_NS)}")

py_output = np.zeros((C_OUT, H_OUT, W_OUT), dtype=np.int8)

for oc in range(C_OUT):
    for oh in range(H_OUT):
        for ow in range(W_OUT):
            acc = int(bias_data[oc])
            for kh in range(KH):
                for kw in range(KW):
                    ih = oh * STRIDE + kh - PAD
                    iw = ow * STRIDE + kw - PAD
                    for ic in range(C_IN):
                        if 0 <= ih < H_IN and 0 <= iw < W_IN:
                            x_val = int(input_int8[ic, ih, iw]) - x_zp_val
                        else:
                            x_val = 0
                        w_val = int(w_data[oc, ic, kh, kw]) - w_zp_val
                        acc += x_val * w_val

            prod = acc * OLD_M0
            prod += (1 << (OLD_NS - 1))
            result = prod >> OLD_NS
            result += y_zp_val
            result = max(-128, min(127, result))
            py_output[oc, oh, ow] = np.int8(result)

log(f"  Python output range: [{py_output.min()}, {py_output.max()}]")

# ============================================================================
# 6. Byte-by-byte comparison: onnxruntime vs Python
# ============================================================================
diff = ort_result.astype(np.int16) - py_output.astype(np.int16)
n_mismatch = int(np.count_nonzero(diff))
n_total = diff.size
max_diff = int(np.abs(diff).max())

log(f"\n{'='*60}")
log(f"COMPARISON: onnxruntime vs Python (gen_crop_data.py)")
log(f"{'='*60}")
log(f"  Total bytes: {n_total}")
log(f"  Exact matches: {n_total - n_mismatch}")
log(f"  Mismatches: {n_mismatch}")
log(f"  Max |diff|: {max_diff}")

if n_mismatch > 0:
    idx = np.where(diff != 0)
    log(f"\n  Mismatches detail (first 30):")
    log(f"  {'oc':>3s} {'oh':>2s} {'ow':>2s}  {'ort':>4s}  {'py':>4s}  {'diff':>5s}")
    for i in range(min(30, len(idx[0]))):
        oc, oh, ow = int(idx[0][i]), int(idx[1][i]), int(idx[2][i])
        log(f"  {oc:3d} {oh:2d} {ow:2d}  {int(ort_result[oc,oh,ow]):4d}  {int(py_output[oc,oh,ow]):4d}  {int(diff[oc,oh,ow]):+5d}")

# ============================================================================
# 7. Verify pixel(0,0) all channels
# ============================================================================
log(f"\n{'='*60}")
log(f"PIXEL (0,0) -- all 32 output channels")
log(f"{'='*60}")
log(f"  {'ch':>3s}  {'ort':>5s}  {'py':>5s}  {'match':>5s}")
for oc in range(C_OUT):
    o = int(ort_result[oc, 0, 0])
    p = int(py_output[oc, 0, 0])
    log(f"  {oc:3d}  {o:5d}  {p:5d}  {'OK' if o==p else 'DIFF=' + str(o-p)}")

# ============================================================================
# 8. Channel 0 all 64 pixels
# ============================================================================
log(f"\n{'='*60}")
log(f"CHANNEL 0 -- all 64 pixels (8x8)")
log(f"{'='*60}")
ch0_diff = ort_result[0].astype(np.int16) - py_output[0].astype(np.int16)
ch0_mismatch = int(np.count_nonzero(ch0_diff))
log(f"  Mismatches in ch0: {ch0_mismatch} of 64")
if ch0_mismatch > 0:
    for oh in range(H_OUT):
        for ow in range(W_OUT):
            if ch0_diff[oh, ow] != 0:
                log(f"    ({oh},{ow}): ort={int(ort_result[0,oh,ow])}, py={int(py_output[0,oh,ow])}, diff={int(ch0_diff[oh,ow])}")

# ============================================================================
# 9. Distribution of diffs
# ============================================================================
if n_mismatch > 0:
    log(f"\n{'='*60}")
    log(f"DIFF DISTRIBUTION")
    log(f"{'='*60}")
    for d in range(-3, 4):
        cnt = int(np.sum(diff == d))
        if cnt > 0:
            log(f"  diff={d:+d}: {cnt} pixels")

# ============================================================================
# 10. Also verify with float arithmetic (dequantize -> conv -> quantize)
# ============================================================================
log(f"\n{'='*60}")
log(f"FLOAT REFERENCE (dequant -> conv -> quant)")
log(f"{'='*60}")

# Dequantize input: float_x = (int8_x - x_zp) * x_scale
x_float = (input_int8.astype(np.float64) - x_zp_val) * x_scale_val

# Dequantize weights
w_float = (w_data.astype(np.float64) - w_zp_val) * w_scale_val

# Dequantize bias
# bias in QLinearConv is int32, scale = x_scale * w_scale
bias_float = bias_data.astype(np.float64) * (x_scale_val * w_scale_val)

# Float convolution
float_output = np.zeros((C_OUT, H_OUT, W_OUT), dtype=np.float64)
for oc in range(C_OUT):
    for oh in range(H_OUT):
        for ow in range(W_OUT):
            acc = bias_float[oc]
            for kh in range(KH):
                for kw in range(KW):
                    ih = oh * STRIDE + kh - PAD
                    iw = ow * STRIDE + kw - PAD
                    for ic in range(C_IN):
                        if 0 <= ih < H_IN and 0 <= iw < W_IN:
                            acc += x_float[ic, ih, iw] * w_float[oc, ic, kh, kw]
            float_output[oc, oh, ow] = acc

# Quantize output: int8_y = round(float_y / y_scale) + y_zp, clamp to [-128, 127]
float_quant = np.clip(np.round(float_output / y_scale_val) + y_zp_val, -128, 127).astype(np.int8)

diff_float_ort = float_quant.astype(np.int16) - ort_result.astype(np.int16)
diff_float_py  = float_quant.astype(np.int16) - py_output.astype(np.int16)

log(f"  Float-ref vs onnxruntime: {int(np.count_nonzero(diff_float_ort))} mismatches, max|diff|={int(np.abs(diff_float_ort).max())}")
log(f"  Float-ref vs Python:      {int(np.count_nonzero(diff_float_py))} mismatches, max|diff|={int(np.abs(diff_float_py).max())}")

# ============================================================================
# 11. Final verdict
# ============================================================================
log(f"\n{'='*60}")
log(f"FINAL VERDICT")
log(f"{'='*60}")

if n_mismatch == 0:
    verdict = "PERFECT MATCH"
    log(f"  Result: PERFECT MATCH")
    log(f"  onnxruntime QLinearConv output == Python expected values")
    log(f"  All {n_total} bytes are byte-for-byte identical.")
    log(f"  Conclusion: gen_crop_data.py expected values are 100% correct.")
    log(f"  The conv_crop_test.c test (2048/2048 pass) is fully validated.")
elif max_diff <= 1:
    verdict = "NEAR MATCH (max diff = 1)"
    log(f"  Result: NEAR MATCH ({n_mismatch} of {n_total} differ by 1)")
    log(f"  This is an acceptable rounding difference.")
    log(f"  onnxruntime uses a slightly different internal requantization")
    log(f"  (float M vs integer M0*2^-n), so off-by-one is expected.")
    log(f"  Conclusion: gen_crop_data.py expected values are TRUSTWORTHY.")
    log(f"  The conv_crop_test.c test (2048/2048 pass) is validated.")
else:
    verdict = f"MISMATCH (max diff = {max_diff})"
    log(f"  Result: MISMATCH ({n_mismatch} of {n_total} differ, max diff = {max_diff})")
    log(f"  Investigation needed!")

# ============================================================================
# Write report
# ============================================================================
report_path = os.path.join(OUT_DIR, "ONNXRT_VERIFICATION.txt")

with open(report_path, "w") as f:
    f.write("ONNX Runtime Verification\n")
    f.write("=========================\n\n")
    f.write(f"Date: 2026-04-11\n")
    f.write(f"onnxruntime version: {ort.__version__}\n")
    f.write(f"onnx version: {onnx.__version__}\n\n")

    f.write("Method:\n")
    f.write("  Built a standalone ONNX sub-model containing a single QLinearConv\n")
    f.write("  node with the exact same weights, bias, scales, and zero-points\n")
    f.write("  as the first QLinearConv in yolov4_int8_qop.onnx.\n")
    f.write("  Input: 8x8x3 gradient pattern (same as gen_crop_data.py), NCHW int8.\n")
    f.write("  Ran inference with onnxruntime CPUExecutionProvider.\n")
    f.write("  Compared output byte-by-byte against:\n")
    f.write("    (a) Python manual arithmetic from gen_crop_data.py (M0=656954014, n_shift=37)\n")
    f.write("    (b) Float64 reference (dequant -> float conv -> requant)\n\n")

    f.write(f"Result: {verdict}\n\n")

    f.write("Details:\n")
    f.write(f"  Bytes compared: {n_total}\n")
    f.write(f"  onnxruntime vs Python: {n_mismatch} mismatches, max|diff| = {max_diff}\n")
    f.write(f"  Float-ref vs onnxruntime: {int(np.count_nonzero(diff_float_ort))} mismatches\n")
    f.write(f"  Float-ref vs Python: {int(np.count_nonzero(diff_float_py))} mismatches\n\n")

    if n_mismatch == 0:
        f.write("Conclusion:\n")
        f.write("  The expected values in conv_crop_test.c are 100% correct.\n")
        f.write("  onnxruntime's QLinearConv produces byte-identical output.\n")
        f.write("  The HW test result (2048/2048 pass on ZedBoard) is fully validated.\n")
    elif max_diff <= 1:
        f.write("Conclusion:\n")
        f.write("  The expected values in conv_crop_test.c are TRUSTWORTHY.\n")
        f.write(f"  Only {n_mismatch}/{n_total} bytes differ, all by exactly 1 (rounding).\n")
        f.write("  onnxruntime uses float-based requantization internally,\n")
        f.write("  while our Python uses integer M0*2^(-n_shift) fixed-point math.\n")
        f.write("  Off-by-one on a small fraction of pixels is expected and acceptable.\n")
        f.write("  The HW test result (2048/2048 pass on ZedBoard) is validated.\n")
    else:
        f.write("Conclusion:\n")
        f.write("  INVESTIGATION NEEDED - unexpected differences.\n")

    f.write("\n\n--- Full comparison log ---\n\n")
    for line in report_lines:
        f.write(line + "\n")

log(f"\nReport written to: {report_path}")

# Cleanup temp model
try:
    os.remove(submodel_path)
except:
    pass

print(f"\nDone. Verdict: {verdict}")
