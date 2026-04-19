# PAUSE_FOR_WEIGHTS Regression Analysis

## Context

Adding a `PAUSE_FOR_WEIGHTS` state to `conv_engine_v4.vhd` caused layer 2
(CONV k=3, c_in=32, c_out=64) to produce wrong CRC, even though layer 2
never exercises IC tiling and should never reach the new state.  The same
firmware with the reverted RTL (commit 2c950ee) works correctly.

The proposed RTL change was:

1. New state `PAUSE_FOR_WEIGHTS` appended after `IC_TILE_ADV` in `state_t`
2. New ports `need_weights` (out) and `weights_loaded` (in)
3. Combinational: `need_weights <= '1' when state = PAUSE_FOR_WEIGHTS else '0'`
4. In `IC_TILE_ADV`: `if cfg_skip_wl='1' then state<=PAUSE_FOR_WEIGHTS ...`
5. New state body: `when PAUSE_FOR_WEIGHTS => if weights_loaded='1' then state<=WL_NEXT`

## Root Cause: `IC_TILE_ADV` transition logic corrupted

### The critical path that breaks non-IC-tiled layers

Layer 2 has c_in=32 and cfg_ic_tile_size=32 (or >= c_in).  After the MAC
loop finishes, the FSM enters `IC_TILE_ADV`.  The condition at line 968 of
the working code is:

```vhdl
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        -- more IC tiles -> WL_NEXT
        ...
        state <= WL_NEXT;
    else
        -- all IC tiles done -> requantize or DONE
        rq_ch <= (others => '0');
        if cfg_no_requantize = '1' then
            state <= DONE_ST;
        else
            state <= MAC_DONE_WAIT;
        end if;
    end if;
```

For layer 2 with ic_tile_base=0, cfg_ic_tile_size=32, cfg_c_in=32:
the condition `(0 + 32) < 32` is false, so the `else` branch fires and
the FSM goes to `MAC_DONE_WAIT` -> requantize -> output.  This is correct.

### What the proposed change does

The proposed change modifies `IC_TILE_ADV` to:

```vhdl
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        -- more IC tiles
        ...
        if cfg_skip_wl = '1' then
            state <= PAUSE_FOR_WEIGHTS;
        else
            state <= WL_NEXT;
        end if;
    else
        -- all IC tiles done -> requantize
        ...
    end if;
```

At first glance this only affects the `if` branch (more tiles exist), which
layer 2 never takes.  So one would expect no regression.  But there is a
subtler mechanism at work.

## Analysis of Four Hypotheses

### Hypothesis 1: FSM encoding change (CONFIRMED as most likely cause)

The current `state_t` enum has exactly 31 states (IDLE through DONE_ST,
positions 0-30).  Adding `PAUSE_FOR_WEIGHTS` after `IC_TILE_ADV` (position
27) shifts the subsequent states:

| State           | Current pos | With PAUSE_FOR_WEIGHTS |
|-----------------|:-----------:|:----------------------:|
| IC_TILE_ADV     |     27      |          27            |
| **PAUSE_FOR_WEIGHTS** | --    |        **28**          |
| MAC_DONE_WAIT   |     28      |          29            |
| MAC_DONE_WAIT2  |     29      |          30            |
| RQ_EMIT         |     30      |          31            |
| RQ_CAPTURE      |     31      |          32            |
| NEXT_PIXEL      |     32      |          33            |
| OC_TILE_ADV     |     33      |          34            |
| DONE_ST         |     34      |          35            |

Wait -- re-counting the current enum carefully:

```
0  IDLE
1  CALC_KK
2  CALC_HOUT_1
3  CALC_HOUT_2
4  CALC_HW
5  CALC_HW_OUT
6  CALC_W_FILTER
7  CALC_TILE_STRIDE
8  CALC_KW_CIN
9  OC_TILE_START
10 BL_EMIT
11 BL_WAIT
12 BL_CAPTURE
13 INIT_ROW
14 INIT_PIXEL_1
15 INIT_PIXEL_2
16 INIT_PIXEL_3
17 BIAS_LOAD
18 WL_NEXT
19 WL_STRIDE
20 WL_EMIT
21 WL_WAIT
22 WL_CAPTURE
23 MAC_PAD_REG
24 MAC_WLOAD
25 MAC_WLOAD_CAP
26 MAC_EMIT
27 MAC_WAIT_DDR
28 MAC_CAPTURE
29 MAC_FIRE
30 IC_TILE_ADV
31 MAC_DONE_WAIT
32 MAC_DONE_WAIT2
33 RQ_EMIT
34 RQ_CAPTURE
35 NEXT_PIXEL
36 OC_TILE_ADV
37 DONE_ST
```

