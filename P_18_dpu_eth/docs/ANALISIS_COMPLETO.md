# Análisis completo del código — 4 archivos clave

---

## 1. conv_engine_v3.vhd (963 líneas) — El corazón del DPU

### 1.1 Qué es

El pipeline hardware que calcula la convolución cuantizada INT8:

```
y[oc, oh, ow] = requantize(
    Σ_{ic_tile} Σ_{kh, kw, ic} (x[ic, ih+kh, iw+kw] - x_zp) × w[oc, kh, kw, ic]
    + bias[oc]
)
```

Usa 32 MACs en paralelo (1 por canal de salida) + 1 requantize pipeline de 8 etapas.

### 1.2 FSM (40 estados, 3 niveles de anidamiento)

```
IDLE
 └─▶ CALC_KK → CALC_HOUT_1 → CALC_HOUT_2 → CALC_HW → CALC_HW_OUT
     → CALC_W_FILTER → CALC_TILE_STRIDE → CALC_KW_CIN
     (pre-computa constantes, 1 mult max por estado)

     └─▶ OC_TILE_START   ◀──────────────────── OC_TILE_ADV ◀─┐
          │                                                     │
          └─▶ BL_EMIT → BL_WAIT → BL_CAPTURE (carga bias)     │
              │                                                 │
              └─▶ INIT_ROW → INIT_PIXEL_1 → _2 → _3           │
                  │                              ◀── NEXT_PIXEL │
                  └─▶ BIAS_LOAD                        ▲        │
                      │                                │        │
                      └─▶ WL_NEXT → WL_STRIDE         │        │
                          │    ◀── IC_TILE_ADV ──┐     │        │
                          └─▶ WL_EMIT→WAIT→CAP   │     │        │
                              │                   │     │        │
                              └─▶ MAC_PAD_REG     │     │        │
                                  └─▶ MAC_WLOAD   │     │        │
                                      └─▶ _CAP    │     │        │
                                          └─▶ MAC_EMIT  │        │
                                              └─▶ _WAIT │        │
                                                  └─▶ _CAPTURE   │
                                                      └─▶ MAC_FIRE
                                                          │      │
                                    ic++ ─── ◀───────────┘      │
                                    kw++ ─── ◀──────┘           │
                                    kh++ ─── ◀─────┘            │
                                    ic_tile++ ── IC_TILE_ADV ──▶│
                                    fin tile ── MAC_DONE_WAIT   │
                                                └─▶ _WAIT2     │
                                                    └─▶ RQ_EMIT │
                                                        └─▶ RQ_CAPTURE
                                                            └─▶ NEXT_PIXEL ──▶┘
                                                                     │
                                    fin pixels ── OC_TILE_ADV ──────▶┘
                                    fin oc_tiles ── DONE_ST ──▶ IDLE
```

### 1.3 El loop MAC — líneas 764-850 (lo más crítico)

El MAC loop recorre `(ic, kw, kh)` del tile IC actual:

```vhdl
-- MAC_FIRE (L821-850): el innermost loop
mac_vi <= '1';                              -- dispara 32 MACs en 1 ciclo
w_base_idx_r <= w_base_idx_r + 1;          -- siguiente peso en weight_buf

if ic < ic_in_tile_limit - 1 then
    ic            <= ic + 1;
    act_ic_offset <= act_ic_offset + hw_reg;   -- ← NCHW: salta H×W por canal
    state         <= MAC_PAD_REG;
elsif kw < kw_size - 1 then                    -- siguiente columna del kernel
    kw <= kw + 1;
    act_ic_offset <= act_tile_base;            -- reset al inicio del ic_tile
elsif kh < kh_size - 1 then                    -- siguiente fila del kernel
    kh <= kh + 1;
    act_kh_offset <= act_kh_offset + cfg_w_in; -- saltar 1 fila del input
else
    state <= IC_TILE_ADV;                      -- tile completo
```

**Línea 829** es la que confirma NCHW: `act_ic_offset += hw_reg` donde `hw_reg = h_in × w_in`. Cada canal siguiente está H×W bytes más adelante (planos separados).

### 1.4 IC Tiling — líneas 855-869

```vhdl
-- IC_TILE_ADV: si quedan más tiles de canales de entrada
if (ic_tile_base + cfg_ic_tile_size) < cfg_c_in then
    ic_tile_base  <= ic_tile_base + cfg_ic_tile_size;
    act_tile_base <= act_tile_base + cfg_ic_tile_size * hw_reg;
    state <= WL_NEXT;           -- recarga pesos del siguiente ic_tile
else
    state <= MAC_DONE_WAIT;     -- todos los ic_tiles → requantize
```

