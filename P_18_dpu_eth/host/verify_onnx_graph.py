"""Verifica el primer QLinearConv y reproduce el calculo en Python puro int,
comparando con layer_002.bin real del ONNX."""
import numpy as np
import onnx
import zlib
from onnx import numpy_helper

ONNX = r"C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
INPUT_BIN = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs/layer_001.bin"
EXPECTED  = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs/layer_002.bin"

m = onnx.load(ONNX)
inits = {i.name: i for i in m.graph.initializer}

convs = [n for n in m.graph.node if n.op_type == "QLinearConv"]
first = convs[0]
print(f"First QLinearConv: {first.name}")

def show(label, name):
    a = numpy_helper.to_array(inits[name])
    if a.ndim == 0:
        print(f"  {label}: scalar={a.item()} dtype={a.dtype}")
    elif a.size <= 8:
        print(f"  {label}: {a.tolist()} dtype={a.dtype}")
    else:
        print(f"  {label}: shape={a.shape} dtype={a.dtype} first5={a.flatten()[:5].tolist()}")

show("x_scale", first.input[1])
show("x_zp",    first.input[2])
show("w",       first.input[3])
show("w_scale", first.input[4])
show("w_zp",    first.input[5])
show("y_scale", first.input[6])
show("y_zp",    first.input[7])
show("bias",    first.input[8])
print(f"  y output: {first.output[0]}")

for a in first.attribute:
    val = None
    if a.type == 7: val = list(a.ints)
    elif a.type == 2: val = a.i
    elif a.type == 3: val = a.s.decode()
    print(f"  attr {a.name} = {val}")

# Params
x_scale = float(numpy_helper.to_array(inits[first.input[1]]))
x_zp    = int(numpy_helper.to_array(inits[first.input[2]]))
W       = numpy_helper.to_array(inits[first.input[3]]).astype(np.int32)  # OIHW int8
w_scale = numpy_helper.to_array(inits[first.input[4]])
w_zp    = numpy_helper.to_array(inits[first.input[5]])
y_scale = float(numpy_helper.to_array(inits[first.input[6]]))
y_zp    = int(numpy_helper.to_array(inits[first.input[7]]))
bias    = numpy_helper.to_array(inits[first.input[8]]).astype(np.int32)

print(f"\n[params]")
print(f"  x_scale={x_scale}  x_zp={x_zp}")
print(f"  y_scale={y_scale}  y_zp={y_zp}")
print(f"  w_scale scalar={w_scale.ndim==0} w_zp scalar={w_zp.ndim==0}")
print(f"  W shape={W.shape}  bias shape={bias.shape}")

# Compute effective multiplier M = x_scale * w_scale / y_scale
# For per-tensor:
if w_scale.ndim == 0:
    w_scale_v = float(w_scale)
    w_zp_v    = int(w_zp)
    M = x_scale * w_scale_v / y_scale
    print(f"  M = x_scale*w_scale/y_scale = {M}")
    print(f"  w_zp = {w_zp_v}")

# Now run the int conv in numpy — layer 0: 3 -> 32, k=3, s=1, p=1
x = np.fromfile(INPUT_BIN, dtype=np.int8).reshape(1, 3, 416, 416).astype(np.int32)
print(f"\n[input] shape={x.shape}  crc=0x{zlib.crc32(x.astype(np.int8).tobytes())&0xFFFFFFFF:08X}")

# Pad 1 on all sides
xp = np.pad(x, ((0,0),(0,0),(1,1),(1,1)), mode="constant", constant_values=x_zp)
print(f"  padded shape={xp.shape}")

# ConvInt32: y_int[oc, oh, ow] = sum_ic,kh,kw (x_pad[ic, oh+kh, ow+kw] - x_zp) * (W[oc,ic,kh,kw] - w_zp)
# Then: y_fp = y_int * (x_scale*w_scale) + bias_fp_component (bias ya esta pre-scaled?)
# QLinearConv formula:
#   y = saturate((conv(x - x_zp, w - w_zp) + bias) * (x_scale*w_scale/y_scale) + y_zp)
# where bias is in int32, pre-scaled by x_scale*w_scale (so conv(...) + bias stays in same units).

print("\n[computing reference conv in numpy int32]...")
N, Cout, Kh, Kw = W.shape[0], W.shape[0], W.shape[2], W.shape[3]   # (32, .., 3, 3)
Cout = W.shape[0]
Cin  = W.shape[1]
Kh, Kw = W.shape[2], W.shape[3]
H, Wdim = x.shape[2], x.shape[3]
w_eff = W - int(w_zp_v)     # (O,I,H,W) int32
x_eff = xp - x_zp            # int32, shape (1,3,H+2,W+2)

# Naive conv — slow; do just layer to verify
out_int32 = np.zeros((1, Cout, H, Wdim), dtype=np.int64)
# Use im2col would be faster but we want simplicity
for oh in range(H):
    for ow in range(Wdim):
        patch = x_eff[0, :, oh:oh+Kh, ow:ow+Kw]   # (Cin, Kh, Kw)
        # multiply with W[:, :, :, :] and sum
        out_int32[0, :, oh, ow] = np.tensordot(
            w_eff, patch, axes=([1,2,3], [0,1,2])
        )
    if oh % 50 == 0:
        print(f"  row {oh}/{H}")

# Add bias
out_int32 += bias.reshape(1, -1, 1, 1)

# Requantize
out_fp = out_int32.astype(np.float64) * M
out_q = np.round(out_fp).astype(np.int64) + y_zp
out_q = np.clip(out_q, -128, 127).astype(np.int8)

# Compare vs expected
expected = np.fromfile(EXPECTED, dtype=np.int8).reshape(1, 32, 416, 416)
match = np.array_equal(out_q, expected)
print(f"\n=== comparing with {EXPECTED} ===")
print(f"  match: {match}")
if not match:
    diff = np.nonzero(out_q.flatten() != expected.flatten())[0]
    print(f"  divergent: {diff.size}/{out_q.size} ({100*diff.size/out_q.size:.2f}%)")
    if diff.size:
        i = diff[0]
        print(f"  first idx {i}:  py={out_q.flatten()[i]}  expected={expected.flatten()[i]}")
        print(f"  first 8 of mine    : {out_q.flatten()[:8]}")
        print(f"  first 8 of expected: {expected.flatten()[:8]}")
