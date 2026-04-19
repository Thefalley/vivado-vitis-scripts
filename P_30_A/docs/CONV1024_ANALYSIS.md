# CONV k=1 c_in=1024 Failure Analysis

## Failing layers

| FPGA idx | ONNX ID | c_in | c_out | k | size  | max_diff |
|----------|---------|------|-------|---|-------|----------|
| 147      | L152    | 1024 | 512   | 1 | 13x13 | 44       |
| 148      | L153    | 1024 | 512   | 1 | 13x13 | 23       |
| 174      | L179    | 1024 | 1024  | 1 | 13x13 | 15       |
| 176      | L181    | 1024 | 512   | 1 | 13x13 | 23       |
| 180      | L185    | 1024 | 512   | 1 | 13x13 | 81       |
| 190      | L195    | 1024 | 512   | 1 | 13x13 | 42       |
| 242      | L249    | 1024 | 512   | 1 | 13x13 | 46       |
| 246      | L253    | 1024 | 512   | 1 | 13x13 | 30       |
| 250      | L257    | 1024 | 512   | 1 | 13x13 | 28       |

All: CONV, kernel=1, stride=1, pad=0, h_in=h_out=13, w_in=w_out=13.

## ARM-side tiling decisions

```
ic_tile_size = 32768 / (32 * 1 * 1) = 1024   (= c_in, no real IC tiling)
needs_ic_tiling = (512*1*1024 > 32768) = TRUE   --> ARM OC groups
real_ic_tiling = (1024 < 1024) = FALSE
tile_h = tile_w = 2   (fits in 8KB BRAM: 128 + 4096 + 128 = 4352 bytes)
n_oc_groups = 512/32 = 16   (or 32 for c_out=1024)
Total CMD_STARTs per spatial tile: 16
Total spatial tiles: ceil(13/2) * ceil(13/2) = 7 * 7 = 49
Total invocations: 49 * 16 = 784
```

ARM writes to registers per OC group:
```c
dpu_write(REG_C_IN,         1024);   // <-- PROBLEM
dpu_write(REG_IC_TILE_SIZE, 1024);   // <-- PROBLEM
dpu_write(REG_C_OUT,        32);     // OK (fits in 10 bits)
```

## ROOT CAUSE: 10-bit port truncation

### The bug

The conv_engine_v4 ports `cfg_c_in` and `cfg_ic_tile_size` are both
`unsigned(9 downto 0)` -- 10 bits, max value 1023.

```vhdl
-- conv_engine_v4.vhd lines 102, 125:
cfg_c_in         : in  unsigned(9 downto 0);   -- MAX 1023
cfg_ic_tile_size : in  unsigned(9 downto 0);   -- MAX 1023
```

The wrapper connects them from the 32-bit AXI register taking only
bits [9:0]:

```vhdl
-- dpu_stream_wrapper_v4.vhd lines 383, 402:
cfg_c_in         => unsigned(reg_c_in(9 downto 0)),         -- truncates!
cfg_ic_tile_size => unsigned(reg_ic_tile_size(9 downto 0)), -- truncates!
```

When the ARM writes 1024 (= 0x400), bit 10 is set but bit 9:0 are
all zero. The conv_engine sees **cfg_c_in = 0** and
**cfg_ic_tile_size = 0**.

Similarly, `cfg_c_out` is `unsigned(9 downto 0)`. Layer 174
(c_out=1024) also truncates cfg_c_out to 0.

### Consequences in the conv_engine FSM

With `cfg_c_in = 0` and `cfg_ic_tile_size = 0`:

1. **WL_NEXT**: `ic_in_tile_limit = min(0, 0-0) = 0`

2. **WL_STRIDE**: `tile_filter_stride = 0 * kk_reg = 0`

3. **MAC loop** (MAC_FIRE): The comparison `ic < ic_in_tile_limit - 1`
   becomes `ic < 0 - 1` in unsigned 10-bit arithmetic = `ic < 1023`.
   The loop runs 1024 iterations (ic = 0..1023). This is accidentally
   the CORRECT iteration count due to unsigned wraparound.

4. **MAC_WLOAD_CAP**: Each step loads 32 weights from wb_ram with
   stride `tile_filter_stride = 0`. All 32 mac_b values read from
   the SAME address (wb_ram[ic]). This means ALL 32 output channels
   compute with filter 0's weights instead of their own.

5. **IC_TILE_ADV**: `(0 + 0) < 0` = FALSE, so no additional IC tiles.
   Goes directly to requantize. Correct behavior (1 tile = full c_in).

6. **Activation addressing**: Uses `hw_reg = h_in * w_in` (not
   affected by cfg_c_in). Reads correct activation data.

### Expected error impact

All 32 output channels per OC group compute:
```
acc[i] = bias[i] + dot(activation_vector, filter_0_weights)
```
instead of:
```
acc[i] = bias[i] + dot(activation_vector, filter_i_weights)
```

