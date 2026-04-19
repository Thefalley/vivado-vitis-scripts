# IC Tiling Alternatives for conv_engine_v4

## Problem Statement

When a CONV layer's weights exceed 32 KB (wb_ram capacity), the ARM must
split the input channels across multiple `CMD_START` invocations (IC tiling).
The 32 MAC accumulators hold partial sums for ONE pixel at a time. After
conv_engine processes all pixels in a tile, only the *last* pixel's
accumulators survive. If spatial tile > 1x1, IC tile 1 would resume on
pixel (0,0) with the wrong accumulators (those of the last pixel of IC tile 0).

**Current workaround:** Force spatial tile = 1x1 when `ic_tile_size < c_in`.

**Performance impact:** For a layer with h_out=w_out=208, c_out=64, c_in=32,
k=3x3, this means:

- 208 x 208 = 43,264 pixels
- ceil(64 / 32) = 2 OC groups
- ceil(32 / 113) = 1 IC tile (fits, no IC tiling needed)

But for a layer with c_in=128, c_out=256, k=3x3:

- ic_tile_size = 32768 / (32 * 9) = 113 (fits all 128 channels)
- No IC tiling needed

Real worst case -- layer with c_in=512, c_out=256, k=3x3, h_out=w_out=26:

- ic_tile_size = 32768 / (32 * 9) = 113
- n_ic_tiles = ceil(512 / 113) = 5
- n_oc_groups = ceil(256 / 32) = 8
- 1x1 tiles: 26 * 26 * 8 * 5 = 27,040 CMD_STARTs
- Each CMD_START: DMA_W + DMA_IN + START + wait = ~200 us overhead
- Total overhead: ~5.4 seconds just in ARM DMA/polling per layer

With larger spatial tiles (e.g., 4x4):

- ceil(26/4) * ceil(26/4) = 49 spatial tiles
- 49 * 8 * 5 = 1,960 CMD_STARTs (13.8x fewer)

---

## Architecture Reference

Key signals in `conv_engine_v4.vhd` (lines 180-220):

```
FSM states: IDLE -> CALC_* -> OC_TILE_START -> BL_* (bias load)
  -> INIT_ROW -> INIT_PIXEL_* -> BIAS_LOAD -> WL_NEXT -> WL_STRIDE
  -> WL_EMIT/WL_WAIT/WL_CAPTURE (weight load from BRAM, skipped if skip_wl=1)
  -> MAC_PAD_REG -> MAC_WLOAD -> MAC_WLOAD_CAP -> MAC_EMIT -> MAC_WAIT_DDR
  -> MAC_CAPTURE -> MAC_FIRE -> IC_TILE_ADV
  -> MAC_DONE_WAIT -> RQ_EMIT/RQ_CAPTURE -> NEXT_PIXEL -> OC_TILE_ADV -> DONE_ST
```

Key resources:
- **wb_ram:** 32 KB xpm_memory_tdpram (Port A = FSM, Port B = ext FIFO)
- **BRAM (wrapper):** 8 KB (2048 x 32-bit), holds input + bias + output
- **mac_array:** 32 mac_units, each with 32-bit accumulator (acc_r)
- **mac_unit control:** `clear` -> zero, `load_bias` -> load bias_in, `valid_in` -> acc += a*b

