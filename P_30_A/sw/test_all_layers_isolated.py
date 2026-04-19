#!/usr/bin/env python3
"""
test_all_layers_isolated.py -- Isolated FPGA verification of ALL 255 YOLOv4 layers.

Each layer is tested independently:
  - Loads ONNX reference activations as input (not cascaded FPGA outputs).
  - Executes that single layer on the FPGA.
  - Reads back the FULL output from DDR.
  - Compares byte-by-byte against ONNX reference output.

Classification per layer:
  BIT-EXACT  : output == reference (0 mismatches)
  ROUNDING   : max |diff| == 1 (typical int8 rounding noise)
  FAIL       : max |diff| >= 2 (real mismatch, report max_diff + count)
  ERR        : FPGA returned non-zero status code
  SKIP       : layer skipped (IC-tiled with --skip-ic-tiled, etc.)
  TIMEOUT    : connection timed out, layer not completed

Usage:
  python test_all_layers_isolated.py
  python test_all_layers_isolated.py --first=10
  python test_all_layers_isolated.py --layers=0,1,2,12,15
  python test_all_layers_isolated.py --skip-ic-tiled --timeout=600
  python test_all_layers_isolated.py --resume results_partial.json

Requires:
  - ZedBoard running eth_server at 192.168.1.10:7001
  - Weights blob at WEIGHTS_BLOB path
  - ONNX reference files in onnx_refs/
  - layer_configs.json, weights_manifest.json in P_18 host dir
"""

import argparse
import json
import numpy as np
import os
import socket
import struct
import sys
import time
import traceback
import zlib
from datetime import datetime

# ---------------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
P18_HOST = os.path.normpath(os.path.join(HERE, "..", "..", "P_18_dpu_eth", "host"))
sys.path.insert(0, P18_HOST)

from yolov4_host import DpuHost, CMD_EXEC_LAYER, STATUS_OK

REFS_DIR = os.path.join(P18_HOST, "onnx_refs")
WEIGHTS_BLOB = r"C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin"

# ---------------------------------------------------------------------------
# DDR address map
# ---------------------------------------------------------------------------
ADDR_IN_A       = 0x16000000
ADDR_IN_B       = 0x17000000
ADDR_OUT        = 0x18000000
ADDR_WEIGHTS    = 0x12000000
ADDR_CFG_ARRAY  = 0x11000000

LAYER_CFG_SIZE  = 72

OP_NAMES = ["CONV", "LEAKY", "ADD", "CONCAT", "POOL", "RESIZE"]

LAYER_CFG_FMT = "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
assert struct.calcsize(LAYER_CFG_FMT) == LAYER_CFG_SIZE


# ---------------------------------------------------------------------------
# pack_cfg -- identical to run_all_layers.py
# ---------------------------------------------------------------------------
def pack_cfg(**kv):
    f = dict(
        op_type=0, act_type=0, layer_idx=0,
        in_addr=0, in_b_addr=0, out_addr=0, w_addr=0, b_addr=0,
        c_in=0, c_out=0, h_in=0, w_in=0, h_out=0, w_out=0,
        kh=0, kw=0, stride_h=0, stride_w=0,
        pad_top=0, pad_bottom=0, pad_left=0, pad_right=0,
        ic_tile_size=0, post_shift=0, leaky_alpha_q=0,
        a_scale_m=0, b_scale_m=0, a_scale_s=0, b_scale_s=0,
        out_zp=0, out_scale_s=0,
        reserved0=0, reserved1=0, reserved2=0,
    )
    f.update(kv)
    return struct.pack(LAYER_CFG_FMT, *[f[k] for k in [
        "op_type", "act_type", "layer_idx",
        "in_addr", "in_b_addr", "out_addr", "w_addr", "b_addr",
        "c_in", "c_out", "h_in", "w_in", "h_out", "w_out",
        "kh", "kw", "stride_h", "stride_w",
        "pad_top", "pad_bottom", "pad_left", "pad_right",
        "ic_tile_size", "post_shift", "leaky_alpha_q",
        "a_scale_m", "b_scale_m", "a_scale_s", "b_scale_s",
        "out_zp", "out_scale_s", "reserved0", "reserved1", "reserved2"]])


