# P_17 — Reporte de reutilización de primitivas

Análisis del código verificado de P_9 / P_11 / P_12 para decidir qué se reutiliza tal cual y qué hay que reescribir, SIN tocar los módulos core.

## Resumen ejecutivo

| Archivo | Estado | Acción en P_17 |
|---|---|---|
| `leaky_relu.vhd` (P_9) | ✅ Verificado HW | **Reutilizar INTACTO** |
| `elem_add.vhd` (P_11) | ✅ Verificado HW | **Reutilizar INTACTO** |
| `maxpool_unit.vhd` (P_12) | ✅ Verificado HW | **Reutilizar INTACTO** |
| `leaky_relu_stream.vhd` (P_9) | ⚠️ NO SIRVE para P_17 | **Re-escribir en dpu_stream_wrapper** |
| `elem_add_stream.vhd` (P_11) | ⚠️ NO SIRVE para P_17 | **Re-escribir en dpu_stream_wrapper** |
| `maxpool_stream.vhd` (P_12) | ⚠️ NO SIRVE para P_17 | **Re-escribir en dpu_stream_wrapper** |

**Los módulos base están perfectos. Los wrappers _stream.vhd son demos hardcoded que no sirven para un DPU multi-capa.**

## Problemas documentados en los _stream.vhd

### Problema #1 — Parámetros como GENERICS, no ports

**Evidencia** (`leaky_relu_stream.vhd:3-9`):
```vhdl
entity leaky_relu_stream is
    generic (
        X_ZP   : integer  := -17;
        Y_ZP   : integer  := -110;
        M0_POS : natural  := 881676063;
        M0_NEG : natural  := 705340861;
        N_POS  : natural  := 29;
        N_NEG  : natural  := 32
    );
```

**Mismo problema en `elem_add_stream.vhd:3-9`**:
```vhdl
generic (
    A_ZP    : integer  := -102;
    B_ZP    : integer  := -97;
    Y_ZP    : integer  := -102;
    M0_A_G  : natural  := 605961470;
    M0_B_G  : natural  := 715593500;
    N_SHIFT : natural  := 30
);
```

**Por qué está mal para P_17:**
Los generics son **constantes de compilación**. El bitstream queda fijado con los parámetros de una sola capa (layer_006 para leaky, layer_X para elem_add). Un DPU que debe ejecutar las ~170 capas de YOLOv4, cada una con M0/zp diferentes, necesita parámetros **vía puertos (runtime configurables)** — es decir registros AXI-Lite como ya hace el conv en P_16.

**Importante:** `leaky_relu.vhd` y `elem_add.vhd` **core** SÍ tienen los params como puertos (verificado en mi grep anterior). El problema es sólo el wrapper. Por eso los cores son reutilizables tal cual.

### Problema #2 — Eficiencia 25% en procesado de 32-bit stream

**Evidencia** (`leaky_relu_stream.vhd:48` y `65`):
```vhdl
x_in <= signed(s_axis_tdata(7 downto 0));   -- solo byte 0 del word de 32 bits
...
m_axis_tdata <= x"000000" & std_logic_vector(y_out);   -- emite 1 byte por word
```

**Mismo patrón en `elem_add_stream.vhd`**:
```vhdl
a_in <= signed(s_axis_tdata(7 downto 0));    -- byte 0 = A
b_in <= signed(s_axis_tdata(15 downto 8));   -- byte 1 = B
                                              -- bytes 2-3 desperdiciados
```

**Por qué está mal:**
- DMA entrega 4 bytes por ciclo (word 32-bit).
- Los wrappers consumen **1 byte por ciclo** (leaky) o **1 par A/B por ciclo** (elem_add).
- Ratio efectivo: **25%** del ancho de banda disponible.
- Para un DPU en serio: no aceptable.

**Lo correcto para P_17:** un SERDES 32→8→32 que unpack los 4 bytes del word y los procesa byte-a-byte en 4 ciclos (o paralelizando 4 copias del core — más DSPs pero 100% eficiente).

### Problema #3 — maxpool_stream hardcodea ventana 2×2

**Evidencia** (`maxpool_stream.vhd:38-41`):
```vhdl
type state_t is (
    ST_INPUT,       -- accept input words: clear / value / read
    ST_OUTPUT,      -- send captured max to output stream
    ST_DONE
);
```
FSM asume que cada 4 inputs consecutivos forman una ventana 2×2 (clear, val, val, val, read).

**Por qué está mal:**
- Solo soporta pool 2×2 con stride=2 "denso" (cada 4 bytes independientes).
- No maneja el layout real espacial: en una imagen H×W×C la ventana 2×2 toca bytes NO consecutivos (4 bytes separados por ancho × canales).
- Funcionó en la demo de P_12 porque el test envió exactamente esa secuencia pre-empaquetada.

**Lo correcto para P_17:** el wrapper orquesta las ventanas según H_in/W_in/C_in. Puede:
- opción A: usar BRAM para re-ordenar (costoso)
- opción B: procesar row-by-row con line-buffer tipo P_20 (complejo)
- opción C: confiar en que el ARM pre-ordena los bytes antes del DMA (simple, pero mueve trabajo al ARM)

Para una primera iteración → opción C. El ARM pre-empaqueta la secuencia "ventana 2×2 por ventana 2×2" y el wrapper sólo hace `clear; val; val; val; read` repetido.

## Módulos core (reutilizables intactos) — inventario