Channel 0 is correct. Channels 1-31 all get filter 0's convolution
result (with their own bias). After requantize with M0/2^n_shift
scale (~0.003), the output error per channel should be on the order
of `|dot(act, w0 - wi)| * scale`. With typical INT8 weights, this
should produce LARGE errors (potentially saturating to max_diff=255).

**Note:** The observed max_diff of 15-81 is SMALLER than expected
for a complete weight mismatch across 31 of 32 channels. This
discrepancy may indicate that the test was run against a partially
fixed firmware, or that the reported max_diff corresponds to a
subset of output bytes. Regardless, the 10-bit truncation is a
confirmed, critical hardware bug.

## Verification checklist from the user's questions

### 1. DMA chunking for w_bytes=32768

```
Chunk 0: offset=0,     size=16380  (DMA_MAX_CHUNK)
Chunk 1: offset=16380, size=16380  (DMA_MAX_CHUNK)
Chunk 2: offset=32760, size=8      (remainder, ALIGN_UP(8,4)=8)
Total:   32768 bytes -- correct, contiguous, no gap/overlap.
```

**Verdict: OK.** DMA chunking works correctly for 32768 bytes.

### 2. Tile size computation

```
c_out_bram = 32 (needs_ic_tiling), ic_tile_size = 1024
tile_h=2: out=128B, in=4096B, bias=128B, total=4352B <= 8192B. FITS.
tile_h=3: out=288B, in=9216B > 8KB. TOO BIG.
Result: tile_h = tile_w = 2.
13x13 output -> 7*7 = 49 spatial tiles (36 full 2x2, 13 partial).
49 tiles * 16 OC groups = 784 CMD_STARTs.
```

**Verdict: OK.** Tile sizing is correct.

### 3. Output copy to DDR for OC groups

```c
memcpy(out_ddr + (uint32_t)(oc_base + c) * L->h_out * L->w_out
                + (uint32_t)(oh0 + rr) * L->w_out + ow0, ...);
```

For oc_base=480 (last group of c_out=512): 480 * 169 = 81120.
Within 32-bit range. No overflow.

**Verdict: OK.**

### 4. Bias offset

```c
memcpy(tile_buf + B_OFF, bias_ddr + oc_base, bias_now);
```

`bias_ddr` is `int32_t*`, so `bias_ddr + oc_base` is byte offset
`oc_base * 4`. For oc_base=480: byte offset 1920. Total bias array
= 512*4 = 2048 bytes. 1920 + 128 = 2048. Fits exactly.

**Verdict: OK.**

### 5. Weight extraction for k=1

```c
memcpy(wt + oc * 1 * ic_ts,
       weights_ddr + (oc_base + oc) * 1024,
       1024);
```

For k=1, p=0 only. Copies 1024 contiguous bytes per filter.
Layout in wt: filter 0 at [0..1023], filter 1 at [1024..2047], etc.
Total: 32 * 1024 = 32768 bytes. Matches w_bytes. Correct OHWI order.

**Verdict: OK.**

## FIX

### Option A: Widen ports to 11 bits (minimal change)

In `conv_engine_v4.vhd`, change all channel/tile-size ports from
10 bits to 11 bits:

```vhdl
cfg_c_in         : in  unsigned(10 downto 0);  -- was 9 downto 0
cfg_c_out        : in  unsigned(10 downto 0);  -- was 9 downto 0
cfg_ic_tile_size : in  unsigned(10 downto 0);  -- was 9 downto 0
```

Also widen all internal signals that hold channel counts:
- `ic_in_tile_limit`, `ic_tile_base`, `oc_tile_base`, `oh`, `ow`,
  `kh`, `kw`, `ic` should all be widened from `unsigned(9 downto 0)`
  to `unsigned(10 downto 0)`.
- The `N_MAC` constant comparisons and `to_unsigned(N_MAC, 10)` calls
  must be updated to `to_unsigned(N_MAC, 11)`.

In `dpu_stream_wrapper_v4.vhd`, update the port connections:

```vhdl
cfg_c_in         => unsigned(reg_c_in(10 downto 0)),
cfg_c_out        => unsigned(reg_c_out(10 downto 0)),
cfg_ic_tile_size => unsigned(reg_ic_tile_size(10 downto 0)),
```

### Option B: Clamp in the ARM C code (software workaround)

Not recommended -- the hardware should support the full range needed
by the YOLOv4 model (max c_in = 1024, max c_out = 1024).

### Rebuild required

After fixing the VHDL, re-synthesize and generate a new bitstream.
The fix adds 1 bit to several counters and address computations,
with negligible impact on timing and resources.

## Files involved

| File | Lines | Issue |
|------|-------|-------|
| `src/conv_engine_v4.vhd` | 102-103, 125 | Port width 10 bits, needs 11 |
| `src/dpu_stream_wrapper_v4.vhd` | 383, 384, 402 | Truncates to bits [9:0] |
| `sw/dpu_exec_v4.c` | 450, 453 | Writes 1024 to register (correct) |
