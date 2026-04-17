# P_18 DPU — RTL usado en el proyecto

Lista definitiva de los módulos VHDL que se sintetizan en el bitstream actual (`build/dpu_eth.runs/impl_1/dpu_eth_bd_wrapper.bit`), con qué cálculo hace cada uno y dónde está la complejidad.

Las fuentes las añade `src/create_bd.tcl` mediante `read_vhdl`.

---

## 1. Lista de archivos (11 archivos, ~4200 líneas VHDL)

| Archivo | Líneas | Proyecto origen | Rol |
|---|---:|---|---|
| `mac_unit.vhd` | 226 | P_13 | 1 MAC pipeline 2 etapas |
| `mac_array.vhd` | 227 | P_13 | 32× mac_unit en paralelo (OCP) |
| `mul_s32x32_pipe.vhd` | 147 | P_13 | Multiplicador 32×32→64 (4 DSP, 5 etapas) |
| `requantize.vhd` | 309 | P_13 | INT32 → INT8 (multiply-shift-saturate) |
| `conv_engine.vhd` | — | P_13 | v1 legacy, no se usa (compilado por compat) |
| `conv_engine_v2.vhd` | — | P_13 | v2 legacy, no se usa |
| `conv_engine_v3.vhd` | **963** | P_13 | **Pipeline CONV principal**, con IC tiling + padding asimétrico |
| `mul_s9xu30_pipe.vhd` | 119 | P_9 | Mult signed9 × unsigned30 → signed40 (2 DSP, 3 etapas) |
| `leaky_relu.vhd` | 365 | P_9 | LeakyRelu INT8 streaming |
| `maxpool_unit.vhd` | 128 | P_12 | MaxPool 2×2 streaming |
| `elem_add.vhd` | 321 | P_11 | Element-wise add cuantizado (residuales YOLOv4) |
| `dpu_stream_wrapper.vhd` | **1234** | P_18 | **TOP del DPU** — mux entre las 4 primitivas |
| `dm_s2mm_ctrl.vhd` | 196 | P_18 | Control AXI DataMover S2MM |

> Los `conv_engine.vhd` / `conv_engine_v2.vhd` se leen por retrocompatibilidad con testbenches; el bitstream final solo instancia `conv_engine_v3` a través del wrapper.

---

## 2. Arquitectura de alto nivel

```
  ┌─────────┐  AXI-Lite GP0 (regs)   ┌────────────────────────────────┐
  │  ARM    │───────────────────────▶│  dpu_stream_wrapper            │
  │ (PS)    │◀─── IRQ (done_latch)───│                                │
  │         │                        │   REG_LAYER_TYPE (0x54) ─┐     │
  └──┬──────┘                        │                          │     │
     │                               │  FSM dispatch:           │     │
     │ AXI4 HP0                      │    S_LOAD/DRAIN (legacy) │     │
     ▼                               │    S_CONV                │     │
  ┌─────────┐   AXI-Stream (DMA)     │    S_STREAM_LR/MP/EA     │     │
  │  DMA    │───────────────────────▶│              │           │     │
  │ MM2S    │                        │              ▼           │     │
  └─────────┘                        │   ┌─────────────────┐    │     │
                                     │   │ conv_engine_v3  │────┤     │
                                     │   │ leaky_relu      │    │     │
                                     │   │ maxpool_unit    │    │     │
                                     │   │ elem_add        │────┼──┐  │
                                     │   └─────────────────┘    │  │  │
                                     │                          ▼  │  │
                                     │          SERDES 32→8 / 8→32 │  │
                                     └──────────────────────────┼──┘  │
                                                                │     │
                                      AXI-Stream out  ◀─────────┘     │
                                             │                        │
                                             ▼                        │
                                    ┌─────────────────┐               │
                                    │  dm_s2mm_ctrl   │──▶ DataMover  │
                                    │  (cmd 72 bits)  │     S2MM → DDR│
                                    └─────────────────┘               │
                                                                      │
```

Dentro del wrapper hay un **BRAM 4 KB compartido** time-muxed: en `S_CONV` es propiedad del `conv_engine_v3` (RW aleatorio); en `S_LOAD/DRAIN/STREAM_*` lo usan los paths de datos.

---

## 3. Pipeline CONV (la primitiva más compleja)

### 3.1 `conv_engine_v3.vhd` — implementa QLinearConv

**Qué calcula:** Convolución cuantizada con bias + requantize por píxel.

