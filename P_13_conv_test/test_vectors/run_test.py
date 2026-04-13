#!/usr/bin/env python3
"""
run_test.py -- Run one or more conv_engine_v2 HW tests on ZedBoard.

Given a layer directory with {params.json, input.bin, weights_ohwi.bin,
bias.bin, expected_output.bin}, this script:
  1. Generates a .c test file from the binary data
  2. Builds the ELF via xsct (build_layer_xsct.tcl)
  3. Programs the FPGA and runs the ELF on the ZedBoard
  4. Reads the JTAG result and compares with expected_output.bin
  5. Reports PASS/FAIL

Usage:
  python run_test.py config_3x3_s1_p1/layer_000
  python run_test.py config_3x3_s1_p1/layer_000 config_1x1_s1_p0/layer_002
  python run_test.py --all                # run all generated layers
  python run_test.py --config config_3x3_s1_p1   # all layers in one config
  python run_test.py --plan               # run representative_tests from test_plan.json

Prerequisites:
  - generate_all.py has been run to create the .bin files
  - Vivado bitstream is built (build/zynq_conv.xsa, build/.../wrapper.bit)
  - xsct is available
"""

import os
import sys
import json
import struct
import subprocess
import argparse
import time
import glob as globmod
import numpy as np

# ============================================================================
# Paths
# ============================================================================
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
P13_DIR     = os.path.dirname(SCRIPT_DIR)
SW_DIR      = os.path.join(P13_DIR, "sw")

BIT_FILE    = os.path.join(P13_DIR, "build", "zynq_conv.runs", "impl_1",
                           "zynq_conv_bd_wrapper.bit")
XSA_FILE    = os.path.join(P13_DIR, "build", "zynq_conv.xsa")
WS_DIR      = os.path.join(P13_DIR, "vitis_ws_layer")

FSBL_CANDIDATES = [
    os.path.join(P13_DIR, "vitis_ws_crop", "zynq_conv_platform",
                 "export", "zynq_conv_platform", "sw",
                 "zynq_conv_platform", "boot", "fsbl.elf"),
    os.path.join(P13_DIR, "vitis_ws", "zynq_conv_platform",
                 "zynq_fsbl", "fsbl.elf"),
    os.path.join(P13_DIR, "vitis_ws_layer", "zynq_conv_platform",
                 "export", "zynq_conv_platform", "sw",
                 "zynq_conv_platform", "boot", "fsbl.elf"),
]

BUILD_TCL   = os.path.join(SW_DIR, "build_layer_xsct.tcl")
RUN_TCL     = os.path.join(SW_DIR, "run_layer_xsct.tcl")

XSCT_DEFAULT = "C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"

GENERATED_C_DIR = os.path.join(SCRIPT_DIR, "_generated_c")


# ============================================================================
# Find tools
# ============================================================================
def find_xsct():
    if os.path.exists(XSCT_DEFAULT):
        return XSCT_DEFAULT
    for p in os.environ.get("PATH", "").split(os.pathsep):
        for name in ["xsct.bat", "xsct"]:
            candidate = os.path.join(p, name)
            if os.path.exists(candidate):
                return candidate
    return None


def find_fsbl():
    for path in FSBL_CANDIDATES:
        if os.path.exists(path):
            return path
    return None


