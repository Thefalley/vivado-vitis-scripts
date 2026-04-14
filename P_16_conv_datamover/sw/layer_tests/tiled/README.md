# P_16 Layer Tests -- IC Tiling Variants

Purpose: verify on real ZedBoard HW that `conv_engine_v3` produces
**bit-exact** outputs against real YOLOv4 ONNX weights when
`ic_tile_size < c_in`, i.e. when the `c_in` accumulation is split across
multiple tile passes of the MAC array.

All baseline tests in `../layer_tests/` write `conv_write(REG_IC_TILE_SIZE, C_IN)`
(one tile covering the whole `c_in`), so the tiling path has never been
exercised on HW with real quantized weights. These variants change that
single register write and nothing else -- `expected_full[]` must still
match byte-for-byte, because `ic_tile_size` is a HW micro-architectural
knob, not an algorithmic change.

## Generator

`_gen.py` copies each baseline verbatim and patches only:

1. The single `conv_write(REG_IC_TILE_SIZE, C_IN);` line at the config
   phase (line ~400 in layer_005, ~460 in layer_038, ~468 in layers
   043/045/047/049).
2. The opening `xil_printf` banner, to announce the tiling config.

All layer parameters, padding, scales/zero-points, weight/input/bias
arrays, and `expected_full[]` are kept identical to the baseline.

Re-run with:
```
python _gen.py
```

## Variants

### Divisible cases (`c_in % ic_tile_size == 0`)

| File                   | Baseline         | c_in | ic_tile_size | tiles |
|------------------------|------------------|-----:|-------------:|------:|
| layer_005_ic1_test.c   | layer_005_test.c |    3 |            1 |     3 |
| layer_038_ic1_test.c   | layer_038_test.c |    9 |            1 |     9 |
| layer_038_ic3_test.c   | layer_038_test.c |    9 |            3 |     3 |
| layer_043_ic1_test.c   | layer_043_test.c |    5 |            1 |     5 |
| layer_045_ic1_test.c   | layer_045_test.c |    5 |            1 |     5 |
| layer_047_ic1_test.c   | layer_047_test.c |    5 |            1 |     5 |

### Non-divisible cases (last tile partial -- stresses `ic_in_tile_limit = min(ic_tile_size, c_in - ic_tile_base)`)

| File                   | Baseline         | c_in | ic_tile_size | tiles | tile sizes |
|------------------------|------------------|-----:|-------------:|------:|-----------:|
| layer_005_ic2_test.c   | layer_005_test.c |    3 |            2 |     2 | 2 + 1      |
| layer_043_ic2_test.c   | layer_043_test.c |    5 |            2 |     3 | 2 + 2 + 1  |
| layer_049_ic2_test.c   | layer_049_test.c |    5 |            2 |     3 | 2 + 2 + 1  |
| layer_038_ic4_test.c   | layer_038_test.c |    9 |            4 |     3 | 4 + 4 + 1  |

## Expected behavior

Every variant must produce the **same** `expected_full[]` bytes as its
baseline. Any mismatch indicates a bug in one of:

- Partial-sum carry across tiles in `mac_array` (tile 0 must load bias,
  tiles 1..N-1 must accumulate without clearing).
- Weight buffer reload per tile (fresh weights each tile, same pixel
  window).
- `ic_in_tile_limit = min(ic_tile_size, c_in - ic_tile_base)` masking
  for the partial last tile (the 4 non-divisible variants).

## Notes

- `layer_057` and `layer_049`'s ic1 variant were not generated on
  purpose -- coverage for `c_in=5, ic1` is already provided by layers
  043/045/047. Non-divisible coverage for `c_in=5` uses 043/049; for
  `c_in=9`, variants 038_ic3 (divisible) and 038_ic4 (non-divisible).
- Do NOT edit the baselines. If one of these variants fails but its
  baseline passes, the defect is in the IC-tiling control path, not in
  the MAC pipeline.
