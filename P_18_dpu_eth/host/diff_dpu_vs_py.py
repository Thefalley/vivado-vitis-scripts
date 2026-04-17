"""Lee el output del DPU que ya esta en DDR de la ultima ejecucion, y compara
byte-a-byte con el output Python verificado (match=True contra ONNX).

Si coincide en los primeros N bytes y diverge despues -> es un problema
especifico de algun tile o de un subindice.
Si diverge desde el byte 0 -> es un error sistematico en todo el flujo.
"""
import sys, os, zlib, struct
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost

# Python reference = reproduce conv layer 0 internally (es lo mismo que verify_onnx_graph)
import onnx
from onnx import numpy_helper

ONNX = r"C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
EXPECTED = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs/layer_002.bin"

# Load expected (Python verificado match ONNX)
exp_nchw = np.fromfile(EXPECTED, dtype=np.int8).reshape(1, 32, 416, 416)

# Read DPU output from board (already produced by last exec_layer)
with DpuHost("192.168.1.10", timeout=20.0) as h:
    print(f"PING: {h.ping()}")
    dpu_bytes = h.read_ddr(0x16000000, 32 * 416 * 416)
    print(f"Read {len(dpu_bytes)} B DPU output")

# DPU produces output in some layout. Try both NCHW (channel major) and NHWC.
dpu_nchw = np.frombuffer(dpu_bytes, dtype=np.int8).reshape(1, 32, 416, 416)
dpu_nhwc_alt = np.frombuffer(dpu_bytes, dtype=np.int8).reshape(1, 416, 416, 32)
dpu_nchw_from_nhwc = np.ascontiguousarray(np.transpose(dpu_nhwc_alt, (0, 3, 1, 2)))

# Compare first pixel (oh=0, ow=0) across 32 channels
print("\n=== PIXEL (0,0) — 32 channels ===")
print(f"  Expected (ONNX/Python, NCHW):")
py_pix = exp_nchw[0, :, 0, 0]
print(f"    {py_pix.tolist()}")

print(f"\n  DPU assuming NCHW (C stride = H*W = 416*416):")
dpu_pix_nchw = dpu_nchw[0, :, 0, 0]
print(f"    {dpu_pix_nchw.tolist()}")
print(f"    match: {np.array_equal(py_pix, dpu_pix_nchw)}")

print(f"\n  DPU assuming NHWC (reshape NHWC then transpose to NCHW):")
dpu_pix_nhwc = dpu_nchw_from_nhwc[0, :, 0, 0]
print(f"    {dpu_pix_nhwc.tolist()}")
print(f"    match: {np.array_equal(py_pix, dpu_pix_nhwc)}")

# First pixel in raw byte order (might reveal layout)
print("\n=== RAW FIRST 32 BYTES of DPU output (as read from DDR) ===")
print(f"  {np.frombuffer(dpu_bytes[:32], dtype=np.int8).tolist()}")
print(f"  Expected first 32 bytes (NCHW):")
print(f"    {exp_nchw.flatten()[:32].tolist()}")

# How many bytes differ overall
diff_nchw = np.count_nonzero(dpu_nchw.flatten() != exp_nchw.flatten())
diff_nhwc = np.count_nonzero(dpu_nchw_from_nhwc.flatten() != exp_nchw.flatten())
tot = exp_nchw.size
print(f"\n=== OVERALL ===")
print(f"  DPU-NCHW vs exp: {diff_nchw}/{tot} diff ({100*diff_nchw/tot:.2f}%)")
print(f"  DPU-NHWC vs exp: {diff_nhwc}/{tot} diff ({100*diff_nhwc/tot:.2f}%)")

# Look at bytes that DO match
match_mask = dpu_nchw.flatten() == exp_nchw.flatten()
n_match = match_mask.sum()
print(f"  DPU-NCHW matching: {n_match}/{tot} ({100*n_match/tot:.2f}%)")
# Where?
first_match_idx = np.where(match_mask)[0][:10] if n_match > 0 else []
print(f"  first 10 matching indices: {first_match_idx}")