```
y[oc, oh, ow] = requantize(
      Σ_{ic, kh, kw}  (x[ic, ih, iw] − x_zp) × w[oc, ic, kh, kw]
      + bias[oc],
  M0, n_shift, y_zp
)
```

**Dos loops de tiling anidados:**
- **OC (Output Channel)**: paralelo de 32 canales a la vez (N_MAC=32). Sin tiling explícito: un `oc_tile` fija 32 canales, se recorre todo el espacio (oh, ow), y luego salta al siguiente oc_tile.
- **IC (Input Channel)**: tiles de `ic_tile_size` canales para no pasarse de los 4 KB de BRAM del wrapper. Configurable (`cfg_ic_tile_size`). Entre ic_tiles los acumuladores NO se limpian → se suma en `acc` el producto parcial.

**FSM estados clave** (simplificado):

```
CALC_KK → CALC_HOUT → OC_TILE_START → BIAS_LOAD
   ↓
   INIT_PIXEL                                     ┐
   ↓                                              │ bucle
   WL_LOAD (carga pesos del ic_tile a weight_buf) │ por pixel
   ↓                                              │ (oh, ow)
   MAC_EMIT → MAC_WAIT_DDR → MAC_CAPTURE → MAC_FIRE (27× para 3×3)
   ↓
   IC_TILE_ADV (si quedan más ic_tiles para este píxel, vuelve a WL_LOAD)
   ↓
   MAC_DONE → RQ_EMIT → RQ_CAPTURE (8 ciclos de requantize)
   ↓
   NEXT_PIXEL                                    ┘
   ↓
   OC_TILE_ADV → (si quedan oc_tiles, vuelve a INIT_PIXEL)
   ↓
   DONE
```

**Recursos**: **36 DSP48E1** = 32 (MACs) + 4 (requantize.mul_s32x32_pipe), sobre 80 disponibles en Zynq-7020 = **45 % del total**. Weight/bias/activation buffers en BRAM (~44 KB).

**Padding asimétrico** (novedad v3 vs v2): soporta `pad_top / pad_bottom / pad_left / pad_right` independientes, necesario para `stride=2` en YOLOv4.

### 3.2 `mac_unit.vhd` — 1 MAC de 2 etapas

```vhdl
-- Etapa 1: multiplicación (1 DSP48E1, cabe en bloque 25×18)
product_r <= a_in * b_in;   -- signed 9 × signed 8 = signed 17

-- Etapa 2: acumulación (carry chain 32 bits)
acc_r <= acc_r + resize(product_r, 32);
```

`a_in` llega como `int8 − x_zp` (9 bits firmados). `b_in` es un peso INT8 con w_zp=0.

### 3.3 `mac_array.vhd` — 32× MAC en paralelo

```vhdl
gen_macs : for i in 0 to N_MAC-1 generate
    u_mac : entity work.mac_unit
        port map(a_in => a_in,        -- broadcast
                 b_in => b_in(i),     -- peso propio
                 bias_in => bias_in(i),
                 acc_out => acc_out(i));
end generate;
```

Todas reciben la misma activación; pesos y bias son distintos → **32 canales de salida en 1 ciclo**. Sin OCP harían 27 × 32 = 864 ciclos por píxel; con OCP, 27.

### 3.4 `mul_s32x32_pipe.vhd` — Multiplicador 32×32

Descompone en 4 productos parciales con A_H|A_L y B_H|B_L (18 bits bajos, 14 altos signed). 5 etapas de pipeline, 4 DSP48E1, carry explícito entre zonas de bits para evitar overflow intermedio. Timing WNS ≈ +1.99 ns @ 100 MHz. **1M+ tests verificados en HW (P_200).**

### 3.5 `requantize.vhd` — INT32 → INT8

8 etapas de pipeline:
1. `acc × M0` → signed 64 (5 etapas internas, 4 DSP)
2. `+ 2^(n-1)` (redondeo)
3. `>> n_shift` (barrel shifter 64 bits)
4. `+ y_zp` → saturar a [-128, 127]

```vhdl
with_zp := s7_shifted + resize(s7_yzp, 32);
if with_zp > 127 then       y_out <= to_signed(127, 8);
elsif with_zp < -128 then    y_out <= to_signed(-128, 8);
else                         y_out <= with_zp(7 downto 0);
end if;
```

---

## 4. Primitivas stream

### 4.1 `leaky_relu.vhd` — `y = x ≥ 0 ? x : α·x`