# ---------------------------------------------------------------------------
# exec_layer -- send CMD_EXEC_LAYER for a single layer index
# ---------------------------------------------------------------------------
def exec_layer(h, idx):
    """Execute layer idx on the FPGA. Returns (status, cycles, out_crc, out_bytes)."""
    h.connect()
    tag = h._next_tag()
    h._send_header(CMD_EXEC_LAYER, 4, tag=tag)
    h._sendall(struct.pack("<HH", idx, 0))
    status, extra = h._expect_ack()
    if len(extra) >= 12:
        cy, crc, nb = struct.unpack("<III", extra[:12])
        return status, cy, crc, nb
    return status, 0, 0, 0


# ---------------------------------------------------------------------------
# Comparison helpers
# ---------------------------------------------------------------------------
def compare_arrays(fpga_data, ref_data):
    """Compare FPGA output vs ONNX reference, byte-by-byte as int8.

    Returns dict with:
        match: bool (exact match)
        max_diff: int
        n_mismatch: int (count of positions where diff != 0)
        n_off_by_1: int (count of positions where |diff| == 1)
        n_off_gt_1: int (count of positions where |diff| > 1)
        classification: str ("BIT-EXACT", "ROUNDING", "FAIL")
        first_mismatch_idx: int or None
    """
    fpga = np.frombuffer(fpga_data, dtype=np.int8)
    ref  = np.frombuffer(ref_data,  dtype=np.int8)

    min_len = min(len(fpga), len(ref))
    if len(fpga) != len(ref):
        # Size mismatch is a hard fail
        return {
            "match": False,
            "max_diff": 999,
            "n_mismatch": abs(len(fpga) - len(ref)),
            "n_off_by_1": 0,
            "n_off_gt_1": 0,
            "classification": "FAIL",
            "first_mismatch_idx": min_len,
            "size_mismatch": True,
            "fpga_size": len(fpga),
            "ref_size": len(ref),
        }

    diff = fpga.astype(np.int16) - ref.astype(np.int16)
    abs_diff = np.abs(diff)
    max_diff = int(abs_diff.max()) if len(abs_diff) > 0 else 0
    mismatch_mask = abs_diff > 0
    n_mismatch = int(mismatch_mask.sum())
    n_off_by_1 = int((abs_diff == 1).sum())
    n_off_gt_1 = int((abs_diff > 1).sum())

    if n_mismatch == 0:
        cls = "BIT-EXACT"
    elif max_diff == 1:
        cls = "ROUNDING"
    else:
        cls = "FAIL"

    first_idx = int(np.argmax(mismatch_mask)) if n_mismatch > 0 else None

    return {
        "match": n_mismatch == 0,
        "max_diff": max_diff,
        "n_mismatch": n_mismatch,
        "n_off_by_1": n_off_by_1,
        "n_off_gt_1": n_off_gt_1,
        "classification": cls,
        "first_mismatch_idx": first_idx,
        "size_mismatch": False,
        "fpga_size": len(fpga),
        "ref_size": len(ref),
    }


# ---------------------------------------------------------------------------
# Reconnect wrapper
# ---------------------------------------------------------------------------
def safe_reconnect(host_ip, port, timeout, max_retries=3):
    """Try to create a fresh DpuHost connection, with retries."""
    for attempt in range(max_retries):
        try:
            h = DpuHost(host_ip, port, timeout=timeout)
            h.connect()
            h.ping()
            return h
        except Exception as e:
            print(f"  [reconnect] attempt {attempt+1}/{max_retries} failed: {e}")
            time.sleep(2)
    return None


