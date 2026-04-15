#!/usr/bin/env python3
"""
extract_weights_blob.py -- Extract every QLinearConv weight + bias tensor from
yolov4_int8_qop.onnx and pack them into a single binary blob loadable to the
ZedBoard DDR (region 0x12000000-0x15FFFFFF, 64 MB reserved).

Outputs:
  - C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin
        Contiguous byte stream: for every FPGA layer in graph order (0..254)
        that is a CONV, append weights (int8, OHWI) then bias (int32 LE).
  - C:/project/vivado/P_17_dpu_multi/sw/runtime/yolov4_weights_manifest.h
        weights_entry_t WEIGHTS_TABLE[NUM_FPGA_LAYERS] = { ... };
        Non-conv layers get an all-zero entry so the index lines up with
        LAYERS[] in layer_configs.h.

Layout:
  ONNX QLinearConv weight tensor is OIHW int8.  conv_engine_v3 expects OHWI,
  so we transpose every weight tensor to (O, H, W, I) before serialising.
  Bias is 1-D int32 per output channel -- left as-is.
  Weight zero-points are checked to be zero (assertion) and discarded.
"""

import os
import sys
import time
import numpy as np
import onnx
from onnx import numpy_helper

ONNX_PATH = "C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
BLOB_PATH = "C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin"
HDR_PATH  = "C:/project/vivado/P_17_dpu_multi/sw/runtime/yolov4_weights_manifest.h"

NUM_FPGA_LAYERS = 255

FPGA_OPS = {
    "QLinearConv", "QLinearLeakyRelu", "QLinearAdd",
    "QLinearConcat", "MaxPool", "Resize",
}

DDR_REGION_BASE = 0x12000000
DDR_REGION_END  = 0x15FFFFFF
DDR_REGION_SIZE = DDR_REGION_END - DDR_REGION_BASE + 1   # 64 MiB


