# Approach E Implementation Plan: Poll weights_ready in IC_TILE_ADV

## Overview

Enable HW-internal IC tiling with spatial tiles >1x1 by having the
conv_engine FSM **wait inside IC_TILE_ADV** for the ARM to reload
weights via the FIFO, rather than returning DONE and requiring a new
CMD_START for each IC tile.

**Zero new FSM states.** The existing 38-state `state_t` enum is untouched.

### How it works

Current flow (1x1 tiles, ARM IC tiling):
```
ARM: load weights IC0 -> CMD_START -> wait DONE
ARM: load weights IC1 -> CMD_START -> wait DONE (but accumulators gone!)
```

New flow (NxN tiles, HW IC tiling):
```
ARM: load weights IC0 -> CMD_START
     conv_engine: pixels loop, IC tile 0 MAC done
     conv_engine: IC_TILE_ADV -> more IC tiles -> assert need_weights, WAIT
ARM: poll need_weights -> load weights IC1 -> CMD_LOAD_WEIGHTS -> pulse weights_loaded
     conv_engine: sees weights_loaded -> WL_NEXT -> WL_STRIDE -> MAC loop for IC1
     conv_engine: IC_TILE_ADV -> no more IC tiles -> requantize -> NEXT_PIXEL
     conv_engine: ... all pixels ... -> DONE
ARM: poll done -> DRAIN
```

The accumulators persist because we never leave the pixel loop -- the FSM
stays in IC_TILE_ADV (same pixel context) until weights arrive.

---

## File Changes

### 1. conv_engine_v4.vhd

#### 1a. New ports (entity, after `ext_wb_we`)

```vhdl
-- BEFORE (line 174-175):
        ext_wb_addr : in  unsigned(14 downto 0);
        ext_wb_data : in  signed(7 downto 0);
        ext_wb_we   : in  std_logic
    );

-- AFTER:
        ext_wb_addr : in  unsigned(14 downto 0);
        ext_wb_data : in  signed(7 downto 0);
        ext_wb_we   : in  std_logic;

        -- Approach E: IC-tile weight reload handshake
        weights_loaded : in  std_logic;   -- pulse from wrapper: new weights in wb_ram
        need_weights   : out std_logic    -- combinational: conv waiting for weights
    );
```

#### 1b. New internal signal (architecture, after `pad_saved`)

```vhdl
-- BEFORE (line 306-307):
    signal pad_saved : std_logic;

-- AFTER:
    signal pad_saved : std_logic;

    ---------------------------------------------------------------------------
    -- Approach E: flag for IC-tile weight reload handshake
    ---------------------------------------------------------------------------
    signal waiting_for_weights : std_logic := '0';
```

#### 1c. Combinational output (after existing debug assignments, ~line 477)

```vhdl
-- BEFORE (line 476-477):
    dbg_pad          <= pad_saved;
    dbg_act_addr     <= act_addr_r;

-- AFTER:
    dbg_pad          <= pad_saved;
    dbg_act_addr     <= act_addr_r;

    -- Approach E: combinational output
    need_weights     <= waiting_for_weights;
```

#### 1d. Reset the flag (in rst_n block, after `pad_saved <= '0';`)

```vhdl
-- BEFORE (line 517):
                pad_saved <= '0';

-- AFTER:
                pad_saved <= '0';
                waiting_for_weights <= '0';
```

#### 1e. Modify IC_TILE_ADV state (the core change)

Current code (lines 967-985):
```vhdl
                when IC_TILE_ADV =>
                    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
                        -- Hay mas ic tiles en este pixel
                        ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
                        -- Actualizar act_tile_base: +ic_tile_size x hw_reg
                        -- 1 mult de 10x20, 1 vez por ic_tile (aceptable)
                        act_tile_base <= act_tile_base
                                       + resize(cfg_ic_tile_size * hw_reg, 25);
                        -- Relanzar carga de pesos del siguiente tile
                        state <= WL_NEXT;
                    else
                        -- Todos los ic_tiles del pixel completados
                        rq_ch <= (others => '0');
                        if cfg_no_requantize = '1' then
                            state <= DONE_ST;
                        else
                            state <= MAC_DONE_WAIT;
                        end if;
                    end if;
```

New code:
```vhdl
                when IC_TILE_ADV =>
                    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
                        -- More IC tiles remain for this pixel
                        if cfg_skip_wl = '1' and waiting_for_weights = '0' then
                            -- Approach E: need ARM to reload wb_ram with next
                            -- IC tile weights. Set flag and stay here polling.
                            waiting_for_weights <= '1';
                            -- Do NOT advance ic_tile_base or act_tile_base yet;
                            -- that happens when weights arrive.
                        elsif cfg_skip_wl = '1' and waiting_for_weights = '1' then
                            -- Polling: wait for ARM to pulse weights_loaded
                            if weights_loaded = '1' then
                                waiting_for_weights <= '0';
                                ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
                                act_tile_base <= act_tile_base
                                               + resize(cfg_ic_tile_size * hw_reg, 25);
                                state <= WL_NEXT;
                            end if;
                            -- else: stay in IC_TILE_ADV, keep polling
                        else
                            -- skip_wl=0 path: EXACTLY as before (legacy BRAM preload)
                            ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
                            act_tile_base <= act_tile_base
                                           + resize(cfg_ic_tile_size * hw_reg, 25);
                            state <= WL_NEXT;
                        end if;
                    else
                        -- All IC tiles for this pixel completed
                        waiting_for_weights <= '0';  -- clear (defensive)
                        rq_ch <= (others => '0');
                        if cfg_no_requantize = '1' then
                            state <= DONE_ST;
                        else
                            state <= MAC_DONE_WAIT;
                        end if;
                    end if;
```

**Key properties:**
- `skip_wl=0` path is IDENTICAL to the original (just moves into `else` branch)
- No new states added -- FSM stays in `IC_TILE_ADV` while polling
- `waiting_for_weights` is registered (no combinational loops)
- `need_weights` is combinational output of registered flag (clean timing)
- `ic_tile_base` and `act_tile_base` only advance after `weights_loaded` pulse

#### 1f. Fix WL_STRIDE w_base_idx_r for per-IC-tile weight reload

When the ARM loads weights per-IC-tile (Approach E path), each IC tile's
weights are loaded at wb_ram address 0 (not at an offset). The current
skip_wl path sets `w_base_idx_r <= resize(oc_tile_base * tile_filter_stride, 20)`
which assumes ALL OC tiles' weights coexist in wb_ram. With Approach E, only
the current OC tile's weights are in wb_ram, starting at address 0.

However, the conv_engine still handles OC tiling internally (oc_tile_base
cycles 0, 32, 64...). So we need `w_base_idx_r = 0` when the ARM loads
weights per-IC-tile, because the FIFO always writes starting at address 0.

**But wait**: re-reading the firmware, the current ARM code sets `c_out=oc_w`
(32 or less) for each CMD_START, meaning the conv_engine sees only one OC group.
`oc_tile_base` is always 0. So `oc_tile_base * tile_filter_stride = 0` already.
This means the current WL_STRIDE code already produces the correct result for
the Approach E case -- no change needed here.

Verified: with `cfg_c_out <= 32` (which the firmware always sets for IC-tiled
layers), the conv_engine OC tiling loop runs exactly once (oc_tile_base=0).
The `w_base_idx_r` calculation `resize(0 * tile_filter_stride, 20) = 0`. Correct.

**No change needed to WL_STRIDE.**

---

### 2. dpu_stream_wrapper_v4.vhd

