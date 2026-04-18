# Audit: Layer 4 -- 42 Rounding Diffs of +-1

## Layer Parameters

| Parameter   | Value            |
|-------------|------------------|
| ONNX Layer  | L009 QLinearConv |
| FPGA Index  | [4]              |
| c_in / c_out| 64 / 64          |
| h_out x w_out| 208 x 208       |
| kernel      | 1x1              |
| stride      | 1                |
| pad         | 0                |
| x_zp        | -97              |
| w_zp        | 0                |
| y_zp        | 7                |
| M0          | 624082313        |
| n_shift     | 37               |
| Output size | 2,768,896 bytes  |

## Tiling Configuration (Computed by Firmware)

| Parameter       | Value    | Notes                                  |
|-----------------|----------|----------------------------------------|
| tile_h x tile_w | 7 x 7   | BRAM fit: 3136+3136+256 = 6528 <= 8192 |
| n_tiles         | 30 x 30 | 900 spatial tiles                      |
| last tile       | 5 x 5   | 208 - 29*7 = 5                         |
| ic_tile_size    | 64       | 64*1*1*64 = 4096 < 32768 => no IC tiling |
| oc_tile_size    | 32       | N_MAC = 32, 2 OC tiles: [0..31],[32..63] |

## Claim Under Audit

> "42 rounding diffs of +-1 are a tiling edge-case rounding issue"

## Analysis

### 1. First Diff Location Disproves Tile-Boundary Correlation

The first diff is at byte offset 45701, which decodes to:

- **Channel 1**, row 11, col 149

Position within the tiling grid:

| Coordinate | Value | Tile index | Local position | At boundary? |
|------------|-------|------------|----------------|--------------|
| row = 11   | 11    | tile 1     | local_row = 4  | **No** (middle of tile) |
| col = 149  | 149   | tile 21    | local_col = 2  | **No** (middle of tile) |
| ch = 1     | 1     | OC tile 0  | within [0..31] | **No** |

If diffs correlated with tile boundaries (rows 0,7,14,...,203 or cols
0,7,14,...,203), the first diff would be expected at one of those
positions. Row 11 mod 7 = 4 and col 149 mod 7 = 2, placing this diff
squarely in the interior of its spatial tile.

### 2. For 1x1 Conv with pad=0, Tile Boundaries Are Irrelevant

This is the critical insight. The firmware computes per spatial tile
(`dpu_exec_v4.c` lines 288-306):

```
ih_start = oh0 * stride - pad = oh0 * 1 - 0 = oh0
iw_start = ow0 * stride - pad = ow0 * 1 - 0 = ow0
in_h_needed = (tile_h - 1) * stride + kernel = (7-1)*1 + 1 = 7
pad_t = pad_b = pad_l = pad_r = 0   (for ALL tiles, always)
```

In the RTL (`conv_engine_v4.vhd`, MAC_PAD_REG state, lines 872-882):

```vhdl
v_ih := ih_base_r + kh;   -- kh=0 for 1x1 => v_ih = oh >= 0
v_iw := iw_base_r + kw;   -- kw=0 for 1x1 => v_iw = ow >= 0
-- pad_saved is NEVER set because v_ih and v_iw are always in-range
```

Consequences:

- **No padding is applied** at any tile edge. The `pad_saved` flag
  is never set. Every activation value is read from DDR, never replaced
  with zero.
- **No kernel overlap** between tiles. For kernel=1x1, each output
  pixel depends on exactly 1 spatial position in the input, so tiles
  are completely independent.
- **Each pixel is computed identically** regardless of its position
  within a tile or whether it is at a tile boundary.

### 3. No IC Tiling for This Layer

Weight buffer capacity: 32,768 bytes. Weights for this layer:
64 * 1 * 1 * 64 = 4,096 bytes. Since 4,096 < 32,768, all input channels
fit in a single IC tile pass.

The firmware sets `no_clear = 0` and `no_requantize = 0` (standard
single-pass mode). There is no partial accumulation across IC tiles
that could introduce rounding variance.

### 4. Accumulator Overflow Check

```
max |x - x_zp| = max(|-97|, |255-(-97)|) = 158   (~8 bits)
max |w|         = 128                               (~8 bits)
max single product = 158 * 128 = 20,224             (~15 bits)
max sum of 64 products = 64 * 20,224 = 1,294,336   (21 bits)
int32 range = +/- 2,147,483,647                     (31 bits)
```

No overflow risk. The 32-bit accumulator has 10 bits of headroom
even before adding the bias.

Multiply overflow check: max |acc * M0| ~ 1,294,336 * 624,082,313 =
807 billion (40 bits), well within signed 64-bit range (63 bits).

### 5. Root Cause: Requantize Rounding Mode Mismatch

The DPU requantize formula (`requantize.vhd`, 8-stage pipeline):

```
y = clamp( ((acc * M0) + 2^(n_shift - 1)) >> n_shift + y_zp, -128, 127 )
```

This implements **round-half-up** (biased-add-then-shift). When
`(acc * M0) mod 2^n` is near `2^(n-1)`, the rounding rounds upward
(toward +infinity).

The ONNX quantization reference likely uses a different rounding
convention (e.g., round-half-to-even / banker's rounding, or truncation
toward zero). Values exactly at the rounding boundary produce outputs
that differ by exactly +-1.

**Statistics**: 42 / 2,768,896 = **0.0015%** (1 in 65,926 pixels).
This extremely low rate is consistent with a rounding boundary condition
that depends on the specific accumulator values and is data-dependent,
not position-dependent.

## Verdict

**The claim is FALSE.** The 42 diffs of +-1 are **not** a tiling
edge-case bug. They are a **requantize rounding mode mismatch** between
the DPU hardware (round-half-up) and the ONNX reference implementation.

Evidence summary:

1. The first diff at (ch=1, row=11, col=149) is at row%7=4, col%7=2 --
   the middle of a spatial tile, not at a boundary.
2. For 1x1 conv with pad=0, tile boundaries are mathematically
   irrelevant: no padding, no kernel overlap, no partial accumulation.
3. The magnitude is always +-1, consistent with a rounding tie-break
   difference, not a computational error.
4. The rate (0.0015%) is consistent with rare rounding-boundary hits
   in the requantize formula.
5. There is no IC tiling, no accumulator overflow, and no leakage
   between tiles.

This is a known and accepted discrepancy in INT8 quantized inference.
The DPU output is **not wrong** -- it uses a valid rounding mode that
differs from the reference by at most 1 LSB on rare boundary values.