Dos ramas en paralelo, se selecciona con MUX al final:
- **Positiva**: `(x − x_zp) × M0_pos >> n_pos + y_zp`
- **Negativa**: `(x − x_zp) × M0_neg >> n_neg + y_zp`

Ambas usan `mul_s9xu30_pipe` (3 etapas, 2 DSP) → 4 DSP total. Latencia 8 ciclos desde `valid_in` hasta `valid_out`.

### 4.2 `maxpool_unit.vhd` — 2×2 max streaming

No tiene line buffer: recibe los 4 bytes de la ventana 2×2 secuencialmente (el reordering a secuencia 2×2 lo hace el wrapper en `S_STREAM_MP`). Implementación trivial:

```vhdl
if clear = '1' then          max_r <= -128;
elsif valid_in = '1' and x_in > max_r then
                             max_r <= x_in;
end if;
```

**Bug histórico fijado (P_12)**: `clear` tiene prioridad sobre `valid_in` → si el primer byte llega el mismo ciclo que `clear`, se pierde. Fix: pulsar `clear` un ciclo ANTES del byte 0.

0 DSP, ~8 LUTs.

### 4.3 `elem_add.vhd` — Add cuantizado YOLOv4

Para residuales `y = a + b` con distintas escalas:

```
y = clamp(
     ((a − a_zp)·M0_a + (b − b_zp)·M0_b) >> n_shift + y_zp,
     −128, 127
)
```

2× `mul_s9xu30_pipe` en paralelo (rama A y rama B), 4 DSP. Latencia 8 ciclos, compatible con `leaky_relu` (el wrapper usa el mismo contador). Los dos operandos llegan intercalados por el wrapper (FSM de 7 fases).

---

## 5. Top-level `dpu_stream_wrapper.vhd` (1234 líneas — el más importante)

### 5.1 Interfaces

| Interface | Ancho | Función |
|---|---|---|
| AXI-Lite GP0 | 32 bits | Registros de config + control (REG_LAYER_TYPE, pads, dims, M0, etc.) |
| AXI-Stream in | 32 bits | Recibe bytes desde el DMA MM2S (activaciones, pesos, bias) |
| AXI-Stream out | 32 bits | Emite salidas para el DataMover S2MM |
| BRAM interno | 1024×32 = 4 KB | Shared buffer — time-muxed entre conv_engine y paths stream |

### 5.2 FSM Top-level

```
S_IDLE
  │
  ├─ cmd_load  ──▶ S_LOAD           (LEGACY: escribe stream → BRAM)
  ├─ cmd_start ──▶ S_CONV           (conv_engine_v3 toma dueño del BRAM)
  ├─ cmd_drain ──▶ S_DRAIN          (LEGACY: lee BRAM → emite stream)
  │
  ├─ REG_LAYER_TYPE=leaky   ──▶ S_STREAM_LR   (bypass BRAM, SERDES 32→8→LR→8→32)
  ├─ REG_LAYER_TYPE=pool    ──▶ S_STREAM_MP
  └─ REG_LAYER_TYPE=add     ──▶ S_STREAM_EA   (FSM 7 fases, A+B intercalados)
```

### 5.3 SERDES 32 ↔ 8

Entrada: un word AXI de 32 b se descompone en 4 bytes, se envían 1 por ciclo a la primitiva (que opera en bytes).
Salida: 4 bytes consecutivos se empaquetan en 1 word de 32 b para el DataMover.

### 5.4 BRAM compartido (clave del diseño)

- Mismo RAMB36E1 (4 KB) lo usan conv_engine_v3 (RW aleatorio) en `S_CONV`, y el path `S_LOAD/S_DRAIN` (FIFO-like) en otros estados.
- Mux simple de puertos controlado por la FSM → ahorra recursos.

**Instancias internas:**

```vhdl
u_conv : entity work.conv_engine_v3 ...      -- línea 342
u_lr   : entity work.leaky_relu      ...      -- línea 400
u_mp   : entity work.maxpool_unit    ...      -- línea 421
u_ea   : entity work.elem_add        ...      -- línea 442
```

---

## 6. DataMover S2MM (`dm_s2mm_ctrl.vhd`)

Comando de 72 bits que se manda al AXI DataMover:

```
[71:68]  RSVD
[67:64]  TAG      (identificador del comando, 4 bits)
[63:32]  SADDR    (dirección DDR destino)
[31]     DRR
[30]     INCR     (dirección incremental, no fija)
[29:24]  DSA
[23]     EOF
[22:0]   BTT      (bytes to transfer, máximo ~8 MB)
```