### `leaky_relu.vhd` (P_9)
Entity ports (todos como señales runtime):
```vhdl
x_in     : in  signed(7 downto 0);
valid_in : in  std_logic;
x_zp     : in  signed(7 downto 0);  -- runtime
y_zp     : in  signed(7 downto 0);
M0_pos   : in  unsigned(31 downto 0);
n_pos    : in  unsigned(5 downto 0);
M0_neg   : in  unsigned(31 downto 0);
n_neg    : in  unsigned(5 downto 0);
y_out    : out signed(7 downto 0);
valid_out: out std_logic;
```
✅ **Reutilizar tal cual**. Pipeline 8 etapas.

### `elem_add.vhd` (P_11)
Entity ports:
```vhdl
a_in, b_in : in  signed(7 downto 0);
valid_in   : in  std_logic;
a_zp, b_zp : in  signed(7 downto 0);
y_zp       : in  signed(7 downto 0);
M0_a, M0_b : in  unsigned(31 downto 0);
n_shift    : in  unsigned(5 downto 0);
y_out      : out signed(7 downto 0);
valid_out  : out std_logic;
```
✅ **Reutilizar tal cual**. Pipeline 8 etapas.

### `maxpool_unit.vhd` (P_12)
Entity ports:
```vhdl
x_in     : in  signed(7 downto 0);
valid_in : in  std_logic;
clear    : in  std_logic;
max_out  : out signed(7 downto 0);
valid_out: out std_logic;
```
✅ **Reutilizar tal cual**. Sin pipeline, comparación serial.

## Máquina de estados en P_17 (orquestación)

El wrapper P_17 tiene **una FSM master** (`dpu_stream_wrapper`) + sub-FSM por modo stream. Jerarquía:

```
         REG_LAYER_TYPE
               │
               ▼
      ┌────────────────┐
      │  Master FSM    │
      │  (S_IDLE       │
      │   S_LOAD       │
      │   S_CONV       │
      │   S_STREAM     │
      │   S_ELEM_ADD   │
      │   S_DRAIN)     │
      └───┬────────┬───┘
          │        │
  CONV    │        │  STREAM
  (random)│        │  (byte-a-byte pipeline)
          ▼        ▼
    ┌──────────┐  ┌────────────────────────────────┐
    │conv_eng_v3│  │ sub-FSM por primitiva:         │
    │(existente)│  │  S_INPUT:  capturar byte del    │
    │          │  │            word (serdes 0..3)   │
    │ driver de│  │  S_FEED:   valid_in=1, wait      │
    │ DDR R/W  │  │            pipeline              │
    │ directo  │  │  S_CAPTURE: acumular y_out byte │
    │ a BRAM   │  │            en reg 32-bit         │
    │          │  │  S_EMIT:   cuando tengamos 4     │
    │          │  │            bytes, tvalid=1       │
    └──────────┘  └────────────────────────────────┘
```

## Secuencia de datos / burst sizes

### Del Block Design actual P_16 (se mantiene en P_17)
```tcl
set_property -dict [list \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_mm2s_burst_size {256} \
    ...
] $dma
```
- **MM2S burst = 256 bytes** = 64 words × 32 bits.
- AXI-Stream tdata = **32 bits = 4 bytes/ciclo @ 100 MHz = 400 MB/s teóricos**
- Transfer length configurable por transfer (XAxiDma_SimpleTransfer)
- `tlast` indica fin de transfer

### Secuencia de bytes por primitiva

**CONV** (flujo P_16, inmutable):
```
[output_zone (zeros) | input HWC | weights OHWI | bias int32[c_out]]
  └── cargado entero a BRAM en 1 DMA transfer de n bytes
```

**LEAKY_RELU** (stream bypass BRAM):
```
byte_0 = x[h=0, w=0, c=0]
byte_1 = x[h=0, w=0, c=1]
byte_2 = x[h=0, w=0, c=2]
byte_3 = x[h=0, w=0, c=3]   ← 1 word 32-bit
byte_4 = x[h=0, w=0, c=4]
...
```
Empaquetamiento C-inner, H-outer (layout CHW consumido como HWC en el stream). Output mismo orden.

**MAXPOOL 2×2 s=2** (stream bypass BRAM, ARM pre-ordena):
```
Para cada ventana 2×2 de la imagen HWC:
  byte_0 = x[h, w, c]       ← CLEAR + VALUE
  byte_1 = x[h, w+1, c]      ← VALUE
  byte_2 = x[h+1, w, c]      ← VALUE
  byte_3 = x[h+1, w+1, c]    ← VALUE + READ (→ 1 byte output)
```
**Pre-ordenado desde C en el ARM.** El wrapper solo itera mecánicamente.

**ELEM_ADD** (stream + BRAM hybrid):
```
Fase 1 (LOAD): ARM pushes tensor A completo a BRAM via DMA.
               A en BRAM[0x000 .. 4095]
Fase 2 (RUN):  ARM pushes tensor B via DMA
               Wrapper lee BRAM(A[i]) + s_axis(B[i]) en paralelo
               elem_add consume ambos → emite y[i] al DataMover
```
Así evitamos el problema de interleave del elem_add_stream actual (que desperdicia 16 bits/word).

## Resumen de decisiones

1. **NO se toca ni una línea** de `leaky_relu.vhd`, `elem_add.vhd`, `maxpool_unit.vhd`.
2. **Se reescriben** los wrappers _stream.vhd dentro del nuevo `dpu_stream_wrapper.vhd` de P_17, con:
   - params por AXI-Lite (no generics)
   - SERDES 32→8→32 (usa los 4 bytes del word)
   - orquestación multi-primitiva desde master FSM
3. **ARM pre-ordena** la secuencia espacial para maxpool (no añadimos line-buffer HW por ahora).
4. **Burst MM2S** sigue en 256 B — sin cambios en el BD.