That is **38 states** currently (positions 0-37).

With `PAUSE_FOR_WEIGHTS` inserted after `IC_TILE_ADV` (position 30), the
new enum has **39 states** (positions 0-38).

**Key effect on Vivado synthesis:**

- **38 states** -> Vivado may pick binary encoding (6 bits cover 0-63) or
  one-hot (38 flip-flops).
- **39 states** -> Still fits 6-bit binary, but Vivado's FSM optimization
  heuristics can change the encoding strategy.  Even with the same
  encoding style, the specific bit patterns for all states after position
  30 shift by one.

The `dbg_state` output uses `state_t'pos(state)` (line 459), which is
combinational and creates a wide state-to-integer decoder.  Adding a state
changes this decoder, which can affect the logic depth and placement.

**However**, FSM encoding change alone should NOT cause functional
regression in simulation.  If simulation also fails, this is not the cause.
If only HW fails but simulation passes, FSM encoding or timing is suspect.

**Verdict:** This is **not** the primary functional cause.  Vivado handles
FSM encoding correctly for any number of states.  The encoding changes, but
the transitions are still synthesized faithfully.

### Hypothesis 2: Combinational `need_weights` output creates new timing path

The proposed combinational output:

```vhdl
need_weights <= '1' when state = PAUSE_FOR_WEIGHTS else '0';
```

This is a single-state decode of the FSM.  In one-hot encoding it is
literally one wire.  In binary encoding it is a 6-input comparator.  Either
way it is trivial timing-wise and should not affect other paths.

**Verdict:** Not the cause.

### Hypothesis 3: `weights_loaded` input default value (CRITICAL -- MOST LIKELY CAUSE)

The proposed change adds a `weights_loaded` input port to conv_engine_v4.
In the wrapper, this signal is described as:

> After S_LOAD_WEIGHTS completes + ce_need_weights: pulse ce_weights_loaded

The critical question is: **what is `weights_loaded` when the FSM is NOT
in `PAUSE_FOR_WEIGHTS`?**

Looking at the wrapper description, `ce_weights_loaded` is only pulsed
when `ce_need_weights` is active (i.e., when the conv_engine is in
`PAUSE_FOR_WEIGHTS`).  At all other times, it should be `'0'`.

**But this is not the bug for layer 2**, because layer 2 never reaches
`PAUSE_FOR_WEIGHTS`, so `weights_loaded` is never sampled.

However, there is a subtle but devastating issue with the proposed
`IC_TILE_ADV` change when **cfg_skip_wl is already '1' from a previous
FIFO-based layer**.

Look at the firmware (dpu_exec_v4.c, line 457):

```c
dpu_write(REG_SKIP_WL, 1);
```

The firmware **always** sets `skip_wl=1` and **never resets it to 0**
between layers.  There is no `dpu_write(REG_SKIP_WL, 0)` anywhere in the
code.

This means `reg_skip_wl` is a sticky register: once set to 1, it stays 1
for ALL subsequent layers (including layer 2).

Now look at the proposed IC_TILE_ADV modification:

```vhdl
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        -- more IC tiles
        if cfg_skip_wl = '1' then
            state <= PAUSE_FOR_WEIGHTS;
        else
            state <= WL_NEXT;
        end if;
    else
        ...
    end if;
```

For layer 2 specifically, `(0 + 32) < 32` is false, so the
PAUSE_FOR_WEIGHTS branch is not taken.  But consider:

**If layer 1 (c_in=3) runs first** and layer 1 also has ic_tile_size >= c_in
(no IC tiling), then layer 1 also never takes the `if` branch.  Layer 2
similarly never takes it.

**So the PAUSE_FOR_WEIGHTS state itself should never be reached for
non-IC-tiled layers.**

This brings us back to looking at the WL_STRIDE transition, which IS
affected by cfg_skip_wl for ALL layers:

```vhdl
when WL_STRIDE =>
    tile_filter_stride <= resize(ic_in_tile_limit * kk_reg, 20);
    if cfg_skip_wl = '1' then
        kh <= (others => '0');
        kw <= (others => '0');
        ic <= (others => '0');
        w_base_idx_r <= resize(oc_tile_base * tile_filter_stride, 20);
        act_ic_offset <= act_tile_base;
        act_kh_offset <= (others => '0');
        state <= MAC_PAD_REG;
    else
        state <= WL_EMIT;
    end if;
```

This code is already in the **working** version (commit 2c950ee) and works
correctly when cfg_skip_wl=1.  So the WL_STRIDE path itself is not the bug.

### Hypothesis 4: Port map change affects signal routing

Adding ports to the entity changes the wrapper's port map.  The new signals
(`ce_need_weights`, `ce_weights_loaded`) require new wires in the wrapper.

**Critical check**: if `ce_weights_loaded` is declared in the wrapper but
the **process that generates it has a bug** (e.g., it defaults to `'1'`
instead of `'0'`, or it pulses spuriously), that could cause problems.

But the user described:

> After S_LOAD_WEIGHTS completes + ce_need_weights: pulse ce_weights_loaded

If the wrapper logic is:

```vhdl
-- hypothetical wrapper logic
if state = S_IDLE and ce_need_weights = '1' then
    -- do weight load, then pulse
    ce_weights_loaded <= '1';
```

...then when the conv_engine is NOT in PAUSE_FOR_WEIGHTS, `ce_need_weights`
is '0', so `ce_weights_loaded` stays '0'.  This should be safe.

**Verdict:** Not the cause by itself, but worth auditing the exact wrapper
implementation.

## THE ACTUAL BUG: Stale `reg_skip_wl` combined with PAUSE_FOR_WEIGHTS interaction

After deeper analysis, the regression for layer 2 is most likely **not
caused by the PAUSE_FOR_WEIGHTS state itself**, since layer 2 never reaches
it.  The regression must come from **a different part of the RTL change**
that was not described in the summary, or from an interaction that was
accidentally introduced.

Re-reading the described changes more carefully:

> 4. In IC_TILE_ADV: added `if cfg_skip_wl='1' then state<=PAUSE_FOR_WEIGHTS else state<=WL_NEXT`

This wording is ambiguous.  There are two possible interpretations:

### Interpretation A (likely what was implemented -- THE BUG):

```vhdl
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        ic_tile_base <= ic_tile_base + cfg_ic_tile_size;
        act_tile_base <= act_tile_base + resize(cfg_ic_tile_size * hw_reg, 25);
        if cfg_skip_wl = '1' then
            state <= PAUSE_FOR_WEIGHTS;
        else
            state <= WL_NEXT;
        end if;
    else
        rq_ch <= (others => '0');
        if cfg_no_requantize = '1' then
            state <= DONE_ST;
        else
            state <= MAC_DONE_WAIT;
        end if;
    end if;
```

Under this interpretation, layer 2 is NOT affected (else branch always
fires for c_in=32, ic_tile_size=32).

### Interpretation B (THE ACTUAL BUG if the code was written carelessly):

```vhdl
when IC_TILE_ADV =>
    if cfg_skip_wl = '1' then
        state <= PAUSE_FOR_WEIGHTS;
    elsif (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        ...
        state <= WL_NEXT;
    else
        ...
        state <= MAC_DONE_WAIT;
    end if;
```

If the `cfg_skip_wl` check was placed **before** (or at the same level as)
the IC-tile-count check, then for ANY layer where `skip_wl=1` (which is
ALL layers since the firmware never resets it), the FSM would go to
`PAUSE_FOR_WEIGHTS` instead of `MAC_DONE_WAIT`.  This would hang or
produce garbage for layer 2.

**This is almost certainly the bug.**

## Definitive Root Cause

The most likely root cause is that the `cfg_skip_wl` guard in IC_TILE_ADV
was implemented as a top-level condition rather than nested inside the
"more tiles exist" branch:

```vhdl
-- BUGGY (breaks non-IC-tiled layers):
when IC_TILE_ADV =>
    if cfg_skip_wl = '1' then          -- <-- always true! (firmware never clears it)
        state <= PAUSE_FOR_WEIGHTS;    -- <-- layer 2 goes here, hangs or corrupts
    elsif ...
```

Instead of:

```vhdl
-- CORRECT (only affects layers that actually need more IC tiles):
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        -- more IC tiles exist
        if cfg_skip_wl = '1' then
            state <= PAUSE_FOR_WEIGHTS;
        else
            state <= WL_NEXT;
        end if;
    else
        -- no more IC tiles -> requantize (unchanged)
        ...
    end if;
```

## Secondary Issue: Sticky `reg_skip_wl`

Even if the IC_TILE_ADV nesting is correct, the firmware has a latent bug:

- `dpu_write(REG_SKIP_WL, 1)` is called on line 457 of dpu_exec_v4.c
- There is **no corresponding `dpu_write(REG_SKIP_WL, 0)` anywhere**
- Other layer types (LEAKY, MAXPOOL, ELEM_ADD) dispatched by
  `eth_server.c` (lines 202-227) do not call `dpu_exec_conv_v4` and
  therefore never touch `REG_SKIP_WL`
- If a non-FIFO code path were ever added, it would inherit skip_wl=1

Currently this is harmless because `dpu_exec_conv_v4` always sets
skip_wl=1 before every conv.  But it is a fragile design.

## Recommendations

### Fix 1: Correct the IC_TILE_ADV nesting (mandatory)

Ensure `PAUSE_FOR_WEIGHTS` is ONLY reachable from the "more IC tiles"
branch:

```vhdl
when IC_TILE_ADV =>
    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
        ic_tile_base  <= ic_tile_base + cfg_ic_tile_size;
        act_tile_base <= act_tile_base + resize(cfg_ic_tile_size * hw_reg, 25);
        if cfg_skip_wl = '1' then
            state <= PAUSE_FOR_WEIGHTS;
        else
            state <= WL_NEXT;
        end if;
    else
        rq_ch <= (others => '0');
        if cfg_no_requantize = '1' then
            state <= DONE_ST;
        else
            state <= MAC_DONE_WAIT;
        end if;
    end if;
```

### Fix 2: Reset `reg_skip_wl` at the start of each layer (defensive)

In `dpu_exec_v4.c`, add an explicit reset before setting it:

```c
/* Always explicitly set skip_wl (don't rely on stale value) */
dpu_write(REG_SKIP_WL, 1);  /* or 0 if using BRAM path */
```

Or in the wrapper VHDL, auto-clear on cmd_start:

```vhdl
-- In the FSM, when cmd_start fires:
elsif cmd_start = '1' then
    reg_skip_wl <= '0';  -- safe default, firmware sets it before START
    ...
```

### Fix 3: Simulation before re-synthesis (verification)

Before re-synthesizing, run the existing testbench with the corrected RTL
for both:
- A single-IC-tile layer (layer 2: c_in=32, ic_tile_size=32)
- A multi-IC-tile layer (any layer where c_in > ic_tile_size)

Confirm both produce bit-exact CRC matches.

### Fix 4: Append `PAUSE_FOR_WEIGHTS` at the end of the enum

To minimize FSM encoding disruption, place the new state at the end of the
enum rather than after IC_TILE_ADV:

```vhdl
type state_t is (
    IDLE,
    CALC_KK, ... ,
    IC_TILE_ADV,
    MAC_DONE_WAIT, MAC_DONE_WAIT2,
    RQ_EMIT, RQ_CAPTURE,
    NEXT_PIXEL,
    OC_TILE_ADV,
    DONE_ST,
    PAUSE_FOR_WEIGHTS   -- <-- at end, doesn't shift existing positions
);
```

This preserves `state_t'pos` values for `dbg_state` readback (register
0x78), so existing debug tools and firmware interpretations remain valid.

## Summary

| Hypothesis | Verdict |
|---|---|
| FSM encoding change | Not a functional cause (cosmetic only) |
| Combinational timing path | Not the cause |
| `weights_loaded` default value | Not relevant for layer 2 |
| **IC_TILE_ADV condition nesting** | **Most likely root cause** |
| Sticky `reg_skip_wl` | Latent risk, not the immediate cause |

The regression is almost certainly caused by the `cfg_skip_wl` check in
`IC_TILE_ADV` being placed at the wrong nesting level, causing ALL layers
(not just multi-IC-tile ones) to divert to `PAUSE_FOR_WEIGHTS` when
`cfg_skip_wl=1` (which is always true since the firmware never clears it).
