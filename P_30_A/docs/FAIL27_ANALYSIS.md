# Analysis: 27 Layer Failures in Isolated Test

## Summary

The 24 listed failures (user reports ~27 total) have **two distinct root causes**:

1. **ONNX tensor index mapping bug** (18 of 24 failures, cfg[227]-cfg[253])
2. **CONV k=1 c_in=1024 wb_ram=32KB bug** (6 of 24 failures, cfg[147,148,174,176,180,190])

Neither is a LEAKY or streaming bug. The LEAKY/ADD/CONCAT failures in the list
are all caused by root cause #1 (wrong reference data, not wrong computation).

---

## Root Cause #1: ONNX Tensor Index Mapping Bug

### The bug

`test_all_layers_isolated.py` uses `tensors[i+2]` to map config index `i` to
its ONNX reference tensor. This assumes a 1:1 correspondence between FPGA
layer configs (255 layers) and ONNX intermediate tensors (263 tensors, offset 2).

**This assumption breaks at config index 227** because the ONNX graph contains
extra detection-head output tensors that have no corresponding FPGA layer config:

| Extra tensor index | Node name | Shape (NHWC) |
|---|---|---|
| 229 | `conv2d_93/BiasAdd:0_quantized` | [1, 52, 52, 255] |
| 245 | `conv2d_101/BiasAdd:0_quantized` | [1, 26, 26, 255] |
| 259 | `conv2d_109/BiasAdd:0_quantized` | [1, 13, 13, 255] |
| 260-262 | float32 versions of above | same spatial dims |

These are Reshape/Transpose outputs of the 3 YOLO detection heads (52x52, 26x26,
13x13). The ONNX graph emits both the raw NCHW conv output AND the transposed
NHWC version. Only the NCHW version has a corresponding FPGA layer config.

### Effect

- **cfg[227]-cfg[241]**: tensor index shifted by +1 (due to extra tensor 229)
- **cfg[242]-cfg[254]**: tensor index shifted by +2 (due to extras 229 + 245)