**Clave**: entre ic_tiles NO se hace `mac_clr`. Los acumuladores **mantienen** la suma parcial. Solo se requantize cuando todos los ic_tiles se han sumado. Esto es lo que hace que IC tiling sea correcto aritméticamente: `acc = Σ_{tile} partial_sum[tile]`.

### 1.5 Requantize + escritura DDR — líneas 890-929

```vhdl
-- RQ_EMIT: alimenta los 32 acumuladores al requantize uno por uno
rq_acc_in <= mac_acc(rq_ch);   -- acumulador del canal rq_ch
rq_vi     <= '1';              -- pulso valid al requantize

-- RQ_CAPTURE: cuando requantize produce resultado (handshake, no 8 ciclos fijos)
if rq_vo = '1' then
    ddr_wr_addr  <= rq_wr_addr_r;           -- dirección de escritura
    ddr_wr_data  <= std_logic_vector(rq_out); -- byte int8 resultado
    ddr_wr_en    <= '1';
    rq_wr_addr_r <= rq_wr_addr_r + hw_out_reg;  -- +H_out×W_out (NCHW stride)
```

**Dirección de escritura (NCHW)**: `addr = cfg_addr_output + oc*h_out*w_out + oh*w_out + ow`. Los canales de salida están separados por `hw_out_reg` bytes.

### 1.6 Padding asimétrico — líneas 764-774

```vhdl
-- MAC_PAD_REG: chequea si el pixel (ih+kh, iw+kw) está fuera del input
v_ih := ih_base + kh;
v_iw := iw_base + kw;
if v_ih < 0 or v_ih >= h_in or v_iw < 0 or v_iw >= w_in then
    pad_saved <= '1';    -- el MAC recibirá 0 en vez del byte real
else
    pad_saved <= '0';
```

Los pads se aplican implícitamente: si el pixel cae fuera, `mac_a <= 0` (L814-815). No se genera un borde explícito de zeros en memoria — el RTL lo maneja con la comparación.

### 1.7 Recursos

```
32 × mac_unit   = 32 DSP48E1 (multiplicación 9×8 por MAC)
1  × requantize = 4 DSP48E1  (mul_s32x32_pipe para acc×M0)
1  × weight_buf BRAM = 32 KB (wb_ram: array of signed 8)
Total: 36 DSP, ~1 BRAM, ~2000 LUTs, WNS +0.6ns @ 100 MHz
```

### 1.8 Reglas de diseño (comentarios L75-81)

1. Reset síncrono dentro de rising_edge
2. Máximo 1 multiplicación por ciclo
3. Carry chains < 30 bits por etapa
4. Sin cadenas combinacionales mult+add
5. Interfaz DDR de 1 ciclo de latencia (EMIT→WAIT→CAPTURE)
6. Reusa mac_array y requantize sin tocarlos

---

## 2. dpu_exec_tiled.c (335 líneas) — Tiling H+W del ARM

### 2.1 Funciones

| Función | Líneas | Rol |
|---|---|---|
| `compute_tile_size()` | 72-94 | Calcula H_TILE×W_TILE máximo que cabe en 4 KB BRAM |
| `run_one_tile()` | 97-196 | Ejecuta UN sub-tile: prepara scratch → DMA → start → drain |
| `dpu_exec_conv_tiled()` | 208-327 | Loop doble oh0/ow0 con pads asimétricos por tile |

### 2.2 `compute_tile_size()` — L72-94

```c
for (int t = 32; t >= 1; t--) {
    int in_h = (stride == 2) ? (2*t + kh - 1) : (t + kh - 1);
    int in_bytes  = in_h * in_h * c_in;
    int out_bytes = t * t * c_out;
    if (ALIGN(in_bytes) + ALIGN(out_bytes) <= room) {
        *h_tile = t; *w_tile = t;
        return 1;
    }
}
```

Prueba tiles cuadrados de 32×32 hasta 1×1. Para layer 0 (c_in=3, c_out=32, k=3, s=1): room = 4096 - ALIGN(864) - ALIGN(128) - 128 = 2944. Tile 8×8: in=10×10×3=300, out=8×8×32=2048 → 2368 ≤ 2944 ✓.

### 2.3 Loop del tiling — L248-328

