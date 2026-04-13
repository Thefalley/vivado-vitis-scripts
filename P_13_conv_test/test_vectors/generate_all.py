#!/usr/bin/env python3
"""
generate_all.py -- Generate binary test vectors for ALL YOLOv4 QLinearConv configs.

Reads yolov4_int8_qop.onnx and produces:
  test_vectors/
    config_3x3_s1_p1/layer_NNN/{input.bin, weights_ohwi.bin, bias.bin,
                                  expected_output.bin, params.json, info.txt}
    config_1x1_s1_p0/layer_NNN/...
    config_3x3_s2_p1100/layer_NNN/...
    test_plan.json

All .bin files are raw little-endian binary (no headers).
Expected output is computed with HW-exact integer math (no ONNX Runtime).

Usage:
  python generate_all.py                  # generate representative layers
  python generate_all.py --all            # generate ALL 110 layers
  python generate_all.py --layers 0,1,5   # specific conv indices
"""

import onnx
import numpy as np
from onnx import numpy_helper
import math
import os
import sys
import json
import argparse
import struct
import time

# ============================================================================
# Configuration
# ============================================================================
ONNX_PATH = "C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
OUT_ROOT  = os.path.dirname(os.path.abspath(__file__))
BRAM_BUDGET = 4096   # bytes
N_MAC       = 32      # conv_engine_v2 OC tile width


# ============================================================================
# Load ONNX model
# ============================================================================
def load_model():
    print("Loading ONNX model: %s" % ONNX_PATH)
    model = onnx.load(ONNX_PATH)
    init_map = {}
    for init in model.graph.initializer:
        init_map[init.name] = numpy_helper.to_array(init)
    qlconv_nodes = [n for n in model.graph.node if n.op_type == "QLinearConv"]
    print("  Total QLinearConv layers: %d" % len(qlconv_nodes))
    return model, init_map, qlconv_nodes


# ============================================================================
# Extract layer info from one QLinearConv node
# ============================================================================
def extract_layer_info(node, init_map, layer_idx):
    """Extract all parameters for a QLinearConv node."""
    info = {"idx": layer_idx, "name": node.name}

    # QLinearConv inputs:
    #   0: x, 1: x_scale, 2: x_zp, 3: w, 4: w_scale, 5: w_zp,
    #   6: y_scale, 7: y_zp, 8: B (optional)
    info["x_scale"] = float(init_map[node.input[1]])
    info["x_zp"]    = int(init_map[node.input[2]])
    info["w_data"]  = init_map[node.input[3]]    # [c_out, c_in/g, kh, kw] int8
    info["w_scale"] = float(init_map[node.input[4]])
    info["w_zp"]    = int(init_map[node.input[5]])
    info["y_scale"] = float(init_map[node.input[6]])
    info["y_zp"]    = int(init_map[node.input[7]])

    if len(node.input) > 8 and node.input[8] in init_map:
        info["bias"] = init_map[node.input[8]]   # [c_out] int32
    else:
        info["bias"] = None

    # Weight shape: [c_out, c_in_per_group, kh, kw]
    wshape = info["w_data"].shape
    info["c_out"]         = wshape[0]
    info["c_in_per_group"] = wshape[1]
    info["kh"]            = wshape[2]
    info["kw"]            = wshape[3]

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

    info["group"]   = attrs.get("group", 1)
    info["strides"] = attrs.get("strides", [1, 1])
    info["pads"]    = attrs.get("pads", [0, 0, 0, 0])
    info["c_in"]    = info["c_in_per_group"] * info["group"]

    info["pad_top"]    = info["pads"][0]
    info["pad_left"]   = info["pads"][1]
    info["pad_bottom"] = info["pads"][2]
    info["pad_right"]  = info["pads"][3]

    # Input spatial dims from model graph (try to infer from known YOLOv4 shapes)
    info["h_in_orig"], info["w_in_orig"] = infer_spatial_dims(info)

    return info


