"""Genera vectores de layer 0 para testbench XSIM:
  - Input 4x4x3 del ONNX (esquina del layer_001.bin)
  - Pesos OIHW layer 0 del ONNX (32,3,3,3) -> OHWI (32,3,3,3)
  - Bias int32 (32,)
  - Output esperado 4x4x32 (calculado con numpy int32 bit-exact).

Escribe todos como .hex (1 byte por linea, dos chars hex) en los paths que
el testbench VHDL leera con textio.
"""
import numpy as np
import onnx
import zlib
from onnx import numpy_helper

ONNX = r"C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
INPUT_BIN = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs/layer_001.bin"
OUT_DIR = r"C:/project/vivado/P_18_dpu_eth/host/xsim_vectors"

import os
os.makedirs(OUT_DIR, exist_ok=True)

# Load ONNX params for layer 0
m = onnx.load(ONNX)
inits = {i.name: i for i in m.graph.initializer}
conv = [n for n in m.graph.node if n.op_type == "QLinearConv"][0]

W = numpy_helper.to_array(inits[conv.input[3]]).astype(np.int32)  # OIHW (32,3,3,3)
w_zp = int(numpy_helper.to_array(inits[conv.input[5]]))           # 0
bias = numpy_helper.to_array(inits[conv.input[8]]).astype(np.int32)
x_zp = int(numpy_helper.to_array(inits[conv.input[2]]))           # -128
y_zp = int(numpy_helper.to_array(inits[conv.input[7]]))           # -17
x_scale = float(numpy_helper.to_array(inits[conv.input[1]]))
w_scale = float(numpy_helper.to_array(inits[conv.input[4]]))
y_scale = float(numpy_helper.to_array(inits[conv.input[6]]))
M = x_scale * w_scale / y_scale
print(f"x_zp={x_zp} y_zp={y_zp}  M={M}")

# M0 * 2^-n form (firmware expects u32 M0 with implicit 2^-37 or so)
# From layer_configs.h: M0=656954014, n_shift=37 for layer 0
M0 = 656954014
n_shift = 37
print(f"Firmware: M0={M0} n_shift={n_shift}  M0/2^n = {M0 / 2**n_shift}")

# Extract 4x4 corner of input (NCHW)
x_full = np.fromfile(INPUT_BIN, dtype=np.int8).reshape(1, 3, 416, 416)
H = W_dim = 4
x = x_full[:, :, :H, :W_dim].astype(np.int32)   # (1,3,4,4)
print(f"x shape={x.shape}  first ch0 row0: {x[0,0,0,:].tolist()}")

# Compute expected output (pure numpy int32 conv + Q0.31 mult + n_shift)
xp = np.pad(x, ((0,0),(0,0),(1,1),(1,1)), mode="constant", constant_values=x_zp)
w_eff = W - w_zp
x_eff = xp - x_zp

Cout = 32
out_int32 = np.zeros((1, Cout, H, W_dim), dtype=np.int64)
for oh in range(H):
    for ow in range(W_dim):
        patch = x_eff[0, :, oh:oh+3, ow:ow+3]
        out_int32[0, :, oh, ow] = np.tensordot(w_eff, patch, axes=([1,2,3],[0,1,2]))

out_int32 += bias.reshape(1, -1, 1, 1)

# --- Requantize using float M (matches ONNX exactly) ---
out_fp = out_int32.astype(np.float64) * M
out_q_float = np.clip(np.round(out_fp).astype(np.int64) + y_zp, -128, 127).astype(np.int8)

# --- Requantize using M0 / 2^n (matches firmware, integer-only) ---
# acc32 = int32 conv+bias. Then (acc32 * M0 + (1<<(n-1))) >> n + y_zp, clip [-128,127].
acc = out_int32.astype(np.int64)
rounding = (1 << (n_shift - 1))
out_int = ((acc * M0 + rounding) >> n_shift) + y_zp
out_q_int = np.clip(out_int, -128, 127).astype(np.int8)

# Check match
print(f"\nfloat-M vs fixed-M0 match: {np.array_equal(out_q_float, out_q_int)}")
if not np.array_equal(out_q_float, out_q_int):
    diff = np.nonzero(out_q_float.flatten() != out_q_int.flatten())[0]
    print(f"  {diff.size}/{out_q_float.size} differ (expected some due to rounding)")

# Use fixed-M0 version as reference (matches what RTL computes)
ref_out = out_q_int    # (1,32,4,4) NCHW int8
print(f"\nRef output NCHW first pixel (oh=0,ow=0, 32 ch):")
print(f"  {ref_out[0,:,0,0].tolist()}")

# --- Dump as .hex files (1 byte per line, two hex chars) ---
def write_hex(arr, path):
    arr_u8 = arr.astype(np.int8).view(np.uint8).flatten()
    with open(path, "w") as f:
        for b in arr_u8:
            f.write(f"{b:02X}\n")

# Input CHW — the RTL indexes as input[c*H*W + h*W + w]
write_hex(x, os.path.join(OUT_DIR, "input_4x4x3_nchw.hex"))
# Weights OHWI — extractor transposes (O,I,H,W) -> (O,H,W,I)
W_ohwi = np.ascontiguousarray(np.transpose(W.astype(np.int8), (0, 2, 3, 1)))
write_hex(W_ohwi, os.path.join(OUT_DIR, "weights_ohwi.hex"))
# Bias int32 LE
bias_le = bias.astype(np.int32).view(np.uint8)
with open(os.path.join(OUT_DIR, "bias_int32.hex"), "w") as f:
    for b in bias_le.flatten():
        f.write(f"{b:02X}\n")
# Expected NCHW
write_hex(ref_out, os.path.join(OUT_DIR, "expected_out_nchw.hex"))

# Sumary
print(f"\n[dump] input:    {x.nbytes} B   -> input_4x4x3_nchw.hex")
print(f"[dump] weights:  {W_ohwi.nbytes} B  -> weights_ohwi.hex")
print(f"[dump] bias:     {bias_le.nbytes} B  -> bias_int32.hex")
print(f"[dump] expected: {ref_out.nbytes} B  -> expected_out_nchw.hex")

# Print params for TB hardcoding
print(f"\n=== PARAMS for VHDL TB ===")
print(f"  c_in  = 3   c_out = 32")
print(f"  h_in  = {H}  w_in  = {W_dim}")
print(f"  h_out = {H}  w_out = {W_dim}")
print(f"  kernel = 3  stride = 1")
print(f"  pad_top = 1 pad_bot = 1 pad_left = 1 pad_right = 1")
print(f"  x_zp = {x_zp}  (as unsigned 8-bit: {x_zp & 0xFF:02X})")
print(f"  y_zp = {y_zp}  (as unsigned 8-bit: {y_zp & 0xFF:02X})")
print(f"  M0   = {M0} = 0x{M0:08X}")
print(f"  n_shift = {n_shift}")

# BRAM layout calc
in_bytes  = 3 * H * W_dim           # 48
out_bytes = 32 * H * W_dim           # 512
w_bytes   = 32 * 3 * 3 * 3           # 864
b_bytes   = 32 * 4                   # 128
tot = ((in_bytes + 0x3F) & ~0x3F) + ((out_bytes + 0x3F) & ~0x3F) + \
      ((w_bytes + 0x3F) & ~0x3F) + ((b_bytes + 0x3F) & ~0x3F)
print(f"\n  BRAM total (aligned 64): {tot} bytes (<=4096)")