The `cfg_no_clear` and `cfg_no_requantize` flags (lines 127-128, 651-653, 707-709,
980-984) are the mechanism enabling ARM IC tiling:
- First IC tile: no_clear=0, no_requantize=1 (clear + accumulate, don't output)
- Middle IC tiles: no_clear=1, no_requantize=1 (keep accumulating)
- Last IC tile: no_clear=1, no_requantize=0 (keep accumulating, then output)

The pixel loop is INIT_ROW -> INIT_PIXEL_1 -> ... -> NEXT_PIXEL (lines 644-1059).
After all pixels, OC_TILE_ADV either advances to next OC tile or goes to DONE_ST.

---

## Approach A: Accumulator Save/Restore via BRAM

### Concept

After IC tile 0 processes all pixels of a spatial tile, save the 32
accumulators (32 x 32-bit = 128 bytes) to a scratch area in the 8 KB BRAM
for each pixel. Before IC tile 1 processes pixel (oh, ow), restore that
pixel's accumulators from BRAM.

This lets spatial tiles be larger than 1x1 because accumulators are
checkpointed per-pixel between IC tiles.

### Memory Cost Analysis

Each pixel needs 128 bytes of accumulator storage (32 MACs x 4 bytes):

| Spatial Tile | Pixels | Acc Storage | Remaining BRAM |
|-------------|--------|-------------|----------------|
| 1x1         | 1      | 128 B       | 7936 B (works trivially, current approach) |
| 2x2         | 4      | 512 B       | 7680 B |
| 4x4         | 16     | 2048 B      | 6144 B |
| 8x8         | 64     | 8192 B      | 0 B (impossible -- no room for input) |
| 4x8         | 32     | 4096 B      | 4096 B |

For 4x4 tiles with k=3x3, stride=1, ic_tile_size=113:
- Input: 113 * 6 * 6 = 4068 bytes
- Bias: 32 * 4 = 128 bytes
- Output: 32 * 4 * 4 = 512 bytes
- Acc storage: 2048 bytes
- Total: 6756 bytes -- fits in 8 KB

For 4x4 tiles with k=3x3, stride=1, ic_tile_size=64 (smaller tile):
- Input: 64 * 6 * 6 = 2304 bytes
- Total: 2304 + 128 + 512 + 2048 = 4992 bytes -- fits easily

### RTL Changes Required

1. **New FSM states** (4-6 states):
   - `ACC_SAVE_INIT`: set up pixel counter and BRAM write address
   - `ACC_SAVE_LOOP`: write mac_acc(i) to BRAM, 4 bytes per accumulator,
     32 accumulators per pixel = 128 writes per pixel (or 32 writes if
     BRAM is 32-bit wide, which it is -- so 32 writes per pixel)
   - `ACC_RESTORE_INIT`: before each pixel in non-first IC tile
   - `ACC_RESTORE_LOOP`: read 32 words from BRAM, load into mac_acc

2. **mac_unit modification**: Need a way to load an arbitrary 32-bit value
   into acc_r. Currently only `clear` (zero) and `load_bias` (from bias_in)
   exist. Would need a new `load_acc` signal + `acc_load_in` port.

3. **BRAM address arbitration**: acc save/restore shares BRAM with input/bias.
   Need a dedicated address region (e.g., top 2 KB of 8 KB BRAM).

4. **Software change**: ARM must configure acc_storage_offset register and
   allocate space in BRAM layout.

### Feasibility: MODERATE

The approach is sound but adds substantial RTL complexity:
- Modifying mac_unit (adding load_acc) changes a verified primitive
- 32 writes per pixel for save, 32 reads for restore
- For 16 pixels: 32*16 = 512 extra BRAM accesses per IC tile boundary
- At ~3 cycles/access = 1536 extra cycles per IC tile transition
- But eliminates 15 of every 16 CMD_STARTs (for 4x4 tiles)

### Performance Estimate

For the worst-case layer (c_in=512, c_out=256, k=3x3, h_out=w_out=26):
- Current (1x1): 27,040 CMD_STARTs, ~5.4 sec overhead
- With 4x4: ceil(26/4)^2 * 8 * 5 = 1,960 CMD_STARTs, ~0.39 sec
- Speedup: ~13.8x on ARM overhead
- RTL overhead: 512 cycles * 5 IC-tile-boundaries * 49 spatial tiles = 125,440
  extra cycles = 1.25 ms at 100 MHz (negligible)

### Risk: HIGH

Adding 4-6 FSM states is exactly what we want to avoid. Modifying mac_unit
adds regression risk. The PAUSE_FOR_WEIGHTS approach (which added a new FSM
state) already caused regressions, and this adds more states plus touches
mac_unit.

**Verdict: Powerful but too risky. Same class of change as PAUSE_FOR_WEIGHTS.**

---

## Approach B: Wider Spatial Tiles with 1xW or Hx1 Geometry

### Concept

Instead of 1x1 tiles, use 1xW tiles (one row, full width). Each tile still
has multiple pixels, but the ARM sends them all in one CMD_START. The
conv_engine processes all pixels sequentially within one invocation.

### Why It Does Not Help

The fundamental constraint is not the tile shape -- it is that the
conv_engine processes ALL pixels in a tile per CMD_START, and at the end,
only the LAST pixel's accumulators remain.

With a 1x26 tile (one full row):
- IC tile 0: conv_engine processes pixels 0..25, accumulators hold pixel 25's partial sums
- IC tile 1: conv_engine processes pixels 0..25 again, but starts pixel 0
  with pixel 25's leftover accumulators (wrong)

This is exactly the same problem as with any spatial tile > 1x1. The
conv_engine does not have per-pixel accumulator storage -- it has one set
of 32 accumulators shared across all pixels in sequence.

The only geometry that works is 1x1: one pixel per tile, so the
accumulators trivially correspond to that single pixel.

### Feasibility: DOES NOT WORK

The approach fundamentally misunderstands the constraint. No RTL or SW
change can make this work without per-pixel accumulator persistence
(which is Approach A).

**Verdict: Invalid. Rejected.**

---

## Approach C: Load ALL IC Tiles' Weights into wb_ram at Once

### Concept

If total weights fit in 32 KB, load them all. For layers where they don't
fit, this approach has nothing to offer.

### Analysis

This is the existing behavior for non-IC-tiled layers. The wb_ram is
already 32 KB. Layers that need IC tiling have weights > 32 KB by
definition:

- Layer with c_out=256, c_in=512, k=3x3: 256 * 512 * 9 = 1,179,648 bytes
- Even one OC group: 32 * 512 * 9 = 147,456 bytes >> 32 KB

Increasing wb_ram size would help but has severe BRAM cost:
- 64 KB wb_ram = 16 BRAM36 (XC7Z020 has 140 total, currently using ~80+)
- 128 KB wb_ram = 32 BRAM36 (would exhaust remaining BRAMs)
- Still wouldn't fit the 147 KB example above

### Feasibility: NOT APPLICABLE

For layers that need IC tiling, this is not a solution. The weights
simply do not fit regardless of reasonable wb_ram sizing.

**Verdict: N/A. Already implemented for layers where it works.**

---

## Approach D: Software-Only CONV on ARM

### Concept

Skip the DPU entirely for IC-tiled layers. Compute the convolution on the
ARM Cortex-A9 in software.

### Performance Estimate

ARM Cortex-A9 at 667 MHz, single-issue, no NEON for int8:
- One MAC = ~3 cycles (load + multiply + accumulate)
- Layer c_out=256, c_in=512, k=3, h_out=w_out=26:
  MACs = 256 * 512 * 9 * 26 * 26 = 797,966,336
- At 3 cycles/MAC: 2.39 billion cycles = 3.58 seconds
- With NEON int16 (4-wide): ~0.9 seconds
- DPU at 100 MHz with 32 MACs: ~797M / 32 = 24.9M cycles = 0.25 seconds
  (but with 1x1 tiling overhead: ~5.4 sec total)

So the DPU with 1x1 tiling is actually SLOWER than pure ARM for this layer,
due to the DMA/CMD_START overhead dominating compute.

### Feasibility: WORKS BUT DEFEATS PURPOSE

No RTL changes needed. Software-only. But running convolutions on ARM
defeats the purpose of having a DPU accelerator. Performance would be
marginally better than current 1x1 tiling for large layers (ARM compute
avoids DMA overhead), but much worse than a properly-tiled DPU approach.

A hybrid approach (ARM for IC-tiled layers, DPU for non-IC-tiled) is
viable as a fallback but not a long-term solution.

**Verdict: Last resort fallback only.**

---

## Approach E: Minimal RTL Change -- Poll weights_ready in IC_TILE_ADV

### Concept

Instead of adding a new FSM state (which caused PAUSE_FOR_WEIGHTS
regressions), reuse the existing `IC_TILE_ADV` state to poll a
"weights_ready" bit. The FSM stays in `IC_TILE_ADV` until the ARM
signals that new weights are loaded, then transitions to `WL_NEXT`
as before.

### How This Helps

This approach does not solve the accumulator-persistence problem.
It addresses a different bottleneck: reducing ARM<->DPU round-trip
latency by having the conv_engine wait internally for the next IC
tile's weights, rather than returning DONE and requiring a new
CMD_START.

But wait -- the core problem is still that accumulators are overwritten
between pixels. Even if the conv_engine polls for weights_ready, it still
processes all pixels per invocation. The accumulator problem remains.

### Revised Concept: SINGLE CMD_START for All IC Tiles

What if we restructure the flow so that ONE CMD_START processes ALL IC tiles
for all pixels? The conv_engine would:

1. Process all pixels for IC tile 0
2. At IC_TILE_ADV: detect more IC tiles needed
3. Instead of going to DONE_ST: go back to pixel loop start (oh=0, ow=0)
   with no_clear=1 internally
4. But first: wait for ARM to load next IC tile's weights into wb_ram

The problem: step 3 would process pixel (0,0) with the accumulators left
from the LAST pixel of IC tile 0. Same fundamental issue.

### Revised Revised Concept: Per-Pixel IC Tile Loop Inside the FSM

What if the pixel loop nests the IC tile loop INSIDE each pixel?

```
for each pixel (oh, ow):
  clear MACs, load bias
  for each ic_tile:
    [wait for weights to be loaded by ARM]
    load weights from wb_ram
    MAC loop over (kh, kw, ic)
  requantize, write output
```

This is exactly how the conv_engine ALREADY works when the weights for
all IC tiles fit in wb_ram (the internal ic_tile loop at IC_TILE_ADV,
line 967). The problem is that when weights DON'T all fit, the ARM must
reload wb_ram between IC tiles, and the conv_engine can't wait for that
mid-pixel.

The `weights_ready` polling in IC_TILE_ADV would enable this:

1. Pixel starts, MACs cleared, bias loaded
2. IC tile 0 weights already in wb_ram, MAC loop runs
3. At IC_TILE_ADV: more IC tiles remain
4. ARM is notified (via interrupt or status register) that IC tile 0
   is done for this pixel
5. ARM loads IC tile 1 weights into wb_ram via DMA_W
6. ARM sets weights_ready register
7. Conv_engine sees weights_ready, goes to WL_NEXT/WL_STRIDE -> MAC loop
8. Repeat for all IC tiles
9. After last IC tile: requantize, write output
10. NEXT_PIXEL, repeat

**This works!** The accumulators persist because we never leave the pixel.
The IC_TILE_ADV state already handles the "more IC tiles" case -- we just
add a wait for weights_ready before going to WL_NEXT.

### Critical Detail: Weights Must Be for Current (oc_tile, ic_tile)

When skip_wl=1, the ARM pre-loads weights into wb_ram via FIFO. Currently
the ARM loads ALL weights for one IC tile (all 32 OC channels) before
CMD_START. With the polling approach, the ARM loads weights for (current_oc_tile,
next_ic_tile) while the conv_engine processes (current_oc_tile, current_ic_tile).

Since wb_ram is dual-ported (Port A = FSM read, Port B = ext FIFO write),
the ARM could write next IC tile's weights to a DIFFERENT region of wb_ram
while the FSM reads current weights from the current region. Double-buffering!

But wb_ram is 32 KB total. One OC group's IC tile weights = 32 * ic_ts * kk.
For ic_ts=113, kk=9: 32*113*9 = 32,544 bytes. That's nearly all of wb_ram.
Double-buffering would need 64 KB. Not feasible.

**So double-buffering is out.** The ARM must wait for the conv_engine to
finish reading current weights before writing new ones. The polling
approach becomes:

1. Conv_engine finishes MAC loop for current IC tile
2. Conv_engine enters IC_TILE_ADV, checks: more IC tiles? Yes
3. Conv_engine asserts `ic_tile_done` status signal
4. Conv_engine polls `weights_ready` register (stays in IC_TILE_ADV)
5. ARM sees `ic_tile_done`, loads next IC tile weights via DMA_W
6. ARM sets `weights_ready`
7. Conv_engine sees it, transitions to WL_STRIDE -> MAC loop
8. ARM clears `weights_ready` (or conv_engine auto-clears on transition)

### RTL Changes Required

Minimal -- all within the existing `IC_TILE_ADV` state:

```vhdl
-- In IC_TILE_ADV (line 967-985):
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        -- More IC tiles for this pixel
        if cfg_skip_wl = '1' and cfg_weights_ready = '0' then
            -- Wait for ARM to load next IC tile weights
            -- Stay in IC_TILE_ADV (poll)
            null;
        else
            ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
            act_tile_base <= act_tile_base
                           + resize(cfg_ic_tile_size * hw_reg, 25);
            state <= WL_NEXT;
        end if;
    else
        -- All IC tiles done for this pixel
        rq_ch <= (others => '0');
        if cfg_no_requantize = '1' then
            state <= DONE_ST;
        else
            state <= MAC_DONE_WAIT;
        end if;
    end if;
```

New signals/ports:
- `cfg_weights_ready : in std_logic` -- set by ARM via AXI-Lite register
- `ic_tile_done : out std_logic` -- asserted when in IC_TILE_ADV with more tiles

Wrapper changes:
- New register `REG_WEIGHTS_READY` (1 bit, W) at e.g. 0x7C
- New status bit `ic_tile_done` readable by ARM (e.g., bit 12 of REG_CTRL)
- Or use an interrupt instead of polling

Software changes in `dpu_exec_v4.c`:
- Remove the per-pixel spatial loop for IC tiling
- Use spatial tiles > 1x1 (same tile-sizing as non-IC-tiled layers)
- ONE CMD_START per (spatial_tile, oc_group)
- Inside: ARM monitors ic_tile_done, loads next weights, sets weights_ready

### No New FSM State

The key advantage: IC_TILE_ADV already exists. We add a conditional wait
(polling a register) inside the existing state. The state_t enumeration
does not change. The FSM encoding is identical. No new state transitions
are added to the graph.

### Feasibility: HIGH

- 5-10 lines of VHDL change in conv_engine_v4
- 1 new input port (cfg_weights_ready)
- 1 new output signal (ic_tile_done, or reuse dbg_state comparison)
- Wrapper: 1 new register + wiring
- Software: restructure the IC tile loop to be synchronous with conv_engine

### Performance Estimate

For the worst-case layer (c_in=512, c_out=256, k=3x3, h_out=w_out=26):

With 4x4 spatial tiles (same as non-IC-tiled):
- 49 spatial tiles * 8 OC groups = 392 CMD_STARTs (not 27,040)
- Within each CMD_START: 5 IC tiles, each requiring:
  - ARM loads weights via DMA_W: ~100 us
  - Conv_engine processes 16 pixels: ~16 * (32 * 9 * 113 * 7 cycles) = ~36M cycles = 360 ms
  - Total per CMD_START: 5 * 100 us + 5 * 360 ms / 49 / 8 = negligible DMA overhead
- Actually, conv_engine dominates. DMA overhead drops from 27,040 * 200 us = 5.4 sec
  to 392 * 200 us = 78 ms for the CMD_START overhead, plus 392 * 4 * 100 us = 157 ms
  for mid-tile weight reloads
- **Total overhead: ~235 ms vs ~5.4 sec = ~23x speedup on overhead**
- Compute time stays the same (same number of MACs)

### Risk Assessment

**Low risk** because:
1. No new FSM states (state_t enum unchanged, encoding unchanged)
2. When cfg_skip_wl='0' (legacy path), the new condition is never entered
   (cfg_skip_wl='0' means old BRAM-preload path, weights_ready is irrelevant)
3. When cfg_weights_ready='1' at entry (ARM pre-set it), behavior is
   identical to current flow (no stall)
4. Only adds a wait condition in one existing state
5. mac_unit is NOT modified
6. Bias load path (cfg_no_clear gating mac_lb) is NOT modified

**One concern:** ARM must reliably detect ic_tile_done and respond quickly.
If ARM is slow to respond, the conv_engine stalls in IC_TILE_ADV. This
adds latency but not incorrectness. Worst case: same total time as 1x1
tiling (ARM is so slow that the overhead equals current approach).

### Software Flow (Detailed)

```c
// SINGLE CMD_START for all IC tiles of this (spatial_tile, oc_group)
dpu_write(REG_NO_CLEAR, 0);        // first IC tile clears
dpu_write(REG_NO_REQUANTIZE, 0);   // requantize after last IC tile
dpu_write(REG_WEIGHTS_READY, 0);   // conv_engine will poll this

// Load first IC tile weights
load_weights_via_fifo(oc_grp, ic_base=0);
dpu_write(REG_WEIGHTS_READY, 1);   // first tile ready

// Load input for ALL channels (not just ic_tile)
// ... or load per-IC-tile input (BRAM may not fit all)
// NOTE: input must be reloaded per IC tile too -- see below

dpu_write(REG_CTRL, CMD_START);

// Monitor and feed IC tiles
for (int ic_base = ic_tile_size; ic_base < c_in; ic_base += ic_tile_size) {
    // Wait for conv_engine to signal ic_tile_done
    while (!(dpu_read(REG_CTRL) & IC_TILE_DONE_BIT))
        ;
    // Load next IC tile weights
    dpu_write(REG_WEIGHTS_READY, 0);
    load_weights_via_fifo(oc_grp, ic_base);
    dpu_write(REG_WEIGHTS_READY, 1);
}

// Wait for final done
wait_done_latch();
```

### CRITICAL ISSUE: Input Data

The conv_engine reads input activations from BRAM (`ddr_rd_addr` in the
wrapper maps to the 8 KB BRAM). For IC tiling, each IC tile needs DIFFERENT
input channels. The BRAM only holds `ic_tile_size` channels' worth of
input data.

When the conv_engine loops back for IC tile 1, it needs input channels
[113..225], but BRAM still holds channels [0..112]. The ARM would need to
reload the BRAM with new input data.

But the conv_engine is NOT in DONE state -- it's in IC_TILE_ADV, waiting
for weights_ready. The wrapper FSM is in S_CONV state, not S_LOAD. The
ARM cannot load new data into BRAM while the wrapper is in S_CONV.

**This is a showstopper for Approach E as described.**

### Resolution: Preload ALL Input Channels

If we load ALL input channels into BRAM at once (not just ic_tile_size
channels), the conv_engine can access any channel during any IC tile.

BRAM capacity check for 4x4 tile, k=3, stride=1, c_in=512:
- Input: 512 * 6 * 6 = 18,432 bytes >> 8 KB BRAM

**Does not fit.** Even with 1x1 tiles:
- Input: 512 * 3 * 3 = 4,608 bytes + bias 128 + output 32 = 4,768 bytes
- Fits in 8 KB, but only 1x1 tile. Back to square one.

For 2x2 tiles:
- Input: 512 * 4 * 4 = 8,192 bytes = exactly 8 KB
- No room for bias or output. Does not fit.

### Resolution 2: Increase BRAM

If the wrapper BRAM is increased from 8 KB to 16 KB (cost: 2 more BRAM36):
- 1x1 tile: 512 * 3 * 3 + 128 + 32 = 4,768 bytes (fits, plenty of room)
- 2x2 tile: 512 * 4 * 4 + 128 + 128 = 8,448 bytes (fits in 16 KB)
- 3x3 tile: 512 * 5 * 5 + 128 + 288 = 13,216 bytes (fits in 16 KB)
- 4x4 tile: 512 * 6 * 6 + 128 + 512 = 19,072 bytes (does NOT fit in 16 KB)

So 16 KB BRAM enables 3x3 spatial tiles with c_in=512. Not 4x4, but still
a 9x improvement over 1x1.

For c_in=256 (more common large layers):
- 4x4: 256 * 6 * 6 + 128 + 512 = 9,856 bytes (fits in 16 KB)
- 5x5: 256 * 7 * 7 + 128 + 800 = 13,472 bytes (fits in 16 KB)

### Resolution 3: Load Only Current IC Tile's Input, Add BRAM Reload

The conv_engine could signal "I need input for IC tile N" and the wrapper
could reload BRAM from DDR/DMA during the IC_TILE_ADV wait. This requires:

1. The wrapper FSM to support a S_RELOAD_INPUT state (mid-conv BRAM reload)
2. The conv_engine to request it and wait
3. The ARM to initiate the DMA

This adds significant complexity to the wrapper FSM (a new state in the
wrapper, even if not in the conv_engine).

---

## Recommended Approach: E-Modified (Polling + All Input Preloaded)

### Summary

Combine Approach E (poll weights_ready in IC_TILE_ADV, no new FSM states
in conv_engine) with preloading ALL input channels into BRAM. Accept the
constraint that spatial tile size is limited by BRAM holding all c_in
channels.

### Spatial Tile Size with 8 KB BRAM

For k=3x3, stride=1, preloading all c_in channels:

| c_in | Max tile | Input bytes | + bias + output | Total |
|------|----------|-------------|-----------------|-------|
| 64   | 6x6     | 64*8*8=4096 | 128+1152=1280   | 5376  |
| 128  | 4x4     | 128*6*6=4608| 128+512=640     | 5248  |
| 256  | 2x2     | 256*4*4=4096| 128+128=256     | 4480  |
| 512  | 1x1     | 512*3*3=4608| 128+32=160      | 4896  |

c_in=512 is stuck at 1x1 even with all channels preloaded. No improvement.

### Spatial Tile Size with 16 KB BRAM (+2 BRAM36)

| c_in | Max tile | Input bytes   | + bias + output | Total  |
|------|----------|---------------|-----------------|--------|
| 64   | 10x10   | 64*12*12=9216 | 128+3200=3328   | 12544  |
| 128  | 7x7     | 128*9*9=10368 | 128+1568=1696   | 12192  |
| 256  | 4x4     | 256*6*6=9216  | 128+512=640     | 9984   |
| 512  | 3x3     | 512*5*5=12800 | 128+288=416     | 13344  |

**16 KB BRAM is the sweet spot.** Even c_in=512 gets 3x3 tiles (9x
improvement over 1x1). Cost: 2 extra BRAM36 (from ~80 to ~82 of 140).

### Final Recommended Implementation

1. **Increase wrapper BRAM from 8 KB to 16 KB** (+2 BRAM36, trivial)
2. **Add `cfg_weights_ready` input to conv_engine_v4** (~3 lines VHDL)
3. **Modify IC_TILE_ADV to poll weights_ready** (~8 lines VHDL)
4. **Add `ic_tile_done` output** (1 line VHDL + wrapper wiring)
5. **Add REG_WEIGHTS_READY register in wrapper** (~10 lines VHDL)
6. **Software: preload ALL c_in channels' input in BRAM, single CMD_START
   per (spatial_tile, oc_group), ARM feeds weights between IC tiles**
   (~50 lines C restructuring)

Total RTL change: ~25 lines in conv_engine_v4, ~15 lines in wrapper.
No new FSM states in conv_engine. One new register in wrapper.

### Performance Summary

| Layer (c_in) | Current 1x1 CMD_STARTs | Proposed CMD_STARTs | Speedup (overhead) |
|-------------|----------------------|--------------------|--------------------|
| c_in=128    | H*W * oc_grps * 2    | ceil(H/4)*ceil(W/4) * oc_grps | ~16x |
| c_in=256    | H*W * oc_grps * 3    | ceil(H/4)*ceil(W/4) * oc_grps | ~16x |
| c_in=512    | H*W * oc_grps * 5    | ceil(H/3)*ceil(W/3) * oc_grps | ~9x |

### Risk: LOW

- No new FSM states in conv_engine (zero encoding risk)
- Legacy path (skip_wl=0) completely unaffected
- mac_unit completely unaffected
- Bias load path completely unaffected
- Only behavioral change: IC_TILE_ADV can stall (wait), which is safe
  because the FSM already holds all state needed to continue

### Alternative If 16 KB BRAM Is Not Available

Stay with 8 KB BRAM. Approach E still helps for c_in <= 256 (4x4 or 2x2
tiles). For c_in=512, fall back to 1x1 tiling. This is a partial
improvement but still significant: most YOLOv4 layers with IC tiling have
c_in <= 256.

---

## Comparison Matrix

| Approach | Works? | New FSM States | BRAM Cost | Speedup | Risk | Recommendation |
|----------|--------|---------------|-----------|---------|------|----------------|
| A: Acc save/restore | Yes | 4-6 states + mac_unit mod | +2KB per pixel set | 13x | HIGH | Reject (too invasive) |
| B: 1xW tiles | No | N/A | N/A | N/A | N/A | Invalid |
| C: Bigger wb_ram | No | 0 | +16-32 BRAM36 | N/A | LOW | N/A (doesn't solve) |
| D: ARM compute | Yes | 0 | 0 | ~1x (saves DMA overhead) | NONE | Last resort |
| E: Poll in IC_TILE_ADV | Yes* | 0 | +2 BRAM36 (16KB wrapper) | 9-16x | LOW | **RECOMMENDED** |

*Requires preloading all input channels, which limits tile size by BRAM
capacity. With 16 KB BRAM, achieves 3x3 to 7x7 tiles depending on c_in.
