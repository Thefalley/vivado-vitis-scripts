#!/usr/bin/env python3
"""
test_all_convs.py -- Automated HW verification of YOLOv4 QLinearConv layers
on ZedBoard using conv_engine_v2.

For each layer:
  1. Takes the pre-generated .c file (from gen_layer_tests.py)
  2. Builds the ELF via xsct
  3. Programs the FPGA + runs the ELF on the ZedBoard
  4. Reads the result via JTAG
  5. Reports PASS/FAIL

Prerequisites:
  - gen_layer_tests.py has been run to create layer_NNN_test.c files
  - The bitstream is already built (does NOT change)
  - xsct is available in PATH or specified via --xsct

Usage:
  python test_all_convs.py --layers 0,1,2,3,4
  python test_all_convs.py --all
  python test_all_convs.py --layers 0,1,2,3,4 --tgt-fpga 4 --tgt-cpu 2
"""

import os
import sys
import subprocess
import argparse
import re
import time
import glob as globmod

# ============================================================================
# Paths
# ============================================================================
SW_DIR = os.path.dirname(os.path.abspath(__file__))
P13_DIR = os.path.dirname(SW_DIR)
LAYER_TESTS_DIR = os.path.join(SW_DIR, "layer_tests")

BIT_FILE = os.path.join(P13_DIR, "build", "zynq_conv.runs", "impl_1",
                         "zynq_conv_bd_wrapper.bit")
XSA_FILE = os.path.join(P13_DIR, "build", "zynq_conv.xsa")
WS_DIR = os.path.join(P13_DIR, "vitis_ws_layer")

# FSBL: use from existing vitis_ws_crop
FSBL_FILE = os.path.join(P13_DIR, "vitis_ws_crop", "zynq_conv_platform",
                          "export", "zynq_conv_platform", "sw",
                          "zynq_conv_platform", "boot", "fsbl.elf")
# Fallback FSBL
FSBL_FILE_ALT = os.path.join(P13_DIR, "vitis_ws", "zynq_conv_platform",
                              "zynq_fsbl", "fsbl.elf")

BUILD_TCL = os.path.join(SW_DIR, "build_layer_xsct.tcl")
RUN_TCL = os.path.join(SW_DIR, "run_layer_xsct.tcl")

# xsct executable
XSCT_DEFAULT = "C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"


def find_xsct():
    """Find xsct executable."""
    if os.path.exists(XSCT_DEFAULT):
        return XSCT_DEFAULT
    # Try PATH
    for p in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(p, "xsct.bat")
        if os.path.exists(candidate):
            return candidate
        candidate = os.path.join(p, "xsct")
        if os.path.exists(candidate):
            return candidate
    return None


def find_fsbl():
    """Find FSBL ELF."""
    if os.path.exists(FSBL_FILE):
        return FSBL_FILE
    if os.path.exists(FSBL_FILE_ALT):
        return FSBL_FILE_ALT
    # Search in workspace
    for ws in [WS_DIR, os.path.join(P13_DIR, "vitis_ws_crop"),
               os.path.join(P13_DIR, "vitis_ws")]:
        pattern = os.path.join(ws, "**", "fsbl.elf")
        matches = globmod.glob(pattern, recursive=True)
        if matches:
            return matches[0]
    return None


def kill_java_hwserver():
    """Kill java and hw_server processes to free JTAG."""
    taskkill = "/c/WINDOWS/system32/taskkill"
    if not os.path.exists(taskkill):
        taskkill = "taskkill"
    for proc in ["java.exe", "hw_server.exe"]:
        try:
            subprocess.run([taskkill, "//F", "//IM", proc],
                         capture_output=True, timeout=10)
        except Exception:
            pass
    time.sleep(1)


def build_layer(xsct, layer_idx):
    """Build a layer test .c into an ELF."""
    src_file = os.path.join(LAYER_TESTS_DIR, f"layer_{layer_idx:03d}_test.c")
    if not os.path.exists(src_file):
        return None, f"Source not found: {src_file}"

    # Forward slashes for TCL
    xsa = XSA_FILE.replace("\\", "/")
    ws = WS_DIR.replace("\\", "/")
    src = src_file.replace("\\", "/")
    tcl = BUILD_TCL.replace("\\", "/")

    cmd = [xsct, tcl, xsa, ws, src]
    print(f"  Building layer {layer_idx}...")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=300, cwd=SW_DIR)
        output = result.stdout + result.stderr
        if result.returncode != 0:
            return None, f"Build failed (rc={result.returncode}):\n{output[-500:]}"
    except subprocess.TimeoutExpired:
        return None, "Build timeout (300s)"

    # Check both possible ELF locations (Debug/ for XSCT, build/ for Vitis)
    elf_path = os.path.join(WS_DIR, "layer_test", "Debug", "layer_test.elf")
    if not os.path.exists(elf_path):
        elf_path = os.path.join(WS_DIR, "layer_test", "build", "layer_test.elf")
    if not os.path.exists(elf_path):
        return None, f"ELF not found after build\n{output[-500:]}"

    return elf_path, None