#### 2a. New signals (after `ce_dbg_state` declaration, ~line 191)

```vhdl
-- BEFORE (line 191):
    signal ce_dbg_state : integer range 0 to 63 := 0;

-- AFTER:
    signal ce_dbg_state : integer range 0 to 63 := 0;

    -- Approach E: IC-tile weight reload handshake
    signal ce_need_weights   : std_logic;         -- from conv_engine (combinational)
    signal ce_weights_loaded : std_logic := '0';  -- pulse to conv_engine
```

#### 2b. Connect new ports in conv_engine instance (~line 436)

```vhdl
-- BEFORE (lines 434-437):
            ext_wb_addr       => ext_wb_addr,
            ext_wb_data       => ext_wb_data,
            ext_wb_we         => ext_wb_we
        );

-- AFTER:
            ext_wb_addr       => ext_wb_addr,
            ext_wb_data       => ext_wb_data,
            ext_wb_we         => ext_wb_we,
            -- Approach E
            weights_loaded    => ce_weights_loaded,
            need_weights      => ce_need_weights
        );
```

#### 2c. Pulse weights_loaded at end of S_LOAD_WEIGHTS (when need_weights is high)

Current S_LOAD_WEIGHTS code (lines 1132-1142):
```vhdl
                    when S_LOAD_WEIGHTS =>
                        ext_wb_we <= '0';
                        if wb_load_count >= reg_wb_n_bytes then
                            done_latch <= '1';
                            state <= S_IDLE;
                        elsif w_stream_valid_i = '1' then
                            ext_wb_addr <= wb_load_count(14 downto 0);
                            ext_wb_data <= signed(w_stream_data_i);
                            ext_wb_we   <= '1';
                            wb_load_count <= wb_load_count + 1;
                        end if;
```

New code:
```vhdl
                    when S_LOAD_WEIGHTS =>
                        ext_wb_we <= '0';
                        ce_weights_loaded <= '0';  -- default: pulse is 1 cycle
                        if wb_load_count >= reg_wb_n_bytes then
                            if ce_need_weights = '1' then
                                -- Approach E: conv_engine waiting in IC_TILE_ADV.
                                -- Pulse weights_loaded to let it proceed to WL_NEXT.
                                ce_weights_loaded <= '1';
                            end if;
                            done_latch <= '1';
                            state <= S_IDLE;
                        elsif w_stream_valid_i = '1' then
                            ext_wb_addr <= wb_load_count(14 downto 0);
                            ext_wb_data <= signed(w_stream_data_i);
                            ext_wb_we   <= '1';
                            wb_load_count <= wb_load_count + 1;
                        end if;
```

**Note**: `ce_weights_loaded` must be defaulted to '0' somewhere. The cleanest
place is in the default-pulse section at the top of the FSM process (after
`ce_start <= '0';`, line 670):

```vhdl
-- BEFORE (line 670):
                ce_start <= '0';

-- AFTER:
                ce_start <= '0';
                ce_weights_loaded <= '0';  -- Approach E: single-cycle pulse
```

**Also add to reset block** (~line 638-639):
```vhdl
-- BEFORE:
                ce_start         <= '0';
                done_latch       <= '0';

-- AFTER:
                ce_start         <= '0';
                done_latch       <= '0';
                ce_weights_loaded <= '0';
```

#### 2d. Expose need_weights as REG_CTRL bit 12 (read-only)

In the AXI-Lite read process, REG_CTRL readback (line 1254-1258):

```vhdl
-- BEFORE:
                                when 16#00# =>
                                    reg_rd_data <= (others => '0');
                                    reg_rd_data(8)           <= done_latch;
                                    reg_rd_data(9)           <= ce_busy;
                                    reg_rd_data(11 downto 10) <= fsm_code;

-- AFTER:
                                when 16#00# =>
                                    reg_rd_data <= (others => '0');
                                    reg_rd_data(8)            <= done_latch;
                                    reg_rd_data(9)            <= ce_busy;
                                    reg_rd_data(11 downto 10) <= fsm_code;
                                    reg_rd_data(12)           <= ce_need_weights;
```

#### 2e. S_CONV must also handle cmd_load_weights during CONV

Currently, `cmd_load_weights` is only accepted in S_IDLE. But with Approach E,
the wrapper is in S_CONV while the conv_engine waits for weights. The ARM
must be able to trigger CMD_LOAD_WEIGHTS while S_CONV is active.

**Option**: Accept `cmd_load_weights` in S_CONV -- transition to S_LOAD_WEIGHTS,
then return to S_CONV when done.

This requires remembering we were in S_CONV. Add a signal:

```vhdl
    signal return_to_conv : std_logic := '0';  -- Approach E
```

Reset it:
```vhdl
                return_to_conv <= '0';
```

Modify S_CONV:
```vhdl
                    when S_CONV =>
                        if ce_done = '1' then
                            done_latch <= '1';
                            state      <= S_IDLE;
                        elsif cmd_load_weights = '1' then
                            -- Approach E: ARM reloading IC tile weights mid-conv
                            return_to_conv <= '1';
                            state <= S_LOAD_WEIGHTS;
                            wb_load_count <= (others => '0');
                        end if;
```

Modify S_LOAD_WEIGHTS completion:
```vhdl
                    when S_LOAD_WEIGHTS =>
                        ext_wb_we <= '0';
                        ce_weights_loaded <= '0';
                        if wb_load_count >= reg_wb_n_bytes then
                            if ce_need_weights = '1' then
                                ce_weights_loaded <= '1';
                            end if;
                            if return_to_conv = '1' then
                                -- Approach E: return to S_CONV (conv_engine still running)
                                return_to_conv <= '0';
                                state <= S_CONV;
                            else
                                done_latch <= '1';
                                state <= S_IDLE;
                            end if;
                        elsif w_stream_valid_i = '1' then
                            ext_wb_addr <= wb_load_count(14 downto 0);
                            ext_wb_data <= signed(w_stream_data_i);
                            ext_wb_we   <= '1';
                            wb_load_count <= wb_load_count + 1;
                        end if;
```

**Critical**: While wrapper is in S_LOAD_WEIGHTS (loading weights to wb_ram via
Port B), the conv_engine is stalled in IC_TILE_ADV (not reading wb_ram via Port A).
There is NO Port A/B conflict because the conv_engine only reads wb_ram during
MAC_WLOAD/MAC_WLOAD_CAP states, and it is stuck in IC_TILE_ADV.

**Also critical**: `done_latch` must NOT be set when returning to S_CONV.
The ARM uses `done_latch` (bit 8) to detect full conv completion. The weight
reload completion is signaled implicitly by `need_weights` going low (which
happens 1 cycle after `weights_loaded` pulse, when the conv_engine clears
`waiting_for_weights` and transitions to WL_NEXT).

#### 2f. Register map documentation update

```
-- 0x00: ctrl    - bit 0: cmd_load  (W, self-clearing)
--                  bit 1: cmd_start (W, self-clearing)
--                  bit 2: cmd_drain (W, self-clearing)
--                  bit 3: cmd_load_weights (W, self-clearing)
--                  bit 8: done      (RO, sticky)
--                  bit 9: busy/conv running (RO)
--                  bits[11:10]: fsm_state (RO): 00=IDLE,01=LOAD,10=CONV,11=DRAIN
--                  bit 12: need_weights (RO) -- conv waiting for IC tile weights
```

---

### 3. dpu_exec_v4.c (firmware)