# ============================================================================
# Generate .c file from binary test vectors
# ============================================================================
def generate_c_from_bins(layer_dir):
    """Read params.json and .bin files, produce a self-contained .c test."""
    params_path = os.path.join(layer_dir, "params.json")
    with open(params_path, "r") as f:
        params = json.load(f)

    # Read binary data
    inp_data    = np.fromfile(os.path.join(layer_dir, "input.bin"), dtype=np.int8)
    wgt_data    = np.fromfile(os.path.join(layer_dir, "weights_ohwi.bin"), dtype=np.int8)
    bias_data   = np.fromfile(os.path.join(layer_dir, "bias.bin"), dtype=np.int32)
    expect_data = np.fromfile(os.path.join(layer_dir, "expected_output.bin"), dtype=np.int8)

    p = params
    t = p["test"]
    k = p["kernel"]
    q = p["quant"]
    b = p["bram"]
    s = p["sizes"]

    layer_idx  = p["layer_index"]
    layer_name = p["layer_name"]
    c_in       = t["c_in"]
    c_out      = t["c_out"]
    h_in       = t["h_in"]
    w_in       = t["w_in"]
    h_out      = t["h_out"]
    w_out      = t["w_out"]
    kh         = k["kh"]
    kw         = k["kw"]
    stride     = k["stride"]
    pad        = k["pad"]
    ksp        = k["ksp"]
    x_zp       = q["x_zp"]
    w_zp       = q["w_zp"]
    y_zp       = q["y_zp"]
    M0         = q["M0"]
    n_shift    = q["n_shift"]
    ic_tile    = p["ic_tile_size"]

    inp_addr   = int(b["addr_input"], 16)
    wgt_addr   = int(b["addr_weights"], 16)
    bias_addr  = int(b["addr_bias"], 16)
    out_addr   = int(b["addr_output"], 16)

    input_bytes  = s["input_bytes"]
    weight_bytes = s["weight_bytes"]
    bias_bytes   = s["bias_bytes"]
    output_bytes = s["output_bytes"]
    total_bytes  = s["total_bytes"]

    # Format helpers
    def fmt_s8_array(name, data, cols=16):
        flat = data.flatten().tolist()
        lines = ["static const s8 %s[%d] = {" % (name, len(flat))]
        for i in range(0, len(flat), cols):
            chunk = flat[i:i+cols]
            line = "    " + ", ".join("%4d" % v for v in chunk)
            if i + cols < len(flat):
                line += ","
            lines.append(line)
        lines.append("};")
        return "\n".join(lines)

    def fmt_s32_array(name, data, cols=8):
        flat = data.flatten().tolist()
        lines = ["static const s32 %s[%d] = {" % (name, len(flat))]
        for i in range(0, len(flat), cols):
            chunk = flat[i:i+cols]
            line = "    " + ", ".join("%d" % v for v in chunk)
            if i + cols < len(flat):
                line += ","
            lines.append(line)
        lines.append("};")
        return "\n".join(lines)

    # x_zp register encoding
    if x_zp < 0:
        x_zp_c = "(u32)(s32)(%d) & 0x1FF" % x_zp
    else:
        x_zp_c = "%d" % x_zp

    if w_zp < 0:
        w_zp_c = "(u32)(s32)(%d) & 0xFF" % w_zp
    else:
        w_zp_c = "%d" % w_zp

    if y_zp < 0:
        y_zp_c = "(u32)(s32)(%d) & 0xFF" % y_zp
    else:
        y_zp_c = "%d" % y_zp

    c_code = """\
/*
 * auto_layer_%03d_test.c -- YOLOv4 QLinearConv layer %d
 * %s
 *
 * Original: c_in=%d, c_out=%d, k=%dx%d, stride=%d, pads=%s
 * Test:     c_in=%d, c_out=%d, crop=%dx%d -> %dx%d
 *
 * Quant: x_zp=%d, w_zp=%d, y_zp=%d, M0=%du, n_shift=%d
 *
 * BRAM layout (%d bytes):
 *   Input:   0x%03X (%d B)
 *   Weights: 0x%03X (%d B)
 *   Bias:    0x%03X (%d B)
 *   Output:  0x%03X (%d B)
 *
 * Auto-generated by run_test.py from binary test vectors.
 */

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include <string.h>

#ifndef XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR
#define XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR 0x43C00000
#endif
#define WRAPPER_BASE  XPAR_CONV_TEST_WRAPPER_0_S_AXI_BASEADDR

#define REG_CTRL           0x00
#define REG_C_IN           0x04
#define REG_C_OUT          0x08
#define REG_H_IN           0x0C
#define REG_W_IN           0x10
#define REG_KSP            0x14
#define REG_X_ZP           0x18
#define REG_W_ZP           0x1C
#define REG_M0             0x20
#define REG_N_SHIFT        0x24
#define REG_Y_ZP           0x28
#define REG_ADDR_INPUT     0x2C
#define REG_ADDR_WEIGHTS   0x30
#define REG_ADDR_BIAS      0x34
#define REG_ADDR_OUTPUT    0x38
#define REG_IC_TILE_SIZE   0x3C
#define REG_BRAM_BASE      0x1000

#define BRAM_INPUT_ADDR    0x%03X
#define BRAM_WEIGHTS_ADDR  0x%03X
#define BRAM_BIAS_ADDR     0x%03X
#define BRAM_OUTPUT_ADDR   0x%03X

#define C_IN    %d
#define C_OUT   %d
#define H_IN    %d
#define W_IN    %d
#define KH      %d
#define KW      %d
#define KSP     0x%02X
#define H_OUT   %d
#define W_OUT   %d

#define INPUT_BYTES   %d
#define WEIGHT_BYTES  %d
#define BIAS_WORDS    %d
#define OUTPUT_BYTES  %d

#define RESULT_ADDR   0x01200000
#define MAGIC_DONE    0xDEAD1234
#define LAYER_IDX     %d

%s

%s

%s

%s

/* ========= Helper functions ========= */

static void write_reg(u32 offset, u32 val)
{
    Xil_Out32(WRAPPER_BASE + offset, val);
}

static u32 read_reg(u32 offset)
{
    return Xil_In32(WRAPPER_BASE + offset);
}

static void write_bram_word(u32 bram_addr, u32 val)
{
    Xil_Out32(WRAPPER_BASE + REG_BRAM_BASE + bram_addr, val);
}

static void write_bram_bytes(u32 bram_addr, const s8 *data, int len)
{
    int i = 0;
    for (; i + 3 < len; i += 4) {
        u32 word = ((u32)(u8)data[i])
                 | ((u32)(u8)data[i+1] << 8)
                 | ((u32)(u8)data[i+2] << 16)
                 | ((u32)(u8)data[i+3] << 24);
        write_bram_word(bram_addr + i, word);
    }
    if (i < len) {
        u32 word = 0;
        for (int j = 0; j < len - i; j++)
            word |= ((u32)(u8)data[i+j]) << (j * 8);
        write_bram_word(bram_addr + i, word);
    }
}

static s8 read_bram_byte(u32 bram_addr)
{
    u32 word_addr = bram_addr & ~0x3u;
    u32 byte_pos  = bram_addr & 0x3u;
    u32 word = Xil_In32(WRAPPER_BASE + REG_BRAM_BASE + word_addr);
    return (s8)((word >> (byte_pos * 8)) & 0xFF);
}

int main(void)
{
    volatile u32 *res = (volatile u32 *)RESULT_ADDR;
    int errors = 0;
    u32 ctrl;

    res[0] = 0xAAAA0000 | LAYER_IDX;
    Xil_DCacheFlushRange((UINTPTR)res, 64);

    xil_printf("\\r\\n=== Layer %d: %s ===\\r\\n");
    xil_printf("  c_in=%%d c_out=%%d %%dx%%d->%%dx%%d k=%%dx%%d\\r\\n",
               C_IN, C_OUT, H_IN, W_IN, H_OUT, W_OUT, KH, KW);

    /* Write input to BRAM */
    write_bram_bytes(BRAM_INPUT_ADDR, input_data, INPUT_BYTES);

    /* Write weights (already OHWI) to BRAM */
    write_bram_bytes(BRAM_WEIGHTS_ADDR, weight_data, WEIGHT_BYTES);

    /* Write bias */
    for (int i = 0; i < BIAS_WORDS; i++)
        write_bram_word(BRAM_BIAS_ADDR + i * 4, (u32)bias_data[i]);

    /* Clear output area */
    for (int i = 0; i < OUTPUT_BYTES; i += 4)
        write_bram_word(BRAM_OUTPUT_ADDR + i, 0xDEDEDEDE);

    /* Configure conv_engine registers */
    write_reg(REG_CTRL, 0);
    write_reg(REG_C_IN,  C_IN);
    write_reg(REG_C_OUT, C_OUT);
    write_reg(REG_H_IN,  H_IN);
    write_reg(REG_W_IN,  W_IN);
    write_reg(REG_KSP,   KSP);
    write_reg(REG_X_ZP, %s);
    write_reg(REG_W_ZP, %s);
    write_reg(REG_M0, %du);
    write_reg(REG_N_SHIFT, %d);
    write_reg(REG_Y_ZP, %s);
    write_reg(REG_ADDR_INPUT,   BRAM_INPUT_ADDR);
    write_reg(REG_ADDR_WEIGHTS, BRAM_WEIGHTS_ADDR);
    write_reg(REG_ADDR_BIAS,    BRAM_BIAS_ADDR);
    write_reg(REG_ADDR_OUTPUT,  BRAM_OUTPUT_ADDR);
    write_reg(REG_IC_TILE_SIZE, C_IN);

    /* Start conv_engine */
    write_reg(REG_CTRL, 1);

    /* Poll for done */
    int timeout = 0;
    do {
        ctrl = read_reg(REG_CTRL);
        timeout++;
        if (timeout > 10000000) {
            xil_printf("ERROR: Timeout! ctrl=0x%%08X\\r\\n", ctrl);
            res[0] = MAGIC_DONE;
            res[1] = LAYER_IDX;
            res[2] = 0;
            res[3] = 99;
            Xil_DCacheFlushRange((UINTPTR)res, 64);
            while(1);
        }
    } while ((ctrl & 0x02) == 0);
    write_reg(REG_CTRL, 0);

    /* Compare output */
    for (int i = 0; i < OUTPUT_BYTES; i++) {
        s8 got = read_bram_byte(BRAM_OUTPUT_ADDR + i);
        s8 exp = expected_full[i];
        if (got != exp) {
            errors++;
            if (errors <= 10) {
                int oc = i / (H_OUT * W_OUT);
                int rem = i %% (H_OUT * W_OUT);
                int oh = rem / W_OUT;
                int ow = rem %% W_OUT;
                xil_printf("  MISMATCH [%%d] oc=%%d (%%d,%%d): got %%d exp %%d\\r\\n",
                           i, oc, oh, ow, (int)got, (int)exp);
            }
        }
    }

    xil_printf("  Total bytes: %%d, Errors: %%d\\r\\n", OUTPUT_BYTES, errors);
    if (errors == 0)
        xil_printf("  >>> PASS <<<\\r\\n");
    else
        xil_printf("  >>> FAIL (%%d errors) <<<\\r\\n", errors);

    /* Write result to DDR for JTAG readback */
    res[0] = MAGIC_DONE;
    res[1] = LAYER_IDX;
    res[2] = OUTPUT_BYTES;
    res[3] = errors;
    Xil_DCacheFlushRange((UINTPTR)res, 64);
    while(1);
}
""" % (
        layer_idx, layer_idx, layer_name,
        p["original"]["c_in"], p["original"]["c_out"], kh, kw, stride, k["pads"],
        c_in, c_out, h_in, w_in, h_out, w_out,
        x_zp, w_zp, y_zp, M0, n_shift,
        total_bytes,
        inp_addr, input_bytes,
        wgt_addr, weight_bytes,
        bias_addr, bias_bytes,
        out_addr, output_bytes,
        # BRAM addresses
        inp_addr, wgt_addr, bias_addr, out_addr,
        # Dimensions
        c_in, c_out, h_in, w_in, kh, kw, ksp, h_out, w_out,
        # Sizes
        input_bytes, weight_bytes, c_out, output_bytes,
        # Layer index
        layer_idx,
        # Data arrays
        fmt_s8_array("input_data", inp_data),
        fmt_s8_array("weight_data", wgt_data),
        fmt_s32_array("bias_data", bias_data),
        fmt_s8_array("expected_full", expect_data),
        # Printf args
        layer_idx, layer_name,
        # Register writes
        x_zp_c, w_zp_c, M0, n_shift, y_zp_c,
    )

    return c_code