def infer_spatial_dims(info):
    """Infer the original H, W from known YOLOv4-416 architecture."""
    # YOLOv4 spatial dims at each stage (416 input)
    # Layer 0: 416x416 c_in=3
    # Layer 1 (s=2): 416->208, c_in=32
    # After CSP1: 208x208, c=64
    # Layer 8 (s=2): 208->104, c_in=64
    # After CSP2: 104x104, c=128
    # Layer 17 (s=2): 104->52, c_in=128
    # After CSP8: 52x52, c=256
    # Layer 38 (s=2): 52->26, c_in=256
    # After CSP8: 26x26, c=512
    # Layer 60 (s=2): 26->13, c_in=512
    # After CSP4: 13x13, c=1024
    # The c_in gives us a rough idea of the stage:
    c_in = info["c_in"]
    if c_in <= 3:
        return 416, 416
    elif c_in <= 32:
        return 416, 416
    elif c_in <= 64:
        return 208, 208
    elif c_in <= 128:
        return 104, 104
    elif c_in <= 256:
        return 52, 52
    elif c_in <= 512:
        return 26, 26
    else:
        return 13, 13


# ============================================================================
# Compute M0 and n_shift for requantization
# ============================================================================
def compute_m0_nshift(x_scale, w_scale, y_scale):
    """
    Compute requantization parameters.
    M0 must fit in signed 31 bits (< 2^31) for the HW multiplier.
    We want the LARGEST n_shift for best precision.
    """
    combined = (x_scale * w_scale) / y_scale
    best_n = None
    for n in range(47, 19, -1):
        M0 = round(combined * (2 ** n))
        if 0 < M0 < 2 ** 31:
            best_n = n
            break
    if best_n is None:
        raise ValueError("Cannot find valid M0/n_shift for scale=%.10g" % combined)
    M0 = round(combined * (2 ** best_n))
    return M0, best_n


# ============================================================================
# Compute test dimensions that fit in 4 KB BRAM
# ============================================================================
def compute_test_dims(info):
    """Determine c_out_test, c_in_test, crop_h, crop_w that fit in BRAM."""
    c_out = info["c_out"]
    c_in  = info["c_in"]
    kh    = info["kh"]
    kw    = info["kw"]
    stride_h = info["strides"][0]

    c_out_test = min(c_out, N_MAC)   # one OC tile

    # conv_engine: pad=1 for 3x3, pad=0 for 1x1
    pad = 1 if kh == 3 else 0

    best = None
    for crop in [8, 7, 6, 5, 4, 3, 2]:
        if kh == 3 and crop < 3:
            continue

        # Output size
        if stride_h == 2:
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
                    "c_in_test":  c_in_t,
                    "crop_h":     crop,
                    "crop_w":     crop,
                    "crop_h_out": crop_out,
                    "crop_w_out": crop_out,
                    "pad":        pad,
                    "total_bytes": total,
                }
                break

        if best is not None:
            break

    return best


# ============================================================================
# Generate deterministic input pattern
# ============================================================================
def gen_input(c_in, h, w, seed=42):
    """Generate a deterministic input pattern in CHW int8."""
    inp = np.zeros((c_in, h, w), dtype=np.int8)
    for c in range(c_in):
        for r in range(h):
            for col in range(w):
                val = ((c * 37 + r * 17 + col * 7 + c * r * 3 + seed) % 256) - 128
                inp[c, r, col] = np.int8(val)
    return inp


# ============================================================================
# Compute expected output with HW-exact integer math
# ============================================================================
def compute_expected(inp, weights, bias, x_zp, w_zp, M0, n_shift, y_zp,
                     stride, pad, c_out_test, c_in_test):
    """
    inp:     [c_in_test, h_in, w_in] int8
    weights: [c_out_test, c_in_test, kh, kw] int8  (OIHW)
    bias:    [c_out_test] int32 (or None)
    Returns: [c_out_test, h_out, w_out] int8
    """
    _, h_in, w_in = inp.shape
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
                        for ic in range(c_in_test):
                            if 0 <= ih < h_in and 0 <= iw < w_in:
                                x_val = int(inp[ic, ih, iw]) - x_zp
                            else:
                                x_val = 0   # pad: x_zp - x_zp = 0
                            w_val = int(weights[oc, ic, kkh, kkw]) - w_zp
                            acc += x_val * w_val

                # Requantize (HW-exact)
                prod = acc * M0
                prod += (1 << (n_shift - 1))   # round
                result = prod >> n_shift         # arithmetic right shift
                result += y_zp
                result = max(-128, min(127, result))
                output[oc, oh, ow] = np.int8(result)

    return output