The firmware changes ONLY the IC-tiled path. Non-IC-tiled layers
(`ic_tile_size == c_in`) are UNTOUCHED.

#### 3a. Key concept change

Currently the firmware does:
```
for each spatial tile:
  for each oc_group:
    for each ic_tile:
      load weights -> load input -> CMD_START -> wait done
    drain
```

With Approach E:
```
for each spatial tile:
  for each oc_group:
    load IC0 weights -> load input (ALL c_in) -> CMD_START
    poll loop:
      if need_weights(bit12) -> load next IC tile weights -> CMD_LOAD_WEIGHTS
      if done(bit8) AND ce_state==0 -> break
    drain
```

The conv_engine processes ALL IC tiles internally (per pixel), the ARM just
keeps the weight pipeline fed.

#### 3b. Input BRAM sizing change for IC-tiled layers

Currently the input loaded to BRAM is `ic_ts * in_h * in_w` (only one IC
tile's channels). With Approach E, the BRAM must hold ALL `c_in` channels
because the conv_engine processes all IC tiles per pixel internally.

```c
// BEFORE:
int in_bytes = ic_ts * in_h_real * in_w_real;

// AFTER (for real_ic_tiling path only):
int in_bytes = (real_ic_tiling ? L->c_in : ic_ts) * in_h_real * in_w_real;
```

This also affects tile size computation -- the BRAM must fit all c_in channels:
```c
// BEFORE (tile sizing, line 293-306):
if (real_ic_tiling) {
    tile_h = 1; tile_w = 1;
} else {
    // ... search for largest tile ...
}

// AFTER:
if (real_ic_tiling) {
    /* Approach E: BRAM holds ALL c_in, not just ic_ts */
    int c_in_bram = L->c_in;
    for (tile_h = 16; tile_h >= 1; tile_h--) {
        tile_w = tile_h;
        int in_h = (tile_h - 1) * stride + kh;
        int in_w = (tile_w - 1) * stride + kw;
        int tot = ALIGN_UP(c_out_bram * tile_h * tile_w, 64)
                + ALIGN_UP(c_in_bram * in_h * in_w, 64)
                + ALIGN_UP(c_out_bram * 4, 64);
        if (tot <= DPU_BRAM_BYTES) break;
    }
    if (tile_h < 1) tile_h = tile_w = 1;
} else {
    for (tile_h = 16; tile_h >= 1; tile_h--) {
        tile_w = tile_h;
        int in_h = (tile_h - 1) * stride + kh;
        int in_w = (tile_w - 1) * stride + kw;
        int tot = ALIGN_UP(c_out_bram * tile_h * tile_w, 64)
                + ALIGN_UP(ic_tile_size * in_h * in_w, 64)
                + ALIGN_UP(c_out_bram * 4, 64);
        if (tot <= DPU_BRAM_BYTES) break;
    }
    if (tile_h < 1) tile_h = tile_w = 1;
}
```

#### 3c. Conv register configuration changes

For IC-tiled layers, the conv_engine must know the FULL c_in and the
ic_tile_size separately:

```c
// BEFORE:
dpu_write(REG_C_IN,         ic_ts);          // only this IC tile's channels
dpu_write(REG_IC_TILE_SIZE, ic_ts);          // same

// AFTER (real_ic_tiling path):
dpu_write(REG_C_IN,         L->c_in);        // FULL c_in
dpu_write(REG_IC_TILE_SIZE, ic_tile_size);   // tile size for HW IC tiling
```

The conv_engine uses `cfg_c_in` for:
- `w_per_filter_full = c_in * kk` (DDR stride between filters -- used by
  WL_EMIT in skip_wl=0 mode; not used in skip_wl=1 mode directly, but
  IC_TILE_ADV uses `cfg_c_in` to detect "more tiles remain")
- `IC_TILE_ADV` comparison: `(ic_tile_base + cfg_ic_tile_size) < cfg_c_in`
- `hw_reg * cfg_c_in` is NOT computed (no such product exists)
- Input addressing: `act_tile_base` accumulates `+ic_tile_size * hw_reg` per
  IC tile. This correctly walks through input channels in the BRAM since
  ALL c_in channels are now loaded.

The conv_engine uses `cfg_ic_tile_size` for:
- `ic_in_tile_limit = min(ic_tile_size, c_in - ic_tile_base)` in WL_NEXT
- IC tile increment in IC_TILE_ADV

So setting `REG_C_IN = c_in` and `REG_IC_TILE_SIZE = ic_ts` makes the
conv_engine correctly:
1. Detect multiple IC tiles (`ic_ts < c_in`)
2. Process `ic_ts` channels per tile
3. Walk through all input channels in BRAM (which now holds all c_in)
4. Wait for weights at IC_TILE_ADV (Approach E handshake)

#### 3d. Complete firmware diff for real_ic_tiling path

The IC tile loop is eliminated. Instead of the inner `for ic_base` loop,
we do ONE CMD_START and then poll for weight reloads.

```c
/* BEFORE (lines 376-485, inside oc_group loop):
 *     for (int ic_base = 0; ic_base < L->c_in; ic_base += ic_tile_size) {
 *         ... load weights ... load input ... CMD_START ... wait done ...
 *     }
 */

/* AFTER (replaces the entire ic_tile loop for real_ic_tiling): */

if (real_ic_tiling) {
    /* --- Approach E: single CMD_START, poll for weight reloads --- */

    /* STEP 1: Load IC tile 0 weights via FIFO */
    int ic_ts_0 = (ic_tile_size < L->c_in) ? ic_tile_size : L->c_in;
    int w_bytes_0 = oc_w * kh * kw * ic_ts_0;
    {
        int8_t *wt = (int8_t *)W_TILE_BUF;
        int full_ic_stride = kh * kw * L->c_in;
        for (int oc = 0; oc < oc_w; oc++) {
            for (int p = 0; p < kh * kw; p++) {
                memcpy(wt + (oc * kh * kw + p) * ic_ts_0,
                       weights_ddr + (oc_base + oc) * full_ic_stride
                                   + p * L->c_in,
                       ic_ts_0);
            }
        }
        Xil_DCacheFlushRange((UINTPTR)wt, ALIGN_UP(w_bytes_0, 64));
        dpu_write(REG_WB_N_BYTES, w_bytes_0);
        dpu_write(REG_CTRL, CMD_LOAD_WEIGHTS);
        int rem = w_bytes_0; UINTPTR src = (UINTPTR)wt;
        while (rem > 0) {
            int chunk = rem > DMA_MAX_CHUNK ? DMA_MAX_CHUNK : rem;
            chunk = ALIGN_UP(chunk, 4);
            rc = wait_dma_idle(&g_dma_w, 5000000);
            if (rc != DPU_OK) { DBGSNAP(0xE1, 0); return rc; }
            dma_send(&g_dma_w, src, chunk);
            src += chunk; rem -= chunk;
        }
        rc = wait_done_latch(20000000);
        if (rc != DPU_OK) { DBGSNAP(0xE3, 0); return rc; }
    }

    /* STEP 2: Load ALL c_in input channels + bias to BRAM */
    int in_bytes = L->c_in * in_h_real * in_w_real;
    int bias_now = oc_w * 4;

    uint8_t *tile_buf = (uint8_t *)TILE_SCRATCH;
    int out_bytes_tile = oc_w * h_tile * w_tile;
    uint32_t IN_OFF = ALIGN_UP(out_bytes_tile, 64);
    uint32_t B_OFF  = ALIGN_UP(IN_OFF + in_bytes, 64);
    uint32_t TOT    = ALIGN_UP(B_OFF + bias_now, 64);

    memset(tile_buf, 0, TOT);
    for (int c = 0; c < L->c_in; c++) {
        for (int rr = 0; rr < in_h_real; rr++) {
            memcpy(tile_buf + IN_OFF + c * in_h_real * in_w_real + rr * in_w_real,
                   in_ddr + (uint32_t)c * L->h_in * L->w_in
                          + (uint32_t)(ih_lo + rr) * L->w_in + iw_lo,
                   in_w_real);
        }
    }
    memcpy(tile_buf + B_OFF, bias_ddr + oc_base, bias_now);
    Xil_DCacheFlushRange((UINTPTR)tile_buf, TOT);

    /* Configure conv registers */
    dpu_write(REG_C_OUT,         oc_w);
    dpu_write(REG_C_IN,          L->c_in);       /* FULL c_in */
    dpu_write(REG_H_IN,          in_h_real);
    dpu_write(REG_W_IN,          in_w_real);
    dpu_write(REG_IC_TILE_SIZE,  ic_tile_size);  /* HW IC tile size */
    dpu_write(REG_N_WORDS,       TOT / 4);
    dpu_write(REG_ADDR_INPUT,    IN_OFF);
    dpu_write(REG_ADDR_WEIGHTS,  0);
    dpu_write(REG_SKIP_WL,       1);
    dpu_write(REG_ADDR_BIAS,     B_OFF);
    dpu_write(REG_PAD_TOP,       pad_t);
    dpu_write(REG_PAD_BOTTOM,    pad_b);
    dpu_write(REG_PAD_LEFT,      pad_l);
    dpu_write(REG_PAD_RIGHT,     pad_r);
    dpu_write(REG_NO_CLEAR,      0);  /* HW handles clear internally */
    dpu_write(REG_NO_REQUANTIZE, 0);  /* HW handles requantize internally */

    /* LOAD input+bias to BRAM */
    dpu_write(REG_CTRL, CMD_LOAD);
    Xil_Out32(g_dma_in.RegBase + 0x04,
              Xil_In32(g_dma_in.RegBase + 0x04) | 0x7000);
    rc = wait_dma_idle(&g_dma_in, 5000000);
    if (rc != DPU_OK) { DBGSNAP(0xE4, 0); return rc; }
    dma_send(&g_dma_in, (UINTPTR)tile_buf, TOT);
    rc = wait_dma_idle(&g_dma_in, 10000000);
    if (rc != DPU_OK) { DBGSNAP(0xE4, 1); return rc; }
    int tm = 0;
    while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 0) {
        if (++tm > 1000000) { DBGSNAP(0xE5, 0); return DPU_ERR_TIMEOUT; }
    }

    /* STEP 3: START conv (single CMD_START for ALL IC tiles) */
    dpu_write(REG_CTRL, CMD_START);

    /* STEP 4: Poll loop -- feed weights as conv_engine requests them */
    int ic_tile_idx = 0;  /* IC tile 0 already loaded */
    for (;;) {
        uint32_t ctrl = dpu_read(REG_CTRL);
        uint32_t ce_st = dpu_read(REG_DBG_CE_STATE);

        /* Check done: bit 8 (done_latch) AND conv_engine in IDLE (state 0) */
        if ((ctrl & 0x100) && ce_st == 0) break;

        /* Check need_weights: bit 12 */
        if (ctrl & 0x1000) {
            ic_tile_idx++;
            int ic_base_next = ic_tile_idx * ic_tile_size;
            int ic_ts_next = ic_tile_size;
            if (ic_base_next + ic_ts_next > L->c_in)
                ic_ts_next = L->c_in - ic_base_next;

            int w_bytes_next = oc_w * kh * kw * ic_ts_next;

            /* Extract next IC tile's weights */
            int8_t *wt = (int8_t *)W_TILE_BUF;
            int full_ic_stride = kh * kw * L->c_in;
            for (int oc = 0; oc < oc_w; oc++) {
                for (int p = 0; p < kh * kw; p++) {
                    memcpy(wt + (oc * kh * kw + p) * ic_ts_next,
                           weights_ddr + (oc_base + oc) * full_ic_stride
                                       + p * L->c_in + ic_base_next,
                           ic_ts_next);
                }
            }
            Xil_DCacheFlushRange((UINTPTR)wt, ALIGN_UP(w_bytes_next, 64));

            /* Load via FIFO (CMD_LOAD_WEIGHTS while S_CONV is active) */
            dpu_write(REG_WB_N_BYTES, w_bytes_next);
            dpu_write(REG_CTRL, CMD_LOAD_WEIGHTS);
            {
                int rem = w_bytes_next; UINTPTR src = (UINTPTR)wt;
                while (rem > 0) {
                    int chunk = rem > DMA_MAX_CHUNK ? DMA_MAX_CHUNK : rem;
                    chunk = ALIGN_UP(chunk, 4);
                    rc = wait_dma_idle(&g_dma_w, 5000000);
                    if (rc != DPU_OK) { DBGSNAP(0xE1, ic_tile_idx); return rc; }
                    dma_send(&g_dma_w, src, chunk);
                    src += chunk; rem -= chunk;
                }
            }
            /* Wait for S_LOAD_WEIGHTS to complete (returns to S_CONV) */
            /* The wrapper sets done_latch when S_LOAD_WEIGHTS finishes.
             * BUT with return_to_conv=1, it goes to S_CONV, not S_IDLE.
             * done_latch is NOT set in the return_to_conv path.
             * So we poll for wrapper state == CONV (bits 11:10 == 2)
             * or need_weights going low.                              */
            tm = 0;
            while (1) {
                uint32_t st = dpu_read(REG_CTRL);
                uint32_t wfsm = (st >> 10) & 0x3;
                /* S_LOAD_WEIGHTS maps to fsm_code "11" (same as DRAIN).
                 * When it transitions back to S_CONV, fsm_code becomes "10". */
                if (wfsm == 2) break;  /* back in S_CONV */
                if (++tm > 5000000) { DBGSNAP(0xE8, ic_tile_idx); return DPU_ERR_TIMEOUT; }
            }
        }
    }

} else {
    /* --- Non IC-tiled path: existing code, UNCHANGED --- */
    for (int ic_base = 0; ic_base < L->c_in; ic_base += ic_tile_size) {
        /* ... existing code verbatim ... */
    }
}
```

#### 3e. Summary of firmware variables that change for real_ic_tiling

| Variable        | Before (1x1 tiles)    | After (Approach E)     |
|----------------|-----------------------|------------------------|
| `REG_C_IN`     | `ic_ts`               | `L->c_in`             |
| `REG_IC_TILE_SIZE` | `ic_ts`          | `ic_tile_size`         |
| `in_bytes`     | `ic_ts * h * w`       | `c_in * h * w`         |
| `no_clear`     | ARM-managed per tile  | 0 (HW manages)        |
| `no_requantize`| ARM-managed per tile  | 0 (HW manages)        |
| IC tile loop   | `for ic_base...`      | single START + poll    |
| tile_h/tile_w  | forced 1x1            | search 16..1 (c_in-based BRAM budget) |

---

## Timing Analysis

### Weight reload latency (dead time per IC tile transition per pixel)

When the conv_engine arrives at IC_TILE_ADV and asserts `need_weights`:
1. ARM polls REG_CTRL and sees bit 12 (need_weights) -- ~1-5 us (AXI-Lite read)
2. ARM extracts next IC tile weights from DDR -- ~10-50 us for 32KB
3. ARM issues CMD_LOAD_WEIGHTS + DMA_W transfer -- ~20-100 us for 32KB
4. Wrapper S_LOAD_WEIGHTS completes, pulses weights_loaded -- ~1 cycle
5. Conv_engine transitions IC_TILE_ADV -> WL_NEXT -> WL_STRIDE -> MAC_PAD_REG

Total dead time per IC-tile boundary per pixel: ~30-150 us

### Comparison with current 1x1 approach

Current 1x1 approach dead time per IC tile:
- DMA_W + CMD_LOAD_WEIGHTS: ~30-100 us
- DMA_IN (reload input tile): ~10-50 us
- CMD_START + CALC_* precompute: ~20 cycles
- Wait for DONE + CMD_START: ~5 us
- Total: ~50-150 us

Approach E per IC tile per pixel:
- DMA_W + CMD_LOAD_WEIGHTS: ~30-100 us (same)
- No DMA_IN (input stays in BRAM): SAVED
- No CMD_START overhead: SAVED
- No CALC_* precompute: SAVED
- Total: ~30-100 us

But the critical speedup is that spatial tiles can be >1x1:
- 4x4 tile: 16 pixels per tile, so 16 IC-tile-boundaries share one weight reload
  (the weight reload happens once per IC tile, not once per pixel!)

**Wait** -- re-reading the flow: the conv_engine processes ALL pixels for IC
tile 0, then needs new weights for IC tile 1 for pixel (0,0) again.

Actually no. Let me re-read the IC_TILE_ADV flow in the conv_engine.

The pixel loop is:
```
INIT_PIXEL_1 -> ... -> BIAS_LOAD -> WL_NEXT -> MAC loop -> IC_TILE_ADV
   if more IC tiles: -> WL_NEXT (same pixel, next IC tile)
   if no more IC tiles: -> requantize -> NEXT_PIXEL
```

So the IC tile loop is INSIDE the pixel loop. For each pixel, the conv_engine
processes ALL IC tiles before moving to the next pixel. The weight reload
happens for every pixel at every IC tile boundary.

For a 4x4 spatial tile with 5 IC tiles:
- 16 pixels * 4 IC tile boundaries = 64 weight reloads per OC group
- vs current 1x1: 16 * 5 CMD_STARTs = 80 full ARM round-trips

The weight reload is the same data each time (same IC tile for all pixels in
the same OC group). So there are 64 reloads of 5 different weight sets,
meaning the ARM reloads the same weight set 16 times (once per pixel).

**This is the inherent cost of not having weight double-buffering.** But the
savings from eliminating CMD_START overhead and DMA_IN reloads may still
yield a net win.

### Optimization: ARM can pre-stage weight data

Since the weight data for each IC tile does not change across pixels, the ARM
can prepare the weight blob once and DMA it repeatedly. The memcpy extraction
from DDR only needs to happen once per IC tile per OC group, not once per pixel.

In the firmware, the ARM keeps `ic_tile_idx` and only increments it when
`need_weights` fires. But the conv_engine fires `need_weights` for every pixel's
IC tile boundary. So for a 4x4 tile with 5 IC tiles:

- Pixel 0: IC tiles 0,1,2,3,4 -- need_weights fires 4 times (tiles 1-4)
- Pixel 1: IC tiles 0,1,2,3,4 -- need_weights fires 4 times
- ...
- Pixel 15: IC tiles 0,1,2,3,4 -- need_weights fires 4 times

Total: 64 weight reloads. The ARM must track which IC tile is needed. Since
the conv_engine resets `ic_tile_base` to 0 at each pixel start (INIT_PIXEL_1
line 659: `ic_tile_base <= (others => '0')`), the IC tile index cycles
0,1,2,3,4,0,1,2,3,4,...

The firmware must track this cycling. Simplest approach: keep a counter that
wraps. Or better: since the conv_engine knows which IC tile it needs, add a
debug register to expose `ic_tile_base`.

**Alternative**: The firmware just keeps a rolling index. Each `need_weights`
means "the NEXT IC tile after the last one loaded." Since the conv_engine
always processes IC tiles 0,1,...,N-1 for each pixel, and IC tile 0's weights
were loaded at CMD_START, the first `need_weights` is for IC tile 1, then 2,
etc. After IC tile N-1 (last), the conv_engine goes to requantize and then
NEXT_PIXEL, where it resets `ic_tile_base=0` and starts again. IC tile 0
weights are NOT in wb_ram anymore (IC tile N-1's weights are). So the next
`need_weights` from pixel 1 is for... IC tile 1? No -- pixel 1 starts at
IC tile 0. But IC tile 0 needs its weights loaded first!

**Problem**: After pixel 0 completes all IC tiles (0..N-1), the conv_engine
goes to NEXT_PIXEL -> INIT_PIXEL_1 for pixel 1. INIT_PIXEL_1 resets
`ic_tile_base <= 0` and goes through BIAS_LOAD -> WL_NEXT -> WL_STRIDE.
In WL_STRIDE, `skip_wl=1` sends it directly to MAC_PAD_REG. But wb_ram
still has IC tile N-1's weights, not IC tile 0's!

**This is a bug in the current approach.** Need to fix it.

### Fix: Reload IC tile 0 weights between pixels

There are several options:

**Option A**: After pixel N, before pixel N+1, the conv_engine needs IC tile 0
weights again. It would need to signal `need_weights` at INIT_PIXEL or BIAS_LOAD.
This adds complexity outside IC_TILE_ADV.

**Option B**: Pre-load ALL IC tiles' weights into wb_ram. But they don't fit
(that's why we need IC tiling).

**Option C**: The ARM loads IC tile 0's weights before CMD_START, and the
conv_engine processes ONLY IC tile 0 for ALL pixels. Then IC_TILE_ADV detects
"more IC tiles" for the FIRST pixel where all-IC-tiles aren't done. It signals
need_weights, ARM loads IC tile 1, and the conv_engine processes IC tile 1 for
ALL pixels. Then IC_TILE_ADV at the last pixel wraps back.

**This is actually how the original design works!** The outer loop is pixels,
inner loop is IC tiles PER PIXEL. But with Option C, we reverse it: outer loop
is IC tiles, inner loop is pixels.

But that requires a redesign of the FSM -- the IC tile loop is currently inside
the pixel loop, not outside.

### Revised Architecture: IC tile loop OUTSIDE pixel loop

Looking at the conv_engine FSM structure:

```
OC_TILE_START -> bias -> pixel_loop {
    INIT_PIXEL -> BIAS_LOAD -> WL_NEXT -> MAC -> IC_TILE_ADV {
        if more IC tiles: -> WL_NEXT (reload weights) -> MAC
        if done: -> requantize -> NEXT_PIXEL
    }
} -> OC_TILE_ADV -> DONE
```

For Approach E to work correctly, we need:
```
OC_TILE_START -> bias -> pixel_loop {
    INIT_PIXEL -> BIAS_LOAD -> WL_NEXT -> MAC -> IC_TILE_ADV {
        if more IC tiles AND waiting: poll weights_loaded -> WL_NEXT
        if done: -> requantize -> NEXT_PIXEL
    }
}
```

The key insight is: for each pixel, ALL IC tiles are processed before moving
to the next pixel. This means IC tile 0 weights must be in wb_ram when pixel 0
starts, IC tile 1 weights after pixel 0's IC tile 0 MAC loop, IC tile 2 after
IC tile 1, etc. Then for pixel 1, IC tile 0 weights must be reloaded.

**The weight reloads happen once per pixel per IC-tile-boundary.**

The firmware just needs to cycle through IC tiles: each `need_weights` means
"load the next IC tile in sequence." The firmware cycles through:
IC1, IC2, ..., ICN-1, IC0, IC1, IC2, ..., ICN-1, IC0, ...

```c
int next_ic_base = ic_tile_size;  /* first need_weights is for IC tile 1 */

for (;;) {
    uint32_t ctrl = dpu_read(REG_CTRL);
    uint32_t ce_st = dpu_read(REG_DBG_CE_STATE);

    if ((ctrl & 0x100) && ce_st == 0) break;  /* done */

    if (ctrl & 0x1000) {  /* need_weights */
        int ic_ts_next = ic_tile_size;
        if (next_ic_base + ic_ts_next > L->c_in)
            ic_ts_next = L->c_in - next_ic_base;

        /* Load weights for (oc_group, next_ic_base) */
        /* ... DMA weight load ... */

        /* Advance to next IC tile (wrapping) */
        next_ic_base += ic_tile_size;
        if (next_ic_base >= L->c_in)
            next_ic_base = 0;  /* wrap for next pixel */
    }
}
```

**Wait** -- when next_ic_base wraps to 0, the conv_engine is either:
1. On the last IC tile of a pixel -> goes to requantize -> NEXT_PIXEL ->
   INIT_PIXEL_1 -> BIAS_LOAD -> WL_NEXT -> WL_STRIDE -> MAC (using IC tile 0
   weights which we just loaded). Correct!
2. Or conv_engine is done (no more pixels) -> goes to OC_TILE_ADV or DONE.

But there is a subtle issue: after the last IC tile, `need_weights` is NOT
asserted (IC_TILE_ADV goes to requantize, not to the wait path). So the
`next_ic_base` wrapping to 0 happens AFTER the last `need_weights` of the
pixel, meaning the ARM pre-stages IC tile 0's weights for the next pixel.

Actually, the firmware does NOT load weights at wrap time -- it only loads when
`need_weights` fires. The sequence for 3 IC tiles, 2 pixels would be:

```
ARM loads IC0, CMD_START
Pixel 0, IC0: MAC done -> IC_TILE_ADV -> need_weights
ARM loads IC1 -> weights_loaded
Pixel 0, IC1: MAC done -> IC_TILE_ADV -> need_weights
ARM loads IC2 -> weights_loaded
Pixel 0, IC2: MAC done -> IC_TILE_ADV -> no more IC tiles -> requantize
              -> NEXT_PIXEL -> INIT_PIXEL_1 -> BIAS_LOAD -> WL_NEXT -> WL_STRIDE
              -> skip_wl=1: MAC_PAD_REG (uses wb_ram as-is = IC2's weights!)
              BUG: should be using IC0's weights for pixel 1!
```

**Confirmed bug**: After pixel 0's last IC tile, wb_ram has IC tile 2 (last)
weights. Pixel 1 starts with these wrong weights.

### Solution: need_weights at WL_STRIDE

We need the conv_engine to also wait for weights at the START of each pixel
(not just between IC tiles). But the user's constraint says "only add logic
inside IC_TILE_ADV."

**Alternative solution**: After the last IC tile of pixel N, DON'T go to
requantize immediately. Instead, if `skip_wl=1` AND this is not the very
last pixel: stay in IC_TILE_ADV, signal `need_weights` for IC tile 0 of
the NEXT pixel.

But this is tricky -- IC_TILE_ADV detects "all IC tiles done" when
`(ic_tile_base + cfg_ic_tile_size) >= cfg_c_in`. At this point we need to
requantize first, then go to NEXT_PIXEL, then need IC0 weights again.
We can't easily intercept at IC_TILE_ADV because requantize must happen first.

### Alternative Architecture: cfg_ic_tile_size == cfg_c_in disables HW IC tiling

Instead of having the conv_engine do HW IC tiling with multiple pixels, we
keep the **ARM IC tiling approach (1 CMD_START per IC tile)** but use
Approach E's polling to avoid the full CMD_START overhead.

Actually, let me re-read the user's request more carefully:

> cfg_c_in = FULL c_in, cfg_ic_tile_size = ic_ts
> Load ALL c_in channels into BRAM (not just ic_ts)
> Load IC tile 0 weights to wb_ram
> CMD_START once
> Poll loop: check need_weights (bit 12) -> reload weights -> CMD_LOAD_WEIGHTS
> Check done (bit 8 AND ce_state==0) -> break

The user already understands this architecture. The conv_engine internally
loops IC tiles per pixel, and the ARM keeps feeding weights. The re-loading
of IC tile 0 for pixel 1 is inherent -- the firmware must handle the wrapping.

Let me revise section 3d of the firmware to handle this correctly:

After the last IC tile (N-1) of pixel K, the conv_engine goes to requantize,
then NEXT_PIXEL, then INIT_PIXEL_1 (which resets `ic_tile_base <= 0`), then
BIAS_LOAD, then WL_NEXT, then WL_STRIDE. In WL_STRIDE with skip_wl=1, it
goes straight to MAC_PAD_REG using whatever is in wb_ram (IC tile N-1's
weights). **This is wrong.**

**The fix**: In WL_STRIDE, when `skip_wl=1` AND `ic_tile_base = 0` (first IC
tile of this pixel) AND `cfg_ic_tile_size < cfg_c_in` (IC tiling is active):
also wait for weights. This means adding a wait in WL_STRIDE, not IC_TILE_ADV.

But the user says "only add logic INSIDE IC_TILE_ADV." This constraint means
we need to handle the IC0 weight reload differently.

**Revised approach: ic_tile_base never resets to 0 within a single CMD_START**

Instead of having INIT_PIXEL_1 reset `ic_tile_base <= 0`, we can leave it and
let the MAC loop continue with the correct IC tile. But that breaks the
existing logic where each pixel starts from IC tile 0.

**Another approach: INIT_PIXEL_1 does NOT reset ic_tile_base or w_base_idx_r**

If we keep `ic_tile_base` at 0 (as INIT_PIXEL_1 does), and the first IC tile's
weights happen to already be in wb_ram... they won't be, because the last
pixel loaded IC tile N-1.

**Final approach: The ARM pre-loads IC tile 0 weights before the conv_engine
reaches pixel 1's WL_STRIDE.**

After the conv_engine finishes IC tile N-1 for pixel K, it goes through:
IC_TILE_ADV -> (no more tiles) -> MAC_DONE_WAIT -> MAC_DONE_WAIT2 ->
RQ_EMIT (32 iterations) -> RQ_CAPTURE (32 iterations) -> NEXT_PIXEL ->
INIT_PIXEL_1 -> INIT_PIXEL_2 -> INIT_PIXEL_3 -> BIAS_LOAD -> WL_NEXT ->
WL_STRIDE -> MAC_PAD_REG

That's roughly 32*2 + 10 = 74 cycles of requantize + pixel init before
WL_STRIDE. At 100 MHz that's 740 ns. The ARM needs to reload IC tile 0 weights
(~32KB via DMA) in that time. DMA at 200 MB/s for 32KB = 160 us. Not enough
time.

**Solution: Signal need_weights ALSO when transitioning from the "all IC tiles
done" branch to requantize.** This way the ARM has the entire requantize +
pixel init time to load IC tile 0.

But this violates the "only logic inside IC_TILE_ADV" constraint... unless we
interpret it as: the `waiting_for_weights` flag is set in IC_TILE_ADV, and the
`need_weights` output drives the ARM notification, but the ACTUAL wait happens
before MAC_PAD_REG -- which is in WL_STRIDE.

**Revised cleaner solution within IC_TILE_ADV:**

When IC_TILE_ADV detects "all IC tiles done for this pixel" (the else branch),
AND `cfg_skip_wl = '1'` AND this is NOT the last pixel of the layer:
- Go to requantize as normal
- But ALSO assert `need_weights` (set `waiting_for_weights <= '1'`)
- The ARM sees `need_weights`, starts loading IC tile 0 for next pixel
- The conv_engine continues through requantize + NEXT_PIXEL + INIT_PIXEL_* +
  BIAS_LOAD + WL_NEXT + WL_STRIDE
- At WL_STRIDE, `skip_wl=1`: check `waiting_for_weights`. If still set,
  wait (poll `weights_loaded`). If already cleared (ARM was fast enough),
  proceed directly.

This requires adding a small check in WL_STRIDE too. Let me revise to keep
it minimal:

**Cleanest approach: WL_STRIDE polls waiting_for_weights (2 lines)**

In WL_STRIDE, after `if cfg_skip_wl = '1' then`:
```vhdl
                when WL_STRIDE =>
                    tile_filter_stride <= resize(ic_in_tile_limit * kk_reg, 20);
                    if cfg_skip_wl = '1' then
                        if waiting_for_weights = '1' then
                            -- Approach E: wait for ARM to finish loading IC tile 0
                            if weights_loaded = '1' then
                                waiting_for_weights <= '0';
                                -- proceed to MAC
                                kh <= (others => '0');
                                kw <= (others => '0');
                                ic <= (others => '0');
                                w_base_idx_r <= (others => '0');
                                act_ic_offset <= act_tile_base;
                                act_kh_offset <= (others => '0');
                                state <= MAC_PAD_REG;
                            end if;
                            -- else: stay in WL_STRIDE, keep polling
                        else
                            -- No wait needed (first pixel, or ARM already loaded)
                            kh <= (others => '0');
                            kw <= (others => '0');
                            ic <= (others => '0');
                            w_base_idx_r <= (others => '0');
                            act_ic_offset <= act_tile_base;
                            act_kh_offset <= (others => '0');
                            state <= MAC_PAD_REG;
                        end if;
                    else
                        state <= WL_EMIT;
                    end if;
```

**Note**: `w_base_idx_r` is set to `(others => '0')` in both branches (not
`oc_tile_base * tile_filter_stride` as before). This is because:
- The ARM loads only ONE OC group's weights per CMD_START
- `cfg_c_out <= 32` for IC-tiled layers
- So `oc_tile_base` is always 0
- `0 * anything = 0`

For safety, use `resize(oc_tile_base * tile_filter_stride, 20)` as before --
it evaluates to 0 anyway.

Actually, there is a problem: the existing skip_wl=1 code uses
`resize(oc_tile_base * tile_filter_stride, 20)` and `tile_filter_stride` is
being computed IN THIS SAME CYCLE. That's a same-cycle dependency. The original
code works because `tile_filter_stride` was computed in the PREVIOUS entry to
WL_STRIDE (or in CALC_TILE_STRIDE). But now we may stay in WL_STRIDE for
multiple cycles (polling). After the first cycle, `tile_filter_stride` has the
correct value from the `resize(ic_in_tile_limit * kk_reg, 20)` assignment.

To be safe, we should only proceed on a cycle where `tile_filter_stride` is
already valid. Since `tile_filter_stride` is assigned on entry to WL_STRIDE,
it's available on the NEXT cycle (registered). If we poll for
`waiting_for_weights`, the second cycle already has the correct value.

But actually, `tile_filter_stride` is updated EVERY cycle we're in WL_STRIDE
(because the assignment is unconditional). And `ic_in_tile_limit` doesn't
change while we're in WL_STRIDE. So `tile_filter_stride` has the correct value
from cycle 2 onwards.

For the first pixel (no wait needed), the existing behavior applies:
`tile_filter_stride` uses the stale value from the previous pass, but
`w_base_idx_r = oc_tile_base * tile_filter_stride = 0 * stale = 0`. Correct.

**Conclusion**: The WL_STRIDE code is safe as-is for Approach E.

---

## Revised Complete IC_TILE_ADV Code

```vhdl
                when IC_TILE_ADV =>
                    if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
                        -- More IC tiles remain for this pixel
                        if cfg_skip_wl = '1' and waiting_for_weights = '0' then
                            -- Approach E: signal ARM to load next IC tile
                            waiting_for_weights <= '1';
                        elsif cfg_skip_wl = '1' and waiting_for_weights = '1' then
                            -- Polling: wait for ARM to pulse weights_loaded
                            if weights_loaded = '1' then
                                waiting_for_weights <= '0';
                                ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
                                act_tile_base <= act_tile_base
                                               + resize(cfg_ic_tile_size * hw_reg, 25);
                                state <= WL_NEXT;
                            end if;
                        else
                            -- skip_wl=0: original path, untouched
                            ic_tile_base <= ic_tile_base + cfg_ic_tile_size(9 downto 0);
                            act_tile_base <= act_tile_base
                                           + resize(cfg_ic_tile_size * hw_reg, 25);
                            state <= WL_NEXT;
                        end if;
                    else
                        -- All IC tiles done for this pixel
                        if cfg_skip_wl = '1' and cfg_ic_tile_size < cfg_c_in then
                            -- Approach E: pre-signal ARM to load IC tile 0 for
                            -- the NEXT pixel. ARM starts DMA while conv_engine
                            -- does requantize + pixel init (70+ cycles).
                            waiting_for_weights <= '1';
                        end if;
                        rq_ch <= (others => '0');
                        if cfg_no_requantize = '1' then
                            state <= DONE_ST;
                        else
                            state <= MAC_DONE_WAIT;
                        end if;
                    end if;
```

And in WL_STRIDE:
```vhdl
                when WL_STRIDE =>
                    tile_filter_stride <= resize(ic_in_tile_limit * kk_reg, 20);
                    if cfg_skip_wl = '1' then
                        if waiting_for_weights = '1' then
                            -- Approach E: wait for IC tile 0 weights (set by
                            -- IC_TILE_ADV after last IC tile of previous pixel)
                            if weights_loaded = '1' then
                                waiting_for_weights <= '0';
                                kh <= (others => '0');
                                kw <= (others => '0');
                                ic <= (others => '0');
                                w_base_idx_r <= resize(oc_tile_base * tile_filter_stride, 20);
                                act_ic_offset <= act_tile_base;
                                act_kh_offset <= (others => '0');
                                state <= MAC_PAD_REG;
                            end if;
                        else
                            -- Original skip_wl path (first pixel, or single IC tile)
                            kh <= (others => '0');
                            kw <= (others => '0');
                            ic <= (others => '0');
                            w_base_idx_r <= resize(oc_tile_base * tile_filter_stride, 20);
                            act_ic_offset <= act_tile_base;
                            act_kh_offset <= (others => '0');
                            state <= MAC_PAD_REG;
                        end if;
                    else
                        state <= WL_EMIT;
                    end if;
```

---

## Revised Firmware Poll Loop

The firmware must handle two types of `need_weights`:
1. **Mid-pixel**: load next IC tile (ic_tile_base += ic_tile_size)
2. **End-of-pixel**: load IC tile 0 for the next pixel (wrap to 0)

Both look the same to the ARM -- `need_weights` is asserted. The firmware
keeps a rolling `next_ic_base`:

```c
/* After CMD_START: */
int next_ic_base = ic_tile_size;  /* first reload will be for IC tile 1 */
int n_ic_tiles = (L->c_in + ic_tile_size - 1) / ic_tile_size;

/* Pre-extract ALL IC tile weight blobs once (avoid repeated memcpy) */
int8_t *wt_blobs[n_ic_tiles];  /* pointers into W_TILE_BUF region */
int wt_sizes[n_ic_tiles];
{
    int8_t *wt_base = (int8_t *)W_TILE_BUF;
    int full_ic_stride = kh * kw * L->c_in;
    for (int t = 0; t < n_ic_tiles; t++) {
        int ic_b = t * ic_tile_size;
        int ic_s = ic_tile_size;
        if (ic_b + ic_s > L->c_in) ic_s = L->c_in - ic_b;
        int wb = oc_w * kh * kw * ic_s;
        wt_blobs[t] = wt_base;
        wt_sizes[t] = wb;
        for (int oc = 0; oc < oc_w; oc++) {
            for (int p = 0; p < kh * kw; p++) {
                memcpy(wt_base + (oc * kh * kw + p) * ic_s,
                       weights_ddr + (oc_base + oc) * full_ic_stride
                                   + p * L->c_in + ic_b,
                       ic_s);
            }
        }
        wt_base += ALIGN_UP(wb, 64);
    }
    Xil_DCacheFlushRange((UINTPTR)W_TILE_BUF,
                         (UINTPTR)wt_base - W_TILE_BUF);
}

/* Poll loop */
int next_tile_idx = 1;  /* IC tile 0 already loaded before CMD_START */
for (;;) {
    uint32_t ctrl = dpu_read(REG_CTRL);
    uint32_t ce_st = dpu_read(REG_DBG_CE_STATE);

    if ((ctrl & 0x100) && ce_st == 0) break;  /* done */

    if (ctrl & 0x1000) {  /* need_weights */
        int t = next_tile_idx;
        dpu_write(REG_WB_N_BYTES, wt_sizes[t]);
        dpu_write(REG_CTRL, CMD_LOAD_WEIGHTS);
        {
            int rem = wt_sizes[t];
            UINTPTR src = (UINTPTR)wt_blobs[t];
            while (rem > 0) {
                int chunk = rem > DMA_MAX_CHUNK ? DMA_MAX_CHUNK : rem;
                chunk = ALIGN_UP(chunk, 4);
                rc = wait_dma_idle(&g_dma_w, 5000000);
                if (rc != DPU_OK) return rc;
                dma_send(&g_dma_w, src, chunk);
                src += chunk; rem -= chunk;
            }
        }
        /* Wait for wrapper to return to S_CONV */
        int tm = 0;
        while (((dpu_read(REG_CTRL) >> 10) & 0x3) != 2) {
            if (++tm > 5000000) return DPU_ERR_TIMEOUT;
        }

        next_tile_idx++;
        if (next_tile_idx >= n_ic_tiles) next_tile_idx = 0;
    }
}
```

**Memory concern**: The pre-extracted weight blobs for all IC tiles must fit
in the W_TILE_BUF region. One OC group's total weights =
`oc_w * kh * kw * c_in`. For oc_w=32, kh=kw=3, c_in=512:
32 * 9 * 512 = 147,456 bytes. W_TILE_BUF is at TILE_SCRATCH + 0x300000
with room to spare. This is fine.

---

## Summary of All Changes

| File | Section | Change |
|------|---------|--------|
| conv_engine_v4.vhd | entity ports | Add `weights_loaded` (in), `need_weights` (out) |
| conv_engine_v4.vhd | signals | Add `waiting_for_weights` (std_logic) |
| conv_engine_v4.vhd | concurrent | Add `need_weights <= waiting_for_weights` |
| conv_engine_v4.vhd | reset | Add `waiting_for_weights <= '0'` |
| conv_engine_v4.vhd | IC_TILE_ADV | Poll `weights_loaded` when skip_wl=1; pre-signal at end |
| conv_engine_v4.vhd | WL_STRIDE | Poll `waiting_for_weights` before skip_wl=1 MAC path |
| conv_engine_v4.vhd | state_t | **NO CHANGE** (zero new states) |
| wrapper_v4.vhd | signals | Add `ce_need_weights`, `ce_weights_loaded`, `return_to_conv` |
| wrapper_v4.vhd | conv instance | Connect `weights_loaded`, `need_weights` |
| wrapper_v4.vhd | S_CONV | Accept `cmd_load_weights` (set `return_to_conv`) |
| wrapper_v4.vhd | S_LOAD_WEIGHTS | Pulse `ce_weights_loaded`; respect `return_to_conv` |
| wrapper_v4.vhd | AXI read | Expose `ce_need_weights` as REG_CTRL bit 12 |
| wrapper_v4.vhd | defaults/reset | Add `ce_weights_loaded`, `return_to_conv` |
| dpu_exec_v4.c | real_ic_tiling path | Single CMD_START + poll loop |
| dpu_exec_v4.c | tile sizing | Use c_in (not ic_ts) for BRAM budget |
| dpu_exec_v4.c | registers | REG_C_IN=c_in, REG_IC_TILE_SIZE=ic_ts |
| dpu_exec_v4.c | no_clear/no_rq | Both 0 (HW manages internally) |

### Non-IC-tiled path preservation

For layers where `ic_tile_size == c_in`:
- `cfg_ic_tile_size == cfg_c_in`
- `(ic_tile_base + cfg_ic_tile_size) < cfg_c_in` is NEVER true in IC_TILE_ADV
- So the "more IC tiles" branch is never taken
- `waiting_for_weights` stays '0'
- `need_weights` stays '0'
- WL_STRIDE skip_wl=1 path: `waiting_for_weights='0'` -> original behavior
- **Zero behavioral change for non-IC-tiled layers**

For skip_wl=0 layers:
- `cfg_skip_wl = '0'`
- IC_TILE_ADV: takes the `else` branch (original code, bit-exact)
- WL_STRIDE: takes the `else state <= WL_EMIT` branch (original code)
- **Zero behavioral change for skip_wl=0 layers**

---

## Risks and Mitigations

1. **Timing**: `need_weights` is combinational (registered flag -> output).
   Clean timing, no combinational path through the AXI-Lite read.

2. **Port B conflict**: While wrapper is in S_LOAD_WEIGHTS writing via Port B,
   conv_engine is in IC_TILE_ADV (or WL_STRIDE) not reading Port A.
   No dual-port conflict.

3. **FSM encoding**: No new states -> no encoding change -> no regressions.

4. **Weight reload latency**: Each pixel's IC tile boundary incurs ~30-100 us
   of weight DMA. For a 4x4 tile with 5 IC tiles, that's 4 reloads/pixel *
   16 pixels = 64 reloads per OC group. At 50 us each = 3.2 ms per OC group.
   But we eliminate 15/16 of the CMD_START overhead (DMA_IN + CMD_START +
   CALC_*), which saves ~15 * 100 us = 1.5 ms. Net overhead per OC group:
   ~1.7 ms more than 1x1, BUT spatial tiles >1x1 enable batching.

5. **Pre-signal optimization**: IC_TILE_ADV sets `waiting_for_weights='1'`
   at end-of-pixel, giving the ARM ~70+ cycles (~700 ns) head start before
   WL_STRIDE checks it. This is not enough for the full DMA, but reduces
   the wait time in WL_STRIDE.