def run_layer(xsct, elf_path, fsbl, tgt_fpga, tgt_cpu):
    """Run a layer test on the ZedBoard and return (status, details)."""
    bit = BIT_FILE.replace("\\", "/")
    elf = elf_path.replace("\\", "/")
    fsbl_f = fsbl.replace("\\", "/")
    tcl = RUN_TCL.replace("\\", "/")

    cmd = [xsct, tcl, bit, elf, fsbl_f, str(tgt_fpga), str(tgt_cpu)]
    print(f"  Running on ZedBoard (fpga={tgt_fpga}, cpu={tgt_cpu})...")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=300, cwd=SW_DIR)
        output = result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "xsct timeout (300s)"

    # Parse the output for STATUS line
    status = "UNKNOWN"
    details = ""
    for line in output.split("\n"):
        if "STATUS:" in line:
            if "PASS" in line:
                status = "PASS"
            elif "FAIL" in line:
                status = "FAIL"
            elif "TIMEOUT" in line:
                status = "TIMEOUT"
        if "Total bytes compared:" in line:
            details += line.strip() + " "
        if "Errors:" in line:
            details += line.strip() + " "
        if "PASS" in line and "BIT-EXACTO" in line:
            details = line.strip()

    if status == "UNKNOWN":
        details = output[-300:]

    return status, details


def main():
    parser = argparse.ArgumentParser(description="Test YOLOv4 conv layers on ZedBoard")
    parser.add_argument("--layers", type=str, default=None,
                        help="Comma-separated layer indices")
    parser.add_argument("--all", action="store_true",
                        help="Test ALL layers (that have .c files)")
    parser.add_argument("--xsct", type=str, default=None,
                        help="Path to xsct executable")
    parser.add_argument("--tgt-fpga", type=int, default=4,
                        help="JTAG target for FPGA (default: 4)")
    parser.add_argument("--tgt-cpu", type=int, default=2,
                        help="JTAG target for CPU (default: 2)")
    parser.add_argument("--skip-build", action="store_true",
                        help="Skip build, use existing ELF")
    parser.add_argument("--skip-kill", action="store_true",
                        help="Don't kill java/hw_server before each run")
    args = parser.parse_args()

    # Find xsct
    xsct = args.xsct or find_xsct()
    if xsct is None:
        print("ERROR: Cannot find xsct. Use --xsct to specify path.")
        sys.exit(1)
    print(f"xsct: {xsct}")

    # Find FSBL
    fsbl = find_fsbl()
    if fsbl is None:
        print("ERROR: Cannot find FSBL ELF.")
        sys.exit(1)
    print(f"FSBL: {fsbl}")

    # Check bitstream
    if not os.path.exists(BIT_FILE):
        print(f"ERROR: Bitstream not found: {BIT_FILE}")
        sys.exit(1)
    print(f"Bitstream: {BIT_FILE}")

    # Determine layer list
    if args.all:
        # Find all .c files in layer_tests/
        files = sorted(globmod.glob(os.path.join(LAYER_TESTS_DIR, "layer_*_test.c")))
        layer_indices = []
        for f in files:
            m = re.search(r"layer_(\d+)_test\.c", os.path.basename(f))
            if m:
                layer_indices.append(int(m.group(1)))
    elif args.layers:
        layer_indices = [int(x.strip()) for x in args.layers.split(",")]
    else:
        print("ERROR: Specify --layers or --all")
        sys.exit(1)

    print(f"\nLayers to test: {layer_indices}")
    print(f"JTAG targets: fpga={args.tgt_fpga}, cpu={args.tgt_cpu}")
    print(f"="*70)

    # Create workspace dir
    os.makedirs(WS_DIR, exist_ok=True)

    results = []
    for i, li in enumerate(layer_indices):
        print(f"\n[{i+1}/{len(layer_indices)}] Layer {li}")
        print(f"-" * 40)

        # Build
        if not args.skip_build:
            elf_path, err = build_layer(xsct, li)
            if err:
                print(f"  BUILD ERROR: {err}")
                results.append((li, "BUILD_ERROR", err[:100]))
                continue
        else:
            elf_path = os.path.join(WS_DIR, "layer_test", "Debug", "layer_test.elf")
            if not os.path.exists(elf_path):
                elf_path = os.path.join(WS_DIR, "layer_test", "build", "layer_test.elf")
            if not os.path.exists(elf_path):
                print(f"  ERROR: ELF not found (--skip-build)")
                results.append((li, "NO_ELF", ""))
                continue

        # Kill java/hw_server
        if not args.skip_kill:
            kill_java_hwserver()

        # Run
        status, details = run_layer(xsct, elf_path, fsbl,
                                    args.tgt_fpga, args.tgt_cpu)
        print(f"  Result: {status} -- {details}")
        results.append((li, status, details))

    # Final report
    print(f"\n{'='*70}")
    print(f"FINAL REPORT: {len(results)} layers tested")
    print(f"{'='*70}")

    n_pass = sum(1 for _, s, _ in results if s == "PASS")
    n_fail = sum(1 for _, s, _ in results if s == "FAIL")
    n_other = len(results) - n_pass - n_fail

    for li, status, details in results:
        marker = "OK" if status == "PASS" else "!!"
        print(f"  [{marker}] Layer {li:3d}: {status:12s}  {details[:60]}")

    print(f"\nSummary: {n_pass} PASS, {n_fail} FAIL, {n_other} OTHER "
          f"(of {len(results)} total)")


if __name__ == "__main__":
    main()