FSM mínimo:

```
ST_IDLE
  │  (hay datos pendientes)
  ▼
ST_SEND_CMD            (empuja 72b al port cmd del DataMover, espera tready)
  │
  ▼
ST_WAIT_DONE           (espera status: {error, done, busy})
  │
  ▼
ST_IDLE
```

Status expuesto al ARM: `busy`, `done`, `error` (bit 0/1/2) → se comprueba por MMIO tras cada `exec_layer` en el firmware.

---

## 7. Cuentas de recursos (post-impl)

| Recurso | Uso | % del Zynq-7020 |
|---|---|---:|
| DSP48E1 | 36 (32 MAC + 4 requantize) + 4 (leaky) + 4 (elem_add) | **55 %** |
| RAMB36 | ~10 (wrapper 4 KB + buffers internos + FIFOs lwIP/DMA) | ~7 % |
| LUT | ~16.8 % (después del fix timing) | — |
| FF | ~12 % | — |
| WNS | **+0.609 ns** @ 100 MHz | — |

Las 4 primitivas comparten el BRAM del wrapper, así que NO hay 4× BRAM de 4 KB — solo uno.

---

## 8. Flujo de 1 capa CONV ejecutándose (secuencia temporal aprox)

```
1. PC → write_ddr(ADDR_CFG, cfg)
2. ARM → EXEC_LAYER(idx)
3. ARM → programa regs via AXI-Lite (cmd_load, pads, dims, M0, ...)
4. ARM → arranca DMA MM2S (in_addr, bytes = c_in·h_in·w_in + w_bytes + b_bytes)
5. Wrapper S_LOAD: recibe stream → BRAM
6. ARM → pulsa cmd_start → wrapper S_CONV
7. conv_engine_v3 itera:
     for oc_tile in (c_out/32):            # 32 canales en paralelo
         load bias (32 × 4 bytes)
         for (oh, ow) in (h_out × w_out):
             for ic_tile in (c_in / ic_tile_size):
                 load weights (ic_tile × 3 × 3 × 32 bytes)
                 for (kh, kw, ic) in (3 × 3 × ic_tile):
                     mac_array.valid_in = 1    # 32 MACs en 1 ciclo
             requantize.emit → m_axis_out (4 bytes / ciclo)
8. Wrapper levanta done_latch (IRQ → ARM)
9. DataMover S2MM: escribe la salida a DDR@out_addr
10. ARM → responde al PC con {cycles, out_crc, out_bytes}
```

**Latencia crítica por píxel**: 2 (MAC pipeline) + 8 (requantize) = **10 ciclos desde último MAC hasta primer byte out**.

**Throughput ideal**: 32 canales/píxel × 1 ciclo por suma + 27 ciclos 3×3 = **~30 ciclos por píxel × c_out/32**.

---

## 9. Puntos de falla conocidos / frágiles

| Componente | Problema | Estado |
|---|---|---|
| `conv_engine_v3` partial-tile | `ic_tile_size` no divisor de `c_in` hacía que `tile_filter_stride` no coincidiera con lo rellenado en weight_buf | **FIJO** (commit `conv_v3`: añadido estado WL_STRIDE) |
| `maxpool_unit` clear vs byte 0 | `clear` llega el mismo ciclo que el primer byte → byte 0 perdido | **FIJO** (wrapper pulsa clear 1 ciclo antes) |
| `elem_add` BRAM latency | Capture de A usaba `bram_dout` stale | **FIJO** (FSM 7 fases, fase 2 captura A, fase 3 captura B) |
| `mul_s32x32_pipe` signo bits altos | Una versión anterior perdía signo al combinar zonas | **FIJO** (P_200: 1M+ tests OK) |
| IC tiling con capas gordas (layer 148: 4.7 MB pesos) | No hay tiling suficiente; `TOT_BYTES > DPU_BRAM_BYTES` retorna `DPU_ERR_TILING` | **PENDIENTE** — no arreglable sin IC tiling >4 KB |

---

## 10. Referencias

- `src/create_bd.tcl` — cómo se añaden los sources y se arma el BD de Vivado.
- `sw/dpu_exec.c` — cómo el firmware programa los regs del wrapper (AXI-Lite) y arranca las primitivas.
- `docs/ESTRUCTURA_PROYECTO.md` — overview del proyecto completo.
- `docs/ETH_PROTOCOL_V1.md` — contrato Ethernet PC↔ARM.
