# LEAKY Layer Failures Analysis

## Root Cause

**The ONNX tensor index mapping (`idx+2`) in the isolated test is wrong
for FPGA layers >= 227.**

The ONNX graph has 257 output nodes (IDs 5-261), but the FPGA layer list
has only 255 entries because 2 ONNX nodes are skipped:
- **ONNX node 232** (skipped, not mapped to any FPGA layer)
- **ONNX node 248** (skipped, not mapped to any FPGA layer)

The manifest `onnx_refs/manifest.json` contains tensors for ALL 257 ONNX
nodes plus 2 input tensors = 259 total (+4 extra = 263 entries). The test
script `test_all_layers_isolated.py` uses `onnx_idx = idx + 2` to map
FPGA layer index to tensor index. This formula is correct ONLY when
`layer_id == idx + 5` (no gaps).

After the first gap (ONNX node 232 between FPGA layers 226 and 227),
the mapping becomes off-by-1. After the second gap (ONNX node 248
between FPGA layers 239 and 241), it becomes off-by-2.

## Impact

| FPGA layer range | ONNX lid range | Shift | Effect |
|------------------|----------------|-------|--------|
| 0-226            | 5-231          | 0     | idx+2 correct, all pass |
| 227-239          | 233-245        | +1    | wrong tensor (off by 1) |
| 240-253          | 246-260        | +2    | wrong tensor (off by 2) |

The test loads the **wrong ONNX reference file** as both:
1. **Input** -- loaded from `tensors[a_idx + 2]` (wrong for a_idx >= 227)
2. **Expected output** -- loaded from `tensors[idx + 2]` (wrong for idx >= 227)

Exception: FPGA layer 227 gets CORRECT input (because `a_idx=226` is
before the gap), but wrong expected output. So the FPGA computes a
correct LEAKY result, but the comparison fails because the reference
is from the wrong ONNX node.

For layers 229+, both input AND expected output are wrong, so the FPGA
processes wrong input data and the comparison against wrong reference
produces large diffs (max_diff 12-221).

## Failing Layers Detail

All 13 failing LEAKY layers are the last 13 LEAKY layers in the network:

| FPGA idx | ONNX lid | c_in  | h | w | Shift | Input OK? |
|----------|----------|-------|---|---|-------|-----------|
| 227      | 233      | 256   |26 |26 | +1    | YES       |
| 229      | 235      | 512   |26 |26 | +1    | NO        |
| 231      | 237      | 256   |26 |26 | +1    | NO        |
| 233      | 239      | 512   |26 |26 | +1    | NO        |
| 235      | 241      | 256   |26 |26 | +1    | NO        |
| 238      | 244      | 512   |26 |26 | +1    | NO        |
| 239      | 245      | 512   |13 |13 | +1    | NO        |
| 243      | 250      | 512   |13 |13 | +2    | NO        |
| 245      | 252      | 1024  |13 |13 | +2    | NO        |
| 247      | 254      | 512   |13 |13 | +2    | NO        |
| 249      | 256      | 1024  |13 |13 | +2    | NO        |
| 251      | 258      | 512   |13 |13 | +2    | NO        |
| 253      | 260      | 1024  |13 |13 | +2    | NO        |

## Why Passing Layers Pass

For layers 0-226, `layer_id == fpga_idx + 5` (no gaps), so `idx + 2`
produces the correct tensor index. All 16 passing LEAKY layers
(1, 3, 7, 9, 11, 14, 17, 19, 22, 23, 25, 27, 30, 32, 35, 38) are
in this range.

## What is NOT Wrong

- The LEAKY VHDL hardware is correct
- The `dpu_exec_leaky` C function is correct
- The `layer_configs.h` parameters match `layer_configs.json` exactly
- The chunking (4092 bytes max) works correctly for all sizes
- There is no BRAM overflow or register width issue
- M0, M0_neg fit in 30 bits; n_shift, n_neg fit in 6 bits; x_zp, y_zp fit in 8 bits
- No DDR address overlaps between input, output, and weights regions

## Fix

Replace the `idx + 2` mapping with a correct mapping based on `layer_id`.
The correct formula is:

```python
onnx_tensor_idx = layers[fpga_idx]["layer_id"] - 3
```

This accounts for the 2 skipped ONNX nodes. Alternatively, build a lookup
table from `layer_id` to tensor index using the manifest.

### In `test_all_layers_isolated.py`:

Line 271 (output tensor):
```python
# WRONG:
onnx_idx = idx + 2
# CORRECT:
onnx_idx = layers[idx]["layer_id"] - 3
```

Lines 306-311 (input tensor):
```python
# WRONG:
in_a_onnx_idx = a_idx + 2
# CORRECT:
in_a_onnx_idx = layers[a_idx]["layer_id"] - 3
```

### In `run_all_layers.py`:

Line 132 (same issue):
```python
# WRONG:
onnx_idx = i + 2
# CORRECT:
onnx_idx = layers[i]["layer_id"] - 3
```

## Skipped ONNX Nodes

| ONNX node | Between FPGA layers | What it is |
|-----------|---------------------|------------|
| 232       | 226 and 227         | Likely a Reshape/Transpose (tensor[229] has shape [1,52,52,255] = NHWC format of 255-channel detection head output) |
| 248       | 241 and 242         | Same pattern for a different detection head |

These nodes are post-processing reshapes for YOLO detection heads that
are not executed on the FPGA.