# ---------------------------------------------------------------------------
# Main test driver
# ---------------------------------------------------------------------------
def run_isolated_test(args):
    # ---- Load metadata ----
    manifest = json.load(open(os.path.join(REFS_DIR, "manifest.json")))
    tensors  = manifest["tensors"]
    layers   = json.load(open(os.path.join(P18_HOST, "layer_configs.json")))
    weights  = json.load(open(os.path.join(P18_HOST, "weights_manifest.json")))

    n_layers = len(layers)   # 255
    n_tensors = len(tensors)  # 263

    print(f"Loaded {n_layers} layer configs, {n_tensors} ONNX tensors")
    print(f"ONNX refs dir: {REFS_DIR}")
    print(f"Weights blob:  {WEIGHTS_BLOB}")
    print()

    # ---- Determine which layers to run ----
    if args.layers:
        layer_indices = [int(x) for x in args.layers.split(",")]
    elif args.first:
        layer_indices = list(range(min(args.first, n_layers)))
    else:
        layer_indices = list(range(n_layers))

    # ---- Identify IC-tiled layers (c_in > 256 and CONV with kernel >= 3) ----
    ic_tiled_set = set()
    for i in range(n_layers):
        L = layers[i]
        if L["op_type"] == 0 and L["c_in"] > 256 and L.get("kernel", 0) >= 3:
            ic_tiled_set.add(i)

    # ---- Resume support ----
    completed = {}
    if args.resume and os.path.exists(args.resume):
        prev = json.load(open(args.resume))
        for r in prev.get("results", []):
            if r.get("classification") not in ("SKIP", "TIMEOUT", "ERR"):
                completed[r["layer_idx"]] = r
        print(f"Resuming: {len(completed)} layers already done")

    # ---- Connect ----
    print(f"Connecting to {args.host}:{args.port} ...")
    h = DpuHost(args.host, args.port, timeout=args.timeout)
    h.connect()
    pong = h.ping()
    print(f"PONG: {pong!r}")

    # ---- Init DPU ----
    print("DPU init ...", end=" ", flush=True)
    st = h.dpu_init()
    print(f"status=0x{st:08X}")

    # ---- Upload weights blob ----
    print(f"Loading weights from {WEIGHTS_BLOB} ...", end=" ", flush=True)
    t0 = time.time()
    wblob = open(WEIGHTS_BLOB, "rb").read()
    h.write_ddr(ADDR_WEIGHTS, wblob)
    dt = time.time() - t0
    print(f"{len(wblob)/1e6:.1f} MB in {dt:.1f}s ({len(wblob)/dt/1e6:.1f} MB/s)")

    # ---- Run each layer in isolation ----
    results = []
    counts = {"BIT-EXACT": 0, "ROUNDING": 0, "FAIL": 0, "ERR": 0, "SKIP": 0, "TIMEOUT": 0}
    total_start = time.time()

    for idx in layer_indices:
        if idx >= n_layers:
            print(f"[{idx:3d}] SKIP  -- index out of range")
            continue

        onnx_idx = (layers[idx]["layer_id"] - 3) if "layer_id" in layers[idx] else (idx + 2)
        if onnx_idx >= n_tensors:
            print(f"[{idx:3d}] SKIP  -- no ONNX tensor for this layer")
            results.append(_skip_result(idx, "no_tensor"))
            counts["SKIP"] += 1
            continue

        # Resume check
        if idx in completed:
            r = completed[idx]
            results.append(r)
            counts[r["classification"]] += 1
            print(f"[{idx:3d}] {r['classification']:10s}  (resumed)")
            continue

        L = layers[idx]
        W = weights[idx] if idx < len(weights) else {"w_off": 0, "w_bytes": 0, "b_off": 0, "b_bytes": 0}
        op_type = L["op_type"]
        op_name = OP_NAMES[op_type] if op_type < len(OP_NAMES) else f"OP{op_type}"

        tensor_info = tensors[onnx_idx]
        expected_file = tensor_info["file"]
        expected_bytes = tensor_info["bytes"]
        node_name = tensor_info["node_name"]

        # ---- Skip IC-tiled if requested ----
        if args.skip_ic_tiled and idx in ic_tiled_set:
            r = _skip_result(idx, "ic_tiled")
            results.append(r)
            counts["SKIP"] += 1
            print(f"[{idx:3d}] SKIP       {op_name:7s}  (IC-tiled, c_in={L['c_in']})")
            continue

        # ---- Load input A (ONNX reference) ----
        a_idx = L["input_a_idx"]
        if a_idx < 0:
            # External input: tensor[1] = quantized input
            in_a_file = os.path.join(REFS_DIR, tensors[1]["file"])
        else:
            in_a_onnx_idx = (layers[a_idx]["layer_id"] - 3) if "layer_id" in layers[a_idx] else (a_idx + 2)
            in_a_file = os.path.join(REFS_DIR, tensors[in_a_onnx_idx]["file"])

        # ---- Load input B (for ADD / CONCAT) ----
        b_idx = L["input_b_idx"]
        in_b_file = None
        if b_idx >= 0:
            in_b_onnx_idx = (layers[b_idx]["layer_id"] - 3) if "layer_id" in layers[b_idx] else (b_idx + 2)
            in_b_file = os.path.join(REFS_DIR, tensors[in_b_onnx_idx]["file"])

        # ---- Load expected output ----
        ref_file = os.path.join(REFS_DIR, expected_file)

        try:
            in_a_data = open(in_a_file, "rb").read()
            ref_data  = open(ref_file, "rb").read()
            in_b_data = open(in_b_file, "rb").read() if in_b_file else None
        except FileNotFoundError as e:
            r = _err_result(idx, op_name, f"file_not_found: {e}")
            results.append(r)
            counts["ERR"] += 1
            print(f"[{idx:3d}] ERR        {op_name:7s}  {e}")
            continue

        # ---- Upload input A to DDR ----
        try:
            h.write_ddr(ADDR_IN_A, in_a_data)

            # ---- Upload input B if needed ----
            if in_b_data:
                h.write_ddr(ADDR_IN_B, in_b_data)

            # ---- Build and upload layer config ----
            w_addr = ADDR_WEIGHTS + W["w_off"] if W["w_bytes"] > 0 else 0
            b_addr = ADDR_WEIGHTS + W["b_off"] if W["b_bytes"] > 0 else 0

            cfg = pack_cfg(
                layer_idx=idx,
                in_addr=ADDR_IN_A,
                in_b_addr=ADDR_IN_B if in_b_data else 0,
                out_addr=ADDR_OUT,
                w_addr=w_addr,
                b_addr=b_addr,
            )
            h.write_ddr(ADDR_CFG_ARRAY + idx * LAYER_CFG_SIZE, cfg)

            # ---- Execute layer ----
            t_exec = time.time()
            status, cycles, out_crc, out_bytes_ret = exec_layer(h, idx)
            dt_exec = time.time() - t_exec

        except socket.timeout:
            # Timeout -- try to reconnect
            r = _timeout_result(idx, op_name)
            results.append(r)
            counts["TIMEOUT"] += 1
            print(f"[{idx:3d}] TIMEOUT    {op_name:7s}  c_in={L['c_in']} h={L['h_in']}x{L['w_in']}")
            h.close()
            h.sock = None
            h = safe_reconnect(args.host, args.port, args.timeout)
            if h is None:
                print("FATAL: cannot reconnect after timeout. Saving partial results.")
                break
            h.dpu_init()
            continue

        except (ConnectionError, OSError, RuntimeError) as e:
            # Connection lost -- try to reconnect
            r = _err_result(idx, op_name, str(e))
            results.append(r)
            counts["ERR"] += 1
            print(f"[{idx:3d}] ERR        {op_name:7s}  {e}")
            h.close()
            h.sock = None
            h = safe_reconnect(args.host, args.port, args.timeout)
            if h is None:
                print("FATAL: cannot reconnect. Saving partial results.")
                break
            h.dpu_init()
            # Re-upload weights after reconnect
            try:
                h.write_ddr(ADDR_WEIGHTS, wblob)
            except Exception:
                print("FATAL: cannot re-upload weights. Stopping.")
                break
            continue

        # ---- Check FPGA status ----
        if status != 0:
            r = _err_result(idx, op_name, f"status=0x{status:08X}")
            r["cycles"] = cycles
            r["exec_ms"] = int(dt_exec * 1000)
            results.append(r)
            counts["ERR"] += 1
            print(f"[{idx:3d}] ERR        {op_name:7s}  status=0x{status:08X}  "
                  f"{dt_exec*1000:.0f}ms  {node_name[:40]}")
            continue

        # ---- Read back FULL output from DDR ----
        try:
            fpga_out = h.read_ddr(ADDR_OUT, expected_bytes)
        except Exception as e:
            r = _err_result(idx, op_name, f"read_back: {e}")
            r["cycles"] = cycles
            results.append(r)
            counts["ERR"] += 1
            print(f"[{idx:3d}] ERR        {op_name:7s}  read_back failed: {e}")
            continue

        # ---- Compare against ONNX reference ----
        cmp = compare_arrays(fpga_out, ref_data)
        classification = cmp["classification"]

        # ---- Build result record ----
        r = {
            "layer_idx": idx,
            "op_type": op_type,
            "op_name": op_name,
            "node_name": node_name,
            "classification": classification,
            "max_diff": cmp["max_diff"],
            "n_mismatch": cmp["n_mismatch"],
            "n_off_by_1": cmp["n_off_by_1"],
            "n_off_gt_1": cmp["n_off_gt_1"],
            "fpga_crc": out_crc,
            "ref_crc": tensors[onnx_idx]["crc32"],
            "fpga_size": cmp["fpga_size"],
            "ref_size": cmp["ref_size"],
            "cycles": cycles,
            "exec_ms": int(dt_exec * 1000),
            "c_in": L["c_in"],
            "c_out": L["c_out"],
            "h_in": L["h_in"],
            "w_in": L["w_in"],
            "h_out": L["h_out"],
            "w_out": L["w_out"],
            "kernel": L.get("kernel", 0),
            "stride": L.get("stride", 1),
            "input_a_idx": L["input_a_idx"],
            "input_b_idx": L["input_b_idx"],
        }
        results.append(r)
        counts[classification] += 1

        # ---- Print line ----
        detail = ""
        if classification == "ROUNDING":
            detail = f"  +/-1: {cmp['n_off_by_1']}/{cmp['fpga_size']}"
        elif classification == "FAIL":
            detail = f"  max_diff={cmp['max_diff']} mismatches={cmp['n_mismatch']}"

        print(f"[{idx:3d}] {classification:10s} {op_name:7s} "
              f"{L['c_in']:4d}x{L['h_in']:3d}x{L['w_in']:3d} -> "
              f"{L['c_out']:4d}x{L['h_out']:3d}x{L['w_out']:3d}  "
              f"{dt_exec*1000:7.0f}ms  {node_name[:40]}{detail}")

        # ---- Dump first bytes on failure ----
        if classification == "FAIL" and cmp["n_off_gt_1"] > 0:
            fi = cmp["first_mismatch_idx"]
            lo = max(0, fi)
            hi = min(lo + 16, cmp["fpga_size"])
            fpga_snip = np.frombuffer(fpga_out[lo:hi], dtype=np.int8).tolist()
            ref_snip  = np.frombuffer(ref_data[lo:hi],  dtype=np.int8).tolist()
            print(f"         fpga[{lo}:{hi}] = {fpga_snip}")
            print(f"         ref [{lo}:{hi}] = {ref_snip}")

    # ---- Done ----
    total_time = time.time() - total_start

    try:
        h.close()
    except Exception:
        pass

    # ---- Save results JSON ----
    output = {
        "timestamp": datetime.now().isoformat(),
        "host": args.host,
        "port": args.port,
        "timeout_s": args.timeout,
        "total_time_s": round(total_time, 1),
        "n_layers_tested": len(results),
        "summary": dict(counts),
        "results": results,
    }

    out_path = args.output
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nResults saved to: {out_path}")

    # ---- Print summary table ----
    print_summary(results, counts, total_time)

    # Return exit code: 0 if all pass, 1 if any FAIL/ERR
    return 0 if (counts["FAIL"] + counts["ERR"]) == 0 else 1


# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------
def _skip_result(idx, reason):
    return {
        "layer_idx": idx,
        "classification": "SKIP",
        "reason": reason,
    }


def _err_result(idx, op_name, error_msg):
    return {
        "layer_idx": idx,
        "op_name": op_name,
        "classification": "ERR",
        "error": error_msg,
    }


def _timeout_result(idx, op_name):
    return {
        "layer_idx": idx,
        "op_name": op_name,
        "classification": "TIMEOUT",
    }


# ---------------------------------------------------------------------------
# Summary printer
# ---------------------------------------------------------------------------
def print_summary(results, counts, total_time):
    n = len(results)
    print()
    print("=" * 78)
    print(f"  ISOLATED LAYER TEST SUMMARY  --  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 78)
    print()
    print(f"  Total layers tested : {n}")
    print(f"  Total time          : {total_time:.1f}s ({total_time/60:.1f} min)")
    print()
    print(f"  BIT-EXACT  : {counts['BIT-EXACT']:4d}  {'*' * min(counts['BIT-EXACT'], 60)}")
    print(f"  ROUNDING   : {counts['ROUNDING']:4d}  {'.' * min(counts['ROUNDING'], 60)}")
    print(f"  FAIL       : {counts['FAIL']:4d}  {'X' * min(counts['FAIL'], 60)}")
    print(f"  ERR        : {counts['ERR']:4d}  {'E' * min(counts['ERR'], 60)}")
    print(f"  TIMEOUT    : {counts['TIMEOUT']:4d}  {'T' * min(counts['TIMEOUT'], 60)}")
    print(f"  SKIP       : {counts['SKIP']:4d}  {'S' * min(counts['SKIP'], 60)}")
    print()

    pass_rate = (counts["BIT-EXACT"] + counts["ROUNDING"]) / n * 100 if n > 0 else 0
    print(f"  Pass rate (exact+rounding) : {pass_rate:.1f}%")
    print()

    # ---- Table of failures ----
    failures = [r for r in results if r.get("classification") in ("FAIL", "ERR", "TIMEOUT")]
    if failures:
        print(f"  --- FAILURES ({len(failures)}) ---")
        print(f"  {'Idx':>4s}  {'Class':10s}  {'Op':7s}  {'Details'}")
        print(f"  {'----':>4s}  {'----------':10s}  {'-------':7s}  {'-------'}")
        for r in failures:
            idx = r["layer_idx"]
            cls = r["classification"]
            op = r.get("op_name", "?")
            if cls == "FAIL":
                det = (f"max_diff={r.get('max_diff',0)}  "
                       f"mismatches={r.get('n_mismatch',0)}  "
                       f"{r.get('node_name','')[:40]}")
            elif cls == "ERR":
                det = r.get("error", "")[:50]
            else:
                det = "timeout"
            print(f"  {idx:4d}  {cls:10s}  {op:7s}  {det}")
        print()

    # ---- Table of rounding layers ----
    rounding = [r for r in results if r.get("classification") == "ROUNDING"]
    if rounding:
        print(f"  --- ROUNDING (+/-1) layers ({len(rounding)}) ---")
        print(f"  {'Idx':>4s}  {'Op':7s}  {'Off-by-1':>10s}  {'Total':>10s}  {'%':>6s}  {'Name'}")
        for r in rounding:
            pct = r["n_off_by_1"] / r["ref_size"] * 100 if r.get("ref_size", 0) > 0 else 0
            print(f"  {r['layer_idx']:4d}  {r.get('op_name','?'):7s}  "
                  f"{r.get('n_off_by_1',0):10d}  {r.get('ref_size',0):10d}  "
                  f"{pct:5.2f}%  {r.get('node_name','')[:40]}")
        print()

    # ---- Per-op summary ----
    op_stats = {}
    for r in results:
        op = r.get("op_name", r.get("op_type", "?"))
        if op not in op_stats:
            op_stats[op] = {"total": 0, "exact": 0, "round": 0, "fail": 0, "err": 0}
        op_stats[op]["total"] += 1
        cls = r.get("classification", "?")
        if cls == "BIT-EXACT":
            op_stats[op]["exact"] += 1
        elif cls == "ROUNDING":
            op_stats[op]["round"] += 1
        elif cls == "FAIL":
            op_stats[op]["fail"] += 1
        elif cls in ("ERR", "TIMEOUT"):
            op_stats[op]["err"] += 1

    print("  --- Per-op breakdown ---")
    print(f"  {'Op':8s}  {'Total':>5s}  {'Exact':>5s}  {'Round':>5s}  {'Fail':>5s}  {'Err':>5s}")
    print(f"  {'--------':8s}  {'-----':>5s}  {'-----':>5s}  {'-----':>5s}  {'-----':>5s}  {'-----':>5s}")
    for op in sorted(op_stats.keys()):
        s = op_stats[op]
        print(f"  {op:8s}  {s['total']:5d}  {s['exact']:5d}  {s['round']:5d}  "
              f"{s['fail']:5d}  {s['err']:5d}")
    print()
    print("=" * 78)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args():
    ap = argparse.ArgumentParser(
        description="Isolated FPGA verification of all 255 YOLOv4 layers vs ONNX reference")

    ap.add_argument("--host", default="192.168.1.10",
                    help="ZedBoard IP (default 192.168.1.10)")
    ap.add_argument("--port", type=int, default=7001,
                    help="ZedBoard port (default 7001)")
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="Socket timeout in seconds (default 120)")
    ap.add_argument("--first", type=int, default=None,
                    help="Only test the first N layers")
    ap.add_argument("--layers", type=str, default=None,
                    help="Comma-separated list of layer indices to test (e.g. 0,1,12,15)")
    ap.add_argument("--skip-ic-tiled", action="store_true",
                    help="Skip layers with c_in>256 and kernel>=3 (IC-tiled)")
    ap.add_argument("--output", type=str,
                    default=os.path.join(HERE, "results_isolated.json"),
                    help="Output JSON file path")
    ap.add_argument("--resume", type=str, default=None,
                    help="Resume from a previous partial results JSON")
    return ap.parse_args()


if __name__ == "__main__":
    args = parse_args()
    sys.exit(run_isolated_test(args))