```
for oh0 = 0 .. h_out step H_TILE:
    for ow0 = 0 .. w_out step W_TILE:
        1. Calcular ih_start = oh0*stride - pad
        2. Calcular pads asimétricos por tile (pad_t, pad_b, pad_l, pad_r)
        3. Extraer sub-input NCHW → tile_in_buf     [BUG 4 ARREGLADO]
        4. run_one_tile(dma, L, dims, pads, tile_in_buf, weights, bias, tile_out_buf)
        5. Copiar tile_out_buf → output global NCHW  [BUG 5 ARREGLADO]
```

### 2.4 BRAM layout de un tile (dentro de run_one_tile)

```
┌──────────────────────────┐ offset 0x000
│  OUTPUT zone (zeros)     │ tile_c_out × tile_h × tile_w bytes
├──────────────────────────┤ IN_OFF (aligned 64)
│  INPUT sub-tile          │ c_in × in_h_real × in_w_real bytes NCHW
├──────────────────────────┤ W_OFF (aligned 64)
│  WEIGHTS (c_out×k×k×c_in)│ 864 B para layer 0 (OHWI)
├──────────────────────────┤ B_OFF (aligned 64)
│  BIAS (c_out × 4)       │ 128 B para layer 0
└──────────────────────────┘ TOT (≤ 4096)
```

### 2.5 Bloqueador: IC tiling

Si `ALIGN(w_bytes) + ALIGN(b_bytes) + 256 >= 4096`, los pesos solos no caben → `compute_tile_size` retorna 0 → `DPU_ERR_TILING`.

Layer 2: w_bytes = 64×3×3×32 = 18432 >> 4096. **No cabe.**

Fix: dividir c_in en ic_tiles, cargar solo `c_out × k × k × ic_tile_size` pesos por sub-ejecución. El RTL ya lo soporta vía `cfg_ic_tile_size`.

---

## 3. eth_server.c (582 líneas) — Servidor TCP

### 3.1 Arquitectura

```
lwIP on_accept()
    │
    └─▶ on_recv() ──▶ State machine:
                       ST_IDLE ──▶ header 8B ──▶ dispatch:
                       │                          ├── WRITE_DDR: ST_STREAM_BYTES
                       │                          ├── CMD pequeño: ST_RECV_SMALL
                       │                          └── CMD sin payload: dispatch directo
                       │
                       ST_STREAM_BYTES ── memcpy directo a DDR (sin buffer)
                       │                 ── streaming_finalize + DCacheFlush
                       │
                       ST_RECV_SMALL ── acumula en payload[64]
                                     ── dispatch_small:
                                        ├── handle_cmd_exec_layer
                                        ├── handle_cmd_read_ddr (async con pending)
                                        ├── handle_cmd_ping
                                        └── ...
```

### 3.2 handle_cmd_exec_layer — L165-300 (lo más importante)

```c
// 1. Lee layer_cfg_t (72 B) de DDR
Xil_DCacheInvalidateRange(cfg_addr, 72);
memcpy(&cfg, (void *)cfg_addr, 72);

// 2. Override opcional: si PC manda dims != 0, sobrescribe LAYERS[i]
if (cfg.h_in != 0 && cfg.c_in != 0 ...) {
    L_local.c_in = cfg.c_in; ...
}

// 3. Dispatch por op_type del firmware (NO del cfg)
switch (L->op_type) {
    case OP_CONV:        dpu_exec_conv_tiled(L, in, w, b, out, &prof);
    case OP_LEAKY_RELU:  dpu_exec_leaky(L, in, out, &prof);
    case OP_MAXPOOL:     dpu_exec_pool(L, in, out, &prof);
    case OP_ADD:         dpu_exec_add(L, in_a, in_b, out, &prof);
    case OP_CONCAT:      arm_concat(L, ...);
    case OP_RESIZE:      arm_upsample(L, ...);
}

// 4. CRC32 del output (FUERA del callback — seguro para lwIP)
out_crc = p18_crc32(out_addr, out_bytes);

// 5. Respuesta ACK con {status, cycles, out_crc, out_bytes}
eth_send_ack(tpcb, tag, status, extra, 12);
```

**Por qué CRC fuera del callback**: el V1 del firmware hacía CRC DENTRO de `on_recv` (durante streaming WRITE), lo que bloqueaba lwIP ~decenas de ms → 50% packet loss. En V0-extendido, el CRC se calcula en el handler de EXEC_LAYER, cuando el payload ya fue recibido y el cliente espera la respuesta → no hay tráfico concurrente.

### 3.3 Streaming WRITE_DDR — L340-400

