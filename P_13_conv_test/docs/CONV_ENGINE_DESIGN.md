# Conv Engine — Diseño, Tiling y Optimizaciones

Documentación profunda de las dos versiones del conv_engine, las decisiones
de diseño, las máquinas de estados, el flujo de datos y las opciones de
optimización para soportar capas grandes.

---

## Índice

1. [Contexto y problema](#1-contexto-y-problema)
2. [Conv engine v1 — sin tiling](#2-conv-engine-v1--sin-tiling)
3. [Conv engine v2 — tiling pixel→ic_tile (elegida)](#3-conv-engine-v2--tiling-pixelic_tile-elegida)
4. [Otras opciones de tiling consideradas](#4-otras-opciones-de-tiling-consideradas)
5. [Resumen FSM v1](#5-resumen-fsm-v1)
6. [Resumen FSM v2](#6-resumen-fsm-v2)
7. [Flujo de datos](#7-flujo-de-datos)
8. [Tabla de compromisos](#8-tabla-de-compromisos)

---

## 1. Contexto y problema

### 1.1 La operación a ejecutar

Una capa **QLinearConv** de YOLOv4 INT8 ejecuta:

```
y[oc][oh][ow] = clamp(
    requantize(
        bias[oc] + Σ_kh Σ_kw Σ_ic ( (x[ic][ih][iw] - x_zp) × w[oc][kh][kw][ic] ),
        M0, n_shift, y_zp
    ),
    -128, 127
)
```

Donde:
- `oc`, `kh`, `kw`, `ic`, `oh`, `ow` son índices de filtro, kernel y pixel de salida
- `ih = oh*stride + kh - pad`, `iw = ow*stride + kw - pad`
- `x` son las activaciones (int8), `w` los pesos (int8)
- `requantize` es: `(acc * M0 + 2^(n-1)) >> n + y_zp`

### 1.2 Recursos disponibles en xc7z020 (ZedBoard)

| Recurso | Cantidad | Notas |
|---|---|---|
| DSP48E1 | 220 | usamos 32 (mac_array) + 4 (requantize) = 36 |
| BRAM18 | 280 (= 140 BRAM36) | ~245 KB total |
| LUTs | 53,200 | |
| FFs | 106,400 | |

### 1.3 El problema fundamental: tamaño de los pesos

| Capa | C_in | C_out | K | Pesos | ¿Cabe en 32 KB? |
|---|---|---|---|---|---|
| **layer_005** | 3 | 32 | 3×3 | 864 B | ✅ Sí |
| layer_010 | 32 | 64 | 3×3 | 18 KB | ✅ Apretado |
| layer_050 | 128 | 128 | 3×3 | 144 KB | ❌ No |
| **layer_148** | **1024** | **512** | **3×3** | **4.7 MB** | ❌ Para nada |

El conv_engine v1 carga **todos los pesos de la capa** en `weight_buf` (32 KB).
**Solo funciona con layer_005 y similares.** Para procesar capas grandes
necesitamos **tiling**: trocear la convolución en sub-convoluciones que
quepan en BRAM.

---

## 2. Conv engine v1 — sin tiling

### 2.1 Estructura

```
┌─────────────────────────────────────────────────────────────┐
│  conv_engine v1                                              │
│                                                              │
│  ┌──────────────┐                                            │
│  │ weight_buf   │  ← carga TODA la capa de DDR (864B/4.7MB)  │
│  │ (32 KB BRAM) │                                            │
│  └──────────────┘                                            │
│                                                              │
│  ┌──────────────┐                                            │
│  │ bias_buf     │  ← 32 valores int32 de bias               │
│  │ (registros)  │                                            │
│  └──────────────┘                                            │
│                                                              │
│  Pseudo-código:                                              │
│  1. Leer weight_buf de DDR (TODOS los pesos)                 │
│  2. Leer bias_buf de DDR                                     │
│  3. Para cada pixel (oh, ow):                                │
│     a. Clear mac_array                                       │
│     b. Load bias                                             │
│     c. Para cada (kh, kw, ic):                               │
│        - Leer activación de DDR                              │
│        - MAC pulse (32 oc en paralelo)                       │
│     d. Requantize 32 oc → escribir 32 bytes a DDR           │
│  4. Done                                                     │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Por qué no escala

- `weight_buf` está dimensionado a **32 KB constante**
- La FSM `WL_EMIT/WAIT/CAPTURE` lee bytes secuencialmente desde DDR
  hasta `w_total = c_out × c_in × kh × kw`
- Si `w_total > WB_SIZE`, **se pierden bytes** (overflow del array)
- Para cargar 4.7 MB necesitarías 4.7M × 3 ciclos = ~14M ciclos → **140 ms** solo cargando pesos por capa
- Y aún así, **no cabe** porque no hay 4.7 MB de BRAM en el chip

### 2.3 Veredicto

✅ **Útil para layer_005** (verificado bit-exacto en simulación con 32/32 PASS)
❌ **No usable para capas grandes** del modelo

---

## 3. Conv engine v2 — tiling pixel→ic_tile (elegida)

### 3.1 Idea

En vez de cargar **todos los pesos**, los procesamos por **tiles**:

- **`oc_tile_size = 32`** (fijo, igual que N_MAC). Procesa 32 filtros de salida en paralelo
- **`ic_tile_size`** (configurable por AXI-Lite). Cuántos canales de entrada por subconvolución

Para layer_148 con `ic_tile_size = 64`:
- `oc_tile_size = 32` → `oc_tile_count = 512 / 32 = 16`
- `ic_tile_size = 64` → `ic_tile_count = 1024 / 64 = 16`
- Tile de pesos = `32 × 64 × 9 = 18 KB` ← **cabe en weight_buf**

### 3.2 Estructura del loop (anidamiento)

```
Para cada oc_tile (0..c_out, paso 32):
    Para cada pixel (oh, ow):
        Clear mac_array
        Load bias[oc_tile..oc_tile+31]                          ← solo el subset

        Para cada ic_tile (0..c_in, paso ic_tile_size):
            Cargar weight_buf[ic_tile] de DDR (32 oc × ic_tile_size × 9)
            Para cada (kh, kw):
                Para cada ic dentro del tile:
                    Leer activación x[ic_tile + ic][ih][iw]
                    MAC pulse (los 32 oc en paralelo, ic_tile_size accumulations)

        Requantize 32 oc → escribir 32 bytes a DDR
```

### 3.3 Por qué este orden de loops

- **`pixel` ANTES de `ic_tile`**: el mac_array **NUNCA se limpia entre ic_tiles
  del mismo pixel** → no necesitamos scratch DDR para acc_partial
- **`oc_tile` el MÁS externo**: cada vez que cambia, recalculamos el bias
  base y la dirección base de pesos. Bias se carga 1 vez por (oc_tile, pixel)
- **`pixel` antes de `ic_tile`**: implica que **leemos los pesos del mismo
  tile MUCHAS veces** (1 vez por pixel)

### 3.4 Coste real (layer_148, h_out=w_out=416, capa intermedia)

```
DDR reads de pesos:
    18 KB × 173,056 pixels × 16 oc_tiles = 49 GB (!)

DDR reads de activaciones:
    27 × 173,056 pixels × 16 oc_tiles = 75 M reads = 75 MB

DDR writes de salida:
    32 × 173,056 pixels × 16 oc_tiles = 88 M writes = 88 MB
```

**TOTAL**: ~50 GB de bandwidth solo para pesos por capa. **A 100 MB/s de DDR
en ZedBoard, eso son 8 minutos por capa.** Muy lento, pero **funciona**.

### 3.5 Por qué la elegimos a pesar del coste

1. **Es la opción más simple** — apenas añade 2 estados nuevos al FSM v1
2. **Cero scratch DDR** — no necesita memoria intermedia
3. **Verificable rápidamente** — basta extender el TB del v1
4. **Útil como prueba conceptual** — demuestra que el tiling funciona
5. **Optimizable después** — la versión optimizada (loop swap o doble buffer)
   se puede hacer encima de esta sin cambiar las primitivas (`mac_array`,
   `requantize`)

### 3.6 Estado actual

- ✅ Código creado: `src/conv_engine_v2.vhd` (896 líneas, 36 estados)
- ✅ Compila sin errores
- ⏳ Pendiente: testbench que verifique con layer_005 (debe dar el mismo
  resultado que v1)
- ⏳ Pendiente: test con tile más pequeño que `c_in` para activar el tiling
  (ej. `ic_tile_size=2` con `c_in=3`)

---

## 4. Otras opciones de tiling consideradas

### 4.1 Opción A — Loop swap (`ic_tile` externo, `pixel` interno)

```
Para cada oc_tile (0..c_out, paso 32):
    Para cada ic_tile (0..c_in, paso ic_tile_size):
        Cargar weight_buf de DDR (UNA sola vez por (oc_tile, ic_tile))
        Para cada pixel (oh, ow):
            Para cada (kh, kw, ic):
                Leer activación
                MAC pulse → suma a acc_partial[oh][ow][oc_tile..oc_tile+31]
        Si es el ÚLTIMO ic_tile:
            Requantize y escribir
        Si no:
            Guardar acc_partial[oh][ow][oc_tile..oc_tile+31] en scratch DDR
```

**Ventaja**: pesos se leen **1 sola vez** por (oc_tile, ic_tile) → **bandwidth
de pesos cae a 4.7 MB por capa** (vs 50 GB).

**Inconveniente**: necesita **scratch DDR para acc_partial**:
- Tamaño: `h_out × w_out × oc_tile_size × 4 bytes`
- Para layer_148 (208×208 output, oc_tile=32): `208×208×32×4 = 5.5 MB`
- Cabe en DDR (Zynq tiene 512 MB) pero **no en BRAM**

**Complejidad FSM**:
- Añade 2 estados: `WRITE_ACC_PARTIAL`, `READ_ACC_PARTIAL`
- Necesita timeline distinta entre ic_tile=0 (carga bias y empieza desde 0),
  ic_tile=k (carga acc_partial desde DDR), e ic_tile=last (carga acc_partial
  + requantize + escribe salida)

**Veredicto**: Sería la siguiente optimización lógica si v2 demuestra ser
viable.

### 4.2 Opción B — Doble buffer ping-pong

```
weight_buf_A, weight_buf_B (cada uno de tamaño tile)

Mientras MAC trabaja con buf_A, DMA carga buf_B en background.
Al cambiar de tile: swap A↔B sin esperar.
```

**Ventaja**: oculta la latencia de carga de pesos. Si `T_load < T_compute`,
el DMA es invisible.

**Inconveniente**:
- Requiere **2× el tamaño de weight_buf** (64 KB en BRAM)
- Necesita **2 puertos DDR independientes** (DMA mientras MAC accede a otra zona)
- FSM mucho más compleja: hay que gestionar 2 contextos en paralelo

**Veredicto**: Es la opción "ideal" pero **demasiado compleja** para
un primer prototipo. Solo merece la pena si v2 demuestra que el cuello de
botella es la latencia de carga de pesos (no las direcciones DDR ni el cómputo).

### 4.3 Opción C — Replicar weight_buf en BRAMs paralelas

En vez de leer 1 peso por ciclo (1 BRAM port) durante MAC_WLOAD (32 ciclos
por step MAC), tener `weight_buf` replicado en 16 BRAMs duales = 32 ports
de lectura. Carga de pesos en **1 ciclo en vez de 32**.

**Ventaja**: acelera el inner loop del MAC ~30×.

**Inconveniente**:
- Multiplica el uso de BRAMs por 16
- Para layer_148 con tile de 18 KB → necesita 18 KB × 16 = **288 KB de BRAM**
- El xc7z020 tiene **245 KB total** → **no cabe**

**Veredicto**: Solo viable en FPGAs más grandes (KV260 tiene ~1 MB de BRAM).

---

## 5. Resumen FSM v1

### 5.1 Lista de estados (25)

```
IDLE
├── CALC_KK         ← kk_reg = kh × kw
├── CALC_HW         ← hw_reg = h_in × w_in
├── CALC_HW_OUT     ← hw_out_reg = h_out × w_out
├── CALC_STRIDE     ← w_stride_per_filter = c_in × kh × kw
├── CALC_TOTAL      ← w_total = c_out × w_stride
├── WL_EMIT         ← lectura DDR de pesos (1 byte)
│   ├── WL_WAIT
│   └── WL_CAPTURE  ← weight_buf[w_idx] <= dato; w_idx++
├── BL_EMIT         ← lectura DDR de bias (1 byte de 4)
│   ├── BL_WAIT
│   └── BL_CAPTURE  ← shift register; cuando 4 bytes → bias_buf[idx]
├── INIT_ROW        ← ow=0
├── INIT_PIXEL_1/2  ← clear, calcular act_base, rq_wr_addr_r
├── BIAS_LOAD       ← mac_lb=1
├── MAC_PAD_REG     ← calcular ih, iw, pad, act_addr_r
├── MAC_WLOAD       ← cargar 32 mac_b del weight_buf (1 por ciclo, 32 ciclos)
├── MAC_EMIT        ← lectura DDR de activación (si no padding)
│   ├── MAC_WAIT_DDR
│   ├── MAC_CAPTURE ← mac_a <= dato leído (con sign extension)
│   └── MAC_FIRE    ← mac_vi=1; avanzar contadores
├── MAC_DONE_WAIT/2 ← drenar pipeline mac (2 ciclos)
├── RQ_EMIT         ← rq_acc_in <= mac_acc[rq_ch]; rq_vi=1
│   └── RQ_CAPTURE  ← cuando rq_vo=1: escribir DDR; avanzar wr_addr
├── NEXT_PIXEL      ← ow++ o oh++
└── DONE_ST         ← done=1, vuelve a IDLE
```

### 5.2 Loops anidados (de más externo a más interno)

```
oh   ← INIT_ROW
  ow ← NEXT_PIXEL
    kh, kw, ic ← MAC_FIRE counters
```

### 5.3 Decisiones críticas

| Estado | Decisión | Por qué |
|---|---|---|
| `IDLE` | start='1' → arrancar | Trigger del ARM |
| `CALC_*` | secuencial, 1 mult/ciclo | Evitar timing violations |
| `WL_EMIT` | `w_idx < w_total`? | Sigue cargando pesos vs pasar a bias |
| `BL_EMIT` | `bias_word_idx < N_MAC`? | Sigue cargando bias vs empezar pixels |
| `BL_CAPTURE` | `bias_byte_idx == 3`? | Bias completo (4 bytes) → guardar como int32 |
| `MAC_PAD_REG` | `ih<0 ∨ ih≥h_in ∨ iw<0 ∨ iw≥w_in`? | Padding (mac_a=0) vs leer DDR |
| `MAC_WLOAD` | `wload_cnt == N_MAC-1`? | Pesos cargados → MAC_EMIT |
| `MAC_FIRE` | `ic<c_in-1 ∨ kw<kw_size-1 ∨ kh<kh_size-1`? | Avanzar dentro del kernel vs drain |
| `RQ_CAPTURE` | `rq_vo == '1'`? | Resultado listo → escribir DDR |
| `RQ_EMIT` | `rq_ch < N_MAC`? | Más canales o NEXT_PIXEL |
| `NEXT_PIXEL` | `ow<w_out-1 ∨ oh<h_out-1`? | Avanzar pixel vs DONE |

---

## 6. Resumen FSM v2

### 6.1 Lista de estados (36)

Igual que v1 con **8 estados nuevos** (marcados con 🆕):

```
IDLE
├── CALC_KK              ← kk_reg = kh × kw
├── CALC_HOUT_1          🆕 calcula h_out, w_out (por fases)
├── CALC_HOUT_2          🆕
├── CALC_HW              ← hw_reg = h_in × w_in
├── CALC_HW_OUT          ← hw_out_reg = h_out × w_out
├── CALC_W_FILTER        🆕 w_per_filter_full = c_in × kh × kw
├── CALC_TILE_STRIDE     🆕 tile_filter_stride = ic_tile_size × kh × kw
├── CALC_KW_CIN          🆕 kw_cin_reg = kw_size × c_in (precomputado)
├── OC_TILE_START        🆕 base_addr de bias y pesos del oc_tile actual
├── BL_EMIT/WAIT/CAPTURE ← cargar bias[oc_tile..oc_tile+31]
├── INIT_ROW
├── INIT_PIXEL_1/2/3     ← (3 fases en v2 vs 2 en v1)
├── BIAS_LOAD
├── WL_NEXT              🆕 setup direcciones del próximo tile de pesos
├── WL_EMIT/WAIT/CAPTURE ← cargar weight_buf SOLO con el tile actual
├── MAC_PAD_REG
├── MAC_WLOAD            ← carga 32 mac_b dentro del tile
├── MAC_EMIT/WAIT/CAPTURE/FIRE
├── IC_TILE_ADV          🆕 avanzar al siguiente ic_tile o pasar a requantize
├── MAC_DONE_WAIT/2
├── RQ_EMIT/CAPTURE
├── NEXT_PIXEL
├── OC_TILE_ADV          🆕 avanzar al siguiente oc_tile o DONE
└── DONE_ST
```

### 6.2 Loops anidados (de más externo a más interno)

```
oc_tile     ← OC_TILE_ADV         🆕 (loop nuevo, externo)
  oh        ← INIT_ROW
    ow      ← NEXT_PIXEL
      ic_tile ← IC_TILE_ADV       🆕 (loop nuevo, intermedio)
        kh, kw, ic_in_tile ← MAC_FIRE counters
```

### 6.3 Decisiones críticas (nuevas vs v1)

| Estado | Decisión | Por qué |
|---|---|---|
| `OC_TILE_START` | recalcular bias_addr, w_oc_base_addr | Cada oc_tile lee bloque distinto |
| `BL_EMIT` (v2) | solo lee 32 bias del oc_tile actual | No carga los 512 bias de la capa |
| `WL_NEXT` | calcular dirección del próximo ic_tile | Sigue siendo dentro del mismo oc_tile |
| `WL_EMIT` (v2) | lee `tile_size_bytes` (no `w_total`) | Solo carga el tile, no toda la capa |
| `IC_TILE_ADV` | `ic_tile_base + ic_tile_size < c_in`? | Más tiles para este pixel vs requantize |
| `OC_TILE_ADV` | `oc_tile_base + N_MAC < c_out`? | Más oc_tiles vs DONE |

### 6.4 Sutilezas del v2

1. **mac_array NO se limpia entre ic_tiles del mismo pixel**.
   El `clear` solo se da en `INIT_PIXEL_1`. Entre `IC_TILE_ADV` y la siguiente
   `WL_NEXT` el acumulador se mantiene → suma sobre todos los `ic_tiles`.

2. **El bias se carga UNA vez por (oc_tile, pixel)**.
   Cada pixel nuevo del mismo oc_tile vuelve a cargar bias_buf en el mac_array.

3. **Los pesos se cargan UNA vez por (oc_tile, pixel, ic_tile)**.
   Cada vez que cambias de pixel, vuelves a leer los pesos del primer ic_tile.
   Esto es lo que hace este enfoque ineficiente para capas grandes.

4. **Layout de pesos en DDR (CRÍTICO)**:
   `weights[oc][kh][kw][ic]` (OHWI). El offset de un peso individual es:
   ```
   addr = base + oc*(kh×kw×c_in) + kh*(kw×c_in) + kw*c_in + ic
   ```

---

## 7. Flujo de datos

### 7.1 Diagrama bloque (v2)

```
       DDR (modelo BRAM 4 KB en simulación / DDR3 real en HW)
        │
        │  read 1 byte/3 cycles
        ▼
   ┌─────────────────┐    ┌──────────────────┐
   │ weight_buf      │    │ bias_buf         │
   │ (BRAM 32 KB)    │    │ (registros 128B) │
   └─────────────────┘    └──────────────────┘
        │ 32 reads          │ array completo
        │ secuenciales      │
        ▼                   ▼
   ┌─────────────────────────────────────────────┐
   │              mac_array (32×)                │
   │  ┌───┐ ┌───┐ ┌───┐  ...  ┌───┐              │
   │  │MAC│ │MAC│ │MAC│       │MAC│              │
   │  └───┘ └───┘ └───┘       └───┘              │
   │  acc[0] acc[1] acc[2] ... acc[31]           │
   └─────────────────────────────────────────────┘
        │                   ▲
        │                   │ mac_a (broadcast)
        │                   │
        │                   └─────── DDR.activación
        │
        ▼ secuencial 32 ciclos
   ┌────────────────┐
   │ requantize     │  M0, n_shift, y_zp → clamp [-128, 127]
   └────────────────┘
        │
        ▼ int8
       DDR (output[oc][oh][ow])
```

### 7.2 Cronograma simplificado de un pixel (v2)

```
ciclo →

[CLEAR]
[BIAS_LOAD]
[WL_NEXT]                                  ← setup direcciones tile pesos
[WL_EMIT][WL_WAIT][WL_CAPTURE] × N_tile    ← carga weight_buf con tile
                                            (N_tile = 32 × ic_tile_size × 9 bytes)
PARA cada (kh, kw, ic_in_tile):            ← inner loop MAC
    [MAC_PAD_REG]                          ← calcula ih, iw, pad
    [MAC_WLOAD] × 32                       ← 32 ciclos para cargar 32 mac_b
    [MAC_EMIT][MAC_WAIT][MAC_CAPTURE]      ← lee 1 byte de activación
    [MAC_FIRE]                             ← 1 ciclo, mac_vi=1
[IC_TILE_ADV]                              ← ¿más ic_tiles?
    SI → vuelve a WL_NEXT
    NO → drain + requantize
[MAC_DONE_WAIT][MAC_DONE_WAIT2]
[RQ_EMIT][RQ_CAPTURE] × 32                 ← 32 canales requantize
[NEXT_PIXEL]
```

### 7.3 Ciclos por pixel (estimación grosso)

```
CLEAR + BIAS_LOAD = ~5
WL inner loop = N_tile × 3 = (32 × ic_tile_size × 9) × 3
              = 864 × ic_tile_size ciclos
              ≈ 55,000 ciclos para ic_tile_size=64
MAC inner loop por step = 32 (wload) + 4 (emit/wait/capture/fire) = 36
Steps por tile = ic_tile_size × kh × kw = 64 × 9 = 576
MAC total por tile = 576 × 36 = 20,736 ciclos
Tiles por pixel = c_in / ic_tile_size = 1024 / 64 = 16
Drain + RQ = 32 × 9 = 288

TOTAL POR PIXEL ≈ (55,000 + 20,736) × 16 + 288 = 1.21 M ciclos
```

A 100 MHz, **12 ms por pixel**. Con 416×416 pixels y 16 oc_tiles
externos: **1380 segundos por capa**. Inviable como output final, pero
**suficiente para validar correctness**.

---

## 8. Tabla de compromisos

### Comparación de las 4 opciones

| Característica | v1 (no tile) | v2 (pixel→ic) | A2 (loop swap) | B (doble buf) |
|---|---|---|---|---|
| **Líneas de código** | ~570 | 896 | ~1100 (est.) | ~1500 (est.) |
| **Estados FSM** | 25 | 36 | ~45 (est.) | ~60 (est.) |
| **BRAM usado** | 32 KB | 32 KB | 32 KB | 64 KB |
| **Scratch DDR** | 0 | 0 | 5.5 MB | 0 |
| **DDR bandwidth pesos (layer_148)** | N/A (no cabe) | 50 GB | **4.7 MB** | 4.7 MB |
| **Funciona con layer_148** | ❌ | ✅ (lento) | ✅ | ✅ (rápido) |
| **Tiempo capa_148 (estimado)** | N/A | ~25 min | ~20 s | ~5 s |
| **Complejidad de verificación** | Baja | Media | Alta | Muy alta |
| **Riesgo de bugs** | Verificado | Bajo (solo añade loops) | Medio (scratch + acc partial) | Alto (concurrencia) |

### Decisión tomada

**v2 (pixel→ic_tile)** porque:
1. Demuestra que el tiling funciona conceptualmente
2. Mínimo cambio sobre v1 (verificado bit-exacto)
3. Reusa todas las primitivas (mac_array, requantize) sin modificar
4. La verificación es fácil: cualquier capa que cabía en v1 debe dar
   exactamente el mismo resultado en v2 con `ic_tile_size = c_in`
5. **Una vez validada**, podemos pasar a A2 (loop swap) sin tirar nada
   porque las primitivas son las mismas

### Pendiente

- [ ] TB de v2 que verifique con layer_005 + `ic_tile_size = c_in` (sin tile real)
- [ ] TB de v2 que verifique con layer_005 + `ic_tile_size = 1` (todo es tile)
- [ ] TB de v2 con valores extremos
- [ ] Implementación en Vivado de v2 (synth + impl)
- [ ] Cuando v2 esté validado: estudio formal de A2 con scratch DDR
- [ ] Implementación de A2 en otra rama