# ============================================================================
# Find all layer directories
# ============================================================================
def find_layer_dirs(root, spec=None):
    """
    Find layer directories to test.
    spec can be:
      - None -> all
      - "config_3x3_s1_p1" -> all layers in that config
      - "config_3x3_s1_p1/layer_000" -> specific layer
    """
    results = []
    if spec is not None:
        full = os.path.join(root, spec)
        if os.path.isdir(full) and os.path.exists(os.path.join(full, "params.json")):
            results.append(full)
        else:
            # It might be a config dir
            for entry in sorted(os.listdir(full)):
                layer_path = os.path.join(full, entry)
                if os.path.isdir(layer_path) and os.path.exists(os.path.join(layer_path, "params.json")):
                    results.append(layer_path)
    else:
        for config_entry in sorted(os.listdir(root)):
            config_path = os.path.join(root, config_entry)
            if not os.path.isdir(config_path) or not config_entry.startswith("config_"):
                continue
            for layer_entry in sorted(os.listdir(config_path)):
                layer_path = os.path.join(config_path, layer_entry)
                if os.path.isdir(layer_path) and os.path.exists(os.path.join(layer_path, "params.json")):
                    results.append(layer_path)
    return results


def find_representative_layers(root):
    """Find representative layers from test_plan.json."""
    plan_path = os.path.join(root, "test_plan.json")
    if not os.path.exists(plan_path):
        print("ERROR: test_plan.json not found at %s" % plan_path)
        return []
    with open(plan_path, "r") as f:
        plan = json.load(f)

    results = []
    for config_dirname, layer_indices in plan.get("representative_tests", {}).items():
        for idx in layer_indices:
            layer_path = os.path.join(root, config_dirname, "layer_%03d" % idx)
            if os.path.isdir(layer_path) and os.path.exists(os.path.join(layer_path, "params.json")):
                results.append(layer_path)
            else:
                print("  WARNING: Representative layer_%03d not found in %s" % (idx, config_dirname))
    return results


