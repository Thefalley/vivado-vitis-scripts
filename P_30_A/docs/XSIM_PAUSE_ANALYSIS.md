# XSIM PAUSE_FOR_WEIGHTS Analysis

## Objective

Determine whether the PAUSE_FOR_WEIGHTS regression (layer 2 wrong results)
is a synthesis/timing issue or a logic/RTL issue, and whether XSIM simulation
can reproduce and diagnose it.

## Verified Facts

### 1. State enum: 38 states (working) vs 39 states (PAUSE)

Working version (2c950ee) has exactly 38 states (positions 0-37).
PAUSE version (759653a) has 39 states (positions 0-38).

PAUSE_FOR_WEIGHTS is inserted at position 31 (after IC_TILE_ADV at 30),
shifting all subsequent states by +1:

| State           | Working pos | PAUSE pos |
|-----------------|:-----------:|:---------:|
| IC_TILE_ADV     |     30      |    30     |
| **PAUSE_FOR_WEIGHTS** | --   |  **31**   |
| MAC_DONE_WAIT   |     31      |    32     |
| MAC_DONE_WAIT2  |     32      |    33     |
| RQ_EMIT         |     33      |    34     |
| RQ_CAPTURE      |     34      |    35     |
| NEXT_PIXEL      |     35      |    36     |
| OC_TILE_ADV     |     36      |    37     |
| DONE_ST         |     37      |    38     |

### 2. Encoding width: NO change (both fit in 6 bits)

- 38 states: ceil(log2(38)) = 6 bits (binary encoding)
- 39 states: ceil(log2(39)) = 6 bits (binary encoding)

Both fit in the same 6-bit binary encoding. No 5-to-6-bit boundary
crossing. The initial hypothesis of 31->32 states causing a bit-width
change was incorrect; the actual count is 38->39.

### 3. No FSM encoding attributes exist

Neither version has `attribute fsm_encoding`, `syn_encoding`, or
`ENUM_ENCODING` on the state signal. Vivado uses its default heuristic
(auto), which typically picks one-hot for FPGAs. With one-hot:
- 38 states = 38 flip-flops
- 39 states = 39 flip-flops
Neither affects functional correctness.

### 4. `dbg_state <= state_t'pos(state)` shifts values

The `state_t'pos(state)` decoder changes for all states after position 30.
For firmware that polls `REG_DBG_CE_STATE` (0x78):
- Working: DONE_ST reports as 37
- PAUSE: DONE_ST reports as 38

The firmware at 759653a checks `ce == 0` (IDLE) to detect conv completion,
not DONE_ST's value, so this shift does not cause a functional bug in the
polling loop.

### 5. IC_TILE_ADV logic is correctly nested (RTL is NOT the bug)

The final PAUSE version (759653a = 5e7ce05) has the cfg_skip_wl check
correctly nested inside the "more IC tiles" branch:

```vhdl
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        -- more IC tiles -> skip_wl check
        if cfg_skip_wl = '1' then
            state <= PAUSE_FOR_WEIGHTS;
        else
            state <= WL_NEXT;
        end if;
    else
        -- all IC tiles done -> MAC_DONE_WAIT (unchanged)
        ...
    end if;
```

For layer 2 (c_in=32, ic_tile_size=32): `(0+32) < 32` is false, so the
else branch fires. Layer 2 NEVER reaches PAUSE_FOR_WEIGHTS. The RTL
transition logic is identical to the working version for this layer.

NOTE: The initial commit (5a18aae) DID have a structural VHDL bug where
`when PAUSE_FOR_WEIGHTS =>` was spliced between the if/else branches of
IC_TILE_ADV. This was fixed in 55b1221 and 5e7ce05. The final compiled
version (759653a) has correct structure.

### 6. WL_STRIDE path is identical in both versions

The w_base_idx_r calculation in WL_STRIDE (the skip_wl path) is
byte-for-byte identical:

```vhdl
when WL_STRIDE =>
    tile_filter_stride <= resize(ic_in_tile_limit * kk_reg, 20);
    if cfg_skip_wl = '1' then
        w_base_idx_r <= resize(oc_tile_base * tile_filter_stride, 20);
        ...
        state <= MAC_PAD_REG;
    else
        state <= WL_EMIT;
    end if;
```

The `tile_filter_stride` used in the w_base_idx_r computation reads the
OLD value (pre-assignment in this delta cycle). This is the same behavior
in both versions -- not a regression source.

### 7. Firmware changes are the primary suspect

The firmware rewrite at 759653a changed the execution model for ALL layers,
not just IC-tiled ones:

**Working firmware (2c950ee):**
- IC tile loop in firmware: for each ic_base, loads weights, input, bias,
  runs conv, then loops
- For non-IC-tiled layers: single iteration, sets REG_C_IN = REG_IC_TILE_SIZE = c_in
- Simple done_latch polling after CMD_START

**PAUSE firmware (759653a):**
- IC tile loop removed from firmware
- Loads ALL c_in channels of input into BRAM at once
- Sets REG_C_IN = L->c_in, REG_IC_TILE_SIZE = ic_tile_size
- For IC-tiled layers: polls for need_weights (bit 12), feeds weight tiles on demand
- For non-IC-tiled layers: falls back to simple wait_done_latch

For layer 2 specifically (c_in=32, ic_tile_size=32, non-IC-tiled):
- Both versions set identical register values
- Both versions load the same amount of data
- Both versions use simple wait_done_latch after CMD_START