# ============================================================================
# Config key for classification
# ============================================================================
def config_key(info):
    kh = info["kh"]
    kw = info["kw"]
    stride = info["strides"][0]
    pads = info["pads"]
    group = info["group"]
    pads_str = "".join(str(p) for p in pads)
    key = "k%dx%d_s%d_p%s" % (kh, kw, stride, pads_str)
    if group > 1:
        key += "_g%d" % group
    return key


def config_dirname(key):
    """Convert config key to directory name."""
    # k3x3_s1_p1111 -> config_3x3_s1_p1
    # k1x1_s1_p0000 -> config_1x1_s1_p0
    # k3x3_s2_p1100 -> config_3x3_s2_p1100
    parts = key.split("_")
    kernel = parts[0].replace("k", "")    # "3x3"
    stride = parts[1]                      # "s1"
    pads_raw = parts[2].replace("p", "")   # "1111" / "0000" / "1100"
    # Simplify symmetric pad
    if pads_raw == "1111":
        pads_str = "p1"
    elif pads_raw == "0000":
        pads_str = "p0"
    else:
        pads_str = "p" + pads_raw

    name = "config_%s_%s_%s" % (kernel, stride, pads_str)
    # Add group if present
    if len(parts) > 3:
        name += "_" + parts[3]
    return name