# ============================================================================
# Build and run one test
# ============================================================================
def build_and_run(layer_dir, xsct, xsa, ws_dir, bit_file, fsbl,
                  tgt_fpga=4, tgt_cpu=2, dry_run=False):
    """Build .c, program FPGA, run, return (status, errors, details)."""

    # Load params for reporting
    with open(os.path.join(layer_dir, "params.json"), "r") as f:
        params = json.load(f)

    layer_idx = params["layer_index"]
    layer_name = params["layer_name"]

    print("\n--- Layer %d: %s ---" % (layer_idx, layer_name))
    print("  Config: k=%dx%d s=%d pad=%s" % (
        params["kernel"]["kh"], params["kernel"]["kw"],
        params["kernel"]["stride"], params["kernel"]["pads"]))
    print("  Test: c_in=%d c_out=%d %dx%d -> %dx%d (%d bytes)" % (
        params["test"]["c_in"], params["test"]["c_out"],
        params["test"]["h_in"], params["test"]["w_in"],
        params["test"]["h_out"], params["test"]["w_out"],
        params["sizes"]["total_bytes"]))

    # 1. Generate .c
    print("  Generating .c file...")
    os.makedirs(GENERATED_C_DIR, exist_ok=True)
    c_code = generate_c_from_bins(layer_dir)
    c_path = os.path.join(GENERATED_C_DIR, "auto_layer_%03d_test.c" % layer_idx)
    with open(c_path, "w") as f:
        f.write(c_code)
    print("  Written: %s" % c_path)

    if dry_run:
        print("  [DRY RUN] Skipping build and execution")
        return ("DRY_RUN", 0, {})

    # 2. Build via xsct
    print("  Building ELF...")
    build_cmd = [xsct, BUILD_TCL, xsa, ws_dir, c_path]
    result = subprocess.run(build_cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        print("  BUILD FAILED:")
        print(result.stdout[-500:] if len(result.stdout) > 500 else result.stdout)
        print(result.stderr[-500:] if len(result.stderr) > 500 else result.stderr)
        return ("BUILD_FAIL", -1, {"stdout": result.stdout, "stderr": result.stderr})

    # Find ELF
    elf_path = os.path.join(ws_dir, "layer_test", "Debug", "layer_test.elf")
    if not os.path.exists(elf_path):
        elf_path = os.path.join(ws_dir, "layer_test", "build", "layer_test.elf")
    if not os.path.exists(elf_path):
        print("  ERROR: ELF not found after build")
        return ("ELF_NOT_FOUND", -1, {})
    print("  ELF: %s" % elf_path)

    # 3. Run on ZedBoard via xsct
    print("  Running on ZedBoard...")
    run_cmd = [xsct, RUN_TCL, bit_file, elf_path, fsbl,
               str(tgt_fpga), str(tgt_cpu)]
    result = subprocess.run(run_cmd, capture_output=True, text=True, timeout=180)
    output = result.stdout

    # 4. Parse result
    status = "UNKNOWN"
    errors = -1

    if "STATUS: PASS" in output:
        status = "PASS"
        errors = 0
    elif "STATUS: FAIL" in output:
        status = "FAIL"
        # Extract error count
        import re
        m = re.search(r"Errors:\s*(\d+)", output)
        if m:
            errors = int(m.group(1))
    elif "STATUS: TIMEOUT" in output:
        status = "TIMEOUT"
        errors = -1
    else:
        status = "UNKNOWN"

    print("  Result: %s (errors=%s)" % (status, errors))

    return (status, errors, {"stdout": output})


# ============================================================================
# Main
# ============================================================================
def main():
    parser = argparse.ArgumentParser(description="Run conv_engine HW tests on ZedBoard")
    parser.add_argument("layers", nargs="*",
                        help="Layer directory paths relative to test_vectors/ "
                             "(e.g. config_3x3_s1_p1/layer_000)")
    parser.add_argument("--all", action="store_true",
                        help="Run all generated layer tests")
    parser.add_argument("--config", type=str, default=None,
                        help="Run all layers in a specific config directory")
    parser.add_argument("--plan", action="store_true",
                        help="Run representative_tests from test_plan.json")
    parser.add_argument("--dry-run", action="store_true",
                        help="Generate .c files but don't build/run")
    parser.add_argument("--xsct", type=str, default=None,
                        help="Path to xsct executable")
    parser.add_argument("--xsa", type=str, default=XSA_FILE,
                        help="Path to .xsa hardware definition")
    parser.add_argument("--bit", type=str, default=BIT_FILE,
                        help="Path to bitstream .bit file")
    parser.add_argument("--ws", type=str, default=WS_DIR,
                        help="Vitis workspace directory")
    parser.add_argument("--tgt-fpga", type=int, default=4,
                        help="JTAG target index for FPGA (default: 4)")
    parser.add_argument("--tgt-cpu", type=int, default=2,
                        help="JTAG target index for CPU (default: 2)")
    args = parser.parse_args()

    # Find xsct
    xsct = args.xsct or find_xsct()
    if not args.dry_run and (xsct is None or not os.path.exists(xsct)):
        print("ERROR: xsct not found. Use --xsct or add to PATH.")
        sys.exit(1)

    # Find FSBL
    fsbl = find_fsbl()
    if not args.dry_run and fsbl is None:
        print("ERROR: FSBL not found. Build the platform first.")
        sys.exit(1)

    # Determine which layers to test
    if args.all:
        layer_dirs = find_layer_dirs(SCRIPT_DIR)
    elif args.plan:
        layer_dirs = find_representative_layers(SCRIPT_DIR)
    elif args.config:
        layer_dirs = find_layer_dirs(SCRIPT_DIR, args.config)
    elif args.layers:
        layer_dirs = []
        for spec in args.layers:
            full = os.path.join(SCRIPT_DIR, spec)
            if os.path.isdir(full) and os.path.exists(os.path.join(full, "params.json")):
                layer_dirs.append(full)
            else:
                # Try as config dir
                found = find_layer_dirs(SCRIPT_DIR, spec)
                layer_dirs.extend(found)
    else:
        print("Usage: run_test.py <layer_dir> [<layer_dir> ...]")
        print("       run_test.py --all")
        print("       run_test.py --plan")
        print("       run_test.py --config config_3x3_s1_p1")
        sys.exit(1)

    if not layer_dirs:
        print("ERROR: No test layers found.")
        sys.exit(1)

    print("=" * 70)
    print("CONV ENGINE TEST RUNNER")
    print("=" * 70)
    print("Layers to test: %d" % len(layer_dirs))
    if not args.dry_run:
        print("xsct: %s" % xsct)
        print("XSA:  %s" % args.xsa)
        print("BIT:  %s" % args.bit)
        print("FSBL: %s" % fsbl)

    # Run tests
    results = []
    t_start = time.time()

    for layer_dir in layer_dirs:
        status, errors, details = build_and_run(
            layer_dir, xsct, args.xsa, args.ws, args.bit, fsbl,
            args.tgt_fpga, args.tgt_cpu, args.dry_run
        )
        results.append({
            "dir": layer_dir,
            "status": status,
            "errors": errors,
        })

    elapsed = time.time() - t_start

    # Summary
    print("\n" + "=" * 70)
    print("TEST SUMMARY")
    print("=" * 70)

    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = sum(1 for r in results if r["status"] == "FAIL")
    timeout = sum(1 for r in results if r["status"] == "TIMEOUT")
    build_fail = sum(1 for r in results if r["status"] == "BUILD_FAIL")
    dry = sum(1 for r in results if r["status"] == "DRY_RUN")
    other = len(results) - passed - failed - timeout - build_fail - dry

    for r in results:
        layer_name = os.path.basename(r["dir"])
        config_name = os.path.basename(os.path.dirname(r["dir"]))
        tag = "PASS" if r["status"] == "PASS" else r["status"]
        print("  %-25s %-12s  %s" % (config_name, layer_name, tag))

    print()
    print("Total: %d tests in %.1f s" % (len(results), elapsed))
    print("  PASS:       %d" % passed)
    if failed > 0:
        print("  FAIL:       %d" % failed)
    if timeout > 0:
        print("  TIMEOUT:    %d" % timeout)
    if build_fail > 0:
        print("  BUILD_FAIL: %d" % build_fail)
    if dry > 0:
        print("  DRY_RUN:    %d" % dry)
    if other > 0:
        print("  OTHER:      %d" % other)

    # Write results JSON
    results_path = os.path.join(SCRIPT_DIR, "test_results.json")
    results_json = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "elapsed_seconds": round(elapsed, 1),
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "timeout": timeout,
        "build_fail": build_fail,
        "results": [
            {
                "dir": os.path.relpath(r["dir"], SCRIPT_DIR),
                "status": r["status"],
                "errors": r["errors"],
            }
            for r in results
        ],
    }
    with open(results_path, "w") as f:
        json.dump(results_json, f, indent=4)
    print("\nResults written to: %s" % results_path)

    # Exit code
    if failed > 0 or timeout > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