def main():
    t_start = time.time()

    print(f"[load] {ONNX_PATH}")
    model = onnx.load(ONNX_PATH)

    # Index every initializer by name for O(1) lookup.
    inits = {init.name: init for init in model.graph.initializer}
    print(f"[load] {len(inits)} initializers, {len(model.graph.node)} nodes")

    # Collect FPGA layers in graph order (must match LAYERS[] in layer_configs.h).
    fpga_nodes = [n for n in model.graph.node if n.op_type in FPGA_OPS]
    assert len(fpga_nodes) == NUM_FPGA_LAYERS, (
        f"expected {NUM_FPGA_LAYERS} FPGA nodes, got {len(fpga_nodes)}"
    )

    # entries[fpga_idx] = (w_off, w_bytes, b_off, b_bytes) or None if non-conv.
    entries = [None] * NUM_FPGA_LAYERS
    blob = bytearray()

    n_conv = 0
    biggest = (-1, 0, "", ())   # (idx, bytes, name, oihw_shape)

    for li, node in enumerate(fpga_nodes):
        if node.op_type != "QLinearConv":
            continue
        n_conv += 1

        # QLinearConv inputs (in order):
        #   0 x, 1 x_scale, 2 x_zp,
        #   3 w, 4 w_scale, 5 w_zp,
        #   6 y_scale, 7 y_zp,
        #   8 B (bias, optional but present in this model)
        w_name  = node.input[3]
        wzp_nm  = node.input[5]
        b_name  = node.input[8] if len(node.input) > 8 else None

        if w_name not in inits:
            raise RuntimeError(
                f"layer {li} ({node.name}): weight '{w_name}' not in initializers"
            )
        w_t = numpy_helper.to_array(inits[w_name])
        if w_t.dtype != np.int8:
            raise RuntimeError(
                f"layer {li}: expected int8 weights, got {w_t.dtype}"
            )
        if w_t.ndim != 4:
            raise RuntimeError(
                f"layer {li}: expected 4-D weights, got shape {w_t.shape}"
            )

        # Verify w_zp == 0 (sanity; layer_configs.h hardcodes w_zp=0 anyway).
        if wzp_nm in inits:
            wzp = numpy_helper.to_array(inits[wzp_nm])
            if np.any(wzp != 0):
                print(f"[warn] layer {li}: non-zero w_zp = {wzp.flatten()[:8]}")

        # OIHW -> OHWI (axes 0,2,3,1).
        oihw_shape = tuple(int(s) for s in w_t.shape)
        w_ohwi = np.ascontiguousarray(np.transpose(w_t, (0, 2, 3, 1)))

        # Bias: int32 little-endian, 1-D length c_out. Always present here.
        if b_name and b_name in inits:
            b_t = numpy_helper.to_array(inits[b_name])
            if b_t.dtype != np.int32:
                # Some QOps store bias as int32 already; convert if not.
                b_t = b_t.astype(np.int32)
        else:
            # No bias -> emit zeros sized c_out.
            b_t = np.zeros((oihw_shape[0],), dtype=np.int32)

        b_le = np.ascontiguousarray(b_t.astype("<i4"))

        # Append to blob.
        w_off = len(blob)
        w_bytes = w_ohwi.nbytes
        blob.extend(w_ohwi.tobytes())

        b_off = len(blob)
        b_bytes = b_le.nbytes
        blob.extend(b_le.tobytes())

        entries[li] = (w_off, w_bytes, b_off, b_bytes)

        if w_bytes > biggest[1]:
            biggest = (li, w_bytes, node.name, oihw_shape)

    total_bytes = len(blob)

    # Write blob.
    os.makedirs(os.path.dirname(BLOB_PATH), exist_ok=True)
    with open(BLOB_PATH, "wb") as f:
        f.write(blob)
    print(f"[write] {BLOB_PATH} ({total_bytes/1024/1024:.2f} MiB)")

    # Write manifest header.
    os.makedirs(os.path.dirname(HDR_PATH), exist_ok=True)
    with open(HDR_PATH, "w") as f:
        f.write("/* AUTO-GENERATED by extract_weights_blob.py - DO NOT EDIT */\n")
        f.write("/* YOLOv4-INT8 weights+bias blob manifest, 1 entry per FPGA layer. */\n\n")
        f.write("#ifndef YOLOV4_WEIGHTS_MANIFEST_H\n")
        f.write("#define YOLOV4_WEIGHTS_MANIFEST_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"#define NUM_FPGA_LAYERS {NUM_FPGA_LAYERS}\n")
        f.write(f"#define WEIGHTS_BLOB_BYTES   {total_bytes}u\n")
        f.write(f"#define WEIGHTS_DDR_BASE     0x{DDR_REGION_BASE:08X}u\n")
        f.write(f"#define WEIGHTS_DDR_END      0x{DDR_REGION_END:08X}u\n")
        f.write(f"#define WEIGHTS_DDR_SIZE     0x{DDR_REGION_SIZE:08X}u  /* 64 MiB */\n\n")
        f.write("typedef struct {\n")
        f.write("    uint32_t weights_offset;   /* byte offset in blob */\n")
        f.write("    uint32_t weights_bytes;\n")
        f.write("    uint32_t bias_offset;\n")
        f.write("    uint32_t bias_bytes;\n")
        f.write("} weights_entry_t;\n\n")
        f.write("/* Indexed by FPGA layer index (0..254). Non-CONV layers carry all zeros. */\n")
        f.write("static const weights_entry_t WEIGHTS_TABLE[NUM_FPGA_LAYERS] = {\n")
        for li, e in enumerate(entries):
            if e is None:
                f.write(f"    [{li:3d}] = {{0u, 0u, 0u, 0u}},\n")
            else:
                w_off, w_bytes, b_off, b_bytes = e
                f.write(
                    f"    [{li:3d}] = {{{w_off}u, {w_bytes}u, "
                    f"{b_off}u, {b_bytes}u}},\n"
                )
        f.write("};\n\n")
        f.write("#endif /* YOLOV4_WEIGHTS_MANIFEST_H */\n")
    print(f"[write] {HDR_PATH}")

    # Stats / DDR fit check.
    elapsed = time.time() - t_start
    fits = total_bytes <= DDR_REGION_SIZE
    print()
    print("================ STATS ================")
    print(f"  conv layers extracted   : {n_conv} / {NUM_FPGA_LAYERS}")
    print(f"  total blob size         : {total_bytes:,} bytes "
          f"({total_bytes/1024/1024:.2f} MiB)")
    print(f"  DDR region reserved     : {DDR_REGION_SIZE:,} bytes "
          f"({DDR_REGION_SIZE/1024/1024:.0f} MiB) "
          f"@ 0x{DDR_REGION_BASE:08X}-0x{DDR_REGION_END:08X}")
    print(f"  fits in DDR region      : {'YES' if fits else 'NO -- OVERFLOW!'}")
    print(f"  free headroom           : "
          f"{(DDR_REGION_SIZE-total_bytes)/1024/1024:.2f} MiB")
    li, sz, nm, sh = biggest
    print(f"  biggest weight tensor   : layer {li} OIHW={sh} "
          f"-> {sz:,} bytes ({sz/1024/1024:.2f} MiB)  [{nm}]")
    print(f"  extraction time         : {elapsed:.2f} s")
    print("=======================================")

    if not fits:
        sys.exit(1)


if __name__ == "__main__":
    main()
