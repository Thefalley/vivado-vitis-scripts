# CONCAT Requantization Parameters -- Correct Values

Extracted from `yolov4_int8_qop.onnx` QLinearConcat nodes on 2026-04-18.
Verified bit-exact (0 diffs) against all 10 ONNX reference tensors.

## The Problem

The `layer_configs.json` had WRONG requantization parameters for CONCAT layers.
The old code treated x_zp and b_zp as the zero points for input_a and input_b
respectively, but the values were **swapped** relative to the ONNX graph, and
the M0/M0_b multipliers were computed from incorrect scale relationships.

## QLinearConcat Requantization Formula

Each input to a CONCAT may have a different quantization scale. The ONNX
`QLinearConcat` operator requantizes each input to match the output scale:

```
out[i] = clip(round((in[i] - x_zp) * (S_in / S_out) + y_zp), -128, 127)
```

where:
- `x_zp` = zero point of the input tensor
- `y_zp` = zero point of the concat output tensor
- `S_in` = scale of the input tensor
- `S_out` = scale of the concat output tensor
- `S_in / S_out` = requantization scale factor

In fixed-point: `requant_scale = M0 / 2^n_shift`

The DPU computes:
```c
int64_t prod = (int64_t)(in - x_zp) * M0;
int64_t half = 1LL << (n_shift - 1);
int8_t  out  = clip((prod + half) >> n_shift + y_zp, -128, 127);
```

## Key Finding: One Input is Always Passthrough (except concat 4)

For 9 of 10 CONCAT layers, one input has `requant_scale = 1.0` and matching
zero points, meaning it is a raw copy (passthrough). Only the OTHER input
needs requantization.

Exception: concat 4 (layer_id=178) has BOTH inputs with requant_scale != 1.0.

Concat 5 (layer_id=190) is special: it has 4 inputs, ALL passthrough.

## Correct Parameters per CONCAT

### Concat 0 -- cfg[15], layer_id=20, 128ch 208x208

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..63     | -95  | 1073741824  | 30      | YES         |
| b     | 64..127   | -94  | 1260369140  | 31      | no          |

y_zp = -95

### Concat 1 -- cfg[36], layer_id=41, 128ch 104x104

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..63     | -108 | 1073741824  | 30      | YES         |
| b     | 64..127   | -105 | 1798597439  | 31      | no          |

y_zp = -108

### Concat 2 -- cfg[87], layer_id=92, 256ch 52x52

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..127    | -107 | 1073741824  | 30      | YES         |
| b     | 128..255  | -102 | 1541979019  | 31      | no          |

y_zp = -107

### Concat 3 -- cfg[140], layer_id=145, 512ch 26x26

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..255    | -116 | 1073741824  | 30      | YES         |
| b     | 256..511  | -107 | 1903176794  | 32      | no          |

y_zp = -116

### Concat 4 -- cfg[173], layer_id=178, 1024ch 13x13 (BOTH inputs need requant)

| input | channels   | x_zp | M0          | n_shift | passthrough |
|-------|------------|------|-------------|---------|-------------|
| a     | 0..511     | -103 | 2107051304  | 31      | no          |
| b     | 512..1023  | -96  | 1951878780  | 31      | no          |

y_zp = -99

### Concat 5 -- cfg[185], layer_id=190, 2048ch 13x13 (4 inputs, ALL passthrough)

All 4 inputs: x_zp = -116, M0 = 1073741824, n_shift = 30 (no requant needed)

y_zp = -116

### Concat 6 -- cfg[195], layer_id=200, 512ch 26x26

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..255    | -98  | 1073741824  | 30      | YES         |
| b     | 256..511  | -111 | 1301865859  | 31      | no          |

y_zp = -98

### Concat 7 -- cfg[209], layer_id=214, 256ch 52x52

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..127    | -107 | 1918228730  | 32      | no          |
| b     | 128..255  | -112 | 1073741824  | 30      | YES         |

y_zp = -112

### Concat 8 -- cfg[224], layer_id=229, 512ch 26x26

| input | channels  | x_zp | M0          | n_shift | passthrough |
|-------|-----------|------|-------------|---------|-------------|
| a     | 0..255    | -105 | 1548186647  | 31      | no          |
| b     | 256..511  | -110 | 1073741824  | 30      | YES         |

y_zp = -110

### Concat 9 -- cfg[241], layer_id=247, 1024ch 13x13

| input | channels   | x_zp | M0          | n_shift | passthrough |
|-------|------------|------|-------------|---------|-------------|
| a     | 0..511     | -108 | 1073741824  | 30      | YES         |
| b     | 512..1023  | -112 | 1608604529  | 31      | no          |

y_zp = -108

## What Was Wrong in Old layer_configs.json

For each CONCAT, the old config had these fields used for requant:
- `x_zp` / `b_zp` -- input_a / input_b zero points (SWAPPED vs ONNX)
- `y_zp` -- output zero point (WRONG, was using one of the input zps)
- `M0` / `M0_b` -- multipliers for input_a / input_b (WRONG values)
- `n_shift` -- shared shift (WRONG, inputs may need different shifts)

The old code apparently had the A/B zero points flipped and computed M0
from incorrect scale ratios. Additionally, input_a and input_b each need
their OWN n_shift (e.g., concat 3 has n_shift_a=30, n_shift_b=32), but
the old config only stored one shared n_shift.

## Files

- `../sw/concat_requant.json` -- machine-readable parameters with all details
- Source ONNX model: `C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx`
- Reference tensors: `C:/project/vivado/P_18_dpu_eth/host/onnx_refs/`