**However**, the commit message explicitly states: "firmware rewrite
introduced regression: layer 2 (non-IC-tiled) fails with wrong CRC."
This could be due to:

1. **done_latch ambiguity**: S_LOAD_WEIGHTS now sets done_latch=1 AND
   conditionally pulses ce_weights_loaded. The done_latch being set by
   both weight-load completion and conv completion creates a race if the
   firmware polls done_latch between CMD_LOAD_WEIGHTS and CMD_START.
   But the code does `wait_done_latch` after CMD_LOAD_WEIGHTS (which
   should succeed) and then again after CMD_START. If done_latch is
   not cleared between commands, the second wait_done_latch returns
   immediately with a stale latch. The wrapper clears done_latch on
   CMD_START (line 742: `done_latch <= '0'`), so this should be safe.

2. **Wrapper state machine differences**: The PAUSE version added
   `ce_weights_loaded <= '0'` as a default pulse-clear on every cycle,
   and `ce_weights_loaded <= '0'` in S_LOAD_WEIGHTS. These changes in
   the wrapper process could affect synthesis of the wrapper FSM itself.

## Can XSIM reproduce the regression?

### Answer: UNLIKELY for the RTL-only path, but YES for a comprehensive test

**Why XSIM alone may not reproduce it:**

1. The existing testbenches (e.g., `auto_L2_tb.vhd`) test the conv_engine
   directly, not through the wrapper. They don't exercise the FIFO weight
   load path (skip_wl), the done_latch handshake, or the need_weights
   protocol.

2. The testbench port map is INCOMPLETE for the PAUSE version. It does not
   connect `need_weights` or `weights_loaded`. The PAUSE conv_engine entity
   has these as mandatory ports without defaults, so the TB won't even
   elaborate.

3. Even if the TB were fixed to connect these ports (weights_loaded='0'),
   the conv_engine's internal behavior for non-IC-tiled layers is logically
   identical. XSIM would show PASS for both versions because the RTL logic
   for layer 2's path is unchanged.

**What XSIM WOULD reveal:**

- If you create a wrapper-level TB that tests the full CMD_LOAD_WEIGHTS ->
  CMD_LOAD -> CMD_START -> poll done_latch sequence, XSIM could expose
  done_latch race conditions or state machine interaction bugs in the
  wrapper.

- If you simulate an IC-tiled layer (c_in > ic_tile_size) with the
  PAUSE mechanism, XSIM would verify the PAUSE_FOR_WEIGHTS -> weight_reload
  -> WL_NEXT flow.

### What to test to isolate the cause

1. **Test A: XSIM conv_engine_v4 (PAUSE version) with non-IC-tiled config**
   - Add `need_weights => open, weights_loaded => '0'` to the TB port map
   - Add `cfg_skip_wl => '0'` (BRAM path, no skip)
   - Run auto_L2_tb vectors
   - Expected: PASS (proves RTL logic is correct for this path)

2. **Test B: XSIM conv_engine_v4 (PAUSE version) with skip_wl='1'**
   - Same as Test A but `cfg_skip_wl => '1'`
   - Pre-load wb_ram via ext_wb_* ports before asserting start
   - Expected: PASS (proves skip_wl path is unchanged)

3. **Test C: HW test with WORKING RTL + PAUSE firmware**
   - Build the WORKING conv_engine_v4 (2c950ee) into a bitstream
   - Run the PAUSE firmware (759653a) against it
   - If layer 2 fails: **firmware is the root cause**
   - If layer 2 passes: **RTL change (synthesis effects) is the cause**

4. **Test D: HW test with PAUSE RTL + WORKING firmware**
   - Build the PAUSE conv_engine_v4 (759653a) into a bitstream
   - Run the WORKING firmware (2c950ee) against it
   - If layer 2 passes: confirms the firmware is the issue
   - Note: IC-tiled layers won't work (no PAUSE handling), but non-IC-tiled
     layers should be fine if the RTL is correct

## Conclusions

1. **The RTL change is logically correct.** The PAUSE_FOR_WEIGHTS state is
   unreachable for non-IC-tiled layers. The IC_TILE_ADV nesting is proper.
   There is no combinational path or signal that could affect layer 2
   differently.

2. **FSM encoding changes (38->39 states) do NOT cause functional bugs.**
   Both fit in 6-bit binary. Even with one-hot encoding change, synthesis
   produces functionally equivalent logic. This cannot cause wrong results
   -- only potentially affect timing.

3. **The regression is almost certainly in the firmware**, not the RTL.
   The commit message itself identifies this: "firmware rewrite changed
   BRAM layout and poll logic for ALL layers." While the analysis shows
   that for layer 2 the register values are identical, there may be subtle
   firmware-level issues (e.g., command sequencing, done_latch clear timing,
   DMA ordering) that are not visible from static RTL analysis.

4. **XSIM of the conv_engine alone will NOT reproduce the bug** because
   the conv_engine's internal logic is unchanged for the non-IC-tiled path.
   A wrapper-level XSIM testbench or the cross-test (Test C/D above) is
   needed to isolate firmware vs RTL.

5. **Recommendation**: Do Test C first (working RTL + PAUSE firmware).
   This is the fastest way to confirm/deny that the firmware rewrite is
   the sole cause of the layer 2 regression.