# ============================================================================
# Select representative layers per config
# ============================================================================
def select_representatives(layers_by_config, all_infos):
    """Pick representative layers for each config."""
    reps = {}
    for ckey, indices in layers_by_config.items():
        if len(indices) <= 4:
            # Few layers: test them all
            reps[ckey] = list(indices)
        else:
            # Pick: first, one from early-middle, one from late-middle, last
            n = len(indices)
            picks = set()
            picks.add(indices[0])                       # first
            picks.add(indices[n // 3])                  # ~33%
            picks.add(indices[2 * n // 3])              # ~66%
            picks.add(indices[-1])                      # last

            # Also pick one with smallest c_in and one with largest
            by_cin = sorted(indices, key=lambda i: all_infos[i]["c_in"])
            picks.add(by_cin[0])       # smallest c_in
            picks.add(by_cin[-1])      # largest c_in

            reps[ckey] = sorted(picks)
    return reps


# ============================================================================
# Generate binary files for one layer
# ============================================================================
def generate_layer(info, dims, out_dir):
    """Generate all .bin + params.json + info.txt for one layer."""
    os.makedirs(out_dir, exist_ok=True)

    layer_idx  = info["idx"]
    layer_name = info["name"]
    c_in_test  = dims["c_in_test"]
    c_out_test = dims["c_out_test"]
    crop_h     = dims["crop_h"]
    crop_w     = dims["crop_w"]
    crop_h_out = dims["crop_h_out"]
    crop_w_out = dims["crop_w_out"]
    pad        = dims["pad"]
    kh         = info["kh"]
    kw         = info["kw"]
    stride     = info["strides"][0]
    x_zp       = info["x_zp"]
    w_zp       = info["w_zp"]
    y_zp       = info["y_zp"]

    # M0 and n_shift
    M0, n_shift = compute_m0_nshift(info["x_scale"], info["w_scale"], info["y_scale"])

    # Input: CHW int8
    inp = gen_input(c_in_test, crop_h, crop_w, seed=layer_idx * 7 + 42)

    # Weights: take first c_out_test output channels, first c_in_test input channels
    w_oihw = info["w_data"][:c_out_test, :c_in_test, :, :]   # [c_out_test, c_in_test, kh, kw]

    # Transpose OIHW -> OHWI for HW
    w_ohwi = np.transpose(w_oihw, (0, 2, 3, 1))              # [c_out_test, kh, kw, c_in_test]

    # Bias: first c_out_test values
    if info["bias"] is not None:
        bias_test = info["bias"][:c_out_test].astype(np.int32)
    else:
        bias_test = np.zeros(c_out_test, dtype=np.int32)

    # Expected output
    expected = compute_expected(
        inp, w_oihw, bias_test, x_zp, w_zp, M0, n_shift, y_zp,
        stride, pad, c_out_test, c_in_test
    )

    # BRAM layout (tight, word-aligned)
    input_bytes  = c_in_test * crop_h * crop_w
    weight_bytes = c_out_test * c_in_test * kh * kw
    bias_bytes   = c_out_test * 4
    output_bytes = c_out_test * crop_h_out * crop_w_out

    inp_start  = 0x000
    inp_end    = inp_start + input_bytes
    wgt_start  = (inp_end + 3) & ~3
    wgt_end    = wgt_start + weight_bytes
    bias_start = (wgt_end + 3) & ~3
    bias_end   = bias_start + bias_bytes
    out_start  = (bias_end + 3) & ~3
    out_end    = out_start + output_bytes

    total_bytes = out_end

    # ---- Write binary files ----

    # input.bin: INT8, CHW order
    inp.astype(np.int8).tofile(os.path.join(out_dir, "input.bin"))

    # weights_ohwi.bin: INT8, OHWI order
    w_ohwi.astype(np.int8).tofile(os.path.join(out_dir, "weights_ohwi.bin"))

    # bias.bin: INT32 little-endian
    bias_test.astype("<i4").tofile(os.path.join(out_dir, "bias.bin"))

    # expected_output.bin: INT8, CHW order
    expected.astype(np.int8).tofile(os.path.join(out_dir, "expected_output.bin"))

    # ---- KSP encoding ----
    if kh == 1:
        ksize_enc = 0
    elif kh == 3:
        ksize_enc = 2
    else:
        ksize_enc = 0
    stride_enc = 1 if stride == 2 else 0
    pad_enc    = 1 if pad > 0 else 0
    ksp = (pad_enc << 3) | (stride_enc << 2) | ksize_enc

    # ---- params.json ----
    params = {
        "layer_name":  layer_name,
        "layer_index": layer_idx,
        "original": {
            "c_in":  info["c_in"],
            "c_out": info["c_out"],
            "h_in":  info["h_in_orig"],
            "w_in":  info["w_in_orig"],
        },
        "test": {
            "c_in":  c_in_test,
            "c_out": c_out_test,
            "h_in":  crop_h,
            "w_in":  crop_w,
            "h_out": crop_h_out,
            "w_out": crop_w_out,
        },
        "kernel": {
            "kh":     kh,
            "kw":     kw,
            "stride": stride,
            "pad":    pad,
            "pads":   info["pads"],
            "ksp":    ksp,
        },
        "quant": {
            "x_zp":    x_zp,
            "w_zp":    w_zp,
            "y_zp":    y_zp,
            "x_scale": info["x_scale"],
            "w_scale": info["w_scale"],
            "y_scale": info["y_scale"],
            "M0":      M0,
            "n_shift": n_shift,
        },
        "bram": {
            "addr_input":   "0x%03X" % inp_start,
            "addr_weights": "0x%03X" % wgt_start,
            "addr_bias":    "0x%03X" % bias_start,
            "addr_output":  "0x%03X" % out_start,
        },
        "sizes": {
            "input_bytes":  input_bytes,
            "weight_bytes": weight_bytes,
            "bias_bytes":   bias_bytes,
            "output_bytes": output_bytes,
            "total_bytes":  total_bytes,
        },
        "ic_tile_size": c_in_test,
    }
    with open(os.path.join(out_dir, "params.json"), "w") as f:
        json.dump(params, f, indent=4)

    # ---- info.txt ----
    lines = []
    lines.append("Layer %d: %s" % (layer_idx, layer_name))
    lines.append("")
    lines.append("Original layer:")
    lines.append("  c_in=%d, c_out=%d, h=%d, w=%d" % (
        info["c_in"], info["c_out"], info["h_in_orig"], info["w_in_orig"]))
    lines.append("  kernel=%dx%d, stride=%d, pads=%s, group=%d" % (
        kh, kw, stride, info["pads"], info["group"]))
    lines.append("")
    lines.append("Test subset:")
    lines.append("  c_in=%d, c_out=%d, crop=%dx%d -> %dx%d" % (
        c_in_test, c_out_test, crop_h, crop_w, crop_h_out, crop_w_out))
    lines.append("  pad=%d, ic_tile_size=%d" % (pad, c_in_test))
    lines.append("")
    lines.append("Quantization:")
    lines.append("  x_scale=%.10g, x_zp=%d" % (info["x_scale"], x_zp))
    lines.append("  w_scale=%.10g, w_zp=%d" % (info["w_scale"], w_zp))
    lines.append("  y_scale=%.10g, y_zp=%d" % (info["y_scale"], y_zp))
    lines.append("  M0=%d, n_shift=%d" % (M0, n_shift))
    lines.append("")
    lines.append("BRAM layout (%d bytes total, fits=%s):" % (total_bytes, total_bytes <= BRAM_BUDGET))
    lines.append("  Input:   0x%03X - 0x%03X  (%d bytes)" % (inp_start, inp_end - 1, input_bytes))
    lines.append("  Weights: 0x%03X - 0x%03X  (%d bytes)" % (wgt_start, wgt_end - 1, weight_bytes))
    lines.append("  Bias:    0x%03X - 0x%03X  (%d bytes)" % (bias_start, bias_end - 1, bias_bytes))
    lines.append("  Output:  0x%03X - 0x%03X  (%d bytes)" % (out_start, out_end - 1, output_bytes))
    lines.append("")
    lines.append("Binary files:")
    lines.append("  input.bin           %d bytes  INT8  CHW [%d,%d,%d]" % (
        input_bytes, c_in_test, crop_h, crop_w))
    lines.append("  weights_ohwi.bin    %d bytes  INT8  OHWI [%d,%d,%d,%d]" % (
        weight_bytes, c_out_test, kh, kw, c_in_test))
    lines.append("  bias.bin            %d bytes  INT32 LE [%d]" % (bias_bytes, c_out_test))
    lines.append("  expected_output.bin %d bytes  INT8  CHW [%d,%d,%d]" % (
        output_bytes, c_out_test, crop_h_out, crop_w_out))
    lines.append("")
    lines.append("Expected output range: [%d, %d]" % (int(expected.min()), int(expected.max())))

    with open(os.path.join(out_dir, "info.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

    return params


# ============================================================================
# Main
# ============================================================================
def main():
    parser = argparse.ArgumentParser(description="Generate test vectors for YOLOv4 conv layers")
    parser.add_argument("--all", action="store_true",
                        help="Generate test vectors for ALL 110 layers")
    parser.add_argument("--layers", type=str, default=None,
                        help="Comma-separated list of conv indices (e.g. 0,1,5,8)")
    parser.add_argument("--outdir", type=str, default=OUT_ROOT,
                        help="Output root directory")
    args = parser.parse_args()

    model, init_map, qlconv_nodes = load_model()
    n_layers = len(qlconv_nodes)

    # ---- Extract info for all layers ----
    print("\nExtracting layer info...")
    all_infos = []
    for i, node in enumerate(qlconv_nodes):
        info = extract_layer_info(node, init_map, i)
        all_infos.append(info)

    # ---- Classify by configuration ----
    layers_by_config = {}   # config_key -> [conv_indices]
    for i, info in enumerate(all_infos):
        ckey = config_key(info)
        layers_by_config.setdefault(ckey, []).append(i)

    print("\n=== Layer Classification ===")
    print("%-25s %5s  %s" % ("Config", "Count", "Conv indices (first 10)"))
    print("-" * 80)
    for ckey in sorted(layers_by_config.keys()):
        indices = layers_by_config[ckey]
        idx_str = ", ".join(str(i) for i in indices[:10])
        if len(indices) > 10:
            idx_str += "..."
        print("%-25s %5d  [%s]" % (ckey, len(indices), idx_str))

    # ---- Decide which layers to generate ----
    if args.layers is not None:
        target_indices = [int(x.strip()) for x in args.layers.split(",")]
        print("\nGenerating specified layers: %s" % target_indices)
    elif args.all:
        target_indices = list(range(n_layers))
        print("\nGenerating ALL %d layers" % n_layers)
    else:
        # Representative selection
        reps = select_representatives(layers_by_config, all_infos)
        target_indices = sorted(set(idx for idxlist in reps.values() for idx in idxlist))
        print("\nGenerating representative layers: %s (%d total)" % (target_indices, len(target_indices)))

    # ---- Compute test dimensions for all targets ----
    print("\nComputing test dimensions...")
    layer_dims = {}
    skipped = []
    for i in target_indices:
        info = all_infos[i]
        dims = compute_test_dims(info)
        if dims is None:
            print("  WARNING: Layer %d (%s) cannot fit in %d bytes -- skipping" % (
                i, info["name"], BRAM_BUDGET))
            skipped.append(i)
        else:
            layer_dims[i] = dims

    target_indices = [i for i in target_indices if i not in skipped]

    # ---- Generate config README files ----
    for ckey in sorted(layers_by_config.keys()):
        dirname = config_dirname(ckey)
        config_dir = os.path.join(args.outdir, dirname)
        os.makedirs(config_dir, exist_ok=True)

        indices = layers_by_config[ckey]
        sample = all_infos[indices[0]]

        readme_lines = []
        readme_lines.append("Configuration: %s" % ckey)
        readme_lines.append("Directory: %s" % dirname)
        readme_lines.append("")
        readme_lines.append("Kernel: %dx%d" % (sample["kh"], sample["kw"]))
        readme_lines.append("Stride: %d" % sample["strides"][0])
        readme_lines.append("Pads: %s" % sample["pads"])
        readme_lines.append("Group: %d" % sample["group"])
        readme_lines.append("")
        readme_lines.append("Total layers with this config: %d" % len(indices))
        readme_lines.append("Conv indices: %s" % indices)
        readme_lines.append("")
        readme_lines.append("Channel dimensions across layers:")
        for idx in indices:
            info = all_infos[idx]
            readme_lines.append("  [%3d] %-40s c_in=%3d c_out=%3d" % (
                idx, info["name"], info["c_in"], info["c_out"]))

        with open(os.path.join(config_dir, "README.txt"), "w") as f:
            f.write("\n".join(readme_lines) + "\n")

    # ---- Generate binary test vectors ----
    print("\nGenerating binary test vectors...")
    generated_params = {}   # conv_idx -> params dict
    t_start = time.time()

    for count, i in enumerate(target_indices):
        info = all_infos[i]
        dims = layer_dims[i]
        ckey = config_key(info)
        dirname = config_dirname(ckey)
        layer_dir = os.path.join(args.outdir, dirname, "layer_%03d" % i)

        params = generate_layer(info, dims, layer_dir)
        generated_params[i] = params

        elapsed = time.time() - t_start
        print("  [%3d/%3d] Layer %3d %-35s  %4d bytes  (%.1fs)" % (
            count + 1, len(target_indices), i, info["name"][:35],
            dims["total_bytes"], elapsed))

    # ---- Generate test_plan.json ----
    print("\nWriting test_plan.json...")

    # Build representative map
    reps_for_plan = select_representatives(layers_by_config, all_infos)

    configs_plan = {}
    for ckey in sorted(layers_by_config.keys()):
        indices = layers_by_config[ckey]
        dirname = config_dirname(ckey)
        sample = all_infos[indices[0]]
        configs_plan[dirname] = {
            "config_key":   ckey,
            "kernel":       "%dx%d" % (sample["kh"], sample["kw"]),
            "stride":       sample["strides"][0],
            "pads":         sample["pads"],
            "group":        sample["group"],
            "count":        len(indices),
            "conv_indices": indices,
        }

    representative_tests = {}
    for ckey, reps_list in reps_for_plan.items():
        dirname = config_dirname(ckey)
        representative_tests[dirname] = reps_list

    generated_list = {}
    for ckey in sorted(layers_by_config.keys()):
        dirname = config_dirname(ckey)
        gen_in_config = [i for i in target_indices if config_key(all_infos[i]) == ckey]
        generated_list[dirname] = gen_in_config

    test_plan = {
        "model": "yolov4_int8_qop.onnx",
        "model_path": ONNX_PATH,
        "total_qlinearconv_layers": n_layers,
        "unique_configs": len(layers_by_config),
        "total_generated": len(target_indices),
        "skipped": skipped,
        "bram_budget_bytes": BRAM_BUDGET,
        "configs": configs_plan,
        "representative_tests": representative_tests,
        "generated_tests": generated_list,
    }

    with open(os.path.join(args.outdir, "test_plan.json"), "w") as f:
        json.dump(test_plan, f, indent=4)

    # ---- Summary ----
    print("\n" + "=" * 70)
    print("GENERATION COMPLETE")
    print("=" * 70)
    print("  Output directory: %s" % args.outdir)
    print("  Layers generated: %d / %d" % (len(target_indices), n_layers))
    print("  Layers skipped:   %d" % len(skipped))
    print("  Configs:")
    for ckey in sorted(layers_by_config.keys()):
        dirname = config_dirname(ckey)
        gen_count = len(generated_list[dirname])
        total = len(layers_by_config[ckey])
        print("    %-25s  %d/%d generated" % (dirname, gen_count, total))
    print("  Total time: %.1f s" % (time.time() - t_start))
    print("  test_plan.json written")


if __name__ == "__main__":
    main()