```
PC manda: [header 8B][addr 4B][data N bytes]

on_recv ve opcode=WRITE_DDR → ST_STREAM_BYTES:
  1. Primeros 4 bytes → dirección DDR destino
  2. Bytes siguientes → memcpy directo a DDR (sin buffer intermedio)
  3. Al terminar: Xil_DCacheFlushRange → ACK
```

Throughput: 44 MB/s medido (vs 0.22 MB/s por JTAG = **200× speedup**).

### 3.4 on_sent callback para READ_DDR grande

```c
// eth_send_raw_async: si tcp_sndbuf se llena, guarda lo pendiente
c->pending_ptr = p;
c->pending_len = len;

// on_sent: lwIP llama cuando libera espacio
if (c->pending_len > 0) {
    eth_send_raw_async(tpcb, c, c->pending_ptr, c->pending_len);
}
```

Sin esto, READ_DDR de >2 KB cortaba porque lwIP tiene tcp_sndbuf ~4 KB.

---

## 4. conv_engine_v3_layer0_tb.vhd — Testbench XSIM

### 4.1 Qué verifica

Conv_engine_v3 standalone (sin wrapper) con vectores REALES del ONNX YOLOv4:
- Input: 4×4×3 NCHW (esquina de layer_001.bin)
- Weights: 32×3×3×3 OHWI (del extract_weights_blob.py)
- Bias: 32 × int32 LE
- Expected: 4×4×32 NCHW (calculado por Python, match ONNX)

### 4.2 Modelo DDR (lección aprendida)

```vhdl
-- PATRÓN CORRECTO: servir DDR dentro del stim process
for t in 0 to 5000000 loop
    wait until rising_edge(clk);
    if ddr_rd_en = '1' then
        ddr_rd_data <= mem(to_integer(ddr_rd_addr));  -- 1 ciclo latencia
    end if;
    if ddr_wr_en = '1' then
        mem(to_integer(ddr_wr_addr)) := ddr_wr_data;
    end if;
    if done = '1' then exit; end if;
end loop;
```

**PATRÓN INCORRECTO** (mi primer intento — producía 'X'):
```vhdl
-- Process separado con signal rd_data_reg → timing ambiguo, valores 'U'
p_ddr : process(clk)
    if rising_edge(clk) then
        rd_data_reg <= mem(addr);   -- ← puede quedar en 'U' durante bootstrap
    end if;
```

### 4.3 Resultado

```
=== RESULT: 512/512 bytes OK, 0 mismatches ===
```

**Esto prueba que el RTL es correcto contra ONNX.** Cualquier divergencia en el board es bug del firmware ARM (cache, formato, tiling), no del RTL.

---

## 5. Flujo completo end-to-end (diagrama consolidado)

```
PC Python                           ARM bare-metal                    FPGA RTL
─────────                           ──────────────                    ────────
                                                                      
yolov4_host.py                      eth_server.c                      dpu_stream_wrapper
  │                                   │                                 │
  ├─ write_ddr(weights 64MB) ──TCP──▶ memcpy→DDR                       │
  ├─ write_ddr(input 519KB)  ──TCP──▶ memcpy→DDR                       │
  ├─ write_ddr(cfg 72B)      ──TCP──▶ memcpy→DDR                       │
  │                                   │                                 │
  └─ exec_layer(0) ───────────TCP──▶ handle_cmd_exec_layer             │
                                      │                                 │
                                    dpu_exec_conv_tiled                 │
                                      │                                 │
                                    for each H+W tile:                  │
                                      │ Invalidate cache               │
                                      │ Extract sub-input NCHW         │
                                      │ Copy weights OHWI + bias       │
                                      │                                 │
                                    run_one_tile:                       │
                                      │ Program MMIO regs              │
                                      │ DMA MM2S ──────stream──▶ BRAM 4KB
                                      │ CTRL=start ────────────▶ conv_engine_v3
                                      │                                 │
                                      │                   32 MACs × (ic,kh,kw)
                                      │                   requantize → int8
                                      │                                 │
                                      │ DataMover S2MM ◀──stream── output
                                      │                                 │
                                      │ wait_done_latch                │
                                      │ wait_dm_done                   │
                                      │                                 │
                                    CRC32(output DDR)                   │
                                      │                                 │
  ◀──────── ACK{crc} ◀───TCP─────── eth_send_ack                      │
  │                                                                     
  compare crc vs ONNX ref                                               
  ✅ 0x8FACA837 == 0x8FACA837                                          
```