This means:
- The **input** loaded for each layer is the WRONG ONNX tensor (different layer's output)
- The **expected output** compared against is also the wrong tensor
- Size mismatches cause garbage reads/partial comparisons

### Affected layers (18)

```
cfg[227] LEAKY  cfg[229] LEAKY  cfg[230] CONV   cfg[231] LEAKY
cfg[233] LEAKY  cfg[234] CONV   cfg[235] LEAKY  cfg[238] LEAKY
cfg[239] LEAKY  cfg[242] CONV   cfg[243] LEAKY  cfg[245] LEAKY
cfg[246] CONV   cfg[247] LEAKY  cfg[249] LEAKY  cfg[250] CONV
cfg[251] LEAKY  cfg[253] LEAKY
```

### Fix

Build a correct mapping that skips the extra NHWC tensors:

```python
EXTRA_TENSOR_INDICES = {229, 245, 259, 260, 261, 262}

def build_correct_mapping(n_layers, n_tensors):
    """Returns dict: config_index -> correct_tensor_index"""
    mapping = {}
    t_idx = 2  # tensor[0]=float input, tensor[1]=quantized input
    for c_idx in range(n_layers):
        while t_idx in EXTRA_TENSOR_INDICES:
            t_idx += 1
        if t_idx >= n_tensors:
            break
        mapping[c_idx] = t_idx
        t_idx += 1
    return mapping
```

Then in the test, replace `tensors[idx + 2]` with `tensors[correct_map[idx]]`
for both the layer's own output reference AND for the input reference
(`tensors[correct_map[input_a_idx]]` instead of `tensors[input_a_idx + 2]`).

**Verification**: with the corrected mapping, ALL 255 layer output sizes match
their ONNX tensor sizes (0 mismatches).

---

## Root Cause #2: CONV k=1 c_in=1024 (wb_ram exactly 32KB)

### Pattern

6 CONV layers fail with correct tensor mapping (cfg < 227):

| Config | Layer ID | c_in | c_out | k | wt/group |
|--------|----------|------|-------|---|----------|
| 147 | L152 | 1024 | 512 | 1 | 32768 |
| 148 | L153 | 1024 | 512 | 1 | 32768 |
| 174 | L179 | 1024 | 1024 | 1 | 32768 |
| 176 | L181 | 1024 | 512 | 1 | 32768 |
| 180 | L185 | 1024 | 512 | 1 | 32768 |
| 190 | L195 | 1024 | 512 | 1 | 32768 |

**ALL have `wt_per_group = 32 * 1 * 1024 = 32768 bytes = exactly WB_SIZE`**.

No CONV layer with `wt_per_group < 32768` (e.g., c_in=512 gives 16384) appears
in the fail list. This is the distinguishing characteristic.

### Tiling parameters

- `ic_tile_size = 1024` (exactly c_in, no real IC tiling)
- `real_ic_tiling = false` (tile NOT forced to 1x1)
- `n_oc_groups = 16` (c_out=512) or 32 (c_out=1024)
- `tile_h = tile_w = 2` (BRAM fits: 32*4 + 1024*4 + 128 = 4352 < 8192)
- Weight DMA: 3 chunks of 16380 + 16380 + 8 bytes

### Analysis

The software path (weight extraction, DMA, BRAM staging, output assembly) was
traced line-by-line and appears correct. The HDL path (FIFO, wb_ram write,
conv_engine MAC loop with skip_wl=1) also appears correct in isolation.

### Possible causes to investigate

1. **wb_ram read-after-write hazard**: The xpm_memory_tdpram uses "read_first"
   write mode. When the conv_engine (Port A) reads address 32767 while Port B
   may still be writing nearby addresses from a previous FIFO transfer, there
   could be a timing hazard. The `done_latch` should prevent this, but verify
   the timing margin.

2. **FIFO stall at exactly 512 words**: The FIFO depth is 512 words (2KB).
   Weight load of 32768 bytes = 8192 words. The FIFO must drain faster than
   it fills. If the `w_stream_ready_o` backpressure doesn't propagate correctly
   to DMA_W, the FIFO could overflow, dropping bytes. With 16KB weights (512
   cin), the FIFO handles 4096 words -- still > 512 but the drain rate might
   keep up. At 32KB, the margin is tighter.

3. **Accumulator precision with 1024 MACs per pixel**: Each output pixel
   accumulates `c_in * kh * kw = 1024` multiply-add operations. The MAC
   accumulator is 32 bits (signed). The worst-case accumulation:
   `1024 * 127 * 127 + bias = 16,516,096 + bias`. This fits in 32 bits
   (max ~2^31). But verify that the requantize module handles these larger
   intermediate values correctly.

4. **ILA-based HW debug**: Instrument the wb_ram Port A read address and data
   during the MAC loop for a c_in=1024 layer. Compare the weight bytes read
   by the conv_engine against the expected values from the ONNX weight blob.
   If bytes near address 32767 are wrong, it points to a FIFO/write issue.
   If all weights are correct but the output is wrong, it points to an
   accumulator or requantize issue.

### Suggested debug plan

```
# 1. Run isolated test on cfg[147] alone with ILA:
python test_all_layers_isolated.py --layers=147

# 2. Compare with a passing layer that differs only in c_in:
#    cfg[141] CONV k=1 c_in=512 c_out=512 (wt_per_group=16384) -- should pass
python test_all_layers_isolated.py --layers=141,147

# 3. If cfg[141] passes and cfg[147] fails, the bug is specific to
#    wt_per_group=32768. Add ILA probes on:
#    - ext_wb_addr, ext_wb_data, ext_wb_we (last bytes written)
#    - wb_addr (Port A read), wb_dout (data read by conv_engine)
#    - mac_acc[0..3] after all 1024 ic steps
```

---

## Both causes may overlap at cfg[242+]

Layers cfg[242], cfg[246], cfg[250] are CONV k=1 c_in=1024 with wt_per_group=32768
(same pattern as Root Cause #2). They appear in the fail list but were classified
under Root Cause #1 (tensor mapping). After fixing the mapping, these layers
should be retested. **They may still fail due to Root Cause #2.** This would
mean the true count of CONV-32KB failures is 6 confirmed + 3 probable = 9.

The LEAKY layers in the fail list (cfg[227], cfg[229], etc.) are caused purely
by the tensor mapping bug (#1). After fixing the mapping, they should be
retested -- they are likely BIT-EXACT or ROUNDING since the LEAKY hardware
has been verified correct for all channel counts up to 1024.

## Summary table

| Root cause | Count | Config range | Fix |
|---|---|---|---|
| Tensor mapping bug | 18 | cfg[227]-cfg[253] | Fix `test_all_layers_isolated.py` mapping |
| CONV 32KB wb_ram | 6 | cfg[147,148,174,176,180,190] | HW debug with ILA |
| **Total explained** | **24** | | |
