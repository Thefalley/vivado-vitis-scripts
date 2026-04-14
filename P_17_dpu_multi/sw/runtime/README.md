# P_17 YOLOv4-416 INT8 Runtime

Bare-metal C runtime for ZedBoard (Zynq-7020) that drives the P_17 DPU
wrapper through the full 255-layer YOLOv4-416 INT8 graph.

## Files

| File | Role |
|---|---|
| `yolov4_runtime.c` | Top-level loop: walks `LAYERS[]`, dispatches per op, manages activations + profiling. |
| `dpu_api.h`        | Public API (`dpu_exec_*`, `arm_*`, memory pool). |
| `dpu_kernels.c`    | (TODO) implements `dpu_exec_conv/leaky/pool/add` with ARM-driven tiling on top of the P_16 LOAD/COMPUTE/DRAIN pattern. |
| `arm_kernels.c`    | (TODO) implements `arm_concat`, `arm_upsample` (NN 2x). Reference impls are inlined under `DPU_RUNTIME_INLINE_STUBS` for sim. |
| `mem_pool.c`       | (TODO) bump-and-recycle allocator backing `pool_alloc/release`. |
| `layer_configs.h`  | Generated table from `vitis-ai/workspace/c_dpu`, copied into the BSP include path. |

## Build

Use the existing P_16 Vitis flow as the template:

```tcl
# from C:/project/vivado/P_17_dpu_multi/sw
xsct build_xsct.tcl runtime
```

The supplied `build_xsct.tcl` already supports the `runtime` subdir and
links the BSP against `xilffs`-free settings (no SD card needed).  No new
hardware spec is required — the same `.xsa` produced by the P_17 Vivado
project drives the runtime.

`Xil_DCacheFlushRange` / `Xil_DCacheInvalidateRange` calls bracket every
DMA boundary inside `dpu_kernels.c`; nothing is needed in user code.

## Run

```tcl
# in xsct
connect; rst -system
fpga -file system_wrapper.bit
loadhw -hw system.xsa -mem-ranges {{0x40000000 0xBFFFFFFF}}
ps7_init; ps7_post_config
# 1) push weights + biases blob
dow -data weights.bin   0x10100000
dow -data biases.bin    0x14000000
# 2) push the calibration image (520 KB raw int8 NHWC, 3x416x416)
dow -data input_int8.bin 0x10000000
# 3) push the runtime ELF and run
dow yolov4_runtime.elf
con
# 4) poll RESULT_ADDR (0x1F000000) for MAGIC_DONE = 0xD09F1234
mrd 0x1F000000 8
```

`res[1]` carries the wall-clock latency in ms; `res[2..4]` are the DDR
pointers to the three YOLO detection-head outputs (small, medium, large).

## Memory budget (256 MB cap)

| Region        | Base        | Size      | Notes                             |
|---------------|-------------|-----------|-----------------------------------|
| ELF / heap    | 0x00000000  | 64 MB     | code + standalone heap/stack      |
| Image input   | 0x10000000  | 1 MB      | 3*416*416 = 519 168 B             |
| Weights       | 0x10100000  | 64 MB     | int8 OHWI (~62 MB total YOLOv4)   |
| Biases        | 0x14000000  | 1 MB      | int32 per OC                      |
| Activation pool| 0x14100000 | 224 MB    | bump-and-recycle                  |
| Result        | 0x1F000000  | 256 B     | XSCT polling area                 |
| **Total HW** |             | **~290 MB**| ZedBoard has 512 MB DDR — fits.  |

The activation pool peaks far below 224 MB.  Worst spatial layer is
416×416×64 ≈ 11 MB; with the longest skip (early concat live across the
backbone) we estimate peak live working set at **~80 MB**.  The 224 MB
budget is sized for 3× headroom and to keep the allocator simple.

## Layer ordering and skip connections

`LAYERS[]` is already sorted topologically by `gen_layer_configs.py`.
The runtime relies on:

* `input_a_idx` and `input_b_idx` reference earlier `LAYERS[]` entries
  (or `-1` for the network input).
* Reference counts are precomputed in `build_refcount()`; outputs are
  released through `pool_release()` the moment their last consumer runs.
* The 3 detection heads (`NUM_FPGA_LAYERS - 3 .. NUM_FPGA_LAYERS - 1`)
  carry an extra +1 refcount so they survive past the last layer.

## Tiling — why ARM-side, not HW

Wrapper BRAM is 4 KB.  YOLOv4 has layers whose input tensor alone is
multi-megabyte.  Therefore each `dpu_exec_*()` slices the work along
(H, W, C_in) so that one tile fits the BRAM budget given in `dpu_api.h`
(`DPU_TILE_INPUT_MAX = 512 B` for CONV, `1536 B` for streaming layers).

The slicing strategy (sketched at the bottom of `yolov4_runtime.c`):

1. Try row-strip tiling: as many rows as fit.
2. If a single output row does not fit, split width into vertical strips.
3. If a width strip with one channel still does not fit, fall back to
   `ic_tile_size` accumulation: process the convolution in chunks of
   input channels and let the DPU accumulator combine them.

`PAD_TOP` / `PAD_BOTTOM` / `PAD_LEFT` / `PAD_RIGHT` registers are set
per-tile so interior tiles see zero padding while edge tiles see the
layer's true pad value.

## Expected runtime (order of magnitude)

YOLOv4-416 INT8 = **~60 GOP** total.

ZedBoard PL @ 100 MHz with the P_17 DPU's effective throughput
≈ 32 MAC/cycle (one conv engine, 3x3 stamp) -> peak **3.2 GOPS**.

DMA + DataMover overheads dominate small tiles; estimated effective
throughput on a 3-4 KB BRAM is ~1 GOPS sustained.

* Compute lower bound: 60 GOP / 3.2 GOPS = **~19 s**.
* Realistic: with thousands of tile dispatches and ARM-side glue,
  expect **30 s – 2 min per frame**.

This is far from real-time; the runtime exists to validate end-to-end
correctness vs. the Python golden reference and to feed the per-layer
profiling JSON consumed by `dpu_timing.h` for future HW tuning (DPU
parallelism, double-buffering, IRQ-driven dispatch in P_18+).

## Verification

`activation_ptr[NUM_FPGA_LAYERS - 3 .. - 1]` are the YOLO head outputs.
Compare byte-for-byte against
`vitis-ai/workspace/c_dpu/run_pipeline.exe` (CPU INT8 reference) using
the same input image; mismatches isolate to a single layer via
`prof_log[]`.
